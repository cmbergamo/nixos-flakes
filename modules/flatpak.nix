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
  };

  # Repositório Flathub declarado em /etc/flatpak/remotes.d/
  # O Flatpak lê nativamente definições .flatpakrepo neste diretório.
  environment.etc."flatpak/remotes.d/flathub.flatpakrepo".source = ./files/flatpak/flathub.flatpakrepo;

  # ===========================================================================
  # Firewall do LocalSend (Flatpak)
  # Porta 53317 TCP: transferência de arquivos e API HTTP
  # Porta 53317 UDP: descoberta de dispositivos por broadcast/multicast na rede local
  # Sem isso, o celular não encontra o computador (apenas o computador encontra o celular).
  # ===========================================================================
  networking.firewall.allowedTCPPorts = [ 53317 ];
  networking.firewall.allowedUDPPorts = [ 53317 ];

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
