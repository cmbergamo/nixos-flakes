{ config, pkgs, ... }:

{
  # ===========================================================================
  # Flatpak & Gerenciamento Declarativo via nix-flatpak
  # ===========================================================================

  services.flatpak = {
    enable = true;

    # Atualização periódica automática
    update.auto = {
      enable = true;
      onCalendar = "weekly";
    };

    # Repositório Flathub
    remotes = [
      {
        name = "flathub";
        location = "https://dl.flathub.org/repo/flathub.flatpakrepo";
      }
    ];

    # Pacotes Flatpak gerenciados declarativamente
    packages = [
      # Navegador e utilitários
      "org.mozilla.firefox"
      "com.rustdesk.RustDesk"
      "org.localsend.localsend_app"
      "io.github.kolunmi.Bazaar"

      # Jogos e Lojas (migrados do Nix nativo)
      "com.valvesoftware.Steam"
      "com.heroicgameslauncher.hgl"
      "net.lutris.Lutris"
      "net.davidotek.pupgui2"
      "org.prismlauncher.PrismLauncher"
    ];

    # Permissões e overrides declarativos para Flatpaks
    overrides = {
      # Firefox: performance no labwc (Wayland) + decodificação por hardware
      # (VA-API na AMD RX 6800, driver amdgpu/mesa).
      "org.mozilla.firefox" = {
        Context = {
          # GPU (DRI): aceleração WebRender + VA-API para vídeo
          devices = [ "dri" ];
          # Mantém vídeo/hardware info funcionando dentro do sandbox
          filesystems = [ "xdg-run/pipewire-0" ];
          # Wayland nativo com fallback X11 (XWayland) para robustez
          sockets = [ "wayland" "fallback-x11" ];
        };
        Environment = {
          # Garante backend Wayland nativo (menos latência que XWayland)
          MOZ_ENABLE_WAYLAND = "1";
          # VA-API dentro do sandbox do RDD (processo de decodificação)
          MOZ_DISABLE_RDD_SANDBOX = "1";
          # Compatibilidade de entrada/XIM no fallback X11
          GTK_IM_MODULE = "wayland";
        };
      };
      "com.rustdesk.RustDesk" = {
        Context = {
          # Suporte a Wayland nativo mantendo fallback X11/XWayland
          sockets = [ "wayland" "x11" ];
          # Acesso direto ao PipeWire para captura de tela em baixa latência no Wayland
          filesystems = [ "xdg-run/pipewire-0" ];
          # Acesso aos dispositivos de GPU (DRI / VA-API) e nós de entrada (uinput)
          devices = [ "dri" "all" ];
        };
      };
    };
  };

  # Repositório Flathub declarado em /etc/flatpak/remotes.d/
  # O Flatpak lê nativamente definições .flatpakrepo neste diretório.
  environment.etc."flatpak/remotes.d/flathub.flatpakrepo".source = ./files/flatpak/flathub.flatpakrepo;

  # Policies enterprise do Firefox: o flatpak do Mozilla já tem permissão de
  # leitura em /etc/firefox/policies (bug 1682462/1795998 — sem furo de sandbox).
  # HardwareAcceleration garante caminho GPU acelerado (WebRender/VA-API na AMD).
  environment.etc."firefox/policies/policies.json".source = ./files/firefox/policies.json;

  # ===========================================================================
  # Firewall do LocalSend e RustDesk (Flatpak)
  # LocalSend:
  #   - Porta 53317 TCP: transferência de arquivos e API HTTP
  #   - Porta 53317 UDP: descoberta de dispositivos por broadcast/multicast
  # RustDesk (conexão direta P2P sem depender de relay público lento):
  #   - Portas 21118 e 21119 TCP: conexão direta por IP / desktop remoto e WebRTC
  #   - Porta 21116 UDP: NAT traversal, STUN e descoberta na rede local (LAN)
  # ===========================================================================
  networking.firewall.allowedTCPPorts = [ 53317 21118 21119 ];
  networking.firewall.allowedUDPPorts = [ 53317 21116 ];

  # Loja de aplicativos com suporte ao Flathub e utilitários
  environment.systemPackages = with pkgs; [
    # Wrapper para que o comando 'firefox' no terminal e em atalhos acione o Flatpak
    (writeShellScriptBin "firefox" ''
      exec ${flatpak}/bin/flatpak run org.mozilla.firefox "$@"
    '')
    # Wrapper para que o comando 'bazaar' no terminal acione o Flatpak
    (writeShellScriptBin "bazaar" ''
      exec ${flatpak}/bin/flatpak run io.github.kolunmi.Bazaar "$@"
    '')
    # Wrapper para que o comando 'rustdesk' no terminal acione o Flatpak
    (writeShellScriptBin "rustdesk" ''
      exec ${flatpak}/bin/flatpak run com.rustdesk.RustDesk "$@"
    '')
    # Wrappers para comandos CLI das lojas/jogos Flatpak
    (writeShellScriptBin "steam" ''
      exec ${flatpak}/bin/flatpak run com.valvesoftware.Steam "$@"
    '')
    (writeShellScriptBin "heroic" ''
      exec ${flatpak}/bin/flatpak run com.heroicgameslauncher.hgl "$@"
    '')
    (writeShellScriptBin "lutris" ''
      exec ${flatpak}/bin/flatpak run net.lutris.Lutris "$@"
    '')
    (writeShellScriptBin "protonup-qt" ''
      exec ${flatpak}/bin/flatpak run net.davidotek.pupgui2 "$@"
    '')
    (writeShellScriptBin "prismlauncher" ''
      exec ${flatpak}/bin/flatpak run org.prismlauncher.PrismLauncher "$@"
    '')
    kdePackages.discover
    kdePackages.flatpak-kcm
  ];
}
