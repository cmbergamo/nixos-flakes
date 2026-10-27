#!/usr/bin/env bash
# [FISCAL-I3-HML-INFRA-DSTK-SERVER-01] Importa o certificado A1 de HOMOLOGACAO para o cofre.
# Executar como o operador do A1 (usuario "fiscal-a1"), em TERMINAL INTERATIVO, depois de copiar o
# .pfx/.p12 para o diretorio de recepcao. Este wrapper apenas prepara o ambiente e chama a CLI
# existente (fiscal_a1_cofre importar): quem pede a senha (sem eco, rpassword), valida titular e
# validade contra a fiscal_certificado_referencia cadastrada e grava PFX+senha no OpenBao (KV-v2).
# Aqui NAO ha senha em argv, em arquivo, em variavel de ambiente ou em historico.
#
# Identidade: AppRole "fiscal-importador" (so grava em hml-*; nao le o conteudo; nunca o root token).
#
# Uso: erp-fiscal-hml-importar-a1 --empresa <id> [--arquivo <caminho dentro da recepcao>] [--sem-verificar]
#      erp-fiscal-hml-importar-a1 --listar-empresas      (mostra id/codigo/razao social/CNPJ; nao importa nada)
set -euo pipefail
umask 077
cd / # carregar_dotenv() le .env do diretorio corrente: nunca rodar a CLI de dentro de um repositorio

die() {
	printf 'ERRO: %s\n' "$*" >&2
	exit 1
}

empresa=""
arquivo=""
verificar=1
listar=0
while [ "$#" -gt 0 ]; do
	case "$1" in
	--empresa) empresa="${2:-}"; shift 2 ;;
	--arquivo) arquivo="${2:-}"; shift 2 ;;
	--sem-verificar) verificar=0; shift ;;
	--listar-empresas) listar=1; shift ;;
	*) die "argumento desconhecido: $1" ;;
	esac
done
if [ "$listar" -eq 1 ]; then
	# descobre o ID da empresa com seguranca (somente leitura, papel erp_app via peer; sem segredo)
	db_url="$(sed -n 's/^DATABASE_URL=//p' "${ERP_FISCAL_HML_ETC:-/etc/erp-fiscal-hml}/importador.env" | head -1)"
	[ -n "$db_url" ] || die "importador.env sem DATABASE_URL"
	exec psql -X -P pager=off -c 'SELECT id, codigo, razao_social, cnpj FROM empresa ORDER BY id' "$db_url"
fi
[[ "$empresa" =~ ^[0-9]{1,9}$ ]] || die "uso: --empresa <id numerico da empresa> (ou --listar-empresas)"
[ -t 0 ] && [ -t 1 ] || die "execute em um terminal interativo (a senha do PFX e pedida sem eco)"

etc="${ERP_FISCAL_HML_ETC:-/etc/erp-fiscal-hml}"
recepcao="${ERP_FISCAL_HML_RECEPCAO:-/var/lib/erp-fiscal-a1/recepcao}"
release="${ERP_FISCAL_HML_RELEASE:-/opt/erp-fiscal-hml/current}"
cli="$release/bin/fiscal_a1_cofre"
[ -x "$cli" ] || die "binario nao instalado: $cli (o administrador instala o build rastreado)"
[ -d "$recepcao" ] || die "diretorio de recepcao ausente: $recepcao"

# --- localiza o arquivo (exatamente UM) -------------------------------------------------------
if [ -z "$arquivo" ]; then
	mapfile -t achados < <(find "$recepcao" -maxdepth 1 -type f \( -iname '*.pfx' -o -iname '*.p12' \) -printf '%f\n' | sort)
	[ "${#achados[@]}" -eq 1 ] || die "coloque exatamente UM .pfx/.p12 em $recepcao (encontrados: ${#achados[@]})"
	arquivo="$recepcao/${achados[0]}"
