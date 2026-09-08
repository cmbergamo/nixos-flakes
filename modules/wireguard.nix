{ config, lib, pkgs, ... }:

let
  # ===========================================================================
  # WireGuard — CLIENTE (esta máquina conecta a um servidor/provedor).
  #
  # Preencha os valores abaixo quando tiver os dados do servidor; a interface
  # wg0 já sobe com o rebuild, mas fica sem peer (inerte) até lá.
  #
  # Chave PRIVADA: gerada automaticamente no primeiro boot em
  #   /var/lib/wireguard/wg0.key (0600, root) — nunca vai para o git.
  # Depois do primeiro rebuild, pegue a chave PÚBLICA desta máquina para
  # cadastrar no servidor:
  #   sudo wg show wg0 public-key
  # ===========================================================================

  # IP que o servidor atribui a esta máquina no túnel (com máscara),
  # ex.: "10.8.0.2/24" ou o que vier no .conf do provedor.
  tunnelIP = "10.66.66.2/24";

  # Chave PÚBLICA do servidor (obrigatória para o peer existir).
  serverPublicKey = null;
  # ex.: serverPublicKey = "xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=";

  # Host:porta UDP do servidor.
  serverEndpoint = null;
  # ex.: serverEndpoint = "vpn.exemplo.com:51820";

  # Tráfego que passa pelo túnel. Padrão = túnel completo (sai tudo pela VPN).
  # Para tráfego seletivo, troque pelas redes do servidor, ex.:
  #   [ "10.8.0.0/24" ]
  serverAllowedIPs = [ "0.0.0.0/0" "::/0" ];

  # DNS usado dentro do túnel (publicamente acessível; 1.1.1.1 = Cloudflare).
  tunnelDNS = [ "1.1.1.1" "9.9.9.9" ];
in
{
  # O módulo do NixOS cuida de tudo: carrega o módulo kernel `wireguard`,
  # instala wireguard-tools e cria os serviços systemd (wireguard-wg0.service
  # + um serviço por peer, com resolução de nome de endpoint infinita —
  # funciona com servidor de IP dinâmico).
  networking.wireguard.interfaces.wg0 = {
    ips = [ tunnelIP ];
    privateKeyFile = "/var/lib/wireguard/wg0.key";
    generatePrivateKeyFile = true;

    # Peer único (servidor). Só existe quando serverPublicKey for preenchida.
    peers = lib.optionals (serverPublicKey != null) [
      {
        inherit serverPublicKey;
        inherit serverEndpoint;
        allowedIPs = serverAllowedIPs;
        # Mantém o NAT da sua rede vivo enquanto a conexão estiver ociosa.
        persistentKeepalive = 25;
      }
    ];

    # DNS do túnel via resolvconf (já habilitado na config principal).
    # Anuncia quando houver peer; linhas resolv.conf por stdin (sem heredoc
    # porque o módulo injeta este texto indentado no script systemd).
    postSetup = lib.optionalString (serverPublicKey != null) ''
      printf '%s\n' ${lib.escapeShellArg (lib.concatStringsSep "\n" (map (ns: "nameserver ${ns}") tunnelDNS))} | ${pkgs.resolvconf}/bin/resolvconf -a wg0 -m 0
    '';
    postShutdown = lib.optionalString (serverPublicKey != null) ''
      ${pkgs.resolvconf}/bin/resolvconf -d wg0 || true
    '';
  };

  # NetworkManager não deve gerenciar wg0 (ele bagunçaria rotas/DNS do túnel).
  networking.networkmanager.unmanaged = [ "interface-name:wg*" ];

  assertions = [
    {
      assertion = serverPublicKey == null || serverEndpoint != null;
      message = ''
        modules/wireguard.nix: serverPublicKey foi definida mas serverEndpoint
        não — preencha "host:porta" do servidor WireGuard.
      '';
    }
  ];

  warnings = lib.optionals (serverPublicKey == null) [
    ''
      wireguard: a interface wg0 está sem peer (serverPublicKey = null).
      Preencha os dados do servidor em modules/wireguard.nix e rode o rebuild
      de novo. Para cadastrar esta máquina no servidor, depois do primeiro
      rebuild: sudo wg show wg0 public-key
    ''
  ];
}
