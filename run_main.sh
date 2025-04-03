#!/bin/bash
# Compile and run the CUDA Assembly launcher

# Assemble the code
nasm -f elf64 -o cuda_launcher.o cuda_launcher.asm

# Link with proper libraries
ld -o cuda_launcher cuda_launcher.o -ldl -lc --dynamic-linker=/lib64/ld-linux-x86-64.so.2

# Run the executable
./cuda_launcher

# Display the exit code
echo "Exit code: $?"

rm cuda_launcher
rm cuda_launcher.o