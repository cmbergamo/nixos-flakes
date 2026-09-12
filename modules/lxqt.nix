{ config, lib, pkgs, ... }:

{
  # Ambiente gráfico LXQt (leve, baseado em Qt) rodando sobre Wayland/labwc.
  #
  # A ativação da sessão e o display manager (greetd + ReGreet) moram em
  # ./wayland.nix. Aqui fica o resto: pacotes do desktop, teclado de console,
  # fontes, temas, portais e as configurações visuais publicadas pelo flake.
  #
  # NOTA: `services.xserver.desktopManager.lxqt` continua sendo o botão de
  # instalação do desktop mesmo com o X desligado — o config do módulo é
  # gated apenas pelo próprio enable (sem asserções pedindo xserver.enable) e
  # só instala pacotes/portais/integrações; nada ali levanta um X server.
  # Manter o módulo (em vez de enumerar pacotes à mão) deixa a lista de
  # componentes acompanhando o nixpkgs a cada `nix flake update`.

  services.xserver.desktopManager.lxqt = {
    enable = true;
    # Extras de tema Qt, ícones, cursores e GTK:
    #  - qt6ct: controlador de tema/fonte/ícone para apps Qt6 (menu Preferências)
    #  - qtstyleplugin-kvantum: engine de temas SVG para Qt (visual moderno)
    #  - papirus-icon-theme: conjunto de ícones completo, limpo e consistente
    #  - bibata-cursors: cursor moderno com cantos arredondados
    #  - gnome-themes-extra: fornece Adwaita-dark para consistência com apps GTK
    extraPackages = with pkgs; [
      qt6Packages.qt6ct
      kdePackages.qtstyleplugin-kvantum
      kdePackages.breeze
      papirus-icon-theme
      bibata-cursors
      kdePackages.breeze-icons
      gnome-themes-extra
    ];
  };

  # Ferramentas removidas do conjunto padrão do LXQt:
  #  - qterminal: o terminal do sistema é o WezTerm (ver ./terminal.nix)
  #  - xscreensaver + obconf-qt: utilitários exclusivamente X11 (o bloqueio
  #    de tela no Wayland é o swaylock; não há openbox para configurar)
  environment.lxqt.excludePackages = [
    pkgs.lxqt.qterminal
    pkgs.xscreensaver
    pkgs.lxqt.obconf-qt
  ];

  # Teclado brasileiro (ABNT2) no console (TTY).
  # Na sessão Wayland o layout vem de /etc/labwc/environment
  # (XKB_DEFAULT_LAYOUT=br); no greeter, da unidade do greetd (./wayland.nix).
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

  # Tela de desbloqueio estilizada (swaylock sob o labwc)
  environment.etc."swaylock/config".source = ./files/swaylock/config;

  # Atalhos globais do LXQt gerenciados pelo flake
  environment.etc."lxqt/globalkeyshortcuts.conf".source = ./files/globalkeyshortcuts.conf;

  systemd.user.services.lxqt-config-setup = {
    description = "Sincroniza configurações visuais e atalhos do LXQt";
    wantedBy = [ "default.target" ];
    before = [ "graphical-session.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "lxqt-config-setup" ''
        mkdir -p "$HOME/.config/lxqt" "$HOME/.config/pcmanfm-qt/lxqt"

        # Atalhos gerenciados pelo flake
        ln -sfn /etc/lxqt/globalkeyshortcuts.conf "$HOME/.config/lxqt/globalkeyshortcuts.conf"

        # Kvantum tema escuro SVG (KvArcDark)
        mkdir -p "$HOME/.config/Kvantum"
        if [ ! -e "$HOME/.config/Kvantum/kvantum.kvconfig" ] || [ -L "$HOME/.config/Kvantum/kvantum.kvconfig" ]; then
          ln -sfn /etc/xdg/Kvantum/kvantum.kvconfig "$HOME/.config/Kvantum/kvantum.kvconfig"
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
