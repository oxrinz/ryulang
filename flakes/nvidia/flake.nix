{
  description = "nvidia";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          config = {
            allowUnfree = true;
            cudaSupport = true;
          };
        };
      in {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            cudatoolkit
            cudaPackages.cuda_cudart
            cudaPackages.cuda_nvcc
            cudaPackages.libcublas
            nvidia-docker
            gdb
            zig
            llvm
            pkgconf
            gcc13
            lldb
            nodejs
          ];

          shellHook = ''
            export LIBCUDA=/run/opengl-driver/lib/libcuda.so
            export CUDA_PATH=${pkgs.cudatoolkit}
            export LD_LIBRARY_PATH=${pkgs.cudatoolkit}/lib:${pkgs.cudaPackages.cuda_cudart}/lib:${pkgs.llvm}/lib:/run/opengl-driver/lib:$LD_LIBRARY_PATH
            export LIBRARY_PATH=/run/opengl-driver/lib:${pkgs.cudatoolkit}/lib:${pkgs.cudaPackages.cuda_cudart}/lib:${pkgs.llvm}/lib:$LIBRARY_PATH
            export C_INCLUDE_PATH=${pkgs.cudatoolkit}/include:${pkgs.llvm}/include:$C_INCLUDE_PATH
            export LLVM_PATH=${pkgs.llvm}
            export LLVM_CONFIG=${pkgs.llvm}/bin/llvm-config
            export PATH=${pkgs.gcc13}/bin:${pkgs.cudatoolkit}/bin:$PATH
            export PKG_CONFIG_PATH=${pkgs.llvm}/lib/pkgconfig:$PKG_CONFIG_PATH
          '';
        };
      });
}
