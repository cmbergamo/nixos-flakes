{ config, pkgs, lib, ... }:

{
  imports = [
    /etc/nixos/hardware-configuration.nix
    ../server/base.nix
    ../server/wireguard.nix
    ../nushell.nix
  ];
  # Bootloader UEFI (systemd-boot)
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # Nome do host no barramento de rede
  networking.hostName = "dstk-server";

  # Fuso Horário e Locale
  time.timeZone = "America/Sao_Paulo";
  i18n.defaultLocale = "pt_BR.UTF-8";

  # Shell padrão para o sistema inteiro (com registro em /etc/shells)
  environment.shells = [ pkgs.nushell pkgs.bashInteractive ];
  users.defaultUserShell = pkgs.nushell;

  # Shell do root preservado em bash para manutenção e compatibilidade com scripts POSIX/resgate
  users.users.root.shell = pkgs.bash;

  # Usuários do sistema (senha inicial 'changeme' para bootstrap; altere no primeiro acesso com 'passwd')
  users.users.cmbergamo = {
    isNormalUser = true;
    description = "cmbergamo";
    extraGroups = [ "wheel" "networkmanager" ];
    initialPassword = "changeme";
    shell = pkgs.nushell;
  };

  users.users.rmbergamo = {
    isNormalUser = true;
    description = "rmbergamo";
    extraGroups = [ ];
    initialPassword = "changeme";
    shell = pkgs.nushell;
  };

  # Integração com o Home Manager
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  # O Nushell gera um ~/.config/nushell/config.nu de scaffold na primeira execução.
  # Sem isto o HM recusa sobrescrever arquivo que não criou e a ativação inteira do
  # usuário falha ("would be clobbered"), deixando o config declarativo fora do ar.
  home-manager.backupFileExtension = "backup";
  # No servidor, o Home Manager e o unico dono de ~/.config/nushell/config.nu.
  # Desliga o servico systemd de usuario para nao haver dois gerenciadores no mesmo caminho.
  modules.nushell.manageUserConfig = false;
  home-manager.users.cmbergamo = { ... }: {
    home.stateVersion = "26.05";
    programs.nushell = {
      enable = true;
      configFile.source = ../files/nushell/config.nu;
    };
  };
  home-manager.users.rmbergamo = { ... }: {
    home.stateVersion = "26.05";
    programs.nushell = {
      enable = true;
      configFile.source = ../files/nushell/config.nu;
    };
  };
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    stdenv.cc.cc.lib
    zlib
    openssl
    curl
    glibc
  ];

  # Garante ~/.local/bin no PATH (onde scripts de instalação costumam salvar binários)
  environment.shellInit = ''
    export PATH="$HOME/.local/bin:''${PATH}"
  '';
  environment.extraInit = config.environment.shellInit;

  # Pacotes adicionais do sistema
  environment.systemPackages = with pkgs; [
    git
  ];

  # Exige senha para comandos sudo
  security.sudo.wheelNeedsPassword = true;

  # Versão do estado inicial do NixOS
  system.stateVersion = "26.05";
}
