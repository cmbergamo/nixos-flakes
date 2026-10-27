#!/usr/bin/env bash
# [FISCAL-I3-HML-INFRA-DSTK-SERVER-01] ENSAIO do banco de homologacao fiscal: PostgreSQL 16 REAL e
# efemero, SOMENTE socket Unix (sem TCP), autenticacao PEER com pg_ident (a mesma estrategia do
# modulo NixOS), as migrations REAIS do repositorio, o script de producao erp-fiscal-hml-migrar, os
# privilegios do papel de runtime e o backup cifrado (pg_dump | age) com restauracao.
# Como no ensaio do cofre, NAO prova a segregacao de usuarios do servidor (usa o usuario atual).
#
# Uso: ENSAIO_DIR=<dir novo e vazio> [ENSAIO_PG_PORTA=15434] [ENSAIO_SAIDA=<tsv>] ensaio-postgres.sh
# Requer no PATH: initdb, pg_ctl, psql, pg_dump, pg_restore, pg_isready, sqlx, age, age-keygen, jq, ss.
set -euo pipefail
umask 077

die() {
	printf 'ERRO: %s\n' "$*" >&2
	exit 1
}

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$AQUI/../../.." && pwd)"
BIN="$RAIZ/deploy/fiscal-hml/bin"
for f in initdb pg_ctl psql pg_dump pg_restore pg_isready sqlx age age-keygen jq ss; do
	command -v "$f" >/dev/null || die "ferramenta ausente no PATH: $f"
done
WORK="${ENSAIO_DIR:?ENSAIO_DIR obrigatorio (diretorio novo e vazio)}"
mkdir -p "$WORK"
[ -z "$(ls -A "$WORK")" ] || die "ENSAIO_DIR precisa estar vazio"
PORTA="${ENSAIO_PG_PORTA:-15434}"
ss -ltn 2>/dev/null | grep -q ":$PORTA " && die "porta $PORTA ocupada"
mkdir -p "$WORK"/{dados,tmp,backup,etc}
# caminho de socket Unix tem limite de 107 bytes: diretorio curto no tmpfs do usuario
SOCK="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/efh-pg.XXXXXX")"
BANCO=erp_fiscal_hml
USUARIO="$(id -un)"
REGISTRO="$WORK/resultados.tsv"
: >"$REGISTRO"

limpar() {
	if [ -f "$WORK/dados/postmaster.pid" ]; then pg_ctl -D "$WORK/dados" -m fast stop >/dev/null 2>&1 || true; fi
	if [ -n "${ENSAIO_SAIDA:-}" ] && [ -f "$REGISTRO" ]; then cp "$REGISTRO" "$ENSAIO_SAIDA"; fi
	rm -rf "$SOCK"
	if [ "${ENSAIO_MANTER:-0}" != "1" ]; then rm -rf "$WORK"; fi
}
trap limpar EXIT

teste() {
	printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >>"$REGISTRO"
	printf '[%s] %s - %s%s\n' "$2" "$1" "$3" "${4:+ ($4)}"
}
espera() { # id descricao esperado obtido
	if [ "$3" = "$4" ]; then teste "$1" PASSOU "$2" "esperado=$3 obtido=$4"; else teste "$1" FALHOU "$2" "esperado=$3 obtido=$4"; fi
}
sql() { psql -X -h "$SOCK" -p "$PORTA" -d "$BANCO" -Atq "$@"; }

printf '== ENSAIO PostgreSQL — %s ==\n' "$(date +%Y-%m-%dT%H:%M:%S)"
printf 'postgres: %s | sqlx-cli: %s\n' "$(psql --version)" "$(sqlx --version)"

# fsync/WAL duravel desligados SO neste banco descartavel: nao sobrecarrega o disco do host (Gate ativo)
initdb -D "$WORK/dados" -U "$USUARIO" --auth-local=peer --auth-host=reject -E UTF8 --locale=C.UTF-8 >/dev/null
cat >"$WORK/dados/pg_ident.conf" <<EOF
# map       os-user       pg-role   (peer: o papel do banco deriva do usuario do SO)
fiscalhml   $USUARIO      $USUARIO
fiscalhml   $USUARIO      erp_migrador
fiscalhml   $USUARIO      erp_app
fiscalhml   $USUARIO      erp_backup
EOF
cat >"$WORK/dados/pg_hba.conf" <<EOF
local   $BANCO   erp_migrador   peer map=fiscalhml
local   $BANCO   erp_app        peer map=fiscalhml
local   $BANCO   erp_backup     peer map=fiscalhml
local   all       $USUARIO      peer
EOF
pg_ctl -D "$WORK/dados" -w -l "$WORK/pg.log" -o "-c listen_addresses='' -c unix_socket_directories='$SOCK' -c port=$PORTA -c fsync=off -c synchronous_commit=off -c full_page_writes=off" start >/dev/null
createdb -h "$SOCK" -p "$PORTA" "$BANCO"
if ss -ltn 2>/dev/null | grep -q ":$PORTA "; then
	teste P01 FALHOU "o banco nao deveria escutar em TCP"
