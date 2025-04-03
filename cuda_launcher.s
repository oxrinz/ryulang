	.text
	.file	"cuda_launcher.ll"
	.globl	main                            # -- Begin function main
	.p2align	4, 0x90
	.type	main,@function
main:                                   # @main
	.cfi_startproc
# %bb.0:                                # %entry
	pushq	%r14
	.cfi_def_cfa_offset 16
	pushq	%rbx
	.cfi_def_cfa_offset 24
	pushq	%rax
	.cfi_def_cfa_offset 32
	.cfi_offset %rbx, -24
	.cfi_offset %r14, -16
	movl	$.Lcuda_lib, %edi
	movl	$2, %esi
	callq	dlopen@PLT
	testq	%rax, %rax
	je	.LBB0_16
# %bb.1:                                # %load_cuInit
	movq	%rax, %rbx
	movl	$.Lsym_cuInit, %esi
	movq	%rax, %rdi
	callq	dlsym@PLT
	xorl	%edi, %edi
	callq	*%rax
	testl	%eax, %eax
	jne	.LBB0_14
# %bb.2:                                # %load_cuDeviceGet
	movl	$.Lsym_cuDeviceGet, %esi
	movq	%rbx, %rdi
	callq	dlsym@PLT
	movl	$.Ldevice, %edi
	xorl	%esi, %esi
	callq	*%rax
	testl	%eax, %eax
	jne	.LBB0_14
# %bb.3:                                # %load_cuCtxCreate
	movl	$.Lsym_cuCtxCreate, %esi
	movq	%rbx, %rdi
	callq	dlsym@PLT
	movl	.Ldevice(%rip), %edx
	movl	$.Lcontext, %edi
	xorl	%esi, %esi
	callq	*%rax
	testl	%eax, %eax
	je	.LBB0_4
.LBB0_14:                               # %error_cuda
	movl	$.Lmsg_error, %edi
	jmp	.LBB0_15
.LBB0_16:                               # %error_exit
	callq	dlerror@PLT
	movq	%rax, %rdi
.LBB0_15:                               # %error_cuda
	callq	print_str@PLT
	movl	$1, %edi
	callq	exit@PLT
.LBB0_4:                                # %read_ptx_file
	callq	read_ptx_file@PLT
	testb	$1, %al
	je	.LBB0_17
# %bb.5:                                # %load_module
	movl	$.Lsym_cuModuleLoadData, %esi
	movq	%rbx, %rdi
	callq	dlsym@PLT
	movq	.Lfile_buffer(%rip), %rsi
	movl	$.Lmodule, %edi
	callq	*%rax
	testl	%eax, %eax
	jne	.LBB0_14
# %bb.6:                                # %get_kernel
	movl	$.Lsym_cuModuleGetFunction, %esi
	movq	%rbx, %rdi
	callq	dlsym@PLT
	movq	.Lmodule(%rip), %rsi
	movl	$.Lkernel, %edi
	movl	$.Lkernel_name, %edx
	callq	*%rax
	testl	%eax, %eax
	jne	.LBB0_14
# %bb.7:                                # %allocate_memory
	movl	$.Lsym_cuMemAlloc, %esi
	movq	%rbx, %rdi
	callq	dlsym@PLT
	movq	%rax, %r14
	movl	$.Ld_input, %edi
	movl	$16, %esi
	callq	*%rax
	testl	%eax, %eax
	jne	.LBB0_14
# %bb.8:                                # %allocate_output
	movl	$.Ld_output, %edi
	movl	$16, %esi
	callq	*%r14
	testl	%eax, %eax
	jne	.LBB0_14
# %bb.9:                                # %allocate_param_n
	movl	$.Ld_param_n, %edi
	movl	$4, %esi
	callq	*%r14
	testl	%eax, %eax
	jne	.LBB0_14
