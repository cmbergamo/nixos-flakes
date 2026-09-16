{ config, pkgs, lib, ... }:

let
  cfg = config.modules.nushell;
in
{
  # ===========================================================================
  # Nushell Padrão Universal (cmb-nix & dstk-server)
  # ===========================================================================

  options.modules.nushell = {
    manageUserConfig = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Se verdadeiro, um servico systemd de usuario sincroniza
        ~/.config/nushell/config.nu como symlink para /etc/nushell/config.nu.

        Deve ser desligado em hosts onde o Home Manager ja gerencia esse arquivo
        (programs.nushell.configFile): dois donos para o mesmo caminho fazem o HM
        falhar com "would be clobbered".
      '';
    };
  };

  config = {
    # Assegura que o pacote nushell esteja presente no sistema
    environment.systemPackages = [ pkgs.nushell ];

    # Publica o arquivo de configuração padrão do sistema
    environment.etc."nushell/config.nu".source = ./files/nushell/config.nu;

    # Popula novos usuários em /etc/skel
    environment.etc."skel/.config/nushell/config.nu".source = ./files/nushell/config.nu;
  }

  # optionalAttrs (e nao mkIf) para NAO instanciar o submodulo da unit quando
  # desligado: mkIf false ainda criaria uma entrada vazia em systemd.user.services.
  // lib.optionalAttrs cfg.manageUserConfig {
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
  };
}
