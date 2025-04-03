llc -filetype=obj cuda_launcher.ll -o cuda_launcher.o
llc cuda_launcher.ll -o cuda_launcher.s
clang -no-pie cuda_launcher.o -o cuda_launcher
./cuda_launcher
echo $?

rm cuda_launcher
#rm cuda_launcher.asm
rm cuda_launcher.o