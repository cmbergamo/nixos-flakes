{ config, pkgs, ... }:

{
  # Toolchain Rust via rustup (gerenciado por usuário, fora do Nix).
  # É o caminho recomendado no NixOS: `programs.nix-ld` (habilitado na config
  # principal) fornece as bibliotecas dinâmicas que os binários do rustup usam.
  #
  # Pós-instalação (uma vez, no terminal):
  #   rustup default stable
  #   rustup component add rust-analyzer clippy rustfmt
  #
  # Em nushell, se ~/.cargo/bin não aparecer no PATH, adicione em
  # ~/.config/nushell/config.nu:  path add ~/.cargo/bin
  environment.systemPackages = with pkgs; [
    rustup

    # Dependências de crates nativos (openssl-sys, libsqlite3-sys, etc.)
    # e ferramentas de debug/perf para desenvolvimento.
    pkg-config
    openssl
    gdb
    valgrind
  ];

  # ~/.cargo/bin e ~/.local/bin com prioridade no PATH (shells de login/interativos).
  environment.shellInit = ''
    export PATH="$HOME/.cargo/bin:$HOME/.local/bin:''${PATH}"
  '';
  environment.extraInit = config.environment.shellInit;
}
