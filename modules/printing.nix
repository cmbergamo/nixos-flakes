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

  # ===========================================================================
  # Scanner integrado da Epson L4260 (Wi-Fi):
  #
  # A L4260 suporta nativamente o protocolo eSCL (Apple AirScan / Mopria Scan)
  # sobre HTTPS (porta 443) e o protocolo Epson Net (porta 1865).
  #
  # Com o backend sane-airscan, o SANE descobre o scanner automaticamente via
  # mDNS (Avahi) e pelo IP configurado. Funciona diretamente em aplicativos
  # como Document Scanner (simple-scan), GIMP e Epson Scan 2 (epsonscan2).
  # ===========================================================================
  hardware.sane = {
    enable = true;
    openFirewall = true;
    extraBackends = with pkgs; [
      sane-airscan
      epsonscan2
    ];
    netConf = "192.168.1.24";
  };

  # Configuração declarativa do sane-airscan: busca instantânea (sem timeout de mDNS)
  # diretamente no endpoint eSCL seguro da impressora na rede local.
  environment.etc."sane.d/airscan.conf".text = ''
    [devices]
    "Epson EcoTank L4260" = https://192.168.1.24/eSCL/
  '';

  # Configuração declarativa do Epson Scan 2 (epsonscan2):
  # Garante que o aplicativo use o modo Network e aponte para o IP 192.168.1.24,
  # evitando que tente conectar via USB por padrão.
  systemd.user.services.epsonscan2-net-config = {
    description = "Configura o IP da Epson L4260 no Epson Scan 2";
    wantedBy = [ "default.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "epsonscan2-net-config" ''
        mkdir -p "$HOME/.epsonscan2/Network" "$HOME/.epsonscan2/Connection"
        cat > "$HOME/.epsonscan2/Network/epsonscan2.conf" << 'EOF'
[Network]
192.168.1.24
EOF
        if [ ! -f "$HOME/.epsonscan2/Connection/PreferredInfo.dat" ] || grep -q '"USB"' "$HOME/.epsonscan2/Connection/PreferredInfo.dat"; then
          cat > "$HOME/.epsonscan2/Connection/PreferredInfo.dat" << 'EOF'
{
    "Connection": {
        "string": "Network"
    },
    "ESDisplayName": {
        "string": "EPSON L4260 Series"
    }
}
EOF
        fi
      '';
    };
  };

  # Aplicativos de digitalização:
  #  - simple-scan: interface gráfica moderna e rápida para escanear em PDF ou imagem
  environment.systemPackages = with pkgs; [
    simple-scan
  ];
}
