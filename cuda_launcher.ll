; LLVM IR for CUDA initialization and kernel execution
; Module definition
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

; External function declarations
declare i8* @dlopen(i8*, i32) 
declare i8* @dlsym(i8*, i8*)
declare i8* @dlerror()
declare i8* @malloc(i64)
declare void @free(i8*)
declare void @exit(i32)

; Global string constants
@cuda_lib = private constant [13 x i8] c"libcuda.so.1\00"
@ptx_path = private constant [11 x i8] c"kernel.ptx\00"
@kernel_name = private constant [11 x i8] c"simple_add\00"

@sym_cuInit = private constant [7 x i8] c"cuInit\00"
@sym_cuDeviceGet = private constant [12 x i8] c"cuDeviceGet\00"
@sym_cuCtxCreate = private constant [15 x i8] c"cuCtxCreate_v2\00"
@sym_cuModuleLoadData = private constant [17 x i8] c"cuModuleLoadData\00"
@sym_cuModuleGetFunction = private constant [20 x i8] c"cuModuleGetFunction\00"
@sym_cuMemAlloc = private constant [14 x i8] c"cuMemAlloc_v2\00"
@sym_cuMemcpyHtoD = private constant [16 x i8] c"cuMemcpyHtoD_v2\00"
@sym_cuMemcpyDtoH = private constant [16 x i8] c"cuMemcpyDtoH_v2\00"
@sym_cuLaunchKernel = private constant [15 x i8] c"cuLaunchKernel\00"

@msg_init = private constant [22 x i8] c"Initializing CUDA...\0A\00"
@msg_error = private constant [26 x i8] c"Error at step with code: \00"
@msg_file_error = private constant [33 x i8] c"Failed to open or read PTX file\0A\00"
@msg_success = private constant [31 x i8] c"Kernel executed successfully!\0A\00"
@msg_result = private constant [17 x i8] c"Kernel results:\0A\00"
@msg_float = private global [8 x i8] c"000.00 \00"
@newline = private constant [2 x i8] c"\0A\00"

@debug_temp = private constant [11 x i8] c"Passed...\0A\00"

; Constants for float conversion
@ten = private constant float 10.0
@point_five = private constant float 0.5
@num_buf = private global [16 x i8] zeroinitializer
@host_input = private constant [4 x float] [float 1.0, float 2.0, float 3.0, float 4.0]
@host_param_n = private constant i32 4

; Global variables
@device = private global i32 0
@context = private global i64 0
@module = private global i64 0
@kernel = private global i64 0
@file_handle = private global i32 0
@file_size = private global i64 0
@file_buffer = private global i8* null
@d_output = private global i64 0
@d_input = private global i64 0
@d_param_n = private global i64 0
@host_output = private global [4 x float] zeroinitializer
@params = private global [3 x i64*] zeroinitializer

