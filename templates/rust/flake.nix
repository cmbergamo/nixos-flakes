{
  description = "Projeto Rust";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, rust-overlay, flake-utils, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ rust-overlay.overlays.default ];
        };
        rust = pkgs.rust-bin.stable.latest.default.override {
          extensions = [ "rust-analyzer" "clippy" "rustfmt" ];
        };
      in
      {
        devShells.default = pkgs.mkShell {
          packages = [
            rust
            pkgs.pkg-config
            pkgs.openssl
            pkgs.mold
          ];
          env.RUSTFLAGS = "-C link-arg=-fuse-ld=mold";
        };

        packages.default = pkgs.rustPlatform.buildRustPackage {
          # buildRustPackage NÃO deriva nome/versão do Cargo.toml em eval-time;
          # mantenha estes valores espelhando [[package]] em Cargo.toml.
          pname = "meu-projeto";
          version = "0.1.0";
          src = ./.;
          cargoLock.lockFile = ./Cargo.lock;
        };
      });
}
