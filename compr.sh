#!/bin/bash
gcc -c lib/runtime/runtime.c -o lib/runtime/runtime.o
ar rcs lib/runtime/libruntime.a lib/runtime/runtime.o

rm lib/runtime/runtime.o