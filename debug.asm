section .data
    cuda_lib db "libcuda.so.1", 0
    ptx_path db "kernel.ptx", 0
    kernel_name db "simple_add", 0

    sym_cuInit db "cuInit", 0
    sym_cuDeviceGet db "cuDeviceGet", 0
    sym_cuCtxCreate db "cuCtxCreate_v2", 0
    sym_cuModuleLoadData db "cuModuleLoadData", 0
    sym_cuModuleGetFunction db "cuModuleGetFunction", 0
    sym_cuMemAlloc db "cuMemAlloc_v2", 0
    sym_cuMemcpyHtoD db "cuMemcpyHtoD_v2", 0
    sym_cuMemcpyDtoH db "cuMemcpyDtoH_v2", 0
    sym_cuLaunchKernel db "cuLaunchKernel", 0

    msg_init db "Initializing CUDA...", 10, 0
    msg_error db "Error at step with code: ", 0
    msg_file_error db "Failed to open or read PTX file", 10, 0
    msg_success db "Kernel executed successfully!", 10, 0
    msg_result db "Kernel results:", 10, 0
    msg_float db "000.00 ", 0  ; Template for float output
    newline db 10, 0

    ; Constants for float conversion
    ten dd 10.0
    
    point_five dd 0.5
    num_buf times 16 db 0 
    data_size equ 16           ; 4 floats (4 bytes each)
    
    ; Sample input data (4 floats)
    host_input dd 1.0, 2.0, 3.0, 4.0
    host_param_n dd 4          ; Number of elements

section .bss
    device resd 1
    context resq 1
    module resq 1
    kernel resq 1
    file_handle resd 1
    file_size resq 1
    file_buffer resq 1
    d_output resq 1
    d_input resq 1
    d_param_n resq 1           ; Device copy of param_n
    host_output resd 4         ; Output buffer on host
    params resq 3              ; Kernel parameters (input_ptr, output_ptr, n)

section .text
    extern dlopen
    extern dlsym
    extern exit
    extern dlerror
    extern malloc
    extern free

global _start
_start:
    ; Load CUDA library
    mov rdi, cuda_lib
    mov rsi, 2                ; RTLD_NOW
    call dlopen
    test rax, rax
    jz error_exit
    mov rbx, rax              ; Save library handle

    ; Initialize CUDA
    mov rdi, rbx
    mov rsi, sym_cuInit
    call dlsym
    mov r12, rax
    xor rdi, rdi              ; flags = 0
    call r12
    test rax, rax
    jnz error_cuda

    ; Get device
    mov rdi, rbx
    mov rsi, sym_cuDeviceGet
    call dlsym
    mov r12, rax
    lea rdi, [device]
    xor rsi, rsi              ; device 0
    call r12
    test rax, rax
    jnz error_cuda

    ; Create context
    mov rdi, rbx
    mov rsi, sym_cuCtxCreate
    call dlsym
    mov r12, rax
    lea rdi, [context]
    xor rsi, rsi              ; flags = 0
    mov edx, [device]
    call r12
    test rax, rax
    jnz error_cuda

    ; Load PTX module
    call read_ptx_file
    test rax, rax
    jz file_error

    mov rdi, rbx
    mov rsi, sym_cuModuleLoadData
    call dlsym
    mov r12, rax
    lea rdi, [module]
    mov rsi, [file_buffer]
    call r12
    test rax, rax
    jnz error_cuda

    ; Get kernel function
    mov rdi, rbx
    mov rsi, sym_cuModuleGetFunction
    call dlsym
    mov r12, rax
    lea rdi, [kernel]
    mov rsi, [module]
    mov rdx, kernel_name
    call r12
    test rax, rax
    jnz error_cuda

    ; Allocate device memory
    mov rdi, rbx
    mov rsi, sym_cuMemAlloc
    call dlsym
    mov r12, rax

    ; Allocate input buffer
    lea rdi, [d_input]
    mov rsi, data_size
    call r12
    test rax, rax
    jnz error_cuda

    ; Allocate output buffer
    lea rdi, [d_output]
    mov rsi, data_size
    call r12
    test rax, rax
    jnz error_cuda

    ; Allocate device copy of n
    lea rdi, [d_param_n]
    mov rsi, 4                ; sizeof(int)
    call r12
    test rax, rax
    jnz error_cuda

    ; Copy input data to device
    mov rdi, rbx
    mov rsi, sym_cuMemcpyHtoD
    call dlsym
    mov r12, rax
    mov rdi, [d_input]
    lea rsi, [host_input]
    mov rdx, data_size
    call r12
    test rax, rax
    jnz error_cuda

    ; Copy n to device
    mov rdi, [d_param_n]
    lea rsi, [host_param_n]
    mov rdx, 4
    call r12
    test rax, rax
    jnz error_cuda

    ; Setup kernel parameters
    lea rax, [d_input]
    mov [params], rax         ; input_ptr
    lea rax, [d_output]
    mov [params+8], rax       ; output_ptr
    lea rax, [d_param_n]
    mov [params+16], rax      ; n (device pointer)

    ; Launch kernel
    mov rdi, rbx
    mov rsi, sym_cuLaunchKernel
    call dlsym
    mov r12, rax

    sub rsp, 8                ; Stack alignment

    mov rdi, [kernel]         ; kernel function
    mov rsi, 1                ; gridDimX
    mov rdx, 1                ; gridDimY
    mov rcx, 1                ; gridDimZ
    mov r8, 4                 ; blockDimX (4 threads)
    mov r9, 1                 ; blockDimY

    push qword 0              ; extra
    push qword params         ; kernelParams
    push qword 0              ; hStream
    push qword 0              ; sharedMemBytes
    push qword 1              ; blockDimZ

    call r12
    add rsp, 48               ; Cleanup stack
    test rax, rax
    jnz error_cuda

    ; Copy results back to host
    mov rdi, rbx
    mov rsi, sym_cuMemcpyDtoH
    call dlsym
    mov r12, rax
    lea rdi, [host_output]
    mov rsi, [d_output]
    mov rdx, data_size
    call r12
    test rax, rax
    jnz error_cuda

    ; Print success message
    mov rdi, msg_success
    call print_str

    ; Print results header
    mov rdi, msg_result
    call print_str

    ; Print all 4 float values
    mov ecx, 4
    lea rbx, [host_output]
