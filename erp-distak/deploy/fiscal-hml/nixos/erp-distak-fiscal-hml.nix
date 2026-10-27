# [FISCAL-I3-HML-INFRA-DSTK-SERVER-01] Modulo NixOS da infraestrutura fiscal de HOMOLOGACAO no
# dstk-server: OpenBao (cofre do A1), PostgreSQL dedicado, worker fiscal, backup cifrado e a conta
# do operador do A1 — tudo SEGREGADO do usuario dos Quality Gates (uid proprio por servico).
#
# COMO USAR (administrador, com sudo): importe este arquivo na configuracao NIXOS VIVA do host (a
# que alimenta o nixos-rebuild; /etc/nixos/configuration.nix NAO e a viva neste host — ver
# evidencias/fiscal/fiscal-i3-hml-infra-dstk-server-01/bloqueio-e-desbloqueio.md):
#
#   imports = [ /caminho/deploy/fiscal-hml/nixos/erp-distak-fiscal-hml.nix ];
#   erpDistak.fiscalHml = {
#     enable = true;
#     operadorChavesSsh = [ "ssh-ed25519 AAAA... dono-do-erp" ];   # chave PUBLICA do dono
#   };
#
# O modulo e autocontido (nao altera sshd, firewall, Docker/Podman, tmux, rede ou os servicos
# existentes), nao inicia o worker por padrao e nao faz reboot. Nada aqui carrega segredo: chaves,
# secret_ids e a CA ficam em /var/lib e /etc/erp-fiscal-hml, criados pelos scripts do administrador.
{ config, lib, pkgs, ... }:

