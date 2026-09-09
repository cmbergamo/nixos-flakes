# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      ./modules/hosts/cmb-nix.nix
      ./modules/rust.nix
      ./modules/gaming.nix
      ./modules/lxqt.nix
      ./modules/terminal.nix
      ./modules/wayland.nix
      ./modules/memory.nix
      ./modules/printing.nix
      ./modules/wireguard.nix
      ./modules/flatpak.nix
    ];

  # Use the GRUB 2 boot loader.
  boot.loader.grub.enable = true;
  boot.loader.grub.devices = [ "/dev/sda" "/dev/sdb" ];
  boot.loader.grub.useOSProber = true;

  # Use latest kernel.
  boot.kernelPackages = pkgs.linuxPackages_latest;

  # Early KMS para GPU AMD Radeon RX 6600 (amdgpu)
  boot.initrd.kernelModules = [ "amdgpu" ];

  # Garante DisplayPort-2 sempre configurado como monitor primário ao iniciar o X11/LightDM
  services.xserver.displayManager.setupCommands = ''
    ${pkgs.xrandr}/bin/xrandr --output DisplayPort-2 --primary --auto || true
  '';

  # Hibernação (suspend-to-disk): partição swap para salvar e restaurar a memória
  boot.resumeDevice = "/dev/disk/by-uuid/bcd27a36-1bb4-4844-b1c3-0007ef6a97f6";

  # Driver de vídeo AMD nativo no X11 e autoconfiguração de telas ao plugar/ligar
  services.xserver.videoDrivers = [ "amdgpu" ];
  # Autorandr com perfil padrão para DisplayPort-2 e suporte à tela de login do LightDM (UID 78)
  services.autorandr = {
    enable = true;
    defaultTarget = "default";
    profiles.default = {
      fingerprint.DisplayPort-2 = "*";
      config.DisplayPort-2 = {
        enable = true;
        primary = true;
        mode = "1920x1080";
      };
    };
  };
  systemd.services.autorandr.environment.AUTORANDR_UID_MIN = "0";

  # Serviço acionado pelo udev ao ligar o monitor (evento DRM) para ativar a saída instantaneamente
  systemd.services.displayport-hotplug = {
    description = "Ativa DisplayPort-2 ao ligar o monitor após o boot";
    wantedBy = [ ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "dp-hotplug" ''
        for auth in /run/lightdm/root/:0 /home/*/.Xauthority; do
          if [ -r "$auth" ]; then
            DISPLAY=:0 XAUTHORITY="$auth" ${pkgs.xrandr}/bin/xrandr --output DisplayPort-2 --auto --primary || true
          fi
        done
      '';
    };
  };

  networking.hostName = "cmb-nix"; # Define your hostname.
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Enable networking
  networking.networkmanager.enable = true;

  # Enable network manager applet
  programs.nm-applet.enable = true;

  # Set your time zone.
  time.timeZone = "America/Sao_Paulo";

  # Select internationalisation properties.
  i18n.defaultLocale = "pt_BR.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "pt_BR.UTF-8";
    LC_IDENTIFICATION = "pt_BR.UTF-8";
    LC_MEASUREMENT = "pt_BR.UTF-8";
    LC_MONETARY = "pt_BR.UTF-8";
    LC_NAME = "pt_BR.UTF-8";
    LC_NUMERIC = "pt_BR.UTF-8";
    LC_PAPER = "pt_BR.UTF-8";
    LC_TELEPHONE = "pt_BR.UTF-8";
    LC_TIME = "pt_BR.UTF-8";
  };

  # X11, LightDM, LXQt e teclado ABNT2: ver ./modules/lxqt.nix


  # Enable CUPS to print documents.
  services.printing.enable = true;

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;

    # Use the WirePlumber session manager
    #wireplumber.enable = true;
  };

  # Flatpak & Flathub configurados em ./modules/flatpak.nix

  # Enable touchpad support (enabled default in most desktopManager).
  # services.libinput.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users."cmbergamo" = {
    isNormalUser = true;
    description = "cmbergamo";
    extraGroups = [ "networkmanager" "wheel" "gamemode" "scanner" "lp" ];
    packages = with pkgs; [
    #  thunderbird
    ];
  };

  # Firefox nativo removido em prol do Flatpak (declarado em modules/flatpak.nix)
  # programs.firefox.enable = false;
  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  # List packages installed in system profile.
  # You can use https://search.nixos.org/ to find more packages (and options).
environment.systemPackages = with pkgs; [
  helix
  #helium
  wezterm
  nushell
  wget
  git
  bat
  ripgrep
  fd
  ntfs3g
  epsonscan2
];

programs.nix-ld.enable = true;

  # Oh-My-Pi (omp): coding agent instalado automaticamente
  programs.omp = {
    enable = true;
    package = pkgs.runCommand "omp-18.1.15" {
      meta = {
        description = "Oh-My-Pi (omp) coding agent";
        homepage = "https://github.com/can1357/oh-my-pi";
        mainProgram = "omp";
      };
    } ''
      mkdir -p $out/bin
      cp ${pkgs.fetchurl {
        url = "https://github.com/can1357/oh-my-pi/releases/download/v18.1.15/omp-linux-x64";
        sha256 = "1p4s2h9ni0ynb31hdq3sjzjxkl11m6kpfihv953sqcmv3yj1hxbl";
      }} $out/bin/omp
      chmod +x $out/bin/omp
    '';
  };

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  # system.copySystemConfiguration = true;

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system - see https://nixos.org/manual/nixos/stable/#sec-upgrading for how
  # to actually do that.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "26.05"; # Did you read the comment?

}
