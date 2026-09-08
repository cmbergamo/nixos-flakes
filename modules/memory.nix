{ config, pkgs, ... }:

{
  # Estratégias para manter o uso de memória baixo e o sistema responsivo.

  # Swap comprimido em RAM (zram): muito mais rápido que swap em disco e
  # reduz a pressão sobre a memória física.
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  # OOM killer preventivo: derruba o processo "vilão" antes do sistema
  # travar (evita aqueles freezes longos esperando swap em disco).
  services.earlyoom = {
    enable = true;
    freeMemThreshold = 5;
    freeSwapThreshold = 5;
  };

  # Prefere manter páginas ativas em RAM; swap só quando necessário.
  boot.kernel.sysctl."vm.swappiness" = 20;
}
