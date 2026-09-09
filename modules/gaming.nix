{ config, pkgs, ... }:

{
  # GPU AMD (Radeon, RDNA): driver amdgpu + OpenGL/Vulkan (radv).
  # Suporte a 32 bits mantido para jogos Wine/Proton executados via Flatpak.
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
    extraPackages = with pkgs; [ vulkan-tools ];
  };

  # Regras udev para controles e gamepads (Xbox, PlayStation, Switch, Steam Controller)
  # no Flatpak da Steam e outros jogos.
  hardware.steam-hardware.enable = true;

  # Regras de firewall para Steam / jogos (Remote Play, LAN transfers e servidores dedicados)
  networking.firewall = {
    allowedTCPPorts = [ 27015 27036 27037 27040 ];
    allowedUDPPorts = [ 27015 27036 10400 10401 ];
    allowedUDPPortRanges = [
      { from = 27031; to = 27035; }
    ];
  };

  # Ferramentas auxiliares de jogos no sistema:
  # gamescope (micro-compositor) e mangohud (overlay de FPS/hardware).
  # As lojas e launchers (Steam, Heroic, Lutris, ProtonUp-Qt, Prism Launcher)
  # foram migrados para Flatpak declarativo em modules/flatpak.nix.
  environment.systemPackages = with pkgs; [
    gamescope
    mangohud
  ];

  # Prioridade de CPU/IO/GPU durante jogos (gamemoderun <jogo>).
  programs.gamemode.enable = true;
}
