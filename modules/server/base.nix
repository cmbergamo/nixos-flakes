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
  networking.networkmanager.enable = false;
  systemd.network.enable = true;

  # Habilita DHCP automático em todas as interfaces de rede cabeadas (en*, eth*)
  systemd.network.networks."10-lan" = {
    matchConfig.Name = "en* eth*";
    networkConfig = {
      DHCP = "yes";
      IPv6AcceptRA = true;
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

  # --- Pacotes Essenciais do Servidor (Terminal-Only) ---
  environment.systemPackages = with pkgs; [
    # Diagnóstico & Monitoramento
    btop
    htop
    iotop
    sysstat
    ncdu
    smartmontools

    # Conectividade & Rede
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
