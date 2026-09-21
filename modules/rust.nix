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
  # Em nushell, ~/.cargo/bin já chega herdando o PATH da sessão (set-environment);
  # não é preciso `path add` — conferir com `nu -l -c '$env.PATH'` se sumir.
  environment.systemPackages = with pkgs; [
    rustup

    # Dependências de crates nativos (openssl-sys, libsqlite3-sys, etc.)
    # e ferramentas de debug/perf para desenvolvimento.
    pkg-config
    openssl
    gdb
    valgrind
  ];

  # ~/.cargo/bin com prioridade (rustup é gerenciado pelo usuário); ~/.local/bin
  # DEPOIS dos caminhos do sistema: binários baixados por scripts de instalação
  # (ex.: omp via `curl -fsSL https://omp.sh/install | sh`) ficam no PATH sem
  # jamais sombrear pacotes gerenciados pelo Nix.
  environment.shellInit = ''
    export PATH="$HOME/.cargo/bin:''${PATH}:$HOME/.local/bin"
  '';
  environment.extraInit = config.environment.shellInit;
}
