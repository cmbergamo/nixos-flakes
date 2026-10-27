#!/usr/bin/env bash
# [FISCAL-I3-HML-INFRA-DSTK-SERVER-01] Ciclo operacional da NF-e de HOMOLOGACAO pela identidade do
# worker (usuario "erp-fiscal"; o operador "fiscal-a1" o invoca via sudo, regra restrita a este
# comando). Superficie MINIMA: allowlist de subcomandos e de flags, valores validados por regex,
# nenhum caminho de arquivo do chamador (os JSON de entrada vao por STDIN para um arquivo temporario
# privado do erp-fiscal, removido ao sair). Nao existe subcomando nem flag que selecione producao
# (a CLI nao tem; o codigo da I3 torna producao impossivel por construcao).
#
# Uso (como fiscal-a1):
#   sudo -u erp-fiscal erp-fiscal-hml-nfe status-servico --empresa-id N --uf SC
#   sudo -u erp-fiscal erp-fiscal-hml-nfe emitente-endereco --usuario-id N   < endereco.json
#   sudo -u erp-fiscal erp-fiscal-hml-nfe preparar --usuario-id N            < entrada.json
#   sudo -u erp-fiscal erp-fiscal-hml-nfe status|consultar|reprocessar|verificar-artefatos \
#        --empresa-id N --documento N
#   sudo -u erp-fiscal erp-fiscal-hml-nfe listar --empresa-id N [--limite N]
set -euo pipefail
umask 077
cd /

die() {
	printf 'ERRO: %s\n' "$*" >&2
	exit 1
}

[ "$#" -ge 1 ] || die "uso: erp-fiscal-hml-nfe <subcomando> [flags] (veja o cabecalho)"
sub="$1"
shift

etc="${ERP_FISCAL_HML_ETC:-/etc/erp-fiscal-hml}"
release="${ERP_FISCAL_HML_RELEASE:-/opt/erp-fiscal-hml/current}"
tmpdir="${ERP_FISCAL_HML_TMP:-/var/lib/erp-fiscal/tmp}"

# valida "--flag valor" exatamente nas formas permitidas: nome=regex ...
declare -A tipo
tipo[--empresa-id]='^[0-9]{1,9}$'
tipo[--documento]='^[0-9]{1,12}$'
tipo[--usuario-id]='^[0-9]{1,9}$'
tipo[--limite]='^[0-9]{1,4}$'
tipo[--uf]='^[A-Z]{2}$'

obrigatorias=()
opcionais=()
usa_stdin=0
case "$sub" in
status-servico) obrigatorias=(--empresa-id --uf) ;;
status | consultar | reprocessar | verificar-artefatos) obrigatorias=(--empresa-id --documento) ;;
listar) obrigatorias=(--empresa-id); opcionais=(--limite) ;;
emitente-endereco | preparar) obrigatorias=(--usuario-id); usa_stdin=1 ;;
*) die "subcomando nao permitido: $sub" ;;
esac

[ $(($# % 2)) -eq 0 ] || die "flags devem vir em pares --flag valor"
declare -A vistas
repassar=()
while [ "$#" -gt 0 ]; do
	flag="$1"
	valor="$2"
	shift 2
	re="${tipo[$flag]:-}"
	[ -n "$re" ] || die "flag nao permitida: $flag"
	permitido=0
	for f in "${obrigatorias[@]}" "${opcionais[@]}"; do [ "$f" = "$flag" ] && permitido=1; done
	[ "$permitido" -eq 1 ] || die "flag $flag nao se aplica a $sub"
	[ -z "${vistas[$flag]:-}" ] || die "flag repetida: $flag"
	[[ "$valor" =~ $re ]] || die "valor invalido para $flag"
	vistas[$flag]=1
	repassar+=("$flag" "$valor")
done
for f in "${obrigatorias[@]}"; do [ -n "${vistas[$f]:-}" ] || die "flag obrigatoria ausente: $f"; done

# ambiente da CLI: so chaves da allowlist (mesmos arquivos do worker; sem segredo)
amb=()
while IFS='=' read -r chave valor; do
	case "$chave" in
	OPENBAO_ADDR | OPENBAO_CACERT | OPENBAO_SECRET_ID_FILE | DATABASE_URL | ERP_ENV | FISCAL_ARTEFATOS_DIR) amb+=("$chave=$valor") ;;
	esac
done <"$etc/worker.env"
amb+=("OPENBAO_ROLE_ID=$(tr -d '\n' <"$etc/fiscal-worker.role-id")")

arquivo=""
if [ "$usa_stdin" -eq 1 ]; then
	[ ! -t 0 ] || die "envie o JSON por stdin (ex.: ... < arquivo.json)"
	mkdir -p "$tmpdir"
	arquivo="$(mktemp "$tmpdir/entrada.XXXXXX.json")"
	trap 'rm -f "$arquivo"' EXIT
	head -c 262145 >"$arquivo"
	[ "$(stat -c %s "$arquivo")" -le 262144 ] || die "JSON maior que 256 KiB"
	jq -e . "$arquivo" >/dev/null 2>&1 || die "o conteudo recebido nao e JSON valido"
	repassar+=(--arquivo "$arquivo")
fi

env -i PATH="$PATH" HOME="${HOME:-/}" RUST_BACKTRACE=0 RUST_LOG=warn "${amb[@]}" \
	"$release/bin/fiscal_nfe_hml" "$sub" "${repassar[@]}"
