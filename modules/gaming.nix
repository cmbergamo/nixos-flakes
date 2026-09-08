{ config, pkgs, ... }:

{
  # GPU AMD (Radeon, RDNA): driver amdgpu + OpenGL/Vulkan (radv), incluindo
  # os componentes de 32 bits que Steam e jogos via Proton exigem.
  hardware.graphics = {
    enable = true;
    extraPackages = with pkgs; [ vulkan-tools ];
  };

  # Steam (habilita também as bibliotecas de 32 bits necessárias).
  programs.steam = {
    enable = true;
    remotePlay.openFirewall = true;      # Steam Remote Play
    dedicatedServer.openFirewall = true; # servidores dedicados
  };

  # Epic Games Store via Heroic Games Launcher (nativo, open source),
  # mais Lutris (GOG/Amazon/etc.) e ProtonUp-Qt para instalar Proton-GE.
  # Obs.: a Epic não tem cliente nativo Linux; instale os jogos pela Heroic.
  # MangoHud (overlay de FPS) funciona como pacote: ative com MANGOHUD=1.
  environment.systemPackages = with pkgs; [
    heroic
    lutris
    protonup-qt
    gamescope
    mangohud
    prismlauncher # Minecraft
  ];

  # Prioridade de CPU/IO/GPU durante jogos (gamemoderun <jogo>).
  programs.gamemode.enable = true;
}
