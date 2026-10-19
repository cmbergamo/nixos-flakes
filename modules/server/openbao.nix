{ config, pkgs, lib, ... }:

{
  # ===========================================================================
  # OpenBao — gerenciador de segredos (fork do HashiCorp Vault)
  #
  # - Servidor single-node com storage Raft persistente em /var/lib/openbao.
  # - UI web habilitada em http://172.17.0.7:8200/ui (via túnel WireGuard).
  # - Escuta em 0.0.0.0:8200, mas o firewall só libera a porta na interface wg0;
  #   na LAN a porta permanece fechada (apenas 22/tcp é exposta pelo base.nix).
  # - TLS desabilitado de propósito: o transporte é o túnel WireGuard. Para
  #   expor na internet, habilite TLS/ACME no listener antes de abrir a porta.
  #
  # Primeiro uso (manual, após o `nixos-rebuild switch`):
  #   export VAULT_ADDR=http://172.17.0.7:8200
  #   bao operator init            # guarde as 5 shares do unseal e o root token
  #   bao operator unseal <share>  # repita 3x (threshold padrão)
  #
  # O serviço não reinicia em `switch` (restartIfChanged = false no módulo do
  # nixpkgs) para não selar o storage e derrubar clientes.
  # ===========================================================================

  services.openbao = {
    enable = true;

    settings = {
      ui = true;

      # Endereço anunciado para clientes/redirects (IP do nó no túnel CMB-Net).
      api_addr = "http://172.17.0.7:8200";
      cluster_addr = "http://127.0.0.1:8201";

      # O módulo roda com DynamicUser + CapabilityBoundingSet vazio, então o
      # mlock do processo não é permitido; o OpenBao exige desabilitar.
      disable_mlock = true;

      storage.raft = {
        path = "/var/lib/openbao";
        node_id = "dstk-server";
      };

      listener.default = {
        type = "tcp";
        address = "0.0.0.0:8200";
        tls_disable = true;
      };
    };
  };

  # Acesso apenas pelo túnel WireGuard (a LAN continua bloqueada).
  networking.firewall.interfaces."wg0".allowedTCPPorts = [ 8200 ];
}
