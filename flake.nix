{
  description = "cmb-nix: NixOS para dev Rust + jogos (Steam/Epic), baixo uso de memória";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";

    # Toolchains Rust versionáveis por flake (para devShells e templates).
    rust-overlay.url = "github:oxalica/rust-overlay";
    rust-overlay.inputs.nixpkgs.follows = "nixpkgs";

    # Gerenciador declarativo de Flatpaks
    nix-flatpak.url = "github:gmodena/nix-flatpak";
  };

  outputs = inputs@{ self, nixpkgs, ... }:
  let
    system = "x86_64-linux";
    pkgs = import nixpkgs {
      inherit system;
      config.allowUnfree = true;
      overlays = [ inputs.rust-overlay.overlays.default ];
    };
  in
  {
    # --- Sistema desta máquina (para outra, adicione um novo bloco aqui) ---
    nixosConfigurations.cmb-nix = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        inputs.nix-flatpak.nixosModules.nix-flatpak
        ./configuration.nix
      ];
    };

    # --- Servidor Headless (Alta Performance e Baixo Uso de Memória) ---
    nixosConfigurations.dstk-server = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [
        ./modules/hosts/server.nix
        ./erp-distak/deploy/fiscal-hml/nixos/erp-distak-fiscal-hml.nix
        ({ pkgs, ... }: {
          erpDistak.fiscalHml = {
            enable = true;
            operadorChavesSsh = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICngzln/77Z3+GEhwbX6cQGpyiIjkaX1pPmfztdUn3q7" ];
            # NÃO definir openbaoPackage: o módulo usa pkgs.openbao se >= 2.6.4 e, senão,
            # usa o OpenBao 2.7.1 do nixpkgs fixado por revisão + hash.
            # worker.habilitar e api.habilitar ficam no PADRÃO (false).
          };
        })
      ];
    };

    # --- Shell de desenvolvimento Rust ---
    # `nix develop` dentro de qualquer projeto: ambiente isolado e pinável,
    # independente do rustup do sistema. Útil para garantir toolchain fixa
    # por projeto (ex.: uma nightly específica) sem mexer no global.
    devShells.${system}.default = pkgs.mkShell {
      packages = with pkgs; [
        (rust-bin.stable.latest.default.override {
          extensions = [ "rust-analyzer" "clippy" "rustfmt" ];
        })
        pkg-config
        openssl
        mold # linker rápido: builds de Cargo sensivelmente mais curtos
      ];
      env.RUSTFLAGS = "-C link-arg=-fuse-ld=mold";
    };

    # --- Templates: `nix flake init -t .#rust` num diretório vazio ---
    templates.rust = {
      path = ./templates/rust;
      description = "Projeto Rust com devShell (rustc, clippy, rustfmt, rust-analyzer, mold)";
    };

    # --- `nix fmt` padroniza os .nix deste repo ---
    formatter.${system} = pkgs.nixfmt;
  };
}