; Main function
define i32 @main() {
entry:
    ; Load CUDA library
    %cuda_lib_ptr = getelementptr [13 x i8], [13 x i8]* @cuda_lib, i64 0, i64 0
    %lib_handle = call i8* @dlopen(i8* %cuda_lib_ptr, i32 2)  ; RTLD_NOW = 2
    %lib_check = icmp eq i8* %lib_handle, null
    br i1 %lib_check, label %error_exit, label %load_cuInit

load_cuInit:
    ; Get cuInit function
    %sym_cuInit_ptr = getelementptr [8 x i8], [8 x i8]* @sym_cuInit, i64 0, i64 0
    %cuInit_fn = call i8* @dlsym(i8* %lib_handle, i8* %sym_cuInit_ptr)
    
    ; Call cuInit(0)
    %cuInit_typed = bitcast i8* %cuInit_fn to i32 (i32)*
    %cuInit_result = call i32 %cuInit_typed(i32 0)
    %cuInit_check = icmp ne i32 %cuInit_result, 0
    br i1 %cuInit_check, label %error_cuda, label %load_cuDeviceGet

load_cuDeviceGet:
    ; Get cuDeviceGet function
    %sym_cuDeviceGet_ptr = getelementptr [12 x i8], [12 x i8]* @sym_cuDeviceGet, i64 0, i64 0
    %cuDeviceGet_fn = call i8* @dlsym(i8* %lib_handle, i8* %sym_cuDeviceGet_ptr)
    
    ; Call cuDeviceGet(&device, 0)
    %cuDeviceGet_typed = bitcast i8* %cuDeviceGet_fn to i32 (i32*, i32)*
    %device_ptr = bitcast i32* @device to i32*
    %cuDeviceGet_result = call i32 %cuDeviceGet_typed(i32* %device_ptr, i32 0)
    %cuDeviceGet_check = icmp ne i32 %cuDeviceGet_result, 0
    br i1 %cuDeviceGet_check, label %error_cuda, label %load_cuCtxCreate

load_cuCtxCreate:
    ; Get cuCtxCreate function
    %sym_cuCtxCreate_ptr = getelementptr [14 x i8], [14 x i8]* @sym_cuCtxCreate, i64 0, i64 0
    %cuCtxCreate_fn = call i8* @dlsym(i8* %lib_handle, i8* %sym_cuCtxCreate_ptr)
    
    ; Call cuCtxCreate(&context, 0, device)
    %cuCtxCreate_typed = bitcast i8* %cuCtxCreate_fn to i32 (i64*, i32, i32)*
    %context_ptr = bitcast i64* @context to i64*
    %device_val = load i32, i32* @device
    %cuCtxCreate_result = call i32 %cuCtxCreate_typed(i64* %context_ptr, i32 0, i32 %device_val)
    %cuCtxCreate_check = icmp ne i32 %cuCtxCreate_result, 0
    br i1 %cuCtxCreate_check, label %error_cuda, label %read_ptx_file

read_ptx_file:
    %ptx_read_result = call i1 @read_ptx_file()
    br i1 %ptx_read_result, label %load_module, label %file_error

load_module:
    ; Get cuModuleLoadData function
    %sym_cuModuleLoadData_ptr = getelementptr [16 x i8], [16 x i8]* @sym_cuModuleLoadData, i64 0, i64 0
    %cuModuleLoadData_fn = call i8* @dlsym(i8* %lib_handle, i8* %sym_cuModuleLoadData_ptr)
    
    ; Call cuModuleLoadData(&module, file_buffer)
    %cuModuleLoadData_typed = bitcast i8* %cuModuleLoadData_fn to i32 (i64*, i8*)*
    %module_ptr = bitcast i64* @module to i64*
    %file_buffer_val = load i8*, i8** @file_buffer
    %cuModuleLoadData_result = call i32 %cuModuleLoadData_typed(i64* %module_ptr, i8* %file_buffer_val)
    %cuModuleLoadData_check = icmp ne i32 %cuModuleLoadData_result, 0
    br i1 %cuModuleLoadData_check, label %error_cuda, label %get_kernel

get_kernel:
    ; Get cuModuleGetFunction function
    %sym_cuModuleGetFunction_ptr = getelementptr [20 x i8], [20 x i8]* @sym_cuModuleGetFunction, i64 0, i64 0
    %cuModuleGetFunction_fn = call i8* @dlsym(i8* %lib_handle, i8* %sym_cuModuleGetFunction_ptr)
    
    ; Call cuModuleGetFunction(&kernel, module, kernel_name)
    %cuModuleGetFunction_typed = bitcast i8* %cuModuleGetFunction_fn to i32 (i64*, i64, i8*)*
    %kernel_ptr = bitcast i64* @kernel to i64*
    %module_val = load i64, i64* @module
    %kernel_name_ptr = getelementptr [11 x i8], [11 x i8]* @kernel_name, i64 0, i64 0
    %cuModuleGetFunction_result = call i32 %cuModuleGetFunction_typed(i64* %kernel_ptr, i64 %module_val, i8* %kernel_name_ptr)
    %cuModuleGetFunction_check = icmp ne i32 %cuModuleGetFunction_result, 0
    br i1 %cuModuleGetFunction_check, label %error_cuda, label %allocate_memory

allocate_memory:
    ; Get cuMemAlloc function
    %sym_cuMemAlloc_ptr = getelementptr [13 x i8], [13 x i8]* @sym_cuMemAlloc, i64 0, i64 0
    %cuMemAlloc_fn = call i8* @dlsym(i8* %lib_handle, i8* %sym_cuMemAlloc_ptr)
    %cuMemAlloc_typed = bitcast i8* %cuMemAlloc_fn to i32 (i64*, i64)*
    
    ; Allocate input buffer - cuMemAlloc(&d_input, data_size)
    %d_input_ptr = bitcast i64* @d_input to i64*
    %data_size = mul i64 4, 4 ; 4 floats * 4 bytes
    %cuMemAlloc_input_result = call i32 %cuMemAlloc_typed(i64* %d_input_ptr, i64 %data_size)
    %cuMemAlloc_input_check = icmp ne i32 %cuMemAlloc_input_result, 0
    br i1 %cuMemAlloc_input_check, label %error_cuda, label %allocate_output

allocate_output:
    ; Allocate output buffer - cuMemAlloc(&d_output, data_size)
    %d_output_ptr = bitcast i64* @d_output to i64*
    %cuMemAlloc_output_result = call i32 %cuMemAlloc_typed(i64* %d_output_ptr, i64 %data_size)
    %cuMemAlloc_output_check = icmp ne i32 %cuMemAlloc_output_result, 0
    br i1 %cuMemAlloc_output_check, label %error_cuda, label %allocate_param_n

allocate_param_n:
    ; Allocate device copy of n - cuMemAlloc(&d_param_n, sizeof(int))
    %d_param_n_ptr = bitcast i64* @d_param_n to i64*
    %cuMemAlloc_n_result = call i32 %cuMemAlloc_typed(i64* %d_param_n_ptr, i64 4)
    %cuMemAlloc_n_check = icmp ne i32 %cuMemAlloc_n_result, 0
    br i1 %cuMemAlloc_n_check, label %error_cuda, label %copy_data

copy_data:
    ; Get cuMemcpyHtoD function
    %sym_cuMemcpyHtoD_ptr = getelementptr [15 x i8], [15 x i8]* @sym_cuMemcpyHtoD, i64 0, i64 0
    %cuMemcpyHtoD_fn = call i8* @dlsym(i8* %lib_handle, i8* %sym_cuMemcpyHtoD_ptr)
    %cuMemcpyHtoD_typed = bitcast i8* %cuMemcpyHtoD_fn to i32 (i64, i8*, i64)*
    
    ; Copy input data to device - cuMemcpyHtoD(d_input, host_input, data_size)
    %d_input_val = load i64, i64* @d_input
    %host_input_ptr = bitcast [4 x float]* @host_input to i8*
    %cuMemcpyHtoD_input_result = call i32 %cuMemcpyHtoD_typed(i64 %d_input_val, i8* %host_input_ptr, i64 %data_size)
    %cuMemcpyHtoD_input_check = icmp ne i32 %cuMemcpyHtoD_input_result, 0
    br i1 %cuMemcpyHtoD_input_check, label %error_cuda, label %copy_param_n

copy_param_n:
    ; Copy n to device - cuMemcpyHtoD(d_param_n, host_param_n, sizeof(int))
    %d_param_n_val = load i64, i64* @d_param_n
    %host_param_n_ptr = bitcast i32* @host_param_n to i8*
    %cuMemcpyHtoD_n_result = call i32 %cuMemcpyHtoD_typed(i64 %d_param_n_val, i8* %host_param_n_ptr, i64 4)
    %cuMemcpyHtoD_n_check = icmp ne i32 %cuMemcpyHtoD_n_result, 0
    br i1 %cuMemcpyHtoD_n_check, label %error_cuda, label %setup_params

setup_params:
    ; Setup kernel parameters
    %params_ptr = bitcast [3 x i64*]* @params to i64**
    %params_0_ptr = getelementptr i64*, i64** %params_ptr, i64 0
    store i64* @d_input, i64** %params_0_ptr
    
    %params_1_ptr = getelementptr i64*, i64** %params_ptr, i64 1
    store i64* @d_output, i64** %params_1_ptr
    
    %params_2_ptr = getelementptr i64*, i64** %params_ptr, i64 2
    store i64* @d_param_n, i64** %params_2_ptr
    
    br label %launch_kernel

launch_kernel:
    
    ; Get cuLaunchKernel function
    %sym_cuLaunchKernel_ptr = getelementptr [15 x i8], [15 x i8]* @sym_cuLaunchKernel, i64 0, i64 0
    %cuLaunchKernel_fn = call i8* @dlsym(i8* %lib_handle, i8* %sym_cuLaunchKernel_ptr)
    
    ; Call cuLaunchKernel
    %cuLaunchKernel_typed = bitcast i8* %cuLaunchKernel_fn to i32 (i64, i32, i32, i32, i32, i32, i32, i64, i8*, i8*, i8**)*
    %kernel_val = load i64, i64* @kernel
    %params_cast = bitcast [3 x i64*]* @params to i8**

    %cuLaunchKernel_result = call i32 %cuLaunchKernel_typed(
    i64 %kernel_val,          ; function
    i32 1,                    ; gridDimX
    i32 1,                    ; gridDimY
    i32 1,                    ; gridDimZ
    i32 4,                    ; blockDimX
    i32 1,                    ; blockDimY
    i32 1,                    ; blockDimZ
    i64 0,                    ; sharedMemBytes
    i8* null,                 ; hStream
    i8** %params_cast,        ; kernelParams (CORRECT POSITION)
    i8* null                  ; extra
    )
    
    %cuLaunchKernel_check = icmp ne i32 %cuLaunchKernel_result, 0
    br i1 %cuLaunchKernel_check, label %error_cuda, label %copy_results

copy_results:
    ; Get cuMemcpyDtoH function
    %sym_cuMemcpyDtoH_ptr = getelementptr [15 x i8], [15 x i8]* @sym_cuMemcpyDtoH, i64 0, i64 0
    %cuMemcpyDtoH_fn = call i8* @dlsym(i8* %lib_handle, i8* %sym_cuMemcpyDtoH_ptr)
    
    ; Call cuMemcpyDtoH(host_output, d_output, data_size)
    %cuMemcpyDtoH_typed = bitcast i8* %cuMemcpyDtoH_fn to i32 (i8*, i64, i64)*
    %host_output_ptr = bitcast [4 x float]* @host_output to i8*
    %d_output_val = load i64, i64* @d_output
    %cuMemcpyDtoH_result = call i32 %cuMemcpyDtoH_typed(i8* %host_output_ptr, i64 %d_output_val, i64 %data_size)
    %cuMemcpyDtoH_check = icmp ne i32 %cuMemcpyDtoH_result, 0
    br i1 %cuMemcpyDtoH_check, label %error_cuda, label %print_results

print_results:
    ; Print success message
    %msg_success_ptr = getelementptr [30 x i8], [30 x i8]* @msg_success, i64 0, i64 0
    call void @print_str(i8* %msg_success_ptr)
    
    ; Print results header
    %msg_result_ptr = getelementptr [17 x i8], [17 x i8]* @msg_result, i64 0, i64 0
    call void @print_str(i8* %msg_result_ptr)
    
    ; Print all 4 float values
    %host_output_float_ptr = bitcast [4 x float]* @host_output to float*
    
    
    %elem0_ptr = getelementptr float, float* %host_output_float_ptr, i64 0
    %elem0 = load float, float* %elem0_ptr
    call void @print_float_value(float %elem0)
    
    
    %elem1_ptr = getelementptr float, float* %host_output_float_ptr, i64 1
    %elem1 = load float, float* %elem1_ptr
    call void @print_float_value(float %elem1)
    
    %elem2_ptr = getelementptr float, float* %host_output_float_ptr, i64 2
    %elem2 = load float, float* %elem2_ptr
    call void @print_float_value(float %elem2)
    
    %elem3_ptr = getelementptr float, float* %host_output_float_ptr, i64 3
    %elem3 = load float, float* %elem3_ptr
    call void @print_float_value(float %elem3)
    
    
    ; Exit cleanly
    call void @exit(i32 0)
    unreachable

error_cuda:
    ; Print CUDA error message and error code
    %msg_error_ptr = getelementptr [27 x i8], [27 x i8]* @msg_error, i64 0, i64 0
    call void @print_str(i8* %msg_error_ptr)
    
    ; Exit with error
    call void @exit(i32 1)
    unreachable

error_exit:
    ; Print dlopen/dlsym error
    %error_msg = call i8* @dlerror()
    call void @print_str(i8* %error_msg)
    call void @exit(i32 1)
    unreachable

file_error:
    ; Print file error message
    %msg_file_error_ptr = getelementptr [32 x i8], [32 x i8]* @msg_file_error, i64 0, i64 0
    call void @print_str(i8* %msg_file_error_ptr)
    call void @exit(i32 1)
    unreachable
}

