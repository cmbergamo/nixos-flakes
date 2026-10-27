#!/usr/bin/env bash
# [FISCAL-I3-HML-INFRA-DSTK-SERVER-01] Logs SANITIZADOS dos servicos fiscais (journald). Precisa de
# acesso ao journal (root ou grupo systemd-journal). Mascara tokens, secret_ids, UUIDs, trechos
# base64 longos (possivel PFX), valores de chaves sensiveis e quebras/escapes ANSI (log injection).
# Os binarios e o OpenBao ja nao registram segredo (testado); isto e defesa em profundidade.
#
# Uso: erp-fiscal-hml-logs [openbao|worker|backup|postgresql] [N linhas (padrao 100, max 2000)]
#      erp-fiscal-hml-logs --filtrar   (le stdin; usado nos testes de sanitizacao)
set -euo pipefail

die() {
	printf 'ERRO: %s\n' "$*" >&2
	exit 1
}

# Filtro de sanitizacao (stdin -> stdout). Reutilizado pelo modo "--filtrar" para teste.
filtrar() {
	sed -E \
		-e 's/\x1b\[[0-9;?]*[a-zA-Z]//g' \
		-e 's/\b(hvs|hvb|hvr|s)\.[A-Za-z0-9_-]{16,}/[TOKEN-MASCARADO]/g' \
		-e 's/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/[UUID-MASCARADO]/g' \
		-e 's/[A-Za-z0-9+\/]{80,}={0,2}/[BASE64-LONGO-MASCARADO]/g' \
		-e 's/("?(client_token|secret_id|senha|password|pfx_base64|authorization|x-vault-token)"?[ :=]+)"?[^" ,}]+/\1[MASCARADO]/Ig' |
		tr -d '\r'
}

if [ "${1:-}" = "--filtrar" ]; then
	filtrar
	exit 0
fi

alvo="${1:-worker}"
linhas="${2:-100}"
[[ "$linhas" =~ ^[0-9]{1,4}$ ]] && [ "$linhas" -le 2000 ] || die "N de linhas invalido (1..2000)"
case "$alvo" in
openbao) unidade="openbao.service" ;;
worker) unidade="erp-fiscal-hml-worker.service" ;;
backup) unidade="erp-fiscal-hml-backup.service" ;;
postgresql) unidade="postgresql.service" ;;
*) die "alvo desconhecido: $alvo (openbao|worker|backup|postgresql)" ;;
esac

journalctl -u "$unidade" -n "$linhas" --no-pager -o short-iso 2>/dev/null | filtrar