let
	cfg = config.erpDistak.fiscalHml;

	# --- caminhos do desenho (documentados em evidencias/.../README.md) ---------------------------
	etc = "/etc/erp-fiscal-hml";
	estadoCofre = "/var/lib/openbao";
	logsCofre = "/var/log/openbao";
	estadoWorker = "/var/lib/erp-fiscal";
	estadoOperador = "/var/lib/erp-fiscal-a1";
	backups = "/var/backups/erp-fiscal-hml";
	pgSocket = "/run/postgresql";
	pgPorta = 5434;
	pgBanco = "erp_fiscal_hml";
	urlBanco = "postgres://erp_app@${lib.replaceStrings [ "/" ] [ "%2F" ] pgSocket}:${toString pgPorta}/${pgBanco}";
	urlBancoMigrador = "postgres://erp_migrador@${lib.replaceStrings [ "/" ] [ "%2F" ] pgSocket}:${toString pgPorta}/${pgBanco}";
	enderecoCofre = "https://127.0.0.1:8200";

	# --- origem verificavel do OpenBao ----------------------------------------------------------------
	# O nixpkgs do host (26.11) traz OpenBao 2.6.2, VULNERAVEL (avisos publicos GHSA: RCE critica em
	# sys/storage/raft/snapshot-force e bypass de ACL, corrigidos em 2.6.3/2.7.0; outros em 2.6.4/2.7.1).
	# Padrao: se o pkgs do sistema ja traz >= 2.6.4, usa-o; senao usa o nixpkgs FIXADO abaixo (rev do
	# NixOS/nixpkgs + hash NAR, origem https do GitHub, binario do cache.nixos.org), onde o OpenBao e 2.7.1.
	# Para atualizar: escolha um rev novo de nixos-unstable (ou de uma branch estavel ja corrigida),
	# calcule o hash com `nix flake metadata github:NixOS/nixpkgs/<rev> --json | jq -r .locked.narHash`,
	# confira a versao e os avisos (docs: evidencias/.../openbao-versao.md) e troque as duas constantes.
	nixpkgsFixadoRev = "55bfb4d7437bd4e09ab7cba58a43bd68eb310044";
	nixpkgsFixadoNarHash = "sha256-jBYGPi4udQ9uo4KQp9m2J0546nJVQitG15gvZSaVVAs=";
	openbaoFixado = (import (builtins.fetchTarball {
		url = "https://github.com/NixOS/nixpkgs/archive/${nixpkgsFixadoRev}.tar.gz";
		sha256 = nixpkgsFixadoNarHash;
	}) { system = pkgs.stdenv.hostPlatform.system; }).openbao;
	openbaoPadrao = if lib.versionAtLeast pkgs.openbao.version "2.6.4" then pkgs.openbao else openbaoFixado;

	# --- configuracao do OpenBao: MESMO gabarito usado no ensaio -----------------------------------
	configCofre = pkgs.replaceVars ../openbao/openbao.hcl.in {
		LISTEN_HOST = "127.0.0.1";
		LISTEN_PORT = "8200";
		CLUSTER_PORT = "8201";
		STATE_DIR = estadoCofre;
		TLS_DIR = "${estadoCofre}/tls";
		AUDIT_FILE = "${logsCofre}/audit.log";
		NODE_ID = "erp-fiscal-hml-1";
	};

	# --- scripts operacionais (shellcheck roda no build; cada script define o proprio "set") -------
	script = nome: entradas: pkgs.writeShellApplication {
		name = nome;
		runtimeInputs = entradas;
		bashOptions = [ ];
		text = builtins.readFile (../bin + "/${nome}.sh");
	};
	base = [ pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.gnused pkgs.gawk ];
	scripts = rec {
		tls = script "erp-fiscal-hml-tls" (base ++ [ pkgs.openssl ]);
		provisionar = script "erp-fiscal-hml-provisionar" (base ++ [ cfg.openbaoPackage pkgs.jq ]);
		bootstrap = script "erp-fiscal-hml-bootstrap" (base ++ [ cfg.openbaoPackage pkgs.jq pkgs.curl provisionar ]);
		unseal = script "erp-fiscal-hml-unseal" (base ++ [ cfg.openbaoPackage pkgs.jq pkgs.curl ]);
		status = script "erp-fiscal-hml-status" (base ++ [ cfg.openbaoPackage pkgs.jq pkgs.curl pkgs.openssl config.services.postgresql.package ]);
		backup = script "erp-fiscal-hml-backup" (base ++ [ pkgs.age pkgs.jq pkgs.curl pkgs.gnutar config.services.postgresql.package ]);
		# openssl: o fallback do parser PKCS#12 do backend (PFX moderno, MAC SHA-256/PBES2) invoca `openssl pkcs12`
		importar = script "erp-fiscal-hml-importar-a1" (base ++ [ config.services.postgresql.package pkgs.openssl ]);
		apiRun = script "erp-fiscal-hml-api-run" base;
		nfe = script "erp-fiscal-hml-nfe" (base ++ [ pkgs.jq pkgs.openssl ]);
		admin = script "erp-fiscal-hml-admin" (base ++ [ cfg.openbaoPackage pkgs.jq pkgs.curl ]);
		isolamento = script "erp-fiscal-hml-verificar-isolamento" (base ++ [ pkgs.curl pkgs.openssh pkgs.acl pkgs.procps pkgs.iproute2 config.services.postgresql.package ]);
		verificar = script "erp-fiscal-hml-verificar-a1" (base ++ [ pkgs.openssl ]);
		migrar = script "erp-fiscal-hml-migrar" (base ++ [ config.services.postgresql.package pkgs.sqlx-cli ]);
		logs = script "erp-fiscal-hml-logs" (base ++ [ pkgs.systemd ]);
		compilar = script "erp-fiscal-hml-compilar" (base ++ [ pkgs.git pkgs.jq pkgs.procps pkgs.util-linux ]);
	};

	# --- endurecimento comum dos servicos (systemd-analyze security) -------------------------------
	endurecimento = {
		NoNewPrivileges = true;
		PrivateTmp = true;
		PrivateDevices = true;
		ProtectSystem = "strict";
		ProtectHome = true;
		ProtectKernelTunables = true;
		ProtectKernelModules = true;
		ProtectKernelLogs = true;
		ProtectControlGroups = true;
		ProtectClock = true;
		ProtectHostname = true;
		ProtectProc = "invisible";
		ProcSubset = "pid";
		RestrictNamespaces = true;
		RestrictRealtime = true;
		RestrictSUIDSGID = true;
		LockPersonality = true;
		SystemCallArchitectures = "native";
		SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
		CapabilityBoundingSet = "";
		AmbientCapabilities = "";
		RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
		# segredos so em memoria: sem swap do cgroup e sem core dump
		MemorySwapMax = 0;
		LimitCORE = 0;
		UMask = "0077";
	};