; Helper function to print strings
define void @print_str(i8* %str) {
entry:
    %len = call i64 @strlen(i8* %str)
    
    ; Use write syscall: write(1, str, len)
    %write_result = call i64 @write(i32 1, i8* %str, i64 %len)
    ret void
}

; Write syscall
declare i64 @write(i32, i8*, i64)

; Helper function to print float value
define void @print_float_value(float %value) {
entry:
    ; Convert float to integer and fractional parts
    %point_five_val = load float, float* @point_five
    %rounded = fadd float %value, %point_five_val
    
    %int_part = fptosi float %rounded to i32
    %int_part_f = sitofp i32 %int_part to float
    %frac_part = fsub float %value, %int_part_f
    
    ; Multiply fractional by 100
    %ten_val = load float, float* @ten
    %frac_part_times_10 = fmul float %frac_part, %ten_val
    %frac_part_times_100 = fmul float %frac_part_times_10, %ten_val
    %frac_digits = fptosi float %frac_part_times_100 to i32
    
    ; Buffer for formatting float
    %msg_float_ptr = getelementptr [8 x i8], [8 x i8]* @msg_float, i64 0, i64 0
    
    ; Format integer part (3 digits)
    call void @format_digit(i8* %msg_float_ptr, i32 %int_part)


    ; Format fractional part (2 digits)
    %frac_output_ptr = getelementptr i8, i8* %msg_float_ptr, i64 4
    call void @format_digit(i8* %frac_output_ptr, i32 %frac_digits)
    
    ; Print the formatted float
    call void @print_str(i8* %msg_float_ptr)
    
    ret void
}

