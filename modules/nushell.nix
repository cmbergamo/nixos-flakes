{ config, pkgs, lib, ... }:

{
  # ===========================================================================
  # Nushell Padrão Universal (cmb-nix & dstk-server)
  # ===========================================================================

  # Assegura que o pacote nushell esteja presente no sistema
  environment.systemPackages = [ pkgs.nushell ];

  # Publica o arquivo de configuração padrão do sistema
  environment.etc."nushell/config.nu".source = ./files/nushell/config.nu;

  # Popula novos usuários em /etc/skel
  environment.etc."skel/.config/nushell/config.nu".source = ./files/nushell/config.nu;

  # Serviço oneshot para vincular ~/.config/nushell/config.nu para sessões de usuário
  systemd.user.services.nushell-config-setup = {
    description = "Sincroniza configuração declarativa do Nushell";
    wantedBy = [ "default.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "nushell-config-setup" ''
        mkdir -p "$HOME/.config/nushell"
        if [ ! -e "$HOME/.config/nushell/config.nu" ] || [ -L "$HOME/.config/nushell/config.nu" ]; then
          ln -sfn /etc/nushell/config.nu "$HOME/.config/nushell/config.nu"
        fi
      '';
    };
  };
}
