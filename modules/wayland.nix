{ config, lib, pkgs, ... }:

{
  # ===========================================================================
  # Stack gráfico: Wayland é o ÚNICO servidor (X11/LightDM removidos).
  #
  # Compositor: labwc (stacking, openbox-like — visual igual ao antigo X11).
  # Sessão: "LXQt (Wayland)" — a única que aparece na tela de login.
  # Tela de login: greetd + ReGreet (GTK4 sobre o compositor cage),
  # substituindo o LightDM, que era exclusivamente X11.
  #
  # O XWayland continua ativo (programs.xwayland, ligado pelo módulo do
  # labwc): é a camada de compatibilidade que apps X e jogos Wine/Proton usam
  # DENTRO da sessão Wayland — não é o antigo "servidor X".
  # ===========================================================================

  # Garantia dura de que nada reativa o X server (o módulo do LXQt em
  # ./lxqt.nix só instala pacotes/portais; o config dele é gated pelo próprio
  # enable, sem asserções exigindo xserver).
  services.xserver.enable = lib.mkForce false;
  # labwc: instala o compositor, liga polkit, PAM do swaylock, XWayland,
  # dconf, graphical-desktop e os portais wlr/gtk (programs/wayland/labwc.nix
  # + wayland-session.nix do nixpkgs).
  #
  # O pacote tem o arquivo de sessão crua removido: o ReGreet varre o
  # XDG_DATA_DIRS inteiro (que inclui /run/current-system/sw/share via
  # pam_env), então sem o strip a entrada "labwc" (compositor pelado, sem
  # painel/menu/fundo) voltaria para a tela de login. O compositor continua
  # sendo o labwc — quem o inicia é o startlxqtwayland (compositor=labwc no
  # session.conf abaixo).
  programs.labwc = {
    enable = true;
    package = pkgs.labwc.overrideAttrs (finalAttrs: prevAttrs: {
      postInstall = (prevAttrs.postInstall or "") + ''
        rm -rf $out/share/wayland-sessions
      '';
    });
  };

  # openbox e lxqt-session chegam instalados pelo módulo LXQt e embarcam
  # arquivos em share/xsessions (o lxqt-session traz o próprio
  # lxqt.desktop "Exec=startlxqt", que seria uma entrada-fantasma X11 no
  # greeter; o openbox traz 3). O ReGreet varre o XDG_DATA_DIRS inteiro —
  # que inclui /run/current-system/sw/share — então o strip é feito nos
  # pacotes, no mesmo princípio do labwc acima.
  # ATENÇÃO: pkgs.lxqt é um scope (makeScope kdePackages.newScope); mesclar
  # com `//` perderia a re-derivação interna. overrideScope re-executa o
  # scope com a definição nova, então TUDO que depende de lxqt-session
  # enxerga o pacote com strip.
  nixpkgs.overlays = [
    (final: prev: {
      openbox = prev.openbox.overrideAttrs (finalAttrs: prevAttrs: {
        postInstall = (prevAttrs.postInstall or "") + ''
          rm -rf $out/share/xsessions
        '';
      });
      lxqt = prev.lxqt.overrideScope (
        lFinal: lPrev: {
          lxqt-session = lPrev.lxqt-session.overrideAttrs (
            finalAttrs: prevAttrs: {
              postInstall = (prevAttrs.postInstall or "") + ''
                rm -rf $out/share/xsessions
              '';
            }
          );
        }
      );
    })
  ];

  # "Farm" de sessões do display manager (lida por greeters que respeitam
  # services.displayManager.sessionPackages): SOMENTE "LXQt (Wayland)".
  # mkForce descarta a sessão labwc crua e a sessão X do módulo LXQt.
  services.displayManager.sessionPackages =
    lib.mkForce [ pkgs.lxqt.lxqt-wayland-session ];

  # Portais: XDG_CURRENT_DESKTOP da sessão é "LXQt:labwc:wlroots"; o portal
  # escolhe a seção de config pelo primeiro token conhecido ("lxqt"). Sem o
  # backend wlr nessa lista, compartilhamento/captura de tela morrem.
  xdg.portal.config.lxqt.default = lib.mkForce [ "lxqt" "wlr" "gtk" ];

  # ---------------------------------------------------------------------------
  # Tela de login: ReGreet (greeter GTK4 do greetd, roda sobre cage) com o
  # mesmo visual do antigo LightDM: papel de parede origami-dark, tema
  # escuro, Papirus-Dark, cursor Bibata e Fira Mono.
  # ---------------------------------------------------------------------------
  services.displayManager.regreet = {
    enable = true;
    iconTheme = {
      package = pkgs.papirus-icon-theme;
      name = "Papirus-Dark";
    };
    cursorTheme = {
      package = pkgs.bibata-cursors;
      name = "Bibata-Modern-Classic";
    };
    font = {
      package = pkgs.fira-mono;
      name = "Fira Mono";
      size = 11;
    };
    settings = {
      background = {
        path = "/run/current-system/sw/share/lxqt/wallpapers/origami-dark.png";
        fit = "Cover";
      };
      GTK.application_prefer_dark_theme = true;
    };
  };

  # Teclado ABNT2 no greeter (cage lê XKB via libinput) e na sessão: o worker
  # do greetd execveia com o environment montado pelo PAM (NÃO o da unidade
  # systemd — verificado no fonte, greetd/src/session/worker.rs), e o pam_env
  # preenche exatamente de /etc/pam/environment, que é renderizado de
  # environment.sessionVariables. É pela mesma corrente que o ReGreet enxerga
  # a farm de sessões: o módulo do display manager injeta
  # sessionData.desktops/share no XDG_DATA_DIRS (confirmado ao vivo em
  # /etc/pam/environment — farm primeiro, /run/current-system/sw/share por
  # último, para temas/ícones).
  environment.sessionVariables.XKB_DEFAULT_LAYOUT = "br";

  # Ferramentas que a sessão Wayland do LXQt usa em runtime:
  #  - swaybg/swayidle/wlopm: fundo, idle e desligar monitores (autostart do labwc)
  #  - swaylock: bloqueador de tela (Win+L / Win+Esc) — PAM criado pelo módulo do labwc
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
  #    depois em XDG_CONFIG_DIRS (/etc/xdg incluído via pam_env); o arquivo
  #    abaixo define labwc. Chaves ausentes no ~/.config do usuário caem no
  #    default do flake (merge de escopos do QSettings).
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