# %bb.10:                               # %copy_data
	movl	$.Lsym_cuMemcpyHtoD, %esi
	movq	%rbx, %rdi
	callq	dlsym@PLT
	movq	%rax, %r14
	movq	.Ld_input(%rip), %rdi
	movl	$.Lhost_input, %esi
	movl	$16, %edx
	callq	*%rax
	testl	%eax, %eax
	jne	.LBB0_14
# %bb.11:                               # %copy_param_n
	movq	.Ld_param_n(%rip), %rdi
	movl	$.Lhost_param_n, %esi
	movl	$4, %edx
	callq	*%r14
	testl	%eax, %eax
	jne	.LBB0_14
# %bb.12:                               # %setup_params
	movq	$.Ld_input, .Lparams(%rip)
	movq	$.Ld_output, .Lparams+8(%rip)
	movq	$.Ld_param_n, .Lparams+16(%rip)
	movl	$.Lsym_cuLaunchKernel, %esi
	movq	%rbx, %rdi
	callq	dlsym@PLT
	movq	.Lkernel(%rip), %rdi
	subq	$8, %rsp
	.cfi_adjust_cfa_offset 8
	movl	$1, %esi
	movl	$1, %edx
	movl	$1, %ecx
	movl	$4, %r8d
	movl	$1, %r9d
	pushq	$0
	.cfi_adjust_cfa_offset 8
	pushq	$.Lparams
	.cfi_adjust_cfa_offset 8
	pushq	$0
	.cfi_adjust_cfa_offset 8
	pushq	$0
	.cfi_adjust_cfa_offset 8
	pushq	$1
	.cfi_adjust_cfa_offset 8
	callq	*%rax
	addq	$48, %rsp
	.cfi_adjust_cfa_offset -48
	testl	%eax, %eax
	jne	.LBB0_14
# %bb.13:                               # %copy_results
	movl	$.Lsym_cuMemcpyDtoH, %esi
	movq	%rbx, %rdi
	callq	dlsym@PLT
	movq	.Ld_output(%rip), %rsi
	movl	$.Lhost_output, %edi
	movl	$16, %edx
	callq	*%rax
	testl	%eax, %eax
	jne	.LBB0_14
# %bb.18:                               # %print_results
	movl	$.Lmsg_success, %edi
	callq	print_str@PLT
	movl	$.Lmsg_result, %edi
	callq	print_str@PLT
	movss	.Lhost_output(%rip), %xmm0      # xmm0 = mem[0],zero,zero,zero
	callq	print_float_value@PLT
	movss	.Lhost_output+4(%rip), %xmm0    # xmm0 = mem[0],zero,zero,zero
	callq	print_float_value@PLT
	movss	.Lhost_output+8(%rip), %xmm0    # xmm0 = mem[0],zero,zero,zero
	callq	print_float_value@PLT
	movss	.Lhost_output+12(%rip), %xmm0   # xmm0 = mem[0],zero,zero,zero
	callq	print_float_value@PLT
	xorl	%edi, %edi
	callq	exit@PLT
.LBB0_17:                               # %file_error
	movl	$.Lmsg_file_error, %edi
	jmp	.LBB0_15
.Lfunc_end0:
	.size	main, .Lfunc_end0-main
	.cfi_endproc
                                        # -- End function
	.globl	print_str                       # -- Begin function print_str
	.p2align	4, 0x90
	.type	print_str,@function
print_str:                              # @print_str
	.cfi_startproc
# %bb.0:                                # %entry
	pushq	%rbx
	.cfi_def_cfa_offset 16
	.cfi_offset %rbx, -16
	movq	%rdi, %rbx
	callq	strlen@PLT
	movl	$1, %edi
	movq	%rbx, %rsi
	movq	%rax, %rdx
	callq	write@PLT
	popq	%rbx
	.cfi_def_cfa_offset 8
	retq
