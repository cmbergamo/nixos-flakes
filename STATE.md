# ESTADO DO FLAKE — cmb-nix (para leitura rápida por IA)

> Doc de trabalho. Atualize ao mudar algo não-óbvio. Formato: fato denso, sem prosa.

## Máquina (verificado ao vivo)
- CPU Ryzen 7 5700X · RAM 32G · GPU AMD RX 6800/6900 XT (1002:73ff, amdgpu, sem NVIDIA)
- GRUB BIOS em /dev/sda e /dev/sdb (MBR, dual-boot Windows os-prober) · kernel linuxPackages_latest
- Hostname `cmb-nix` · user `cmbergamo` (wheel, networkmanager, gamemode) · shell padrão bash; nushell via wezterm
- IP LAN 192.168.1.18/24 (DHCP) · locale pt_BR.UTF-8 · tz America/Sao_Paulo · teclado br/ABNT2 (console+greeter+labwc; X não existe mais)
- Impressora Epson L4260 Wi-Fi: 192.168.1.24 (DHCP — reservar p/ MAC e0:bb:9e:12:cf:e2), portas 9100+515+631 abertas; IPP puro exige TLS (HTTP 426)

## Flake
- inputs: nixos-unstable pin `8ce4ef6c` (26.11.20260910) + rust-overlay (follows) + oh-my-pi (follows nixpkgs)
- host único: `nixosConfigurations.cmb-nix` → `./configuration.nix`
- `allowUnfree=true`; `nix-ld` ON (rustup/FHS bins); stateVersion "26.05"
- `programs.omp.enable=true`: Oh-My-Pi via input `oh-my-pi` do flake (compila do fonte localmente a cada bump — ~10min; sem cache binário; antes havia fetchurl v18.1.15 hardcoded que congelava a versão) + nix-ld; PATH inclui ~/.local/bin
- devShell `nix develop` (rust-bin stable + r-a/clippy/rustfmt + mold); template `nix flake init -t .#rust`
- `/etc/nixos` é CÓPIA VELHA separada (sem ./modules) — fonte da verdade é ESTE repo; rebuild sempre `--flake .#cmb-nix`

