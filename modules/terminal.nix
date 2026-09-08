{ config, pkgs, ... }:

{
  # ===========================================================================
  # Terminal: apenas o WezTerm, rodando Nushell.
  #
  # Remove os terminais que chegam "de fábrica" pelo X server (xterm) e pelo
  # LXQt (qterminal) e publica a configuração do WezTerm gerenciada pelo flake.
  # ===========================================================================

  # xterm: vem na lista padrão de pacotes do módulo do X server; o
  # excludePackages apenas o remove do profile do sistema.
  services.xserver.excludePackages = [ pkgs.xterm ];

  # qterminal: vem nos optionalPackages do LXQt (removível por design).
  environment.lxqt.excludePackages = [ pkgs.lxqt.qterminal ];

  # Configuração do WezTerm: o wezterm procura wezterm.lua primeiro em
  # ~/.config/wezterm/ e depois em $XDG_CONFIG_DIRS/wezterm (= /etc/xdg).
  # Como não existe ~/.config/wezterm, este arquivo do flake é o usado.
  # Para personalizar: crie ~/.config/wezterm/wezterm.lua (ele vence).
  environment.etc."xdg/wezterm/wezterm.lua".source = ./files/wezterm/wezterm.lua;
}
