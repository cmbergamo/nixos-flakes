#!/usr/bin/env bash
# [FISCAL-I3-HML-INFRA-DSTK-SERVER-01] Renderiza o gabarito openbao.hcl.in (a MESMA fonte usada
# pelo modulo NixOS) com valores validados por allowlist, para o ensaio. Sem segredos.
#
# Uso: STATE_DIR=... TLS_DIR=... AUDIT_FILE=... [LISTEN_PORT=...] render-config.sh <gabarito.hcl.in>
set -euo pipefail

die() {
	printf 'ERRO: %s\n' "$*" >&2
	exit 1
}

gabarito="${1:-}"
[ -n "$gabarito" ] && [ -f "$gabarito" ] || die "uso: render-config.sh <gabarito.hcl.in>"

LISTEN_HOST="${LISTEN_HOST:-127.0.0.1}"
LISTEN_PORT="${LISTEN_PORT:-8200}"
CLUSTER_PORT="${CLUSTER_PORT:-8201}"
STATE_DIR="${STATE_DIR:?STATE_DIR obrigatorio}"
TLS_DIR="${TLS_DIR:?TLS_DIR obrigatorio}"
AUDIT_FILE="${AUDIT_FILE:?AUDIT_FILE obrigatorio}"
NODE_ID="${NODE_ID:-erp-fiscal-hml-1}"

[[ "$LISTEN_HOST" == "127.0.0.1" ]] || die "LISTEN_HOST so pode ser 127.0.0.1 (cofre nao e exposto na rede)"
[[ "$LISTEN_PORT" =~ ^[0-9]{2,5}$ && "$CLUSTER_PORT" =~ ^[0-9]{2,5}$ ]] || die "porta invalida"
[[ "$STATE_DIR" =~ ^/[A-Za-z0-9_./-]+$ && "$TLS_DIR" =~ ^/[A-Za-z0-9_./-]+$ && "$AUDIT_FILE" =~ ^/[A-Za-z0-9_./-]+$ ]] || die "caminho invalido"
[[ "$NODE_ID" =~ ^[A-Za-z0-9_-]+$ ]] || die "NODE_ID invalido"

saida="$(sed \
	-e "s|@LISTEN_HOST@|$LISTEN_HOST|g" \
	-e "s|@LISTEN_PORT@|$LISTEN_PORT|g" \
	-e "s|@CLUSTER_PORT@|$CLUSTER_PORT|g" \
	-e "s|@STATE_DIR@|$STATE_DIR|g" \
	-e "s|@TLS_DIR@|$TLS_DIR|g" \
	-e "s|@AUDIT_FILE@|$AUDIT_FILE|g" \
	-e "s|@NODE_ID@|$NODE_ID|g" \
	"$gabarito")"
if grep -qE '@[A-Z_]+@' <<<"$saida"; then
	die "marcador sem valor no gabarito"
fi
printf '%s\n' "$saida"
