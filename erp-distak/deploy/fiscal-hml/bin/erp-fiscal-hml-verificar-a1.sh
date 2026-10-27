#!/usr/bin/env bash
# [FISCAL-I3-HML-INFRA-DSTK-SERVER-01] Verificacao do A1 importado, com a identidade do WORKER
# (AppRole "fiscal-worker": le o cofre, nunca escreve). Executado como usuario "erp-fiscal" —
# normalmente via "sudo -u erp-fiscal" a partir do operador (regra de sudoers restrita a este
# comando exato). So aceita "--empresa <id>".
#
# Criterio de sucesso e a EVIDENCIA, nao o exit code: a CLI "homologar" retorna 0 mesmo quando so
# registra HOMOLOGACAO_REAL_PENDENTE_INSUMO (SEFAZ inalcancavel). Aqui exigimos, no texto real:
#   1. titular/validade/fingerprint lidos do material resolvido no cofre pelo AppRole do worker;
#   2. "OK: assinatura XML-DSig sintetica gerada e verificada localmente.";
#   3. "SEFAZ homologacao respondeu: cStat=107" (mTLS real com o A1 contra a SEFAZ de HML);
#   4. "fiscal_nfe_hml status-servico" => situacao=em_operacao (e registrada).
# Nenhuma NF-e e emitida; e so consulta de status de servico.
#
# Uso: erp-fiscal-hml-verificar-a1 --empresa <id>
set -euo pipefail
umask 077
cd /

die() {
	printf 'ERRO: %s\n' "$*" >&2
	exit 1
}

[ "$#" -eq 2 ] && [ "$1" = "--empresa" ] || die "uso: erp-fiscal-hml-verificar-a1 --empresa <id>"
empresa="$2"
[[ "$empresa" =~ ^[0-9]{1,9}$ ]] || die "empresa invalida"

etc="${ERP_FISCAL_HML_ETC:-/etc/erp-fiscal-hml}"
release="${ERP_FISCAL_HML_RELEASE:-/opt/erp-fiscal-hml/current}"
amb=()
while IFS='=' read -r chave valor; do
	case "$chave" in
	OPENBAO_ADDR | OPENBAO_CACERT | OPENBAO_SECRET_ID_FILE | DATABASE_URL | ERP_ENV | FISCAL_ARTEFATOS_DIR) amb+=("$chave=$valor") ;;
	esac
done <"$etc/worker.env"
amb+=("OPENBAO_ROLE_ID=$(tr -d '\n' <"$etc/fiscal-worker.role-id")")
executa() { env -i PATH="$PATH" HOME="${HOME:-/}" RUST_BACKTRACE=0 RUST_LOG=warn "${amb[@]}" "$@" 2>&1; }

falhou=0
item() { # ok|falha descricao
	if [ "$1" = ok ]; then printf '[OK]    %s\n' "$2"; else printf '[FALHA] %s\n' "$2"; falhou=1; fi
}

printf '== verificacao do A1 (HML) — empresa %s — %s ==\n' "$empresa" "$(date +%Y-%m-%dT%H:%M:%S)"

set +e
saida_h="$(executa "$release/bin/fiscal_a1_cofre" homologar --empresa "$empresa")"
codigo_h=$?
saida_s="$(executa "$release/bin/fiscal_nfe_hml" status-servico --empresa-id "$empresa" --uf SC)"
codigo_s=$?
set -e

# Mostra o que a CLI imprimiu de NAO sensivel (titular/validade/fingerprint/resultado).
grep -E '^(titular|valido_ate|fingerprint_sha256): ' <<<"$saida_h" || true

if [ "$codigo_h" -eq 0 ] && grep -q '^titular: ' <<<"$saida_h" && grep -q '^fingerprint_sha256: ' <<<"$saida_h"; then
	item ok "material A1 resolvido no cofre pelo AppRole do worker (titular, validade e fingerprint lidos)"
else
	item falha "material A1 nao resolvido pelo worker (codigo $codigo_h): $(grep -vE '^[[:space:]]*$' <<<"$saida_h" | tail -2 | tr '\n' ' ')"
fi
if grep -q '^OK: assinatura XML-DSig sintetica gerada e verificada localmente\.' <<<"$saida_h"; then
	item ok "assinatura XML-DSig sintetica gerada e verificada localmente"
else
	item falha "assinatura local nao comprovada"
fi
if grep -qE '^SEFAZ homologacao respondeu: cStat=.*107' <<<"$saida_h" && ! grep -q 'HOMOLOGACAO_REAL_PENDENTE_INSUMO' <<<"$saida_h"; then
	item ok "mTLS com o A1 contra a SEFAZ de homologacao: cStat=107 (servico em operacao)"
else
	item falha "SEFAZ HML nao confirmou cStat=107 (HOMOLOGACAO_REAL_PENDENTE_INSUMO nao e sucesso): $(grep -E 'SEFAZ|PENDENTE' <<<"$saida_h" | head -1 | cut -c1-200)"
fi
if [ "$codigo_s" -eq 0 ] && grep -q '^status_servico situacao=em_operacao' <<<"$saida_s"; then
	item ok "fiscal_nfe_hml status-servico (UF SC): em_operacao (consulta registrada)"
else
	item falha "status-servico nao retornou em_operacao (codigo $codigo_s): $(tail -1 <<<"$saida_s" | cut -c1-200)"
fi

if [ "$falhou" -eq 0 ]; then
	printf 'VERIFICACAO_A1_OK — isto prova cofre + assinatura + mTLS + status; NAO e homologacao: falta a autorizacao real (cStat=100).\n'
else
	printf 'VERIFICACAO_A1_FALHOU — corrija o item [FALHA] acima (nenhuma NF-e foi emitida).\n'
	exit 1
fi
