alias r := run
alias b := build
alias e := error
alias t := test-kernel
alias p := build-ptx

run:
    zig build run -- run sb.ryu --dump-llvm

build:
    zig build run -- build sb.ryu --dump-llvm

error err_code="0":
    nvcc err.cu -o err
    ./err {{err_code}}
    rm ./err

test-kernel:
    nvcc ptx_test.cu -o test -lcuda
    ./test
    rm ./test

build-ptx:
    nvcc example.ptx --cubin
    rm ./example.cubin