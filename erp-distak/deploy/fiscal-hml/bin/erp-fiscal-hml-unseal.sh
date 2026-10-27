#!/usr/bin/env bash
# [FISCAL-I3-HML-INFRA-DSTK-SERVER-01] Destrava o OpenBao do cofre fiscal apos um reinicio.
# O cofre NAO se destrava sozinho (sem auto-unseal: nao ha KMS/HSM/TPM aprovado neste host) —
# decisao deliberada; a intervencao humana e parte do desenho. Qualquer usuario pode executar;
# so quem possui chaves de recuperacao consegue destravar. Cada chave e lida por prompt OCULTO
# do proprio "bao" (nunca argv, nunca historico, nunca arquivo).
#
# Uso: erp-fiscal-hml-unseal
set -euo pipefail

die() {
	printf 'ERRO: %s\n' "$*" >&2
	exit 1
}

export BAO_ADDR="${BAO_ADDR:-https://127.0.0.1:8200}"
export BAO_CACERT="${BAO_CACERT:-/etc/erp-fiscal-hml/openbao-ca.pem}"
[ -t 0 ] || die "execute em um terminal interativo (prompt oculto)"

estado() { bao status -format=json 2>/dev/null || true; }

# Apos o ultimo unseal o no ainda e "standby" por alguns segundos ate assumir a lideranca; so
# declaramos sucesso com o cofre ATIVO (sys/health = 200), nunca antes.
aguardar_ativo() {
	local codigo
	for _ in $(seq 1 60); do
		codigo="$(curl -s -o /dev/null -w '%{http_code}' --cacert "$BAO_CACERT" "$BAO_ADDR/v1/sys/health" 2>/dev/null || true)"
		[ "$codigo" = "200" ] && return 0
		sleep 0.5
	done
	return 1
}

s="$(estado)"
[ -n "$s" ] || die "OpenBao inacessivel em $BAO_ADDR (servico ativo?)"
[ "$(jq -r .initialized <<<"$s")" = "true" ] || die "cofre nao inicializado (rode o bootstrap como administrador)"

for _ in $(seq 1 10); do
	s="$(estado)"
	if [ "$(jq -r .sealed <<<"$s")" = "false" ]; then
		aguardar_ativo || die "cofre destravado mas nao ficou ATIVO em 30 s (veja: journalctl -u openbao)"
		printf 'cofre DESTRAVADO e ATIVO (versao %s).\n' "$(jq -r .version <<<"$s")"
		exit 0
	fi
	printf 'progresso: %s/%s chaves.\n' "$(jq -r .progress <<<"$s")" "$(jq -r .t <<<"$s")"
	bao operator unseal >/dev/null
done
die "limite de tentativas atingido; cofre continua selado"
