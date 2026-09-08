{ config, pkgs, ... }:

{
  # Ambiente gráfico LXQt (leve, baseado em Qt).
  # Tudo que diz respeito à sessão gráfica mora neste módulo.

  # X11 + display manager LightDM + LXQt.
  services.xserver = {
    enable = true;
    displayManager.lightdm.enable = true;
    desktopManager.lxqt.enable = true;
  };

  # Teclado brasileiro (ABNT2) no X e no console (TTY).
  services.xserver.xkb = {
    layout = "br";
    variant = "";
  };
  console.keyMap = "br-abnt2";

  # Portais XDG: o módulo do LXQt já liga xdg.portal + portal lxqt sozinho;
  # isto aqui garante mesmo se um dia trocar de desktop.
  xdg.portal.enable = true;

  # Extras de tema Qt que o LXQt não instala por padrão:
  #  - qt6ct: controlador de tema/fonte/ícone para apps Qt6 (menu Preferências)
  #  - qtstyleplugin-kvantum: engine de temas SVG para Qt (visual moderno)
  services.xserver.desktopManager.lxqt.extraPackages = with pkgs; [
    qt6Packages.qt6ct
    kdePackages.qtstyleplugin-kvantum
  ];
}
