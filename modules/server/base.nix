{ config, pkgs, ... }:

{
  # ===========================================================================
  # Módulo Base do Servidor (Headless, Alta Performance e Baixo Uso de Memória)
  # ===========================================================================

  # --- Tuning de Memória e Sistema Operacional ---
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  services.earlyoom = {
    enable = true;
    freeMemThreshold = 5;
    freeSwapThreshold = 5;
  };

  boot.tmp.cleanOnBoot = true;

  boot.kernel.sysctl = {
    "vm.swappiness" = 10;
    "vm.vfs_cache_pressure" = 50;
    "net.core.default_qdisc" = "fq";
    "net.ipv4.tcp_congestion_control" = "bbr";
    "net.ipv4.tcp_fastopen" = 3;
    "net.ipv4.tcp_syncookies" = 1;
    "net.ipv4.tcp_tw_reuse" = 1;
    "net.ipv4.tcp_fin_timeout" = 15;
  };

  # --- Manutenção Automática do Nix Store ---
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };

  nix.settings = {
    auto-optimise-store = true;
    experimental-features = [ "nix-command" "flakes" ];
  };

  # --- Rede e Firewall ---
  networking.useNetworkd = true;
  networking.useDHCP = false; # DHCP delegado nativamente ao systemd-networkd
  networking.networkmanager.enable = false;
  systemd.network.enable = true;

  # Força as interfaces ethernet eno* (eno1, eno2) administrativamente UP com DHCP
  systemd.network.networks."05-eno" = {
    matchConfig.Name = "eno*";
    linkConfig = {
      ActivationPolicy = "always-up";
      RequiredForOnline = false;
    };
    networkConfig = {
      DHCP = "yes";
      IPv6AcceptRA = true;
    };
  };

  # Habilita DHCP automático em todas as interfaces de rede cabeadas e wireless (en*, eth*, wl*, wlan*)
  systemd.network.networks."10-lan" = {
    matchConfig.Name = "en* eth* wl* wlan*";
    linkConfig = {
      ActivationPolicy = "always-up";
      RequiredForOnline = false;
    };
    networkConfig = {
      DHCP = "yes";
      IPv6AcceptRA = true;
    };
  };

  # Garante a nível de link do udev que as interfaces estejam em estado always-up
  systemd.network.links."10-lan" = {
    matchConfig.OriginalName = "en* eth* wl* wlan*";
    linkConfig = {
      ActivationPolicy = "always-up";
    };
  };

  # Serviço de inicialização prévia: garante ativação administrativa imediata das placas de rede no boot
  systemd.services.bring-network-interfaces-up = {
    description = "Garante que interfaces de rede ethernet eno1/eno2 e correlatas estejam administrativamente UP no boot";
    wantedBy = [ "network-pre.target" ];
    before = [ "network-pre.target" "systemd-networkd.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "bring-network-interfaces-up" ''
        for iface in /sys/class/net/en* /sys/class/net/eth*; do
          if [ -d "$iface" ]; then
            dev="$(basename "$iface")"
            ${pkgs.iproute2}/bin/ip link set dev "$dev" up || true
          fi
        done
      '';
    };
  };

  # Evita que o boot trave esperando por portas ethernet desconectadas em placas multi-porta
  systemd.network.wait-online.anyInterface = true;
  # Resolução de nomes DNS via systemd-resolved integrada ao networkd
  services.resolved = {
    enable = true;
    fallbackDns = [ "1.1.1.1" "8.8.8.8" ];
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 ];
  };

  # --- Acesso Remoto e Segurança ---
  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      # Permite login por senha para o primeiro bootstrap do servidor.
      # APÓS CADASTRAR CHAVES SSH (users.users.<user>.openssh.authorizedKeys.keys),
      # ALTERE PasswordAuthentication PARA false POR SEGURANÇA.
      PasswordAuthentication = true;
      PermitRootLogin = "prohibit-password";
    };
  };

  services.fail2ban.enable = true;

  # --- Containers (Podman) ---
  virtualisation.podman = {
    enable = true;
    dockerCompat = true;
    dockerSocket.enable = true;
    defaultNetwork.settings.dns_enabled = true;
  };

  # --- Desativação Explícita de Pilhas Desktop ---
  services.xserver.enable = false;
  services.pipewire.enable = false;
  services.printing.enable = false;

  # Suporte completo a terminfo de terminais modernos (WezTerm, Kitty, Alacritty)
  # Resolve o problema de caracteres que quebram linha ou rolam a tela no SSH
  environment.enableAllTerminfo = true;

  # --- Pacotes Essenciais do Servidor (Terminal-Only) ---
  environment.systemPackages = with pkgs; [
    pkgs.wezterm.terminfo
    btop
    htop
    iotop
    sysstat
    ncdu
    smartmontools
    curl
    wget
    rsync
    tcpdump
    dnsutils
    ethtool
    iproute2
    socat
    netcat-openbsd
    mtr

    # Terminal & Produtividade
    tmux
    helix
    neovim
    nushell
    git
    ripgrep
    fd
    bat
    eza
    fzf
    jq
    podman-compose

    # Sistemas de Arquivos
    e2fsprogs
    xfsprogs
    btrfs-progs
  ];
}