.Lfunc_end1:
	.size	print_str, .Lfunc_end1-print_str
	.cfi_endproc
                                        # -- End function
	.globl	print_float_value               # -- Begin function print_float_value
	.p2align	4, 0x90
	.type	print_float_value,@function
print_float_value:                      # @print_float_value
	.cfi_startproc
# %bb.0:                                # %entry
	pushq	%rbx
	.cfi_def_cfa_offset 16
	.cfi_offset %rbx, -16
	movss	.Lpoint_five(%rip), %xmm1       # xmm1 = mem[0],zero,zero,zero
	addss	%xmm0, %xmm1
	cvttss2si	%xmm1, %esi
	cvttps2dq	%xmm1, %xmm1
	cvtdq2ps	%xmm1, %xmm1
	subss	%xmm1, %xmm0
	movss	.Lten(%rip), %xmm1              # xmm1 = mem[0],zero,zero,zero
	mulss	%xmm1, %xmm0
	mulss	%xmm1, %xmm0
	cvttss2si	%xmm0, %ebx
	movl	$.Lmsg_float, %edi
	callq	format_digit@PLT
	movl	$.Lmsg_float+4, %edi
	movl	%ebx, %esi
	callq	format_digit@PLT
	movl	$.Lmsg_float, %edi
	callq	print_str@PLT
	popq	%rbx
	.cfi_def_cfa_offset 8
	retq
.Lfunc_end2:
	.size	print_float_value, .Lfunc_end2-print_float_value
	.cfi_endproc
                                        # -- End function
	.globl	format_digit                    # -- Begin function format_digit
	.p2align	4, 0x90
	.type	format_digit,@function
format_digit:                           # @format_digit
	.cfi_startproc
# %bb.0:                                # %entry
	movslq	%esi, %rcx
	imulq	$1374389535, %rcx, %rax         # imm = 0x51EB851F
	movq	%rax, %rdx
	shrq	$63, %rdx
	sarq	$37, %rax
	addl	%edx, %eax
	imull	$100, %eax, %edx
	subl	%edx, %ecx
	movslq	%ecx, %rcx
	imulq	$1717986919, %rcx, %rdx         # imm = 0x66666667
	movq	%rdx, %rsi
	shrq	$63, %rsi
	sarq	$34, %rdx
	addl	%esi, %edx
	leal	(%rdx,%rdx), %esi
	leal	(%rsi,%rsi,4), %esi
	subl	%esi, %ecx
	addb	$48, %al
	addb	$48, %dl
	addb	$48, %cl
	movb	%al, (%rdi)
	movb	%dl, 1(%rdi)
	movb	%cl, 2(%rdi)
	retq
.Lfunc_end3:
	.size	format_digit, .Lfunc_end3-format_digit
	.cfi_endproc
                                        # -- End function
	.globl	read_ptx_file                   # -- Begin function read_ptx_file
	.p2align	4, 0x90
	.type	read_ptx_file,@function
read_ptx_file:                          # @read_ptx_file
	.cfi_startproc
# %bb.0:                                # %entry
	pushq	%rbp
	.cfi_def_cfa_offset 16
	.cfi_offset %rbp, -16
	movq	%rsp, %rbp
	.cfi_def_cfa_register %rbp
	pushq	%rbx
	pushq	%rax
	.cfi_offset %rbx, -24
	movl	$.Lptx_path, %edi
	xorl	%esi, %esi
	callq	open@PLT
	testl	%eax, %eax
	js	.LBB4_3
# %bb.1:                                # %get_size
	movl	%eax, .Lfile_handle(%rip)
	movq	%rsp, %rbx
	leaq	-144(%rbx), %rsi
	movq	%rsi, %rsp
	movl	%eax, %edi
	callq	fstat@PLT
	movq	-96(%rbx), %rdi
	movq	%rdi, .Lfile_size(%rip)
	incq	%rdi
	callq	malloc@PLT
	testq	%rax, %rax
	je	.LBB4_3