else
	teste P01 PASSOU "PostgreSQL escuta SOMENTE em socket Unix (nenhum listener TCP na porta $PORTA)" "$(pg_isready -h "$SOCK" -p "$PORTA")"
fi

# --- procedimento oficial de provisionamento (script de producao) --------------------------------
if saida="$("$BIN/erp-fiscal-hml-migrar.sh" --repo "$RAIZ" --socket "$SOCK" --porta "$PORTA" --banco "$BANCO" 2>&1)"; then
	teste P02 PASSOU "erp-fiscal-hml-migrar: papeis -> migrations (sqlx, erp_migrador via peer) -> grants -> verificacao" "$(tail -1 <<<"$saida")"
else
	teste P02 FALHOU "erp-fiscal-hml-migrar" "$(tail -3 <<<"$saida" | tr '\n' '|')"
fi
arquivos="$(find "$RAIZ/backend/migrations" -maxdepth 1 -name '[0-9]*.sql' | wc -l)"
espera P03 "todas as migrations do repositorio aplicadas com sucesso" "$arquivos" "$(sql -c 'SELECT count(*) FROM _sqlx_migrations WHERE success')"
if saida2="$("$BIN/erp-fiscal-hml-migrar.sh" --repo "$RAIZ" --socket "$SOCK" --porta "$PORTA" --banco "$BANCO" 2>&1)"; then
	teste P04 PASSOU "migrar e idempotente (2a execucao conclui OK)"
else
	teste P04 FALHOU "migrar 2a execucao" "$(tail -2 <<<"$saida2" | tr '\n' '|')"
fi

# --- o runtime (erp_app) conecta pela MESMA URL que os binarios usam e nao tem poder de DDL -----
URL_APP="postgres://erp_app@${SOCK//\//%2F}:${PORTA}/${BANCO}"
espera P05 "erp_app conecta por socket Unix com peer/pg_ident (URL usada pelos binarios)" 1 "$(psql -X "$URL_APP" -Atqc 'SELECT 1')"
espera P06 "erp_app le a tabela da I3 (fiscal_certificado_referencia)" 0 "$(psql -X "$URL_APP" -Atqc 'SELECT count(*) FROM fiscal_certificado_referencia')"
nega() { # id descricao comando
	if psql -X "$URL_APP" -v ON_ERROR_STOP=1 -qc "$3" >/dev/null 2>"$WORK/tmp/erro.txt"; then
		teste "$1" FALHOU "$2" "a operacao NAO foi negada"
	elif grep -q 'permission denied\|must be owner\|no permission' "$WORK/tmp/erro.txt"; then
		teste "$1" PASSOU "$2" "$(head -1 "$WORK/tmp/erro.txt" | cut -c1-120)"
	else
		teste "$1" FALHOU "$2" "erro inesperado: $(head -1 "$WORK/tmp/erro.txt" | cut -c1-120)"
	fi
}
nega P07 "erp_app NAO cria tabelas (sem DDL)" 'CREATE TABLE intruso (x int)'
nega P08 "erp_app NAO derruba tabelas" 'DROP TABLE fiscal_certificado_referencia'
nega P09 "erp_app NAO desativa triggers da auditoria" 'ALTER TABLE auditoria_evento DISABLE TRIGGER ALL'
nega P10 "erp_app NAO apaga auditoria" 'DELETE FROM auditoria_evento'
nega P11 "erp_app NAO cria papeis" "CREATE ROLE intruso LOGIN"
# o migrador via URL tambem e peer (provado no P02); aqui: um papel sem map nao conecta
if psql -X "postgres://intruso@${SOCK//\//%2F}:${PORTA}/${BANCO}" -Atqc 'SELECT 1' >/dev/null 2>&1; then
	teste P12 FALHOU "papel sem mapeamento peer conseguiu conectar"
else
	teste P12 PASSOU "papel sem mapeamento peer/pg_ident NAO conecta (sem senha, sem TCP)"
fi
# o sqlx (mesmo parser de URL do runtime) aceita a URL do erp_app por socket Unix: o "migrate info"
# tenta criar a tabela de controle e o erp_app (corretamente) NAO pode — o "permission denied" prova
# que a URL foi interpretada, conectou e autenticou como erp_app.
sqlx migrate info --source "$RAIZ/backend/migrations" --database-url "$URL_APP" >"$WORK/tmp/info.txt" 2>&1 || true
if grep -q 'permission denied for schema public' "$WORK/tmp/info.txt" && ! grep -qi 'empty host\|configuration\|could not connect\|authentication' "$WORK/tmp/info.txt"; then
	teste P13 PASSOU "sqlx interpreta a URL (socket Unix percent-encoded), conecta e autentica como erp_app; DDL negado ao runtime"
else
	teste P13 FALHOU "sqlx com a URL do erp_app" "$(head -2 "$WORK/tmp/info.txt" | tr '\n' '|')"
fi

