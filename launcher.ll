; ModuleID = 'test.c'
source_filename = "test.c"
target datalayout = "e-m:e-p270:32:32-p271:32:32-p272:64:64-i64:64-i128:128-f80:128-n8:16:32:64-S128"
target triple = "x86_64-unknown-linux-gnu"

@.str = private unnamed_addr constant [11 x i8] c"kernel.ptx\00", align 1
@.str.1 = private unnamed_addr constant [9 x i8] c"myKernel\00", align 1
@__const.main.x = private unnamed_addr constant [3 x i32] [i32 1, i32 2, i32 3], align 4

; Function Attrs: nounwind sspstrong uwtable
define noundef i32 @main() local_unnamed_addr #0 {
  %1 = alloca i32, align 4
  %2 = alloca ptr, align 8
  %3 = alloca ptr, align 8
  %4 = alloca ptr, align 8
  %5 = alloca i64, align 8
  %6 = alloca [3 x i32], align 4
  %7 = alloca [1 x ptr], align 8
  call void @llvm.lifetime.start.p0(i64 4, ptr nonnull %1) #4
  call void @llvm.lifetime.start.p0(i64 8, ptr nonnull %2) #4
  call void @llvm.lifetime.start.p0(i64 8, ptr nonnull %3) #4
  call void @llvm.lifetime.start.p0(i64 8, ptr nonnull %4) #4
  call void @llvm.lifetime.start.p0(i64 8, ptr nonnull %5) #4
  %8 = tail call i32 @cuInit(i32 noundef 0) #4
  %9 = call i32 @cuDeviceGet(ptr noundef nonnull %1, i32 noundef 0) #4
  %10 = load i32, ptr %1, align 4, !tbaa !5
  %11 = call i32 @cuCtxCreate_v2(ptr noundef nonnull %2, i32 noundef 0, i32 noundef %10) #4
  %12 = call i32 @cuModuleLoad(ptr noundef nonnull %3, ptr noundef nonnull @.str) #4
  %13 = load ptr, ptr %3, align 8, !tbaa !9
  %14 = call i32 @cuModuleGetFunction(ptr noundef nonnull %4, ptr noundef %13, ptr noundef nonnull @.str.1) #4
  call void @llvm.lifetime.start.p0(i64 12, ptr nonnull %6) #4
  call void @llvm.memcpy.p0.p0.i64(ptr noundef nonnull align 4 dereferenceable(12) %6, ptr noundef nonnull align 4 dereferenceable(12) @__const.main.x, i64 12, i1 false)
  %15 = call i32 @cuMemAlloc_v2(ptr noundef nonnull %5, i64 noundef 12) #4
  %16 = load i64, ptr %5, align 8, !tbaa !11
  %17 = call i32 @cuMemcpyHtoD_v2(i64 noundef %16, ptr noundef nonnull %6, i64 noundef 12) #4
  call void @llvm.lifetime.start.p0(i64 8, ptr nonnull %7) #4
  store ptr %5, ptr %7, align 8, !tbaa !9
  %18 = load ptr, ptr %4, align 8, !tbaa !9
  %19 = call i32 @cuLaunchKernel(ptr noundef %18, i32 noundef 1, i32 noundef 1, i32 noundef 1, i32 noundef 3, i32 noundef 1, i32 noundef 1, i32 noundef 0, ptr noundef null, ptr noundef nonnull %7, ptr noundef null) #4
  %20 = load i64, ptr %5, align 8, !tbaa !11
  %21 = call i32 @cuMemFree_v2(i64 noundef %20) #4
  %22 = load ptr, ptr %2, align 8, !tbaa !9
  %23 = call i32 @cuCtxDestroy_v2(ptr noundef %22) #4
  call void @llvm.lifetime.end.p0(i64 8, ptr nonnull %7) #4
  call void @llvm.lifetime.end.p0(i64 12, ptr nonnull %6) #4
  call void @llvm.lifetime.end.p0(i64 8, ptr nonnull %5) #4
  call void @llvm.lifetime.end.p0(i64 8, ptr nonnull %4) #4
  call void @llvm.lifetime.end.p0(i64 8, ptr nonnull %3) #4
  call void @llvm.lifetime.end.p0(i64 8, ptr nonnull %2) #4
  call void @llvm.lifetime.end.p0(i64 4, ptr nonnull %1) #4
  ret i32 0
}

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.start.p0(i64 immarg, ptr nocapture) #1

declare i32 @cuInit(i32 noundef) local_unnamed_addr #2

declare i32 @cuDeviceGet(ptr noundef, i32 noundef) local_unnamed_addr #2

declare i32 @cuCtxCreate_v2(ptr noundef, i32 noundef, i32 noundef) local_unnamed_addr #2

declare i32 @cuModuleLoad(ptr noundef, ptr noundef) local_unnamed_addr #2

declare i32 @cuModuleGetFunction(ptr noundef, ptr noundef, ptr noundef) local_unnamed_addr #2

; Function Attrs: mustprogress nocallback nofree nounwind willreturn memory(argmem: readwrite)
declare void @llvm.memcpy.p0.p0.i64(ptr noalias nocapture writeonly, ptr noalias nocapture readonly, i64, i1 immarg) #3

declare i32 @cuMemAlloc_v2(ptr noundef, i64 noundef) local_unnamed_addr #2

declare i32 @cuMemcpyHtoD_v2(i64 noundef, ptr noundef, i64 noundef) local_unnamed_addr #2

declare i32 @cuLaunchKernel(ptr noundef, i32 noundef, i32 noundef, i32 noundef, i32 noundef, i32 noundef, i32 noundef, i32 noundef, ptr noundef, ptr noundef, ptr noundef) local_unnamed_addr #2

declare i32 @cuMemFree_v2(i64 noundef) local_unnamed_addr #2

declare i32 @cuCtxDestroy_v2(ptr noundef) local_unnamed_addr #2

; Function Attrs: mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite)
declare void @llvm.lifetime.end.p0(i64 immarg, ptr nocapture) #1

attributes #0 = { nounwind sspstrong uwtable "min-legal-vector-width"="0" "no-trapping-math"="true" "probe-stack"="inline-asm" "stack-protector-buffer-size"="4" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" }
attributes #1 = { mustprogress nocallback nofree nosync nounwind willreturn memory(argmem: readwrite) }
attributes #2 = { "no-trapping-math"="true" "stack-protector-buffer-size"="4" "target-cpu"="x86-64" "target-features"="+cmov,+cx8,+fxsr,+mmx,+sse,+sse2,+x87" "tune-cpu"="generic" "zero-call-used-regs"="used-gpr" }
attributes #3 = { mustprogress nocallback nofree nounwind willreturn memory(argmem: readwrite) }
attributes #4 = { nounwind }

!llvm.module.flags = !{!0, !1, !2, !3}
!llvm.ident = !{!4}

!0 = !{i32 1, !"wchar_size", i32 4}
!1 = !{i32 4, !"probe-stack", !"inline-asm"}
!2 = !{i32 8, !"PIC Level", i32 2}
!3 = !{i32 7, !"uwtable", i32 2}
!4 = !{!"clang version 19.1.7"}
!5 = !{!6, !6, i64 0}
!6 = !{!"int", !7, i64 0}
!7 = !{!"omnipotent char", !8, i64 0}
!8 = !{!"Simple C/C++ TBAA"}
!9 = !{!10, !10, i64 0}
!10 = !{!"any pointer", !7, i64 0}
!11 = !{!12, !12, i64 0}
!12 = !{!"long long", !7, i64 0}