## Módulos (todos importados em configuration.nix)
| arquivo | faz | pegadinhas/decisões |
|---|---|---|
| hosts/cmb-nix.nix | /mnt/windows: nvme0n1p3 931G (UUID 34C813AFC8136E7C, ntfs3 force); /mnt/dados: sda2 223G (UUID B8567E5F567E1DF6, ntfs-3g); udev anti-wakeup p/ mouse óptico USB; serviço systemd disable-acpi-wakeup (desativa GPP0/NVMe falso despertar no AMD AM4) | nomes estavam invertidos; sda2 (dados) falhava com -22 no ntfs3 por bug no $BadClus, corrigido usando ntfs-3g; nvme0n1p3 (windows) monta perfeito no ntfs3; bookmarks GTK Dados e Windows; falso wakeup por GPP0 e ruído do sensor óptico corrigidos; hotplug xrandr/autorandr REMOVIDO no cutover Wayland (visava DisplayPort-2, conector nem usado — o ativo é DP-3; labwc auto-habilita no modo preferido) |
| rust.nix | rustup + pkg-config/openssl/gdb/valgrind; PATH ~/.cargo/bin via shellInit+extraInit | pós-instalação manual: `rustup default stable && rustup component add rust-analyzer clippy rustfmt`; nushell precisa `path add ~/.cargo/bin` |
| gaming.nix | hardware.graphics (enable32Bit); udev steam-hardware; firewall Steam (27015/27036/27037/27040 TCP, 27015/27036/10400-10401/27031-27035 UDP); gamescope + mangohud; gamemode | Steam, Heroic, Lutris, ProtonUp-Qt e Prism Launcher migrados para Flatpaks declarativos |
| lxqt.nix | módulo `services.xserver.desktopManager.lxqt` (ativação de pacotes/portais, com X desligado — sem asserções contra isso); excludePackages: qterminal+xscreensaver+obconf-qt; xkb br console; portal; fontes Fira Mono+Fira Code+Inter+JetBrains Mono+Noto Color Emoji; extras qt6ct+kvantum+breeze+papirus+bibata+gnome-themes-extra; tema escuro Kvantum KvArcDark, painel 36px/ícone 24px; GTK 2/3/4 prefer-dark; dconf global; swaylock /etc/swaylock/config; helix catppuccin; QT_STYLE_OVERRIDE=kvantum; serviço lxqt-config-setup sincroniza ~/.config | picom/xscreensaver/openbox rc.xml removidos com o X11; openbox continua instalado (pré-requisito do módulo) mas com xsessions strippado via overlay |
| terminal.nix | remove qterminal (via lxqt.nix); publica /etc/xdg/wezterm/wezterm.lua com tema Catppuccin Mocha, Fira Mono 11.5, opacidade 0.95, padding 12px e nushell -l | wezterm lê XDG_CONFIG_DIRS; ~/.config/wezterm/wezterm.lua venceria; default_prog = nu -l (nushell login) |
| wayland.nix | STACK GRÁFICO ÚNICO (X11/LightDM removidos): services.xserver.enable=mkForce false; programs.labwc (sessão crua strippada no pacote); greetd+ReGreet (greeter GTK4 sobre cage; origami-dark, prefer-dark, Papirus-Dark, Bibata, Fira Mono 11); sessionPackages=mkForce [lxqt-wayland-session] (farm=1 sessão); overlay strip xsessions do openbox+lxqt-session (overrideScope — `//` raso NÃO funciona em scope); XKB_DEFAULT_LAYOUT=br via sessionVariables (greeter NÃO herda env da unidade systemd — worker execveia com env do PAM/pam_env); portal lxqt=[lxqt,wlr,gtk]; /etc/labwc (rc/env/autostart/menu/themerc); session.conf compositor=labwc+swaylock; labwc-config-link | ReGreet varre XDG_DATA_DIRS inteiro → strips nos pacotes são obrigatórios (senão labwc/openbox/lxqt X vazam p/ tela de login); sem kanshi: labwc habilita toda saída no modo preferido (autoEnableOutputs); DP-3 é o conector em uso (o antigo xrandr mirava DisplayPort-2, já morto) |
| memory.nix | zram zstd 50%; earlyoom 5%/5%; swappiness 20 | |
| printing.nix | avahi (nssmdns4+fw); drivers=[epson-escpr]; fila Epson-L4260 socket://192.168.1.24:9100; scanner SANE com sane-airscan em /etc/sane.d/airscan.conf (eSCL/Mopria https 192.168.1.24 porta 443 sem timeout mDNS) + epsonscan2 (com overlay withNonFreePlugins=true para plugin de rede ESC/I-2 + serviço epsonscan2-net-config garante IP 192.168.1.24 e modo Network) + firewall portas 1865 TCP/UDP; app simple-scan | L4260 responde eSCL nativo sobre HTTPS (testado e confirmado); grupos scanner e lp no usuário; epsonscan2 exige plugin proprietário bundle para rede (porta 1865) |
| wireguard.nix | cliente wg0; chave privada auto-gerada /var/lib/wireguard/wg0.key (generatePrivateKeyFile); peer condicional; NM unmanaged `interface-name:wg*`; DNS túnel 1.1.1.1/9.9.9.9 via resolvconf postSetup (linhas printf, sem heredoc — módulo injeta indentado) | **PENDENTE: preencher serverPublicKey+serverEndpoint (e tunnelIP) no topo do arquivo quando usuário passar dados do servidor**; sem peer = warning esperado no rebuild; após preencher: cadastrar `sudo wg show wg0 public-key` no servidor |
| flatpak.nix | gerenciamento declarativo via nix-flatpak; auto-update semanal; pacotes declarativos: Firefox, RustDesk, LocalSend, Bazaar, Steam, Heroic, Lutris, ProtonUp-Qt, PrismLauncher; wrappers CLI para terminal/atalhos; firewall LocalSend portas 53317 TCP/UDP | migração do Firefox e jogos nativos para Flatpak; liberação da porta 53317 corrige descoberta do LocalSend pelo celular |