# o papel de backup le tudo e nao escreve nada
URL_BKP="postgres://erp_backup@${SOCK//\//%2F}:${PORTA}/${BANCO}"
espera P13b "erp_backup le dados (pg_read_all_data)" 140 "$(psql -X "$URL_BKP" -Atqc 'SELECT count(*) FROM _sqlx_migrations')"
if psql -X "$URL_BKP" -v ON_ERROR_STOP=1 -qc 'CREATE TABLE x (a int)' >/dev/null 2>&1 || psql -X "$URL_BKP" -v ON_ERROR_STOP=1 -qc 'INSERT INTO fiscal_certificado_referencia DEFAULT VALUES' >/dev/null 2>&1; then
	teste P13c FALHOU "erp_backup conseguiu escrever"
else
	teste P13c PASSOU "erp_backup NAO escreve (nem DDL nem DML)"
fi

# --- backup cifrado (script de producao, modo ensaio) e restauracao ------------------------------
age-keygen -o "$WORK/tmp/age-ident.txt" 2>/dev/null
age-keygen -y "$WORK/tmp/age-ident.txt" >"$WORK/etc/backup-recipients.txt"
export ERP_FISCAL_HML_BACKUP_TESTE=1 ERP_FISCAL_HML_ETC="$WORK/etc" ERP_FISCAL_HML_BACKUP_DIR="$WORK/backup" \
	RUNTIME_DIRECTORY="$WORK/run-backup" ERP_FISCAL_HML_PG_SOCKET="$SOCK" ERP_FISCAL_HML_PG_PORTA="$PORTA" \
	ERP_FISCAL_HML_PG_BANCO="$BANCO"
if "$BIN/erp-fiscal-hml-backup.sh" --sem-cofre --sem-artefatos >"$WORK/tmp/backup.out" 2>&1; then
	dump="$(find "$WORK/backup" -name '*_postgres.dump.age' | head -1)"
	teste P14 PASSOU "erp-fiscal-hml-backup gerou dump cifrado" "$(basename "$dump") $(stat -c %s "$dump") bytes"
else
	teste P14 FALHOU "backup" "$(tail -2 "$WORK/tmp/backup.out" | tr '\n' '|')"
	dump=""
fi
if [ -n "$dump" ]; then
	if grep -aq 'PGDMP' "$dump"; then teste P15 FALHOU "dump cifrado contem cabecalho PGDMP legivel"; else teste P15 PASSOU "o arquivo cifrado nao expoe o formato do dump (PGDMP ausente em claro)"; fi
	age -d -i "$WORK/tmp/age-ident.txt" -o "$WORK/tmp/dump.restaurar" "$dump"
	createdb -h "$SOCK" -p "$PORTA" erp_fiscal_hml_restauro
	pg_restore -h "$SOCK" -p "$PORTA" -d erp_fiscal_hml_restauro --no-owner --role="$USUARIO" "$WORK/tmp/dump.restaurar" >/dev/null 2>"$WORK/tmp/restore.err" || true
	orig="$(sql -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")"
	rest="$(psql -X -h "$SOCK" -p "$PORTA" -d erp_fiscal_hml_restauro -Atqc "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")"
	mig="$(psql -X -h "$SOCK" -p "$PORTA" -d erp_fiscal_hml_restauro -Atqc 'SELECT count(*) FROM _sqlx_migrations')"
	if [ "$orig" = "$rest" ] && [ "$mig" = "$arquivos" ]; then
		teste P16 PASSOU "restauracao do dump decifrado em banco novo: mesmas tabelas e migrations" "tabelas=$rest migrations=$mig"
	else
		teste P16 FALHOU "restauracao" "orig=$orig rest=$rest migrations=$mig/$arquivos"
	fi
fi
# sem destinatarios o backup NAO grava nada em claro
rm -rf "$WORK/backup2"
if ERP_FISCAL_HML_BACKUP_DIR="$WORK/backup2" ERP_FISCAL_HML_BACKUP_DESTINATARIOS="$WORK/etc/nao-existe.txt" \
	"$BIN/erp-fiscal-hml-backup.sh" --sem-cofre --sem-artefatos >"$WORK/tmp/backup2.out" 2>&1; then
	teste P17 FALHOU "backup sem destinatarios deveria falhar"
elif grep -q 'BACKUP_SEM_DESTINATARIO' "$WORK/tmp/backup2.out" && [ ! -d "$WORK/backup2" ]; then
	teste P17 PASSOU "backup sem destinatarios falha explicitamente e nao grava nada (nunca texto claro)"
else
	teste P17 FALHOU "backup sem destinatarios" "$(tail -1 "$WORK/tmp/backup2.out")"
fi

total="$(wc -l <"$REGISTRO")"
passou="$(awk -F'\t' '$2=="PASSOU"' "$REGISTRO" | wc -l)"
falhou="$(awk -F'\t' '$2=="FALHOU"' "$REGISTRO" | wc -l)"
printf '== RESUMO: %s testes, %s PASSOU, %s FALHOU ==\n' "$total" "$passou" "$falhou"
[ "$falhou" -eq 0 ]