# %bb.2:                                # %read_file
	movq	%rax, .Lfile_buffer(%rip)
	movl	.Lfile_handle(%rip), %ebx
	movq	.Lfile_size(%rip), %rdx
	movl	%ebx, %edi
	movq	%rax, %rsi
	callq	read@PLT
	movq	.Lfile_buffer(%rip), %rax
	movq	.Lfile_size(%rip), %rcx
	movb	$0, (%rax,%rcx)
	movl	%ebx, %edi
	callq	close@PLT
	movb	$1, %al
	jmp	.LBB4_4
.LBB4_3:                                # %error
	xorl	%eax, %eax
.LBB4_4:                                # %error
	leaq	-8(%rbp), %rsp
	popq	%rbx
	popq	%rbp
	.cfi_def_cfa %rsp, 8
	retq
.Lfunc_end4:
	.size	read_ptx_file, .Lfunc_end4-read_ptx_file
	.cfi_endproc
                                        # -- End function
	.type	.Lcuda_lib,@object              # @cuda_lib
	.section	.rodata,"a",@progbits
.Lcuda_lib:
	.asciz	"libcuda.so.1"
	.size	.Lcuda_lib, 13

	.type	.Lptx_path,@object              # @ptx_path
.Lptx_path:
	.asciz	"kernel.ptx"
	.size	.Lptx_path, 11

	.type	.Lkernel_name,@object           # @kernel_name
.Lkernel_name:
	.asciz	"simple_add"
	.size	.Lkernel_name, 11

	.type	.Lsym_cuInit,@object            # @sym_cuInit
.Lsym_cuInit:
	.asciz	"cuInit"
	.size	.Lsym_cuInit, 7

	.type	.Lsym_cuDeviceGet,@object       # @sym_cuDeviceGet
.Lsym_cuDeviceGet:
	.asciz	"cuDeviceGet"
	.size	.Lsym_cuDeviceGet, 12

	.type	.Lsym_cuCtxCreate,@object       # @sym_cuCtxCreate
.Lsym_cuCtxCreate:
	.asciz	"cuCtxCreate_v2"
	.size	.Lsym_cuCtxCreate, 15

	.type	.Lsym_cuModuleLoadData,@object  # @sym_cuModuleLoadData
	.p2align	4, 0x0
.Lsym_cuModuleLoadData:
	.asciz	"cuModuleLoadData"
	.size	.Lsym_cuModuleLoadData, 17

	.type	.Lsym_cuModuleGetFunction,@object # @sym_cuModuleGetFunction
	.p2align	4, 0x0
.Lsym_cuModuleGetFunction:
	.asciz	"cuModuleGetFunction"
	.size	.Lsym_cuModuleGetFunction, 20

	.type	.Lsym_cuMemAlloc,@object        # @sym_cuMemAlloc
.Lsym_cuMemAlloc:
	.asciz	"cuMemAlloc_v2"
	.size	.Lsym_cuMemAlloc, 14

	.type	.Lsym_cuMemcpyHtoD,@object      # @sym_cuMemcpyHtoD
.Lsym_cuMemcpyHtoD:
	.asciz	"cuMemcpyHtoD_v2"
	.size	.Lsym_cuMemcpyHtoD, 16

	.type	.Lsym_cuMemcpyDtoH,@object      # @sym_cuMemcpyDtoH
.Lsym_cuMemcpyDtoH:
	.asciz	"cuMemcpyDtoH_v2"
	.size	.Lsym_cuMemcpyDtoH, 16

	.type	.Lsym_cuLaunchKernel,@object    # @sym_cuLaunchKernel
.Lsym_cuLaunchKernel:
	.asciz	"cuLaunchKernel"
	.size	.Lsym_cuLaunchKernel, 15

	.type	.Lmsg_init,@object              # @msg_init
	.p2align	4, 0x0
.Lmsg_init:
	.asciz	"Initializing CUDA...\n"
	.size	.Lmsg_init, 22

	.type	.Lmsg_error,@object             # @msg_error
	.p2align	4, 0x0