## files/ (conteúdo publicado)
- globalkeyshortcuts.conf: Win+B firefox, Win+T wezterm, Win+E pcmanfm, Win+R runner, Super_L fancymenu, Print screengrab, volume/brightness/VT switches (Win+Esc removido: era xscreensaver; no Wayland rc.xml já binda W-Esc/W-l → swaylock)
- lxqt/lxqt.conf: theme=dark, icon_theme=Papirus-Dark, cursor_theme=Bibata-Modern-Classic (24), font=Fira Mono 10, style=kvantum, palette=Dark, seção [Palette] dark completa
- Kvantum/kvantum.kvconfig: theme=KvArcDark (renderização escura SVG em todos os widgets Qt6/PCManFM-Qt)
- lxqt/panel.conf: panelSize=36, iconSize=24, alignment=Center, fancymenu (nix-snowflake), taskbar (200px, raiseOnCurrentDesktop), worldclock, font=Fira Mono 10
- pcmanfm-qt/settings.conf: wallpaper origami-dark.png, font=Fira Mono 10, icon=Papirus-Dark, terminal=wezterm, sem atalhos soltos no desktop
- labwc/rc.xml: theme=Vent-dark, icon=Papirus-Dark, fontes Fira Mono 10/11, Win+Return/Win+T wezterm, W-b/W-B firefox, W-e pcmanfm, W-Escape/W-l swaylock, Super_L onRelease→lxqt-qdbus openmenu, W-r→lxqt-runner, A-F2 runner, Print→screengrab, media keys via lxqt-qdbus volume (fallback wpctl no script), brightness lxqt-config-brightness, F12 removido (era qterminal)
- labwc/themerc: paleta dark moderna (#2e3440 / #eceff4 / botões suaves)
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
- último toplevel OK: j7xqi7dxcbzphjas51xmfbyvk7z746iw (pós-cutover Wayland; warning de peer wireguard ausente é esperado)

## Não-fazendas (armadilhas já caindo fora)
- NÃO referenciar /nix/store/hash em arquivos de config (quebra no `nix flake update`) — usar /run/current-system/sw/...
- NÃO `programs.steam` antigo `services.xserver.desktopManager.steam` (renomeado); NÃO `hardware.opengl` (removido 25.11+)
- NÃO editar ~/.config/lxqt/globalkeyshortcuts.conf nem ~/.config/labwc como fonte (serviços/symlinks do flake vencem no login)
- discover (KDE) permanece instalado por escolha do usuário; flatpak ativo (remotes padrão)
- session.conf do usuário (~/.config/lxqt/) vence [General] do /etc/xdg p/ QSettings; limpo pós-cutover (tinha window_manager=openbox órfão); compositor=labwc garantido via merge de escopo
- overlay com chave pontilhada (`lxqt.x = ...`) SUBSTITUI o namespace `pkgs.lxqt` inteiro (merge `//` raso) — para scopes (makeScope) usar SEMPRE `prev.lxqt.overrideScope (lFinal: lPrev: { ... })`
- `systemd.services.greetd...Environment` NÃO chega ao greeter: o worker do greetd execveia com o env montado pelo PAM (greetd/src/session/worker.rs) → injetar env de greeter/sessão via `environment.sessionVariables` (cai em /etc/pam/environment)
## Histórico
e00c0c9 (2026-09-08): wayland/terminal/printing/wireguard/hosts+STATE.md. Antes: `git log --oneline`.
