#!/bin/bash
# Compile and run the CUDA Assembly launcher

# Assemble the code
nasm -f elf64 -o debug.o debug.asm

# Link with proper libraries
ld -o debug debug.o -ldl -lc --dynamic-linker=/lib64/ld-linux-x86-64.so.2

# Run the executable
./debug

# Display the exit code
echo "Exit code: $?"

rm debug
rm debug.o