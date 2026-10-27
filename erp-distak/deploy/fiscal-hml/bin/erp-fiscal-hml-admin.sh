#!/usr/bin/env bash
# [FISCAL-I3-HML-INFRA-DSTK-SERVER-01] Sessao ADMINISTRATIVA TEMPORARIA do cofre (break-glass).
# Depois do bootstrap nao existe root token. Para rotacionar secret_id, alterar politica ou fazer
# manutencao, o administrador (root) usa este comando, que:
#   1. autentica com o AppRole "fiscal-recuperacao" (so permite sys/generate-root-token/*);
#   2. gera um root token EXIGINDO o quorum de 3 das 5 chaves de recuperacao (prompt oculto);
#   3. executa o comando dado (ou um shell) com BAO_TOKEN no ambiente SO desse processo;
#   4. REVOGA o root token ao terminar (e o token de recuperacao).
# Sozinha, a credencial de recuperacao (arquivo 0400 do root) nao le segredo, nao escreve nada e nao
# altera politica: o poder vem das chaves de recuperacao, que NAO estao no servidor.
# (No OpenBao >= 2.6 o endpoint de geracao de root token e autenticado; sem esta identidade o cofre
# ficaria sem caminho de administracao depois da revogacao do root token.)
#
# Uso (root, terminal interativo):
#   erp-fiscal-hml-admin                                   # shell administrativo temporario
#   erp-fiscal-hml-admin -- erp-fiscal-hml-provisionar --politicas /etc/erp-fiscal-hml/politicas \
#       --role-ids-dir /etc/erp-fiscal-hml --secret-id-worker ... --rotacionar
set -euo pipefail
umask 077

die() {
	printf 'ERRO: %s\n' "$*" >&2
	exit 1
}

etc="${ERP_FISCAL_HML_ETC:-/etc/erp-fiscal-hml}"
export BAO_ADDR="${BAO_ADDR:-https://127.0.0.1:8200}"
export BAO_CACERT="${BAO_CACERT:-$etc/openbao-ca.pem}"
sid_arquivo="${ERP_FISCAL_HML_SID_RECUPERACAO:-$etc/credenciais/recuperacao-secret-id}"
role_id_arquivo="${ERP_FISCAL_HML_ROLE_RECUPERACAO:-$etc/fiscal-recuperacao.role-id}"

comando=()
if [ "$#" -gt 0 ]; then
	[ "$1" = "--" ] || die "uso: erp-fiscal-hml-admin [-- comando args...]"
	shift
	comando=("$@")
fi
[ -t 0 ] && [ -t 1 ] || die "execute em um terminal interativo (as chaves sao pedidas sem eco)"
[ -r "$sid_arquivo" ] || die "sem acesso a $sid_arquivo (execute como root)"

st="$(bao status -format=json 2>/dev/null || true)"
[ -n "$st" ] || die "OpenBao inacessivel em $BAO_ADDR"
[ "$(jq -r .sealed <<<"$st")" = "false" ] || die "cofre selado — destrave primeiro (erp-fiscal-hml-unseal)"
limiar="$(jq -r .t <<<"$st")"

token_rec=""
token_root=""
limpar() {
	if [ -n "$token_root" ]; then BAO_TOKEN="$token_root" bao token revoke -self >/dev/null 2>&1 || true; fi
	if [ -n "$token_rec" ]; then BAO_TOKEN="$token_rec" bao token revoke -self >/dev/null 2>&1 || true; fi
}
trap limpar EXIT

# 1. identidade de recuperacao (secret_id lido de arquivo; corpo por pipe)
token_rec="$(jq -n --rawfile r "$role_id_arquivo" --rawfile s "$sid_arquivo" \
	'{role_id: ($r|rtrimstr("\n")), secret_id: ($s|rtrimstr("\n"))}' |
	curl -sS --fail --cacert "$BAO_CACERT" -X POST -H 'Content-Type: application/json' --data-binary @- \
		"$BAO_ADDR/v1/auth/approle/login" | jq -r .auth.client_token)"
[ -n "$token_rec" ] && [ "$token_rec" != "null" ] || die "login do AppRole de recuperacao falhou"

# 2. geracao do root token (OTP local; chaves por stdin do CLI, nunca argv)
otp="$(BAO_TOKEN="$token_rec" bao operator generate-root -generate-otp)"
BAO_TOKEN="$token_rec" bao operator generate-root -cancel >/dev/null 2>&1 || true
nonce="$(BAO_TOKEN="$token_rec" bao operator generate-root -init -otp="$otp" -format=json | jq -r .nonce)"
[ -n "$nonce" ] && [ "$nonce" != "null" ] || die "nao foi possivel iniciar a geracao do token"
codificado=""
for i in $(seq 1 "$limiar"); do
	read -rsp "Chave de recuperacao $i/$limiar (sem eco): " chave </dev/tty
	printf '\n'
	resposta="$(printf '%s' "$chave" | BAO_TOKEN="$token_rec" bao operator generate-root -nonce="$nonce" -format=json - 2>&1)" ||
		die "chave recusada: $(printf '%s' "$resposta" | head -c 200)"
	unset chave
	codificado="$(jq -r '.encoded_token // empty' <<<"$resposta" 2>/dev/null || true)"
done
[ -n "$codificado" ] || die "quorum de chaves nao completou a geracao do token"
token_root="$(printf '%s' "$codificado" | BAO_TOKEN="$token_rec" bao operator generate-root -decode=- -otp="$otp")"
[ -n "$token_root" ] || die "falha ao decodificar o token"

# 3. executa com o token SO no ambiente do processo filho; 4. revoga ao sair (trap)
printf 'Sessao administrativa temporaria ativa: o token sera REVOGADO ao sair.\n'
if [ "${#comando[@]}" -gt 0 ]; then
	BAO_TOKEN="$token_root" "${comando[@]}"
else
	BAO_TOKEN="$token_root" PS1='[cofre-admin] \w \$ ' bash --noprofile --norc -i
fi
