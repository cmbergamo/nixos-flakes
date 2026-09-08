{ config, pkgs, ... }:

{
  # ===========================================================================
  # Impressora Epson EcoTank L4260 (Wi-Fi, 192.168.1.24) — só neste computador.
  #
  # O módulo hardware.printers garante a fila declarativamente a cada boot /
  # rebuild (lpadmin). Como esta config é por host, a fila só existe aqui; e
  # com compartilhamento desligado (defaultShared/browsing = false, padrões do
  # cupsd do NixOS) nenhuma outra máquina da rede a vê.
  # ===========================================================================

  # Avahi (mDNS): é o que o backend "dnssd" do CUPS usa para LOCALIZAR
  # impressoras de rede na busca automática (lpinfo -v / página "Adicionar
  # Impressora"). Sem isto o CUPS não achava a L4260 no Wi-Fi.
  # nssmdns4 resolve nomes *.local (ex.: EPLAC873B.local) pelo sistema.
  services.avahi = {
    enable = true;
    nssmdns4 = true;
    openFirewall = true;
  };

  # Driver ESC/P-R da Epson: coloca os PPDs (inclusive o da L4260 Series) no
  # ModelDir do CUPS — antes o pacote estava só no systemPackages, invisível
  # para o lpinfo -m.
  services.printing.drivers = [ pkgs.epson-escpr ];

  # Fila declarativa. deviceUri em socket:// (porta 9100, "jetdirect"):
  #   - ipp:// puro não funciona: a impressora exige TLS (responde HTTP 426).
  #   - https:///ipps:// falhava por causa do certificado autoassinado da
  #     Epson (a fila antiga ficou "desabilitada: configuration is incorrect").
  #   - socket:// funciona sem TLS na LAN de casa; o raster é gerado pelo
  #     driver escpr. Se quiser status/tinta, dá para trocar para
  #     ipps://EPLxxxxxx.local:631/ipp/print depois de confiar o cert dela.
  #
  # Atenção: o IP 192.168.1.24 vem do DHCP do roteador — reserve-o para o
  # MAC da impressora (e0:bb:9e:12:cf:e2) para o socket:// nunca quebrar.
  hardware.printers = {
    ensureDefaultPrinter = "Epson-L4260";
    ensurePrinters = [
      {
        name = "Epson-L4260";
        location = "Escritório";
        description = "Epson EcoTank L4260 (Wi-Fi)";
        deviceUri = "socket://192.168.1.24:9100";
        model = "epson-inkjet-printer-escpr/Epson-L4260_Series-epson-escpr-en.ppd";
        ppdOptions = {
          PageSize = "A4";
        };
      }
    ];
  };
}
