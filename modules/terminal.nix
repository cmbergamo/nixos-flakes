{ config, pkgs, ... }:

{
  # ===========================================================================
  # Terminal: apenas o WezTerm, rodando Nushell.
  #
  # (qterminal é removido em ./lxqt.nix via environment.lxqt.excludePackages;
  # xterm nem existe mais: era pacote do módulo do X server, removido na
  # migração Wayland.)
  # ===========================================================================

  # Configuração do WezTerm: o wezterm procura wezterm.lua primeiro em
  # ~/.config/wezterm/ e depois em $XDG_CONFIG_DIRS/wezterm (= /etc/xdg).
  # Como não existe ~/.config/wezterm, este arquivo do flake é o usado.
  # Para personalizar: crie ~/.config/wezterm/wezterm.lua (ele vence).
  environment.etc."xdg/wezterm/wezterm.lua".source = ./files/wezterm/wezterm.lua;
}
