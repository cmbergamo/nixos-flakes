{
  description = "A very basic flake";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs = {self, nixpkgs}: {
    nixosConfigurations.cmb-nix = nixpkgs.lib.nixosSystem {
      modules = [ ./configuration.nix ];
    };
  };
}
