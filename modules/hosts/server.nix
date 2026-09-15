{ config, pkgs, ... }:

{
  imports = [
    /etc/nixos/hardware-configuration.nix
    ../server/base.nix
    ../server/wireguard.nix
  ];

  # Nome do host no barramento de rede
  networking.hostName = "dstk-server";

  # Fuso Horário e Locale
  time.timeZone = "America/Sao_Paulo";
  i18n.defaultLocale = "pt_BR.UTF-8";

  # Usuários do sistema (senha inicial 'changeme' para bootstrap; altere no primeiro acesso com 'passwd')
  users.users.cmbergamo = {
    isNormalUser = true;
    description = "cmbergamo";
    extraGroups = [ "wheel" ];
    initialPassword = "changeme";
    shell = pkgs.bash;
  };

  users.users.rmbergamo = {
    isNormalUser = true;
    description = "rmbergamo";
    extraGroups = [ ];
    initialPassword = "changeme";
    shell = pkgs.bash;
  };

  # Pacotes adicionais do sistema
  environment.systemPackages = with pkgs; [
    git
  ];

  # Exige senha para comandos sudo
  security.sudo.wheelNeedsPassword = true;

  # Versão do estado inicial do NixOS
  system.stateVersion = "26.05";
}
