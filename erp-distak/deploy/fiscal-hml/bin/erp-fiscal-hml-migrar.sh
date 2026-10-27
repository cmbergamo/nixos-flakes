#!/usr/bin/env bash
# [FISCAL-I3-HML-INFRA-DSTK-SERVER-01] Provisiona o banco de HOMOLOGACAO fiscal pelo procedimento
# OFICIAL (deploy/postgres/README.md, "Ordem de provisionamento"): 10_criar_papeis.sql ->
# sqlx migrate run (como erp_migrador) -> 20_conceder_privilegios_runtime.sql -> verificacao.
# O fiscal_worker NUNCA roda migrations; este e o unico caminho. Executar como o usuario "postgres"
# do cluster dedicado (ex.: runuser -u postgres -- erp-fiscal-hml-migrar ...), que o pg_ident mapeia
# para o papel de migrations. Sem senha (autenticacao peer por socket Unix). Idempotente.
#
# Uso: erp-fiscal-hml-migrar --repo <checkout no commit do build> [--socket DIR] [--porta N] [--banco NOME]
set -euo pipefail
umask 077

die() {
	printf 'ERRO: %s\n' "$*" >&2
	exit 1
}

repo=""
socket="/run/postgresql"
porta="5434"
banco="erp_fiscal_hml"
while [ "$#" -gt 0 ]; do
	case "$1" in
	--repo) repo="${2:-}"; shift 2 ;;
	--socket) socket="${2:-}"; shift 2 ;;
	--porta) porta="${2:-}"; shift 2 ;;
	--banco) banco="${2:-}"; shift 2 ;;
	*) die "argumento desconhecido: $1" ;;
	esac
done
[[ "$repo" =~ ^/[A-Za-z0-9_./-]+$ ]] && [ -d "$repo/backend/migrations" ] || die "--repo deve ser a raiz de um checkout (com backend/migrations)"
[[ "$socket" =~ ^/[A-Za-z0-9_./-]+$ && "$porta" =~ ^[0-9]{2,5}$ && "$banco" =~ ^[a-z_][a-z0-9_]*$ ]] || die "parametro invalido"
papeis="$repo/deploy/postgres/10_criar_papeis.sql"
grants="$repo/deploy/postgres/20_conceder_privilegios_runtime.sql"
[ -f "$papeis" ] && [ -f "$grants" ] || die "scripts deploy/postgres/*.sql ausentes em $repo"

# URL no formato canonico do sqlx 0.8 para socket Unix: o diretorio do socket vai percent-encoded
# no host (postgres://usuario@%2Fdir%2Fdo%2Fsocket:porta/banco). "usuario@" com host vazio e invalido.
socket_enc="${socket//\//%2F}"

psql_admin() { psql -X -v ON_ERROR_STOP=1 -h "$socket" -p "$porta" -d "$banco" "$@"; }

printf '1/4 papeis (erp_migrador, erp_app) — 10_criar_papeis.sql\n'
psql_admin -q -f "$papeis" 2>&1 | grep -E 'NOTICE|ERROR' | sed 's/^/    /' || true

# Papel de BACKUP (somente leitura, sem privilegio administrativo): permite o pg_dump pelo servico
# de backup sem trocar de usuario do SO (peer: root -> erp_backup). Adicao desta rodada; nao altera
# os papeis oficiais erp_migrador/erp_app.
psql_admin -q <<'SQL' | grep -E 'ERROR' | sed 's/^/    /' || true
DO $$
BEGIN
	IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'erp_backup') THEN
		CREATE ROLE erp_backup LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS INHERIT;
	END IF;
END $$;
GRANT pg_read_all_data TO erp_backup;
SQL

printf '2/4 migrations (sqlx migrate run como erp_migrador, peer via socket Unix)\n'
DATABASE_URL="postgres://erp_migrador@${socket_enc}:${porta}/${banco}" \
	sqlx migrate run --source "$repo/backend/migrations" | tail -3 | sed 's/^/    /'

printf '3/4 privilegios minimos do runtime — 20_conceder_privilegios_runtime.sql\n'
psql_admin -q -f "$grants" 2>&1 | grep -E 'ERROR' | sed 's/^/    /' || true

printf '4/4 verificacao\n'
esperado="$(find "$repo/backend/migrations" -maxdepth 1 -name '[0-9]*.sql' -printf '%f\n' | sed 's/_.*//' | sort | tail -1 | sed 's/^0*//')"
aplicadas="$(psql_admin -Atqc 'SELECT count(*) FROM _sqlx_migrations WHERE success')"
cabeca="$(psql_admin -Atqc 'SELECT max(version) FROM _sqlx_migrations WHERE success')"
arquivos="$(find "$repo/backend/migrations" -maxdepth 1 -name '[0-9]*.sql' | wc -l)"
[ "$cabeca" = "$esperado" ] || die "versao do banco ($cabeca) diferente da ultima migration do checkout ($esperado)"
[ "$aplicadas" = "$arquivos" ] || die "migrations aplicadas ($aplicadas) diferente do numero de arquivos ($arquivos)"
for tabela in fiscal_certificado_referencia fiscal_nfe_emissao fiscal_nfe_status_servico fiscal_estabelecimento_endereco; do
	existe="$(psql_admin -Atqc "SELECT to_regclass('public.$tabela') IS NOT NULL")"
	[ "$existe" = "t" ] || die "tabela da I3 ausente: $tabela"
done
runtime_ok="$(psql_admin -Atqc "SELECT NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole FROM pg_roles WHERE rolname='erp_app'")"
[ "$runtime_ok" = "t" ] || die "erp_app deveria ser papel sem privilegio administrativo"
backup_ok="$(psql_admin -Atqc "SELECT NOT rolsuper AND NOT rolcreatedb AND NOT rolcreaterole AND pg_has_role('erp_backup','pg_read_all_data','member') FROM pg_roles WHERE rolname='erp_backup'")"
[ "$backup_ok" = "t" ] || die "erp_backup deveria ser leitura-apenas (pg_read_all_data) e sem privilegio administrativo"
printf 'OK: schema na versao %s (%s migrations), tabelas da I3 presentes, erp_app sem privilegio administrativo, erp_backup somente leitura.\n' "$cabeca" "$aplicadas"
