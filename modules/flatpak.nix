{ config, pkgs, ... }:

{
  # ===========================================================================
  # Flatpak & Loja Flathub
  # ===========================================================================

  services.flatpak.enable = true;

  # Repositório Flathub declarado em /etc/flatpak/remotes.d/
  # O Flatpak lê nativamente definições .flatpakrepo neste diretório.
  environment.etc."flatpak/remotes.d/flathub.flatpakrepo".source = ./files/flatpak/flathub.flatpakrepo;

  # Garante que o repositório Flathub também esteja registrado no banco OSTree
  # do Flatpak para a loja gráfica (KDE Discover) e comandos de terminal.
  systemd.services.configure-flathub = {
    description = "Garante o repositório Flathub no Flatpak";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "configure-flathub" ''
        ${pkgs.flatpak}/bin/flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
      '';
    };
  };

  # Loja de aplicativos com suporte ao Flathub e gerenciamento de permissões
  environment.systemPackages = with pkgs; [
    bazaar              # Loja gráfica dedicada para o Flathub (vitrine, pesquisa e instalação em 1 clique)
    kdePackages.discover
    kdePackages.flatpak-kcm
  ];
}
