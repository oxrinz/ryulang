define i32 @main() {
entry:
  %0 = call i32 @cuInit(i32 0)
  %1 = call i32 @cudaCheckError(i32 %0, i32 0)
  %device = alloca i32, align 4
  %2 = call i32 @cuDeviceGet(ptr %device, i32 0)
  %3 = call i32 @cudaCheckError(i32 %2, i32 1)
  %context = alloca i32, align 4
  %load_device = load i32, ptr %device, align 4
  %4 = call i32 @cuCtxCreate_v2(ptr %context, i32 0, i32 %load_device)
  %5 = call i32 @cudaCheckError(i32 %4, i32 2)
  %module = alloca i32, align 4
  %6 = call i32 @cuModuleLoadData(ptr %module, ptr @ptx_str)
  %7 = call i32 @cudaCheckError(i32 %6, i32 3)
  call void @print(ptr @string)
  %result_ptr = tail call ptr @malloc(i32 mul (i32 ptrtoint (ptr getelementptr (float, ptr null, i32 1) to i32), i32 3))
  %kernel = alloca i32, align 4
  %load_module = load i32, ptr %module, align 4
  %8 = call i32 @cuModuleGetFunction(ptr %kernel, i32 %load_module, ptr @kernel_name)
  %9 = call i32 @cudaCheckError(i32 %8, i32 8)
  %d_input = alloca i64, align 8
  %10 = call i32 @cuMemAlloc_v2(ptr %d_input, i64 48)
  %11 = call i32 @cudaCheckError(i32 %10, i32 4)
  %d_output = alloca i64, align 8
  %12 = call i32 @cuMemAlloc_v2(ptr %d_output, i64 48)
  %13 = call i32 @cudaCheckError(i32 %12, i32 4)
  %dereferenced_device_ptr = load i64, ptr %d_input, align 4
  %14 = call i32 @cuMemcpyHtoD_v2(i64 %dereferenced_device_ptr, ptr @array_data, i64 12)
  %15 = call i32 @cudaCheckError(i32 %14, i32 5)
  %function_val = load i32, ptr %kernel, align 4
  %kernel_params_array = alloca [1 x ptr], align 8
  store ptr %d_input, ptr %kernel_params_array, align 8
  %16 = call i32 @cuLaunchKernel(i32 %function_val, i32 1, i32 1, i32 1, i32 6, i32 1, i32 1, i32 0, i32 0, ptr %kernel_params_array, ptr null)
  %17 = call i32 @cudaCheckError(i32 %16, i32 7)
  %dereferenced_device_ptr1 = load i64, ptr %d_output, align 4
  %18 = call i32 @cuMemcpyDtoH_v2(ptr %result_ptr, i64 %dereferenced_device_ptr1, i64 12)
  %19 = call i32 @cudaCheckError(i32 %18, i32 6)
  %20 = call ptr @array_to_string(ptr %result_ptr, i64 3, i32 1)
  call void @print(ptr %20)
  ret i32 0
}
