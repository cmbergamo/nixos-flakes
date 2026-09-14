# ===========================================================================
# Template de Configuração de Hardware do Servidor (server-hardware.nix)
# ===========================================================================
# INSTRUÇÕES DE INSTALAÇÃO NO HARDWARE ALVO:
#
# 1. Ao instalar o NixOS na máquina servidora dedicada, execute:
#    nixos-generate-config --show-hardware-config > modules/hosts/server-hardware.nix
#
# 2. Isso sobrescreverá este template com os UUIDs reais de disco, módulos de
#    kernel e arquitetura da máquina servidora alvo.
#
# 3. NOTA SOBRE BOOTLOADER:
#    - Por padrão (UEFI), este template utiliza systemd-boot.
#    - Se a máquina alvo utilizar BIOS legada (MBR) em vez de UEFI, substitua o
#      bloco systemd-boot por:
#        boot.loader.grub.enable = true;
#        boot.loader.grub.device = "/dev/sda"; # Ou o disco correto de boot
# ===========================================================================

{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # Bootloader padrão (UEFI)
  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;

  # Módulos iniciais de kernel (placeholders comuns)
  boot.initrd.availableKernelModules = [ "xhci_pci" "ahci" "nvme" "usbhid" "usb_storage" "sd_mod" ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "kvm-amd" "kvm-intel" ];
  boot.extraModulePackages = [ ];

  # Partições placeholder (serão substituídas pelo nixos-generate-config no servidor)
  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-label/boot";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  swapDevices = [ ];

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}
