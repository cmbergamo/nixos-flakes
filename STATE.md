# ESTADO DO FLAKE — cmb-nix (para leitura rápida por IA)

> Doc de trabalho. Atualize ao mudar algo não-óbvio. Formato: fato denso, sem prosa.

## Máquina (verificado ao vivo)
- CPU Ryzen 7 5700X · RAM 32G · GPU AMD RX 6800/6900 XT (1002:73ff, amdgpu, sem NVIDIA)
- GRUB BIOS em /dev/sda e /dev/sdb (MBR, dual-boot Windows os-prober) · kernel linuxPackages_latest
- Hostname `cmb-nix` · user `cmbergamo` (wheel, networkmanager, gamemode) · shell padrão bash; nushell via wezterm
- IP LAN 192.168.1.18/24 (DHCP) · locale pt_BR.UTF-8 · tz America/Sao_Paulo · teclado br/ABNT2 (X+console+labwc)
- Impressora Epson L4260 Wi-Fi: 192.168.1.24 (DHCP — reservar p/ MAC e0:bb:9e:12:cf:e2), portas 9100+515+631 abertas; IPP puro exige TLS (HTTP 426)

## Flake
- inputs: nixos-unstable pin `c043004d` (26.11.20260905) + rust-overlay (follows) + oh-my-pi (follows nixpkgs)
- host único: `nixosConfigurations.cmb-nix` → `./configuration.nix`
- `allowUnfree=true`; `nix-ld` ON (rustup/FHS bins); stateVersion "26.05"
- `programs.omp.enable=true`: Oh-My-Pi instalado automaticamente no sistema (/run/current-system/sw/bin/omp) via release oficial v18.1.15 + nix-ld; PATH inclui ~/.local/bin
- devShell `nix develop` (rust-bin stable + r-a/clippy/rustfmt + mold); template `nix flake init -t .#rust`
- `/etc/nixos` é CÓPIA VELHA separada (sem ./modules) — fonte da verdade é ESTE repo; rebuild sempre `--flake .#cmb-nix`