.Lmsg_error:
	.asciz	"Error at step with code: "
	.size	.Lmsg_error, 26

	.type	.Lmsg_file_error,@object        # @msg_file_error
	.p2align	4, 0x0
.Lmsg_file_error:
	.asciz	"Failed to open or read PTX file\n"
	.size	.Lmsg_file_error, 33

	.type	.Lmsg_success,@object           # @msg_success
	.p2align	4, 0x0
.Lmsg_success:
	.asciz	"Kernel executed successfully!\n"
	.size	.Lmsg_success, 31

	.type	.Lmsg_result,@object            # @msg_result
	.p2align	4, 0x0
.Lmsg_result:
	.asciz	"Kernel results:\n"
	.size	.Lmsg_result, 17

	.type	.Lmsg_float,@object             # @msg_float
	.data
.Lmsg_float:
	.asciz	"000.00 "
	.size	.Lmsg_float, 8

	.type	.Lnewline,@object               # @newline
	.section	.rodata,"a",@progbits
.Lnewline:
	.asciz	"\n"
	.size	.Lnewline, 2

	.type	.Ldebug_temp,@object            # @debug_temp
.Ldebug_temp:
	.asciz	"Passed...\n"
	.size	.Ldebug_temp, 11

	.type	.Lten,@object                   # @ten
	.p2align	2, 0x0
.Lten:
	.long	0x41200000                      # float 10
	.size	.Lten, 4

	.type	.Lpoint_five,@object            # @point_five
	.p2align	2, 0x0
.Lpoint_five:
	.long	0x3f000000                      # float 0.5
	.size	.Lpoint_five, 4

	.type	.Lnum_buf,@object               # @num_buf
	.local	.Lnum_buf
	.comm	.Lnum_buf,16,1
	.type	.Lhost_input,@object            # @host_input
	.p2align	2, 0x0
.Lhost_input:
	.long	0x3f800000                      # float 1
	.long	0x40000000                      # float 2
	.long	0x40400000                      # float 3
	.long	0x40800000                      # float 4
	.size	.Lhost_input, 16

	.type	.Lhost_param_n,@object          # @host_param_n
	.p2align	2, 0x0
.Lhost_param_n:
	.long	4                               # 0x4
	.size	.Lhost_param_n, 4

	.type	.Ldevice,@object                # @device
	.local	.Ldevice
	.comm	.Ldevice,4,4
	.type	.Lcontext,@object               # @context
	.local	.Lcontext
	.comm	.Lcontext,8,8
	.type	.Lmodule,@object                # @module
	.local	.Lmodule
	.comm	.Lmodule,8,8
	.type	.Lkernel,@object                # @kernel
	.local	.Lkernel
	.comm	.Lkernel,8,8
	.type	.Lfile_handle,@object           # @file_handle
	.local	.Lfile_handle
	.comm	.Lfile_handle,4,4
	.type	.Lfile_size,@object             # @file_size
	.local	.Lfile_size
	.comm	.Lfile_size,8,8
	.type	.Lfile_buffer,@object           # @file_buffer
	.local	.Lfile_buffer
	.comm	.Lfile_buffer,8,8
	.type	.Ld_output,@object              # @d_output
	.local	.Ld_output
	.comm	.Ld_output,8,8
	.type	.Ld_input,@object               # @d_input
	.local	.Ld_input
	.comm	.Ld_input,8,8
	.type	.Ld_param_n,@object             # @d_param_n
	.local	.Ld_param_n
	.comm	.Ld_param_n,8,8
	.type	.Lhost_output,@object           # @host_output
	.local	.Lhost_output
	.comm	.Lhost_output,16,4
	.type	.Lparams,@object                # @params
	.local	.Lparams
	.comm	.Lparams,24,16
	.section	".note.GNU-stack","",@progbits
