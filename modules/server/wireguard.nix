{ config, pkgs, ... }:

{
  # ===========================================================================
  # WireGuard — Rede CMB-Net (dstk-server)
  #
  # Configuração derivada de CMB-Net.conf:
  # - Endereço IP do nó no túnel: 172.17.0.7/16
  # - Porta de escuta UDP: 51820
  # - Peer: Gateway/Servidor CMB-Net (35.211.106.233:51820)
  # - Sub-rede permitida/roteada: 172.17.0.0/16
  # - Keepalive persistente: 25 segundos
  #
  # Chave PRIVADA:
  # Deve ser provisionada no servidor em /etc/wireguard/wg0.key (0640, root:systemd-network)
  # para que não seja exposta no repositório git ou no Nix store público.
  # ===========================================================================

  # Abertura da porta UDP 51820 e confiança no tráfego da interface wg0 no firewall
  networking.firewall.allowedUDPPorts = [ 51820 ];
  networking.firewall.trustedInterfaces = [ "wg0" ];

  # Garante diretório seguro com grupo systemd-network para leitura pelo daemon
  systemd.tmpfiles.rules = [
    "d /etc/wireguard 0750 root systemd-network -"
  ];

  networking.wireguard.interfaces.wg0 = {
    ips = [ "172.17.0.7/16" ];
    listenPort = 51820;
    privateKeyFile = "/etc/wireguard/wg0.key";

    peers = [
      {
        publicKey = "T7lCMdgXOvs2OCxV89tZfG42GMVYY6/z2ki8CenJrjM=";
        allowedIPs = [ "172.17.0.0/16" ];
        endpoint = "35.211.106.233:51820";
        persistentKeepalive = 25;
      }
    ];
  };

  # Utilitários de linha de comando para depuração e inspeção (wg, wg-quick)
  environment.systemPackages = with pkgs; [
    wireguard-tools
  ];
}