## Módulos (todos importados em configuration.nix)
| arquivo | faz | pegadinhas/decisões |
|---|---|---|
| hosts/cmb-nix.nix | /mnt/windows: nvme0n1p3 931G (UUID 34C813AFC8136E7C, ntfs3 force); /mnt/dados: sda2 223G (UUID B8567E5F567E1DF6, ntfs-3g); udev anti-wakeup p/ mouse óptico USB; serviço systemd disable-acpi-wakeup (desativa GPP0/NVMe falso despertar no AMD AM4) | nomes estavam invertidos; sda2 (dados) falhava com -22 no ntfs3 por bug no $BadClus, corrigido usando ntfs-3g; nvme0n1p3 (windows) monta perfeito no ntfs3; bookmarks GTK Dados e Windows; falso wakeup por GPP0 e ruído do sensor óptico corrigidos |
| rust.nix | rustup + pkg-config/openssl/gdb/valgrind; PATH ~/.cargo/bin via shellInit+extraInit | pós-instalação manual: `rustup default stable && rustup component add rust-analyzer clippy rustfmt`; nushell precisa `path add ~/.cargo/bin` |
| gaming.nix | hardware.graphics + vulkan-tools; programs.steam (32bit ok); heroic (Epic), lutris, protonup-qt, gamescope, mangohud, prismlauncher; gamemode | GPU AMD: amdgpu nativo, nada extra |
| lxqt.nix | X11+LightDM estilizado (origami-dark, Adwaita-dark, Papirus-Dark, Bibata 24, Fira Mono 11, relógio pt_BR)+LXQt; xscreensaver estilizado (PAM+setuid, dialogTheme darkgray, Fira Mono); xkb br; portal; fontes Fira Mono+Fira Code+Inter+JetBrains Mono+Noto Color Emoji; papirus-icon-theme + bibata-cursors + breeze + breeze-icons + gnome-themes-extra; compositor picom (glx, vsync 165Hz, sombras, 8px cantos arredondados); tema escuro dark, Kvantum KvArcDark (SVG engine), seção [Palette] dark nativa, painel 36px/ícone 24px + logo nix-snowflake; Openbox Vent-dark com fontes Fira Mono 10; GTK 2/3/4 prefer-dark Adwaita-dark; dconf global color-scheme prefer-dark; swaylock em /etc/swaylock/config; helix catppuccin_mocha; BAT_THEME; QT_STYLE_OVERRIDE=kvantum; serviço `lxqt-config-setup` sincroniza atalhos, openbox, xscreensaver, kvantum, gtk2/3 bookmarks e defaults | openbox rc.xml publicado em /etc/xdg/openbox/rc.xml + symlink ~/.config/open…
| terminal.nix | remove xterm (services.xserver.excludePackages) e qterminal (environment.lxqt.excludePackages); publica /etc/xdg/wezterm/wezterm.lua com tema Catppuccin Mocha, Fira Mono 11.5, opacidade 0.95, padding 12px e nushell -l | wezterm lê XDG_CONFIG_DIRS; ~/.config/wezterm/wezterm.lua venceria; default_prog = nu -l (nushell login) |
| wayland.nix | sessão "LXQt (Wayland)": programs.labwc + sessionPackages lxqt-wayland-session; /etc/labwc (rc/env/autostart/menu/themerc com tema Vent-dark, Papirus-Dark e Fira Mono 10/11); /etc/xdg/lxqt/session.conf (compositor=labwc, lock_command_wayland=swaylock -f); serviço `labwc-config-link` symlink ~/.config/labwc→/etc/labwc | startlxqtwayland faz `labwc -C ~/.config/labwc`; themerc alinhado para paleta dark moderna (#2e3440/#eceff4); rc.xml usa Vent-dark e Fira Mono; swaylock lê /etc/swaylock/config (origami-dark + cores nórdicas) |
| memory.nix | zram zstd 50%; earlyoom 5%/5%; swappiness 20 | |
| printing.nix | avahi (nssmdns4+fw); drivers=[epson-escpr]; fila Epson-L4260 socket://192.168.1.24:9100; scanner SANE com sane-airscan em /etc/sane.d/airscan.conf (eSCL/Mopria https 192.168.1.24 porta 443 sem timeout mDNS) + epsonscan2 (serviço epsonscan2-net-config garante IP 192.168.1.24 e modo Network) + openFirewall; app simple-scan | L4260 responde eSCL nativo sobre HTTPS (testado e confirmado); grupos scanner e lp no usuário; epsonscan2 vinha por padrão buscando USB, corrigido declarativamente |
| wireguard.nix | cliente wg0; chave privada auto-gerada /var/lib/wireguard/wg0.key (generatePrivateKeyFile); peer condicional; NM unmanaged `interface-name:wg*`; DNS túnel 1.1.1.1/9.9.9.9 via resolvconf postSetup (linhas printf, sem heredoc — módulo injeta indentado) | **PENDENTE: preencher serverPublicKey+serverEndpoint (e tunnelIP) no topo do arquivo quando usuário passar dados do servidor**; sem peer = warning esperado no rebuild; após preencher: cadastrar `sudo wg show wg0 public-key` no servidor |
| flatpak.nix | services.flatpak; repo Flathub em /etc/flatpak/remotes.d/flathub.flatpakrepo + serviço systemd configure-flathub; bazaar (loja Flathub-first) + discover + flatpak-kcm | declarativo via remotes.d + registrado no OSTree p/ Discover, Bazaar e CLI |

## files/ (conteúdo publicado)
- globalkeyshortcuts.conf: Win+B firefox, Win+T wezterm, Win+E pcmanfm, Win+Esc xscreensaver-lock, Win+R runner, Super_L fancymenu, Print screengrab, volume/brightness/VT switches
- lxqt/lxqt.conf: theme=dark, icon_theme=Papirus-Dark, cursor_theme=Bibata-Modern-Classic (24), font=Fira Mono 10, style=kvantum, palette=Dark, seção [Palette] dark completa
- Kvantum/kvantum.kvconfig: theme=KvArcDark (renderização escura SVG em todos os widgets Qt6/PCManFM-Qt)
- lxqt/panel.conf: panelSize=36, iconSize=24, alignment=Center, fancymenu (nix-snowflake), taskbar (200px, raiseOnCurrentDesktop), worldclock, font=Fira Mono 10
- pcmanfm-qt/settings.conf: wallpaper origami-dark.png, font=Fira Mono 10, icon=Papirus-Dark, terminal=wezterm, sem atalhos soltos no desktop
- openbox/rc.xml: theme=Vent-dark, fontes Fira Mono 10/11
- labwc/rc.xml: theme=Vent-dark, icon=Papirus-Dark, fontes Fira Mono 10/11, Win+Return/Win+T wezterm, W-b/W-B firefox, W-e pcmanfm, W-Escape/W-l swaylock, Super_L onRelease→lxqt-qdbus openmenu, W-r→lxqt-runner, A-F2 runner, Print→screengrab, media keys via lxqt-qdbus volume (fallback wpctl no script), brightness lxqt-config-brightness, F12 removido (era qterminal)
- labwc/themerc: paleta dark moderna (#2e3440 / #eceff4 / botões suaves)
- xscreensaver/xscreensaver: tela de desbloqueio darkgray, tipografia Fira Mono, data formatada, fade suave
- swaylock/config: tela de desbloqueio Wayland com wallpaper origami-dark-labwc, indicador circular nórdico (#2e3440/#88c0d0/#bf616a), fonte Fira Mono 15
- labwc/environment: XKB_DEFAULT_LAYOUT=br; autostart: swaybg wallpaper stable + swayidle 300s wlopm off/on
- wezterm/wezterm.lua: color_scheme Catppuccin Mocha, Fira Mono 11.5, opacity 0.95, padding, nu -l
- helix/config.toml: theme catppuccin_mocha, cursor shapes, relative numbers
- flatpak/flathub.flatpakrepo: definição declarativa oficial do repositório Flathub (GPGKey, URL, metadata)

## Verificação (padrão desta sessão)
```bash
export XDG_CACHE_HOME=/tmp/nixcache-common   # fetcher-cache raiz bloqueia nix eval sem isso
nix eval --extra-experimental-features 'nix-command flakes' --impure \
  --expr 'let f = builtins.getFlake "/home/cmbergamo/nixos-flakes"; in f.nixosConfigurations.cmb-nix.config.<opcao>'
nix eval --raw ... --expr '...config.system.build.toplevel.outPath'   # ~10s, prova que instancia
```
- qdbus real: /nix/store/zl9j32ik1fbnww5skqxjvybcvbk0i3q9-qttools-6.11.2/bin/qdbus (não estava no PATH antes do terminal.nix; agora qt6.qttools instalado)
- último toplevel OK: fi746q9y6i40h6lw1961kk22r3xhddjy (pós-hosts+wireguard; warning de peer ausente é esperado)

## Não-fazendas (armadilhas já caindo fora)
- NÃO referenciar /nix/store/hash em arquivos de config (quebra no `nix flake update`) — usar /run/current-system/sw/...
- NÃO `programs.steam` antigo `services.xserver.desktopManager.steam` (renomeado); NÃO `hardware.opengl` (removido 25.11+)
- NÃO editar ~/.config/lxqt/globalkeyshortcuts.conf nem ~/.config/labwc como fonte (serviços/symlinks do flake vencem no login)
- session.conf do usuário (~/.config/lxqt/) vence [General] do /etc/xdg p/ QSettings; compositor=labwc já garantido via merge de escopo
- discover (KDE) permanece instalado por escolha do usuário; flatpak ativo (remotes padrão)

## Histórico
e00c0c9 (2026-09-08): wayland/terminal/printing/wireguard/hosts+STATE.md. Antes: `git log --oneline`.
