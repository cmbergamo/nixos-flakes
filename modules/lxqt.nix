{ config, lib, pkgs, ... }:

{
  # Ambiente gráfico LXQt (leve, baseado em Qt).
  # Tudo que diz respeito à sessão gráfica mora neste módulo.

  # X11 + display manager LightDM + LXQt.
  # X11 + display manager LightDM estilizado + LXQt.
  services.xserver = {
    enable = true;
    displayManager.lightdm = {
      enable = true;
      background = "${pkgs.lxqt.lxqt-themes}/share/lxqt/wallpapers/origami-dark.png";
      greeters.gtk = {
        enable = true;
        theme = {
          name = "Adwaita-dark";
          package = pkgs.gnome-themes-extra;
        };
        iconTheme = {
          name = "Papirus-Dark";
          package = pkgs.papirus-icon-theme;
        };
        cursorTheme = {
          name = "Bibata-Modern-Classic";
          package = pkgs.bibata-cursors;
          size = 24;
        };
        clock-format = "%A, %d de %B de %Y  |  %H:%M";
        extraConfig = ''
          font-name = Fira Mono 11
          xft-antialias = true
          xft-dpi = 96
          xft-hintstyle = hintslight
          xft-rgba = rgb
          position = 50%,center 50%,center
          panel-position = top
        '';
      };
    };
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

  # Tipografia de sistema com Fira Mono como padrão.
  fonts = {
    enableDefaultPackages = true;
    packages = with pkgs; [
      fira-mono
      fira-code
      inter
      jetbrains-mono
      noto-fonts-color-emoji
      font-awesome
    ];
    fontconfig = {
      enable = true;
      antialias = true;
      hinting = {
        enable = true;
        style = "slight";
      };
      subpixel.rgba = "rgb";
      defaultFonts = {
        monospace = [ "Fira Mono" "Fira Code" ];
        sansSerif = [ "Fira Mono" "Inter" "DejaVu Sans" ];
        serif = [ "DejaVu Serif" ];
        emoji = [ "Noto Color Emoji" ];
      };
    };
  };

  # Extras de tema Qt, ícones, cursores e GTK:
  #  - qt6ct: controlador de tema/fonte/ícone para apps Qt6 (menu Preferências)
  #  - qtstyleplugin-kvantum: engine de temas SVG para Qt (visual moderno)
  #  - papirus-icon-theme: conjunto de ícones completo, limpo e consistente
  #  - bibata-cursors: cursor moderno com cantos arredondados
  #  - gnome-themes-extra: fornece Adwaita-dark para consistência com apps GTK
  services.xserver.desktopManager.lxqt.extraPackages = with pkgs; [
    qt6Packages.qt6ct
    kdePackages.qtstyleplugin-kvantum
    kdePackages.breeze
    papirus-icon-theme
    bibata-cursors
    kdePackages.breeze-icons
    gnome-themes-extra
  ];

  # Compositor para X11 (picom):
  #  - Aceleração GLX via GPU AMD (sem tearing, vsync suave a 165Hz)
  #  - Sombras suaves sob janelas ativas/inativas
  #  - Cantos levemente arredondados (8px) estilo moderno
  #  - Efeito suave de fade ao abrir/fechar janelas
  services.picom = {
    enable = true;
    backend = "glx";
    vSync = true;
    shadow = true;
    shadowOpacity = 0.55;
    fade = true;
    fadeDelta = 4;
    settings = {
      corner-radius = 8;
      rounded-corners-exclude = [
        "window_type = 'dock'"
        "window_type = 'desktop'"
      ];
      shadow-exclude = [
        "name = 'Notification'"
        "class_g = 'Conky'"
        "class_g ?= 'Notify-osd'"
        "class_g = 'Cairo-clock'"
        "_GTK_FRAME_EXTENTS@:c"
        "window_type = 'dock'"
        "window_type = 'desktop'"
      ];
    };
  };

  # Preferência global de tema escuro via dconf (Portal XDG, GSettings, Firefox, Chrome, apps GTK4 e Electron):
  programs.dconf = {
    enable = true;
    profiles.user.databases = [
      {
        settings = {
          "org/gnome/desktop/interface" = {
            color-scheme = "prefer-dark";
            gtk-theme = "Adwaita-dark";
            icon-theme = "Papirus-Dark";
            cursor-theme = "Bibata-Modern-Classic";
            font-name = "Fira Mono 10";
            monospace-font-name = "Fira Mono 10";
          };
        };
      }
    ];
  };

  # Variáveis globais para tema escuro e cursor consistente em apps Qt/GTK/CLI:
  environment.sessionVariables = {
    GTK_THEME = "Adwaita-dark";
    QT_STYLE_OVERRIDE = "kvantum";
    XCURSOR_THEME = "Bibata-Modern-Classic";
    XCURSOR_SIZE = "24";
    BAT_THEME = "Catppuccin Mocha";
    COLORTERM = "truecolor";
  };

  # ---------------------------------------------------------------------------
  # Configurações visuais padrão (XDG) gerenciadas pelo flake.
  # ---------------------------------------------------------------------------
  environment.etc."xdg/lxqt/lxqt.conf".source = ./files/lxqt/lxqt.conf;
  environment.etc."xdg/lxqt/panel.conf".source = ./files/lxqt/panel.conf;
  environment.etc."xdg/pcmanfm-qt/lxqt/settings.conf".source = ./files/pcmanfm-qt/settings.conf;
  environment.etc."xdg/openbox/rc.xml".source = ./files/openbox/rc.xml;
  environment.etc."xdg/Kvantum/kvantum.kvconfig".source = ./files/Kvantum/kvantum.kvconfig;
  environment.etc."xdg/gtk-3.0/settings.ini".text = ''
    [Settings]
    gtk-theme-name=Adwaita-dark
    gtk-icon-theme-name=Papirus-Dark
    gtk-font-name=Fira Mono 10
    gtk-cursor-theme-name=Bibata-Modern-Classic
    gtk-cursor-theme-size=24
    gtk-application-prefer-dark-theme=1
  '';
  environment.etc."xdg/gtk-4.0/settings.ini".text = ''
    [Settings]
    gtk-theme-name=Adwaita-dark
    gtk-icon-theme-name=Papirus-Dark
    gtk-font-name=Fira Mono 10
    gtk-cursor-theme-name=Bibata-Modern-Classic
    gtk-cursor-theme-size=24
    gtk-application-prefer-dark-theme=1
  '';

  # Configuração de tema escuro para o editor Helix
  environment.etc."xdg/helix/config.toml".source = ./files/helix/config.toml;

  # Telas de desbloqueio estilizadas (XScreenSaver no X11 e Swaylock no Wayland)
  environment.etc."xscreensaver".source = ./files/xscreensaver/xscreensaver;
  environment.etc."swaylock/config".source = ./files/swaylock/config;

  # Atalhos globais do LXQt gerenciados pelo flake
  environment.etc."lxqt/globalkeyshortcuts.conf".source = ./files/globalkeyshortcuts.conf;

  systemd.user.services.lxqt-config-setup = {
    description = "Sincroniza configurações visuais e atalhos do LXQt e Openbox";
    wantedBy = [ "default.target" ];
    before = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "lxqt-config-setup" ''
        mkdir -p "$HOME/.config/lxqt" "$HOME/.config/openbox" "$HOME/.config/pcmanfm-qt/lxqt"

        # Atalhos gerenciados pelo flake
        ln -sfn /etc/lxqt/globalkeyshortcuts.conf "$HOME/.config/lxqt/globalkeyshortcuts.conf"

        # Openbox: se não existir rc.xml ou se for symlink, aponta para o flake
        if [ ! -e "$HOME/.config/openbox/rc.xml" ] || [ -L "$HOME/.config/openbox/rc.xml" ]; then
          ln -sfn /etc/xdg/openbox/rc.xml "$HOME/.config/openbox/rc.xml"
        fi


        # Kvantum tema escuro SVG (KvArcDark)
        mkdir -p "$HOME/.config/Kvantum"
        if [ ! -e "$HOME/.config/Kvantum/kvantum.kvconfig" ] || [ -L "$HOME/.config/Kvantum/kvantum.kvconfig" ]; then
          ln -sfn /etc/xdg/Kvantum/kvantum.kvconfig "$HOME/.config/Kvantum/kvantum.kvconfig"
        fi
        # XScreenSaver: tela de desbloqueio dark com Fira Mono
        if [ ! -e "$HOME/.xscreensaver" ]; then
          cp -f /etc/xscreensaver "$HOME/.xscreensaver"
          chmod 644 "$HOME/.xscreensaver"
        fi

        # LXQt geral e painel: se estiver nos defaults vazios de fábrica, aplica a configuração elegante do flake
        if [ ! -e "$HOME/.config/lxqt/lxqt.conf" ] || (grep -q '^[[:space:]]*__userfile__=true[[:space:]]*$' "$HOME/.config/lxqt/lxqt.conf" && [ "$(wc -l < "$HOME/.config/lxqt/lxqt.conf")" -le 3 ]); then
          cp -f /etc/xdg/lxqt/lxqt.conf "$HOME/.config/lxqt/lxqt.conf"
          chmod 644 "$HOME/.config/lxqt/lxqt.conf"
        fi

        if [ ! -e "$HOME/.config/lxqt/panel.conf" ] || [ "$(wc -l < "$HOME/.config/lxqt/panel.conf")" -le 25 ]; then
          cp -f /etc/xdg/lxqt/panel.conf "$HOME/.config/lxqt/panel.conf"
          chmod 644 "$HOME/.config/lxqt/panel.conf"
        fi

        if [ ! -e "$HOME/.config/pcmanfm-qt/lxqt/settings.conf" ]; then
          cp -f /etc/xdg/pcmanfm-qt/lxqt/settings.conf "$HOME/.config/pcmanfm-qt/lxqt/settings.conf"
          chmod 644 "$HOME/.config/pcmanfm-qt/lxqt/settings.conf"
        fi

        # Bookmarks do gerenciador de arquivos (Lugares / Barra lateral do PCManFM-Qt)
        mkdir -p "$HOME/.config/gtk-3.0"
        if [ ! -e "$HOME/.config/gtk-3.0/bookmarks" ]; then
          cat > "$HOME/.config/gtk-3.0/bookmarks" << 'EOF'
file:///mnt/dados Dados
file:///mnt/windows Windows
EOF
        else
          grep -q "/mnt/dados" "$HOME/.config/gtk-3.0/bookmarks" || echo "file:///mnt/dados Dados" >> "$HOME/.config/gtk-3.0/bookmarks"
          grep -q "/mnt/windows" "$HOME/.config/gtk-3.0/bookmarks" || echo "file:///mnt/windows Windows" >> "$HOME/.config/gtk-3.0/bookmarks"
        fi

        # Tema escuro para aplicativos GTK-2 legados
        if [ ! -e "$HOME/.gtkrc-2.0" ]; then
          cat > "$HOME/.gtkrc-2.0" << 'EOF'
gtk-theme-name="Adwaita-dark"
gtk-icon-theme-name="Papirus-Dark"
gtk-font-name="Fira Mono 10"
gtk-cursor-theme-name="Bibata-Modern-Classic"
gtk-cursor-theme-size=24
EOF
        fi
      '';
    };
  };
}