.print_loop:
    movss xmm0, [rbx]         ; Load float value
    call print_float_value
    
    add rbx, 4                ; Next float
    dec rcx
    jnz .print_loop

    ; Exit cleanly
    mov rdi, 0
    call exit

; Prints float value in xmm0
print_float_value:
    ; Convert float to integer and fractional parts
    movss xmm1, [point_five]
    addss xmm0, xmm1          ; Round to nearest integer
    
    cvttss2si eax, xmm0       ; Integer part
    cvtsi2ss xmm1, eax
    subss xmm0, xmm1          ; Fractional part
    
    ; Multiply fractional by 100
    movss xmm1, [ten]
    mulss xmm0, xmm1
    mulss xmm0, xmm1
    cvttss2si ebx, xmm0       ; Get 2 decimal digits
    
    ; Convert to ASCII
    lea rdi, [msg_float]
    
    ; Integer part (3 digits)
    mov esi, eax
    call format_digit
    mov byte [rdi+3], '.'     ; Decimal point
    
    ; Fractional part (2 digits)
    mov esi, ebx
    call format_digit
    
    ; Print the formatted float
    mov rdi, msg_float
    call print_str
    ret

; Helper: format 2-digit number at RDI+4 (for fractional part)
; or RDI (for integer part)
format_digit:
    mov eax, esi
    xor edx, edx
    mov ecx, 10
    div ecx                  ; AL = tens digit, AH = ones digit
    add al, '0'
    mov [rdi], al
    add ah, '0'
    mov [rdi+1], ah
    ret

; Read PTX file into memory
read_ptx_file:
    ; Open PTX file
    mov rdi, ptx_path     ; Parameter 1: filename
    mov rsi, 0            ; Parameter 2: O_RDONLY
    mov rax, 2            ; syscall: open
    syscall
    
    test rax, rax
    js .error
    
    ; Save file descriptor
    mov [file_handle], eax
    
    ; Get file size
    sub rsp, 144          ; Allocate space for stat struct
    mov rdi, rax          ; Parameter 1: file descriptor
    mov rsi, rsp          ; Parameter 2: stat buffer
    mov rax, 5            ; syscall: fstat
    syscall
    
    ; File size is at offset 48 in stat structure
    mov rax, [rsp + 48]
    mov [file_size], rax
    add rsp, 144          ; Restore stack
    
    ; Allocate buffer for file content
    mov rdi, [file_size]
    add rdi, 1            ; Add space for null terminator
    call malloc
    test rax, rax
    jz .error
    
    ; Save buffer pointer
    mov [file_buffer], rax
    
    ; Read file content
    mov rdi, [file_handle]
    mov rsi, rax          ; Parameter 2: buffer
    mov rdx, [file_size]  ; Parameter 3: count
    mov rax, 0            ; syscall: read
    syscall
    
    ; Add null terminator
    mov rax, [file_buffer]
    mov rcx, [file_size]
    mov byte [rax + rcx], 0
    
    ; Close file
    mov rdi, [file_handle]
    mov rax, 3            ; syscall: close
    syscall

    mov rax, 1            ; Return success
    ret

.error:
    xor rax, rax          ; Return failure
    ret

error_cuda:
    ; Print CUDA error message and error code
    mov rdi, msg_error
    call print_str
    mov rdi, rax
    call print_int
    mov rdi, newline
    call print_str
    
    ; Exit with error
    mov rdi, 1                ; Exit code for CUDA error
    call exit

print_int:
    mov rax, rdi              ; Number to print
    mov rdi, num_buf          ; Buffer for conversion
    mov rcx, 10               ; Base 10
    add rdi, 15               ; Start at end of buffer
    mov byte [rdi], 0         ; Null terminator
.loop:
    dec rdi
    xor rdx, rdx
    div rcx
    add dl, '0'
    mov [rdi], dl
    test rax, rax
    jnz .loop
    mov rdi, rdi              ; String to print
    call print_str
    ret

print_str:
    ; Calculate string length (null-terminated)
    mov rsi, rdi
    xor rcx, rcx
    not rcx
    xor al, al
    cld
    repne scasb
    not rcx
    dec rcx
    
    ; Print using write syscall
    mov rdx, rcx              ; String length
    mov rdi, 1                ; STDOUT
    mov rax, 1                ; syscall: write
    syscall
    ret

error_exit:
    ; Print dlopen/dlsym error
    call dlerror
    mov rdi, rax
    call print_str
    mov rdi, 1
    call exit

file_error:
    mov rdi, msg_file_error
    call print_str
    mov rdi, 1
    call exit