fi
real="$(realpath -e -- "$arquivo")" || die "arquivo inexistente"
case "$real" in "$(realpath -e -- "$recepcao")"/*) ;; *) die "o arquivo precisa estar dentro de $recepcao" ;; esac
[ -f "$real" ] && [ ! -L "$arquivo" ] || die "o arquivo deve ser regular (sem link simbolico)"
[ "$(stat -c %u -- "$real")" = "$(id -u)" ] || die "o arquivo deve pertencer ao usuario atual"
tamanho="$(stat -c %s -- "$real")"
{ [ "$tamanho" -gt 0 ] && [ "$tamanho" -le 65536 ]; } || die "tamanho incompativel com um A1 (${tamanho} bytes)"
chmod 0600 -- "$real"

# --- ambiente da CLI: so chaves da allowlist, de arquivos root-owned sem segredo --------------
amb=()
while IFS='=' read -r chave valor; do
	case "$chave" in
	OPENBAO_ADDR | OPENBAO_CACERT | OPENBAO_SECRET_ID_FILE | DATABASE_URL | ERP_ENV) amb+=("$chave=$valor") ;;
	esac
done <"$etc/importador.env"
amb+=("OPENBAO_ROLE_ID=$(tr -d '\n' <"$etc/fiscal-importador.role-id")")
for c in OPENBAO_ADDR OPENBAO_SECRET_ID_FILE DATABASE_URL ERP_ENV; do
	printf '%s\n' "${amb[@]}" | grep -q "^$c=" || die "importador.env sem $c"
done

# --- pre-checagem da referencia cadastrada (mensagem clara em vez de AcessoNegado no cofre) -----
db_url=""
for kv in "${amb[@]}"; do
	case "$kv" in DATABASE_URL=*) db_url="${kv#DATABASE_URL=}" ;; esac
done
ident="$(printf 'SELECT identificador_cofre FROM fiscal_certificado_referencia WHERE empresa_id = :e;\n' |
	psql -X -Atq -v e="$empresa" "$db_url" 2>/dev/null || true)"
[ -n "$ident" ] || die "a empresa $empresa NAO tem certificado-referencia cadastrado (ou o banco esta inacessivel): cadastre-o pela tela Fiscal > Certificado antes de importar (ver procedimento-a1.md)"
[[ "$ident" =~ ^hml-[A-Za-z0-9_.-]+$ ]] || die "identificador_cofre cadastrado ('$ident') deve comecar com 'hml-' (o AppRole de homologacao so enxerga o prefixo hml-). Corrija na tela Fiscal > Certificado e repita."
printf 'referencia cadastrada: identificador_cofre=%s\n' "$ident"

printf 'Importando %s (empresa %s). A senha do PFX sera pedida em seguida (sem eco).\n' "$(basename -- "$real")" "$empresa"
set +e
saida="$(env -i PATH="$PATH" HOME="$HOME" TERM="${TERM:-dumb}" RUST_BACKTRACE=0 RUST_LOG=warn "${amb[@]}" \
	"$cli" importar --empresa "$empresa" --arquivo "$real")"
codigo=$?
set -e
printf '%s\n' "$saida"
[ "$codigo" -eq 0 ] || die "importacao falhou (codigo $codigo) — o arquivo de recepcao foi mantido"
grep -q '^OK: material A1 gravado no cofre\.' <<<"$saida" || die "a CLI nao confirmou a gravacao — o arquivo de recepcao foi mantido"

# --- copia temporaria: remove (sem alegar apagamento fisico) ----------------------------------
rm -f -- "$real"
cat <<'EOF'

Copia de recepcao REMOVIDA do servidor (rm). Observacao honesta: o sistema de arquivos (XFS) nao
garante apagamento fisico irrecuperavel; por isso o diretorio de recepcao e privado (0700) do
operador e o arquivo ficou nele por pouco tempo. MANTENHA o A1 original em custodia segura FORA
do servidor — esta rotina nunca apaga a sua copia original.
EOF

if [ "$verificar" -eq 1 ]; then
	printf '\nVerificando com a identidade do WORKER (leitura do cofre, assinatura local, mTLS e status na SEFAZ HML)...\n'
	exec sudo -n -u erp-fiscal /run/current-system/sw/bin/erp-fiscal-hml-verificar-a1 --empresa "$empresa"
fi