define void @format_digit(i8* %buffer, i32 %value) {
entry:
    ; For a 3-digit field (or 2-digit field for decimals)
    ; We need to handle hundreds, tens, and ones

    ; Get the digits
    %hundreds = sdiv i32 %value, 100
    %temp = srem i32 %value, 100
    %tens = sdiv i32 %temp, 10
    %ones = srem i32 %temp, 10
    
    ; Convert to ASCII
    %hundreds_ascii = add i32 %hundreds, 48  ; '0' is ASCII 48
    %tens_ascii = add i32 %tens, 48
    %ones_ascii = add i32 %ones, 48
    
    ; Store in buffer (assuming buffer has at least 3 positions)
    %hundreds_ptr = getelementptr i8, i8* %buffer, i64 0
    %tens_ptr = getelementptr i8, i8* %buffer, i64 1
    %ones_ptr = getelementptr i8, i8* %buffer, i64 2
    
    %hundreds_char = trunc i32 %hundreds_ascii to i8
    %tens_char = trunc i32 %tens_ascii to i8
    %ones_char = trunc i32 %ones_ascii to i8
    
    store i8 %hundreds_char, i8* %hundreds_ptr
    store i8 %tens_char, i8* %tens_ptr
    store i8 %ones_char, i8* %ones_ptr
    
    ret void
}

