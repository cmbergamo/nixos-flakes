{
  description = "cmb-nix: NixOS para dev Rust + jogos (Steam/Epic), baixo uso de memória";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = {self, nixpkgs}: {
    nixosConfigurations.cmb-nix = nixpkgs.lib.nixosSystem {
      modules = [ ./configuration.nix ];
    };
  };
}
