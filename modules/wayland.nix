{ config, lib, pkgs, ... }:

{
  # ===========================================================================
  # LXQt no Wayland (sessão "LXQt (Wayland)" no LightDM).
  #
  # Compositor: labwc (stacking, openbox-like — visual igual ao LXQt X11).
  # A sessão X11 continua disponível como alternativa no mesmo greeter.
  # ===========================================================================

  # labwc: instala o compositor, registra a sessão no display manager,
  # liga polkit, PAM do swaylock, XWayland e o portal wlr
  # (tudo que programs/wayland/labwc.nix + wayland-session.nix do nixpkgs fazem).
  programs.labwc.enable = true;

  # Sessão LXQt-Wayland disponível no LightDM
  # (sessions-directory lê share/wayland-sessions de sessionPackages).
  services.displayManager.sessionPackages = [ pkgs.lxqt.lxqt-wayland-session ];

  # Ferramentas que a sessão Wayland do LXQt usa em runtime:
  #  - swaybg/swayidle/wlopm: fundo, idle e desligar monitores (autostart do labwc)
  #  - swaylock: bloqueador de tela (Win+L / Win+Esc) — PAM criado acima
  #  - qt6.qtwayland: plugin de plataforma Qt (apps Qt nativos em Wayland)
  #  - qt6.qttools: fornece qdbus, usado pelo script lxqt-qdbus (atalhos do painel)
  #  - grim/slurp: captura de tela via portal/CLI
  #  - wl-clipboard: clipboard Wayland (wl-copy/wl-paste)
  #  - pamixer: controle de volume nos binds de mídia do labwc
  environment.systemPackages = with pkgs; [
    swaybg
    swayidle
    wlopm
    swaylock
    qt6.qtwayland
    qt6.qttools
    grim
    slurp
    wl-clipboard
    pamixer
  ];

  # Configuração do labwc gerenciada pelo flake, publicada em /etc/labwc:
  # teclado br, Win (menu iniciar), Win+R (executar), Win+Return/Win+T (wezterm),
  # Win+B, Win+E, Win+Esc/W-L (swaylock), Print -> screengrab, fundo, idle.
  environment.etc."labwc/rc.xml".source = ./files/labwc/rc.xml;
  environment.etc."labwc/environment".source = ./files/labwc/environment;
  environment.etc."labwc/autostart".source = ./files/labwc/autostart;
  environment.etc."labwc/menu.xml".source = ./files/labwc/menu.xml;
  environment.etc."labwc/themerc".source = ./files/labwc/themerc;
  environment.etc."labwc/themerc-override".source = ./files/labwc/themerc-override;

  # ---------------------------------------------------------------------------
  # Sessão LXQt-Wayland: escolhe labwc como compositor e swaylock como
  # bloqueador, e vincula a configuração do labwc do flake.
  #
  # Como funciona (verificado nas fontes de lxqt-wayland-session 0.4.1 e
  # liblxqt 2.4):
  #  - startlxqtwayland lê `compositor=` de lxqt/session.conf em ~/.config e
  #    depois em XDG_CONFIG_DIRS (=/etc/xdg); o arquivo abaixo define labwc.
  #    O ~/.config/lxqt/session.conf do usuário continua valendo para o que
  #    ele tiver (ex.: window_manager=openbox no X11); chaves ausentes nele
  #    caem no default do flake (merge de escopos do QSettings).
  #  - Com compositor=labwc o script roda `labwc -C ~/.config/labwc`:
  #    o symlink ~/.config/labwc -> /etc/labwc (criado pelo serviço abaixo)
  #    faz o flake mandar na config e impede a cópia dos defaults na primeira
  #    execução. Para personalizar, troque o symlink por um diretório próprio.
  #  - lxqt-leave --lockscreen (menu Sair) chama LXQt::ScreenSaver, que no
  #    Wayland executa `lock_command_wayland` de [General] em session.conf.
  # ---------------------------------------------------------------------------
  environment.etc."xdg/lxqt/session.conf".text = ''
    [General]
    compositor=labwc
    lock_command_wayland=swaylock -f
  '';

  systemd.user.services.labwc-config-link = {
    description = "Vincula config do labwc gerenciada pelo flake (~/.config/labwc -> /etc/labwc)";
    wantedBy = [ "default.target" ];
    before = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "labwc-config-link" ''
        mkdir -p "$HOME/.config"
        if [ -e "$HOME/.config/labwc" ] && [ ! -L "$HOME/.config/labwc" ]; then
          # usuário tem um diretório próprio; não sobrescrever
          :
        else
          ln -sfn /etc/labwc "$HOME/.config/labwc"
        fi
      '';
    };
  };
}