; Function to read PTX file into memory
define i1 @read_ptx_file() {
entry:
    ; Open PTX file using open syscall
    %ptx_path_ptr = getelementptr [11 x i8], [11 x i8]* @ptx_path, i64 0, i64 0
    %fd = call i32 @open(i8* %ptx_path_ptr, i32 0)  ; O_RDONLY = 0
    
    ; Check if open succeeded
    %open_check = icmp slt i32 %fd, 0
    br i1 %open_check, label %error, label %get_size

get_size:
    ; Store file descriptor
    store i32 %fd, i32* @file_handle
    
    ; Get file size using fstat syscall
    %stat_buf = alloca [144 x i8]  ; Allocate space for stat struct
    %stat_result = call i32 @fstat(i32 %fd, i8* %stat_buf)
    
    ; Extract file size from stat struct (offset 48)
    %size_ptr = getelementptr [144 x i8], [144 x i8]* %stat_buf, i64 0, i64 48
    %size_ptr_cast = bitcast i8* %size_ptr to i64*
    %file_size_val = load i64, i64* %size_ptr_cast
    
    ; Store file size
    store i64 %file_size_val, i64* @file_size
    
    ; Allocate buffer
    %file_size_plus_one = add i64 %file_size_val, 1
    %buffer = call i8* @malloc(i64 %file_size_plus_one)
    
    ; Check malloc result
    %malloc_check = icmp eq i8* %buffer, null
    br i1 %malloc_check, label %error, label %read_file

read_file:
    ; Store buffer pointer
    store i8* %buffer, i8** @file_buffer
    
    ; Read file using read syscall
    %fd_val = load i32, i32* @file_handle
    %file_size_val2 = load i64, i64* @file_size
    %read_result = call i64 @read(i32 %fd_val, i8* %buffer, i64 %file_size_val2)
    
    ; Add null terminator
    %file_buffer_val = load i8*, i8** @file_buffer
    %file_size_val3 = load i64, i64* @file_size
    %null_pos = getelementptr i8, i8* %file_buffer_val, i64 %file_size_val3
    store i8 0, i8* %null_pos
    
    ; Close file
    %close_result = call i32 @close(i32 %fd_val)
    
    ret i1 true  ; Success

error:
    ret i1 false  ; Failure
}

; Helper syscalls and libc functions for file operations
declare i32 @open(i8*, i32)
declare i32 @close(i32)
declare i64 @read(i32, i8*, i64)
declare i32 @fstat(i32, i8*)
declare i64 @strlen(i8*)