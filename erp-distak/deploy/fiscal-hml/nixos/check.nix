# Harness de VALIDACAO do modulo (nao e usado na implantacao): avalia o modulo em um sistema minimo
# e expoe as unidades/scripts para build. Ver ensaio/validar-modulo-nixos.sh.
let
	flake = builtins.getFlake "github:NixOS/nixpkgs/${builtins.getEnv "NIXPKGS_REV"}";
	sys = flake.lib.nixosSystem {
		system = "x86_64-linux";
		modules = [
			(builtins.getEnv "MODULO")
			({ ... }: {
				fileSystems."/" = { device = "/dev/null"; fsType = "xfs"; };
				boot.loader.grub.enable = false;
				system.stateVersion = "26.05";
				networking.hostName = "dstk-server";
				erpDistak.fiscalHml.enable = true;
				erpDistak.fiscalHml.operadorChavesSsh = [ "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPLACEHOLDERPLACEHOLDERPLACEHOLDERPLACEHOLDER dono-do-erp" ];
			})
		];
	};
	c = sys.config;
in {
	inherit sys;
	failedAssertions = map (a: a.message) (builtins.filter (a: !a.assertion) c.assertions);
	openbaoUnit = c.systemd.units."openbao.service".unit;
	workerUnit = c.systemd.units."erp-fiscal-hml-worker.service".unit;
	backupUnit = c.systemd.units."erp-fiscal-hml-backup.service".unit;
	apiUnit = c.systemd.units."erp-fiscal-hml-api.service".unit;
	etcApi = c.environment.etc."erp-fiscal-hml/api.env".source;
	backupTimer = c.systemd.units."erp-fiscal-hml-backup.timer".unit;
	workerWanted = c.systemd.services.erp-fiscal-hml-worker.wantedBy;
	pgHba = c.services.postgresql.authentication;
	sudo = c.security.sudo.extraRules;
	scriptsPkgs = builtins.filter (p: (p ? name) && flake.lib.hasPrefix "erp-fiscal-hml-" p.name) c.environment.systemPackages;
	etcWorker = c.environment.etc."erp-fiscal-hml/worker.env".source;
	etcImportador = c.environment.etc."erp-fiscal-hml/importador.env".source;
	users = builtins.attrNames (builtins.removeAttrs c.users.users [ "root" "nobody" ]);
}
