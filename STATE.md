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
| hosts/cmb-nix.nix | monta /mnt/windows + /mnt/dados (ntfs3, UUID, uid=1000, nofail, automount) | UUIDs reais /dev/disk/by-uuid; removido bigtime (inválido p/ ntfs3) |
| rust.nix | rustup + pkg-config/openssl/gdb/valgrind; PATH ~/.cargo/bin via shellInit+extraInit | pós-instalação manual: `rustup default stable && rustup component add rust-analyzer clippy rustfmt`; nushell precisa `path add ~/.cargo/bin` |
| gaming.nix | hardware.graphics + vulkan-tools; programs.steam (32bit ok); heroic (Epic), lutris, protonup-qt, gamescope, mangohud, prismlauncher; gamemode | GPU AMD: amdgpu nativo, nada extra |
| lxqt.nix | X11+LightDM+LXQt; xscreensaver (PAM+setuid — corrige desbloqueio); xkb br; portal; qt6ct+kvantum; atalhos globais via files/globalkeyshortcuts.conf + serviço symlink ~/.config/lxqt/ | serviço `lxqt-shortcuts-link`; GUI sobrescreve no próximo login |
| terminal.nix | remove xterm (services.xserver.excludePackages) e qterminal (environment.lxqt.excludePackages); publica /etc/xdg/wezterm/wezterm.lua | wezterm lê XDG_CONFIG_DIRS; ~/.config/wezterm/wezterm.lua venceria; default_prog = nu -l (nushell login) |
| wayland.nix | sessão "LXQt (Wayland)": programs.labwc + sessionPackages lxqt-wayland-session; /etc/labwc (rc/env/autostart/menu/themerc); /etc/xdg/lxqt/session.conf (compositor=labwc, lock_command_wayland=swaylock -f); serviço `labwc-config-link` symlink ~/.config/labwc→/etc/labwc | startlxqtwayland faz `labwc -C ~/.config/labwc` (só o symlink garante flake); script anexaria XKB pt — environment fixa br; autostart usa /run/current-system/sw/.../origami-dark-labwc.png (NUNCA store path); lxqt-leave usa liblxqt ScreenSaver → key `lock_command_wayland` de [General]; qt6.qttools=qdbus p/ lxqt-qdbus; polkit/swaylock-PAM/xwayland/portal-wlr vêm do helper wayland-session.nix |
| memory.nix | zram zstd 50%; earlyoom 5%/5%; swappiness 20 | |
| printing.nix | avahi (nssmdns4+fw); drivers=[epson-escpr]; hardware.printers.ensurePrinters Epson-L4260 socket://192.168.1.24:9100, model `epson-inkjet-printer-escpr/Epson-L4260_Series-epson-escpr-en.ppd` (FORMATO BARRA — `:` = driver dinâmico, falha); default printer; A4 | fila antiga https:// falhava p/ cert autoassinado; escpr em systemPackages NÃO aparece em lpinfo -m — usar services.printing.drivers; serviço ensure-printers roda lpadmin a cada boot/rebuild |
| wireguard.nix | cliente wg0; chave privada auto-gerada /var/lib/wireguard/wg0.key (generatePrivateKeyFile); peer condicional; NM unmanaged `interface-name:wg*`; DNS túnel 1.1.1.1/9.9.9.9 via resolvconf postSetup (linhas printf, sem heredoc — módulo injeta indentado) | **PENDENTE: preencher serverPublicKey+serverEndpoint (e tunnelIP) no topo do arquivo quando usuário passar dados do servidor**; sem peer = warning esperado no rebuild; após preencher: cadastrar `sudo wg show wg0 public-key` no servidor |

## files/ (conteúdo publicado)
- globalkeyshortcuts.conf: Win+B xdg-open, Win+T wezterm, Win+E pcmanfm, Win+Esc xscreensaver-lock, Win+R runner, Super_L fancymenu, Print screengrab, volume/brightness/VT switches
- labwc/rc.xml: Win+Return/Win+T wezterm, W-b/W-e/W-Escape/W-l swaylock, Super_L onRelease→lxqt-qdbus openmenu, W-r→lxqt-runner, A-F2 runner, Print→screengrab, media keys via lxqt-qdbus volume (fallback wpctl no script), brightness lxqt-config-brightness, F12 removido (era qterminal)
- labwc/environment: XKB_DEFAULT_LAYOUT=br; autostart: swaybg wallpaper stable + swayidle 300s wlopm off/on
- wezterm/wezterm.lua: só default_prog nu -l

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
