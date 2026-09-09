{ config, pkgs, ... }:

# ===========================================================================
# Configuração específica deste computador (cmb-nix).
# Monta automaticamente os outros HDs/SSDs instalados, por UUID
# (estável mesmo se trocar de porta SATA ou a ordem de detecção mudar).
#
# Mapeamento real dos discos:
#   /dev/nvme0n1p3 931G  NTFS  -> Windows (sistema, UUID 34C813AFC8136E7C) -> /mnt/windows
#   /dev/sda2      223G  NTFS  -> Dados (arquivos, UUID B8567E5F567E1DF6) -> /mnt/dados
#   /dev/sda1      578M  NTFS  -> "Reservado pelo Sistema" (não monta)
# ===========================================================================
{
  # Windows (NVMe 931G): monta via driver ntfs3 in-kernel com flag force.
  fileSystems."/mnt/windows" = {
    device = "/dev/disk/by-uuid/34C813AFC8136E7C";
    fsType = "ntfs3";
    options = [
      "uid=1000" "gid=100"        # você (cmbergamo) é o dono dos arquivos
      "noatime"
      "iocharset=utf8"
      "windows_names"
      "force"                     # monta mesmo se o Windows deixar a flag dirty (Fast Startup)
      "nofail"                    # não trava o boot se a partição estiver indisponível
      "x-systemd.automount"       # monta automaticamente ao acessar a pasta
    ];
  };

  # Dados (SATA SSD 223G): monta via ntfs-3g (o driver ntfs3 falha com -22 ao analisar $BadClus nesta partição).
  fileSystems."/mnt/dados" = {
    device = "/dev/disk/by-uuid/B8567E5F567E1DF6";
    fsType = "ntfs-3g";
    options = [
      "uid=1000" "gid=100"
      "dmask=022"
      "fmask=133"
      "windows_names"
      "nofail"
      "x-systemd.automount"
    ];
  };

  # Garante que os diretórios de montagem existam.
  systemd.tmpfiles.rules = [
    "d /mnt/windows 0755 root root -"
    "d /mnt/dados 0755 root root -"
  ];

  # Permite montar/desmontar outros volumes removíveis pelo gerenciador
  # de arquivos (thunar/pcmanftp-qt) sem senha de root.
  services.udisks2.enable = true;

  # ===========================================================================
  # Previne despertar falso/imediato ao suspender ou hibernar (AMD AM4 / Ryzen)
  # ===========================================================================

  # 1) Desativa wakeup pelo mouse óptico USB.
  # Sensores ópticos possuem microvibrações/ruído constante na mesa que acordam
  # o computador instantaneamente ao entrar em modo de economia de energia.
  # O computador continua acordando normalmente ao teclar qualquer botão do teclado
  # ou pelo botão Power do gabinete.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="18f8", ATTR{idProduct}=="0f97", ATTR{power/wakeup}="disabled"
    ACTION=="add", SUBSYSTEM=="input", ATTR{name}=="*Optical Mouse*", ATTR{power/wakeup}="disabled"

    # Ativa DisplayPort-2 automaticamente ao ligar o monitor após o boot
    ACTION=="change", SUBSYSTEM=="drm", TAG+="systemd", ENV{SYSTEMD_WANTS}+="displayport-hotplug.service"
  '';

  # 2) Desativa o nó ACPI GPP0 (PCIe / barramento do SSD NVMe).
  # Em placas-mãe AM4, a transição de energia do barramento NVMe gera um sinal
  # espúrio de wakeup em GPP0 que acorda o sistema no mesmo milissegundo.
  systemd.services.disable-acpi-wakeup = {
    description = "Desativa nós ACPI com falso despertar imediato no AMD AM4";
    wantedBy = [ "multi-user.target" ];
    after = [ "multi-user.target" ];
    script = ''
      for dev in GPP0; do
        if grep -q "^$dev.*\*enabled" /proc/acpi/wakeup; then
          echo "$dev" > /proc/acpi/wakeup
        fi
      done
    '';
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
  };
}