in
{
	options.erpDistak.fiscalHml = {
		enable = lib.mkEnableOption "infraestrutura fiscal de homologacao (OpenBao + PostgreSQL + worker) segregada dos Gates";

		operadorChavesSsh = lib.mkOption {
			type = lib.types.listOf lib.types.str;
			default = [ ];
			description = ''
				Chaves SSH PUBLICAS autorizadas a entrar como o usuario "fiscal-a1" (o dono do ERP, que
				copia o A1 e digita a senha). Conta propria: NAO e o usuario dos Gates.
			'';
		};

		openbaoPackage = lib.mkOption {
			type = lib.types.package;
			default = openbaoPadrao;
			defaultText = lib.literalExpression "pkgs.openbao se >= 2.6.4, senao o OpenBao 2.7.1 do nixpkgs fixado por rev + hash";
			description = ''
				Pacote do OpenBao. Versao minima 2.6.4 (assertion): as versoes anteriores tem avisos de seguranca
				publicos graves (RCE critica em sys/storage/raft/snapshot-force, bypass de ACL). O padrao ja resolve
				isto sem downgrade: usa o pkgs do sistema se for >= 2.6.4, senao o nixpkgs fixado.
			'';
		};

		worker.habilitar = lib.mkOption {
			type = lib.types.bool;
			default = false;
			description = ''
				Inicia o erp-fiscal-hml-worker no boot. PADRAO false: so ligue depois do A1 importado e
				verificado (erp-fiscal-hml-verificar-a1) — por desenho o worker nao processa fila nenhuma
				antes disso. O servico fica instalado e pode ser iniciado a mao (systemctl start).
			'';
		};

		api.habilitar = lib.mkOption {
			type = lib.types.bool;
			default = false;
			description = ''
				Inicia a API do ERP (erp_backend, SO em 127.0.0.1:8080) no boot. PADRAO false: e um servico
				TEMPORARIO para o cadastro fiscal (empresa, perfil, certificado-referencia, endereco) pela
				tela do ERP via tunel SSH; suba com systemctl start, cadastre e pare. Roda como usuario
				proprio (erp-fiscal-api) e NUNCA acessa o cofre/A1.
			'';
		};

		release = lib.mkOption {
			type = lib.types.str;
			default = "/opt/erp-fiscal-hml/current";
			description = "Diretorio (symlink) do build rastreado: bin/ + build-info.json. Instalado pelo administrador.";
		};
	};

	config = lib.mkIf cfg.enable {
		assertions = [
			{
				assertion = lib.versionAtLeast cfg.openbaoPackage.version "2.6.4";
				message = "erpDistak.fiscalHml: OpenBao ${cfg.openbaoPackage.version} < 2.6.4 (RCE critica e bypass de ACL corrigidos em 2.6.3/2.7.0; outros em 2.6.4/2.7.1). Use o padrao do modulo ou um pacote >= 2.6.4.";
			}
			{
				assertion = cfg.operadorChavesSsh != [ ];
				message = "erpDistak.fiscalHml.operadorChavesSsh deve conter a chave PUBLICA do dono (login do usuario fiscal-a1).";
			}
		];

		# ---------------------------------------------------------------- usuarios e grupos ---------
		users.groups.openbao = { };
		users.users.openbao = {
			isSystemUser = true;
			group = "openbao";
			home = estadoCofre;
			description = "OpenBao - cofre do A1 fiscal (HML)";
		};
		users.groups.erp-fiscal = { };
		users.users.erp-fiscal = {
			isSystemUser = true;
			group = "erp-fiscal";
			home = estadoWorker;
			description = "Worker fiscal (HML)";
		};
		users.groups.erp-fiscal-api = { };
		users.users.erp-fiscal-api = {
			isSystemUser = true;
			group = "erp-fiscal-api";
			home = "/var/lib/erp-fiscal-api";
			description = "API do ERP para o cadastro fiscal (HML, temporaria)";
		};
		users.groups.fiscal-a1 = { };
		users.users.fiscal-a1 = {
			isNormalUser = true;
			group = "fiscal-a1";
			home = estadoOperador;
			createHome = false;
			description = "Operador do A1 fiscal (dono do ERP)";
			shell = pkgs.bashInteractive;
			hashedPassword = "!"; # sem senha: so entra por chave publica
			openssh.authorizedKeys.keys = cfg.operadorChavesSsh;
		};

		# ------------------------------------------------------------------ diretorios -------------
		systemd.tmpfiles.rules = [
			"d ${estadoCofre} 0700 openbao openbao -"
			"d ${estadoCofre}/raft 0700 openbao openbao -"
			"d ${estadoCofre}/tls 0700 openbao openbao -"
			"d /var/lib/erp-fiscal-hml-pki 0700 root root -"
			"d ${logsCofre} 0750 openbao openbao -"
			"d ${etc} 0755 root root -"
			"d ${etc}/credenciais 0700 root root -"
			"d ${estadoWorker} 0750 erp-fiscal erp-fiscal -"
			"d ${estadoWorker}/credenciais 0700 erp-fiscal erp-fiscal -"
			"d ${estadoWorker}/artefatos 0750 erp-fiscal erp-fiscal -"
			"d ${estadoWorker}/tmp 0700 erp-fiscal erp-fiscal -"
			"d /var/lib/erp-fiscal-api 0750 erp-fiscal-api erp-fiscal-api -"
			"d /var/lib/erp-fiscal-api/credenciais 0700 erp-fiscal-api erp-fiscal-api -"
			"d ${estadoOperador} 0700 fiscal-a1 fiscal-a1 -"
			"d ${estadoOperador}/recepcao 0700 fiscal-a1 fiscal-a1 -"
			"d ${estadoOperador}/credenciais 0700 fiscal-a1 fiscal-a1 -"
			"d ${backups} 0700 root root -"
			"d /opt/erp-fiscal-hml 0755 root root -"
			"d /opt/erp-fiscal-hml/releases 0755 root root -"
		];

		# ------------------------------------------------ configuracao legivel (sem segredos) -------
		environment.etc = {
			"erp-fiscal-hml/politicas/fiscal-worker.hcl".source = ../openbao/politicas/fiscal-worker.hcl;
			"erp-fiscal-hml/politicas/fiscal-importador.hcl".source = ../openbao/politicas/fiscal-importador.hcl;
			"erp-fiscal-hml/politicas/fiscal-backup.hcl".source = ../openbao/politicas/fiscal-backup.hcl;
			"erp-fiscal-hml/politicas/fiscal-recuperacao.hcl".source = ../openbao/politicas/fiscal-recuperacao.hcl;
			# Variaveis do worker (EnvironmentFile do servico E leitura do erp-fiscal-hml-verificar-a1).
			# Sem segredo: so enderecos e CAMINHOS (o secret_id fica em arquivo 0400 do proprio usuario).
			"erp-fiscal-hml/worker.env".text = lib.generators.toKeyValue { } {
				ERP_ENV = "homologacao";
				DATABASE_URL = urlBanco;
				OPENBAO_ADDR = enderecoCofre;
				OPENBAO_CACERT = "${etc}/openbao-ca.pem";
				OPENBAO_SECRET_ID_FILE = "${estadoWorker}/credenciais/openbao-secret-id";
				FISCAL_ARTEFATOS_DIR = "${estadoWorker}/artefatos";
			};
			# API de cadastro (opt-in): o bootstrap do ERP usa o papel de migrations so para validar/
			# reaplicar grants (o banco ja foi migrado pelo erp-fiscal-hml-migrar); sem segredo no arquivo.
			"erp-fiscal-hml/api.env".text = lib.generators.toKeyValue { } {
				ERP_ENV = "homologacao";
				BIND_ADDR = "127.0.0.1:8080";
				DATABASE_URL = urlBanco;
				MIGRATION_DATABASE_URL = urlBancoMigrador;
			};
			"erp-fiscal-hml/importador.env".text = lib.generators.toKeyValue { } {
				ERP_ENV = "homologacao";
				DATABASE_URL = urlBanco;
				OPENBAO_ADDR = enderecoCofre;
				OPENBAO_CACERT = "${etc}/openbao-ca.pem";
				OPENBAO_SECRET_ID_FILE = "${estadoOperador}/credenciais/openbao-secret-id";
			};
		};

		environment.systemPackages = [ cfg.openbaoPackage ] ++ lib.attrValues scripts;

		# --------------------------------------------------------------------- OpenBao ------------
		systemd.services.openbao = {
			description = "OpenBao - cofre do A1 fiscal (HML)";
			wantedBy = [ "multi-user.target" ];
			after = [ "network.target" ];
			# nao entra em loop de falha antes de o administrador gerar a PKI (erp-fiscal-hml-tls)
			unitConfig.ConditionPathExists = [ "${estadoCofre}/tls/server.crt" "${estadoCofre}/tls/server.key" ];
			serviceConfig = endurecimento // {
				ExecStart = "${cfg.openbaoPackage}/bin/bao server -config=${configCofre}";
				ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
				User = "openbao";
				Group = "openbao";
				Restart = "on-failure";
				RestartSec = "5s";
				TimeoutStopSec = "30s";
				ReadWritePaths = [ estadoCofre logsCofre ];
				# o cofre so conversa em loopback (defesa em profundidade alem do bind 127.0.0.1)
				IPAddressDeny = "any";
				IPAddressAllow = [ "127.0.0.0/8" "::1/128" ];
				# limites razoaveis: nao competir com os Gates
				MemoryMax = "1G";
				CPUQuota = "100%";
				TasksMax = 512;
				Nice = 5;
			};
		};

		# rotacao da auditoria (SIGHUP reabre o arquivo); 90 dias locais
		services.logrotate.settings."${logsCofre}/audit.log" = {
			frequency = "daily";
			rotate = 90;
			compress = true;
			delaycompress = true;
			missingok = true;
			notifempty = true;
			su = "openbao openbao";
			create = "0600 openbao openbao";
			postrotate = "systemctl kill -s HUP openbao.service || true";
		};

		# ------------------------------------------------------------ PostgreSQL dedicado ----------
		# Cluster NOVO e separado dos dois PostgreSQL em Podman do usuario dos Gates. Somente socket
		# Unix (sem TCP) e autenticacao PEER mapeada: o papel do banco deriva do usuario do SO.
		services.postgresql = {
			enable = true;
			package = pkgs.postgresql_16;
			enableTCPIP = false;
			ensureDatabases = [ pgBanco ];
			settings = {
				port = pgPorta;
				listen_addresses = lib.mkForce "";
				unix_socket_directories = pgSocket;
				max_connections = 30;
				shared_buffers = "256MB";
				log_connections = true;
			};
			authentication = lib.mkForce ''
				local all postgres peer map=fiscalhml
				local ${pgBanco} erp_migrador peer map=fiscalhml
				local ${pgBanco} erp_app peer map=fiscalhml
				local ${pgBanco} erp_backup peer map=fiscalhml
			'';
			identMap = ''
				fiscalhml postgres postgres
				fiscalhml postgres erp_migrador
				fiscalhml erp-fiscal erp_app
				fiscalhml fiscal-a1 erp_app
				fiscalhml erp-fiscal-api erp_app
				fiscalhml erp-fiscal-api erp_migrador
				fiscalhml root erp_backup
			'';
		};

		# --------------------------------------------------------------- worker fiscal -------------
		systemd.services.erp-fiscal-hml-worker = {
			description = "Worker fiscal NF-e (HOMOLOGACAO) — fiscal_worker";
			wantedBy = lib.optional cfg.worker.habilitar "multi-user.target";
			after = [ "network-online.target" "openbao.service" "postgresql.service" ];
			wants = [ "network-online.target" ];
			unitConfig.ConditionPathExists = "${cfg.release}/bin/fiscal_worker";
			# o fallback PKCS#12 do backend (PFX moderno) executa `openssl pkcs12`; sem isto o PATH da unidade nao o contem
			path = [ pkgs.openssl ];
			environment = {
				RUST_LOG = "info";
				RUST_BACKTRACE = "0";
				HOSTNAME = "dstk-server-fiscal-hml";
			};
			serviceConfig = endurecimento // {
				EnvironmentFile = "${etc}/worker.env";
				ExecStart = "${cfg.release}/bin/fiscal_worker";
				User = "erp-fiscal";
				Group = "erp-fiscal";
				Restart = "on-failure";
				RestartSec = "15s";
				TimeoutStopSec = "30s";
				ReadWritePaths = [ "${estadoWorker}/artefatos" ];
				ReadOnlyPaths = [ etc "${estadoWorker}/credenciais" "/opt/erp-fiscal-hml" ];
				MemoryDenyWriteExecute = true;
				MemoryMax = "1G";
				CPUQuota = "100%";
				TasksMax = 256;
				Nice = 10;
			};
		};

		# ------------------------------------------- API de cadastro fiscal (temporaria, opt-in) -----
		systemd.services.erp-fiscal-hml-api = {
			description = "API do ERP (HOMOLOGACAO) em loopback — cadastro fiscal temporario";
			wantedBy = lib.optional cfg.api.habilitar "multi-user.target";
			after = [ "postgresql.service" ];
			wants = [ "postgresql.service" ];
			unitConfig.ConditionPathExists = "${cfg.release}/bin/erp_backend";
			environment = {
				RUST_LOG = "info";
				RUST_BACKTRACE = "0";
			};
			serviceConfig = endurecimento // {
				EnvironmentFile = "${etc}/api.env";
				ExecStart = "${scripts.apiRun}/bin/erp-fiscal-hml-api-run";
				User = "erp-fiscal-api";
				Group = "erp-fiscal-api";
				Restart = "on-failure";
				RestartSec = "15s";
				TimeoutStopSec = "30s";
				ReadOnlyPaths = [ etc "/var/lib/erp-fiscal-api/credenciais" "/opt/erp-fiscal-hml" ];
				# so conversa em loopback (cliente via tunel SSH) e socket Unix do banco
				IPAddressDeny = "any";
				IPAddressAllow = [ "127.0.0.0/8" "::1/128" ];
				MemoryDenyWriteExecute = true;
				MemoryMax = "1G";
				CPUQuota = "100%";
				TasksMax = 256;
				Nice = 10;
			};
		};

		# ---------------------------------------------------------------- backup cifrado ----------
		systemd.services.erp-fiscal-hml-backup = {
			description = "Backup cifrado (age) do cofre, do banco e dos artefatos fiscais HML";
			after = [ "openbao.service" "postgresql.service" ];
			# sem destinatarios (chaves PUBLICAS age do dono) o backup nem tenta
			unitConfig.ConditionPathExists = "${etc}/backup-recipients.txt";
			environment.BAO_CACERT = "${etc}/openbao-ca.pem";
			serviceConfig = endurecimento // {
				Type = "oneshot";
				ExecStart = "${scripts.backup}/bin/erp-fiscal-hml-backup";
				User = "root";
				RuntimeDirectory = "erp-fiscal-hml-backup";
				RuntimeDirectoryMode = "0700";
				# root le os artefatos (dono erp-fiscal) e escreve o backup; CAP_DAC_READ_SEARCH para ler 0750
				CapabilityBoundingSet = [ "CAP_DAC_READ_SEARCH" ];
				AmbientCapabilities = [ "CAP_DAC_READ_SEARCH" ];
				ReadWritePaths = [ backups etc ];
				ReadOnlyPaths = [ estadoWorker pgSocket ];
				# sem MemoryDenyWriteExecute: o age e um binario Go e nao foi ensaiado sob essa restricao
				Nice = 15;
				IOSchedulingClass = "idle";
				CPUQuota = "50%";
			};
		};
		systemd.timers.erp-fiscal-hml-backup = {
			wantedBy = [ "timers.target" ];
			timerConfig = {
				OnCalendar = "*-*-* 03:30:00";
				Persistent = true;
				RandomizedDelaySec = "20m";
			};
		};

		# --------------------------------------------- verificacao do A1 pela identidade do worker ---
		# O operador (fiscal-a1) pode executar SOMENTE estes dois comandos, como erp-fiscal (que tem o
		# secret_id do worker), e iniciar/parar/consultar as DUAS unidades opt-in (API de cadastro e
		# worker) — comandos systemctl EXATOS, sem curinga. Os scripts validam os argumentos.
		security.sudo.extraRules = [
			{
				users = [ "fiscal-a1" ];
				runAs = "root";
				commands = map (c: { command = "/run/current-system/sw/bin/systemctl ${c}"; options = [ "NOPASSWD" ]; }) [
					"start erp-fiscal-hml-api.service"
					"stop erp-fiscal-hml-api.service"
					"status erp-fiscal-hml-api.service --no-pager"
					"start erp-fiscal-hml-worker.service"
					"stop erp-fiscal-hml-worker.service"
					"status erp-fiscal-hml-worker.service --no-pager"
				];
			}
			{
				users = [ "fiscal-a1" ];
				runAs = "erp-fiscal";
				commands = [
					{
						command = "/run/current-system/sw/bin/erp-fiscal-hml-verificar-a1 --empresa [0-9]*";
						options = [ "NOPASSWD" ];
					}
					# ciclo da NF-e de homologacao: o script valida subcomando/flags (allowlist) e recebe o
					# JSON por stdin; nao ha caminho de arquivo do chamador nem selecao de producao
					{
						command = "/run/current-system/sw/bin/erp-fiscal-hml-nfe *";
						options = [ "NOPASSWD" ];
					}
				];
			}
		];
	};
}
