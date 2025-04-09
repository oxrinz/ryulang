{
  description = "Zig + CUDA development environment";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, flake-utils }:
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
            gdb
            zig
            llvm
            clang
          ];
          shellHook = ''
            export CUDA_PATH=${pkgs.cudatoolkit}
            export LD_LIBRARY_PATH=/run/opengl-driver/lib:${pkgs.cudatoolkit}/lib:${pkgs.cudaPackages.cuda_cudart}/lib:${pkgs.llvm}/lib:$LD_LIBRARY_PATH
            export LIBRARY_PATH=/run/opengl-driver/lib:${pkgs.cudatoolkit}/lib:${pkgs.cudaPackages.cuda_cudart}/lib:${pkgs.llvm}/lib:$LIBRARY_PATH
            export C_INCLUDE_PATH=${pkgs.cudatoolkit}/include:${pkgs.llvm}/include:$C_INCLUDE_PATH
            export LLVM_PATH=${pkgs.llvm}
            export LLVM_CONFIG=${pkgs.llvm}/bin/llvm-config
          '';
        };
      });
}
