{ config, pkgs, ... }:

# ===========================================================================
# Configuração específica deste computador (cmb-nix).
# Monta automaticamente os outros HDs/SSDs instalados, por UUID
# (estável mesmo se trocar de porta SATA ou a ordem de detecção mudar).
#
# Mapeamento detectado em 2026-09-07:
#   /dev/sda2      223G  NTFS  -> antigo Windows (sistema)
#   /dev/nvme0n1p3 931G  NTFS  -> dados
#   /dev/sda1      578M  NTFS  -> "Reservado pelo Sistema" (não monta;
#                                 acessível pelo gerenciador de arquivos
#                                 via udisks2 se precisar)
# ===========================================================================
{
  fileSystems."/mnt/windows" = {
    device = "/dev/disk/by-uuid/B8567E5F567E1DF6";
    fsType = "ntfs3";
    options = [
      "uid=1000" "gid=100"        # você (cmbergamo) é o dono dos arquivos
      "noatime"
      "iocharset=utf8"
      "windows_names"
      "nofail"                    # não trava o boot se o Windows deixar a partição suja/bloqueada
      "x-systemd.automount"       # monta sob demanda ao acessar a pasta
      "x-systemd.idle-timeout=1min"
    ];
  };

  fileSystems."/mnt/dados" = {
    device = "/dev/disk/by-uuid/34C813AFC8136E7C";
    fsType = "ntfs3";
    options = [
      "uid=1000" "gid=100"
      "noatime"
      "iocharset=utf8"
      "windows_names"
      "nofail"
      "x-systemd.automount"
      "x-systemd.idle-timeout=1min"
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
}
