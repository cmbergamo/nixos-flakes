{ config, lib, pkgs, ... }:

{
  # Ambiente gráfico LXQt (leve, baseado em Qt).
  # Tudo que diz respeito à sessão gráfica mora neste módulo.

  # X11 + display manager LightDM + LXQt.
  services.xserver = {
    enable = true;
    displayManager.lightdm.enable = true;
    desktopManager.lxqt.enable = true;
  };

  # Bloqueio de tela (xscreensaver, usado pelo "Lock screen"/Win+Esc do LXQt).
  # Este módulo é OBRIGATÓRIO para o desbloqueio funcionar: ele cria o
  # wrapper setuid /run/wrappers/bin/xscreensaver-auth e o serviço PAM
  # /etc/pam.d/xscreensaver. Sem eles, a senha digitada na tela de bloqueio
  # nunca autentica (era o seu bug: xscreensaver-auth não era setuid root
  # e o fallback PAM (/etc/pam.d/other) é deny-all).
  services.xscreensaver.enable = true;

  # O daemon continua sendo iniciado pelo autostart do próprio LXQt
  # (lxqt-xscreensaver-autostart); desligo o serviço systemd do módulo para
  # não haver dois daemons. O binário busca o wrapper em /run/wrappers/bin
  # a cada autenticação, então basta o rebuild — sem precisar reiniciar a
  # sessão para o desbloqueio voltar a funcionar.
  systemd.user.services.xscreensaver.wantedBy = lib.mkForce [ ];

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

  # ---------------------------------------------------------------------------
  # Atalhos globais do LXQt (lxqt-globalkeysd) gerenciados pelo flake.
  #
  # Win+B -> navegador padrão   |   Win+T -> wezterm   |   Win+E -> PCManFM-Qt
  #
  # Fonte da verdade: ./files/globalkeyshortcuts.conf (editável no flake).
  # O rebuild publica em /etc/lxqt/ e um serviço de usuário faz symlink em
  # ~/.config/lxqt/ a cada login. Edições feitas pela GUI "Atalhos de
  # teclado" são sobrescritas no próximo login — edite o arquivo do flake.
  # ---------------------------------------------------------------------------
  environment.etc."lxqt/globalkeyshortcuts.conf".source = ./files/globalkeyshortcuts.conf;

  systemd.user.services.lxqt-shortcuts-link = {
    description = "Vincula atalhos globais do LXQt gerenciados pelo flake";
    wantedBy = [ "default.target" ];
    before = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "lxqt-shortcuts-link" ''
        mkdir -p "$HOME/.config/lxqt"
        ln -sfn /etc/lxqt/globalkeyshortcuts.conf "$HOME/.config/lxqt/globalkeyshortcuts.conf"
      '';
    };
  };
}
