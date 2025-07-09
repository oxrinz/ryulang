; ModuleID = 'main'
source_filename = "main"

@ptx_str = global [73 x i8] c".version 8.4\0A.target sm_52\0A.address_size 64\0A.visible .entry main(\0A)\0A{\0A\0A}\0A", !dbg !0
@kernel_name = private unnamed_addr constant [5 x i8] c"main\00", align 1

define i32 @main(ptr %0, ptr %1) !dbg !1 {
entry:
  %2 = call i64 @cuInit(i64 0)
  %3 = call i64 @cudaCheckError(i64 %2, i64 0)
  %device = alloca i64, align 8
  %4 = call i64 @cuDeviceGet(ptr %device, i64 0)
  %5 = call i64 @cudaCheckError(i64 %4, i64 1)
  %context = alloca i64, align 8
  %load_device = load i64, ptr %device, align 4
  %6 = call i64 @cuCtxCreate_v2(ptr %context, i64 0, i64 %load_device)
  %7 = call i64 @cudaCheckError(i64 %6, i64 2)
  %d_output = alloca i64, align 8, !dbg !0
  %8 = call i64 @cuMemAlloc_v2(ptr %d_output, i64 8), !dbg !0
  %9 = call i64 @cudaCheckError(i64 %8, i64 4), !dbg !0
  %dereferenced_device_ptr = load i64, ptr %d_output, align 4, !dbg !0
  %10 = call i64 @cuMemcpyHtoD_v2(i64 %dereferenced_device_ptr, ptr inttoptr (i64 140737488321200 to ptr), i64 8), !dbg !0
  %11 = call i64 @cudaCheckError(i64 %10, i64 5), !dbg !0
  %d_output1 = alloca i64, align 8, !dbg !0
  %12 = call i64 @cuMemAlloc_v2(ptr %d_output1, i64 8), !dbg !0
  %13 = call i64 @cudaCheckError(i64 %12, i64 4), !dbg !0
  %dereferenced_device_ptr2 = load i64, ptr %d_output1, align 4, !dbg !0
  %14 = call i64 @cuMemcpyHtoD_v2(i64 %dereferenced_device_ptr2, ptr inttoptr (i64 140737488321200 to ptr), i64 8), !dbg !0
  %15 = call i64 @cudaCheckError(i64 %14, i64 5), !dbg !0
  %module = alloca i64, align 8, !dbg !0
  %16 = call i64 @cuModuleLoadData(ptr %module, ptr @ptx_str), !dbg !0
  %17 = call i64 @cudaCheckError(i64 %16, i64 3), !dbg !0
  %kernel = alloca i64, align 8, !dbg !0
  %load_module = load i64, ptr %module, align 4, !dbg !0
  %18 = call i64 @cuModuleGetFunction(ptr %kernel, i64 %load_module, ptr @kernel_name), !dbg !0
  %19 = call i64 @cudaCheckError(i64 %18, i64 8), !dbg !0
  %function_val = load i32, ptr %kernel, align 4, !dbg !0
  %kernel_params_array = alloca [2 x ptr], align 8, !dbg !0
  %element_ptr = getelementptr [2 x ptr], ptr %kernel_params_array, i64 0, i64 0, !dbg !0
  store ptr %d_output, ptr %element_ptr, align 8, !dbg !0
  %element_ptr3 = getelementptr [2 x ptr], ptr %kernel_params_array, i64 0, i64 1, !dbg !0
  store ptr %d_output1, ptr %element_ptr3, align 8, !dbg !0
  %20 = call i64 @cuLaunchKernel(i32 %function_val, i32 1, i32 1, i32 1, i32 2, i32 2, i32 1, i32 0, i32 0, ptr %kernel_params_array, ptr null), !dbg !0
  %21 = call i64 @cudaCheckError(i64 %20, i64 7), !dbg !0
  ret i32 0, !dbg !0
}

declare i64 @cuInit(i64)

define i64 @cudaCheckError(i64 %0, i64 %1) {
entry:
  %cmp = icmp eq i64 %0, 0
  br i1 %cmp, label %success, label %error

success:                                          ; preds = %entry
  ret i64 0

error:                                            ; preds = %entry
  call void @exit(i64 %0)
  unreachable
}

declare void @exit(i64)

declare i64 @cuDeviceGet(ptr, i64)

declare i64 @cuCtxCreate_v2(ptr, i64, i64)

declare i64 @cuMemAlloc_v2(ptr, i64)

declare i64 @cuMemcpyHtoD_v2(i64, ptr, i64)

declare i64 @cuModuleLoadData(ptr, ptr)

declare i64 @cuModuleGetFunction(ptr, i64, ptr)

declare i64 @cuLaunchKernel(i32, i32, i32, i32, i32, i32, i32, i32, i32, ptr, ptr)

!llvm.dbg.cu = !{!5}

!0 = !DILocation(line: 20, column: 5, scope: !1)
!1 = distinct !DISubprogram(name: "main", linkageName: "main", scope: !2, file: !2, line: 1, type: !3, spFlags: DISPFlagDefinition, unit: !5)
!2 = !DIFile(filename: "sb.ryu", directory: ".")
!3 = !DISubroutineType(types: !4)
!4 = !{}
!5 = distinct !DICompileUnit(language: DW_LANG_C, file: !2, producer: "TestCompile", isOptimized: false, runtimeVersion: 0, emissionKind: FullDebug, splitDebugInlining: false)
