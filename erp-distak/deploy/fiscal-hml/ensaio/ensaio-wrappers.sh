#!/usr/bin/env bash
# [FISCAL-I3-HML-INFRA-DSTK-SERVER-01] Ensaio da LOGICA dos wrappers erp-fiscal-hml-importar-a1 e
# erp-fiscal-hml-verificar-a1 com binarios STUB (nao ha A1 nem binarios compilados neste host).
# Prova: validacoes de entrada, pre-checagem do prefixo hml-, remocao da copia so em sucesso
# CONFIRMADO, isolamento do ambiente (env -i) e — o caso critico — que a verificacao NAO aceita
# "exit 0 + HOMOLOGACAO_REAL_PENDENTE_INSUMO" como sucesso. NAO prova os binarios reais (isso exige
# o build; ver testes.md: NAO EXECUTADO).
#
# Uso: ENSAIO_DIR=<dir novo e vazio> [ENSAIO_SAIDA=<tsv>] ensaio-wrappers.sh
# Requer: script (util-linux), jq.
set -euo pipefail
umask 077

die() {
	printf 'ERRO: %s\n' "$*" >&2
	exit 1
}

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$AQUI/../../.." && pwd)"
BIN="$RAIZ/deploy/fiscal-hml/bin"
WORK="${ENSAIO_DIR:?ENSAIO_DIR obrigatorio (diretorio novo e vazio)}"
mkdir -p "$WORK"
[ -z "$(ls -A "$WORK")" ] || die "ENSAIO_DIR precisa estar vazio"
mkdir -p "$WORK"/{etc,recepcao,release/bin,stubs,tmp}
REGISTRO="$WORK/resultados.tsv"
: >"$REGISTRO"
trap 'if [ -n "${ENSAIO_SAIDA:-}" ]; then cp "$REGISTRO" "$ENSAIO_SAIDA"; fi; if [ "${ENSAIO_MANTER:-0}" != "1" ]; then rm -rf "$WORK"; fi' EXIT

teste() {
	printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >>"$REGISTRO"
	printf '[%s] %s - %s%s\n' "$2" "$1" "$3" "${4:+ ($4)}"
}

# --- ambiente simulado (sem segredos reais) -----------------------------------------------------
cat >"$WORK/etc/importador.env" <<EOF
ERP_ENV=homologacao
DATABASE_URL=stub://banco
OPENBAO_ADDR=https://127.0.0.1:8200
OPENBAO_CACERT=$WORK/etc/openbao-ca.pem
OPENBAO_SECRET_ID_FILE=$WORK/etc/sid-importador
EOF
cp "$WORK/etc/importador.env" "$WORK/etc/worker.env"
printf 'role-id-importador-sintetico\n' >"$WORK/etc/fiscal-importador.role-id"
printf 'role-id-worker-sintetico\n' >"$WORK/etc/fiscal-worker.role-id"

# stub do psql: devolve o identificador definido em STUB_IDENT (ignora a consulta)
cat >"$WORK/stubs/psql" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '%s' "${STUB_IDENT:-}"
EOF
# stub da CLI do cofre: comportamento escolhido pelo arquivo "modo" (importar e homologar)
cat >"$WORK/release/bin/fiscal_a1_cofre" <<'EOF'
#!/usr/bin/env bash
modo="$(cat @WORK@/modo)"
env | grep -c '^OPENBAO_' >@WORK@/tmp/openbao-vars
env | grep -q '^SEGREDO_DE_TESTE=' && echo vazou >@WORK@/tmp/vazamento-env
case "$1:$modo" in
importar:ok)
	printf 'titular: CN=EMPRESA TESTE:12345678000199\nvalido_ate: 2027-01-01T00:00:00\nfingerprint_sha256: ab12\nidentificador_cofre: hml-x\nOK: material A1 gravado no cofre.\n' ;;
importar:falha) echo "falha ao abrir o PFX: senha incorreta" >&2; exit 101 ;;
importar:semconfirmacao) printf 'titular: x\n' ;;
homologar:ok)
	printf 'titular: CN=EMPRESA TESTE\nvalido_ate: 2027-01-01T00:00:00\nfingerprint_sha256: ab12\nOK: assinatura XML-DSig sintetica gerada e verificada localmente.\nSEFAZ homologacao respondeu: cStat=Some("107") xMotivo=Some("Servico em Operacao")\n' ;;
homologar:pendente)
	printf 'titular: CN=EMPRESA TESTE\nvalido_ate: 2027-01-01T00:00:00\nfingerprint_sha256: ab12\nOK: assinatura XML-DSig sintetica gerada e verificada localmente.\nHOMOLOGACAO_REAL_PENDENTE_INSUMO: SEFAZ de homologacao indisponivel a partir deste ambiente\n' ;;
homologar:panico) echo "thread main panicked: falha ao resolver material A1 no cofre: acesso negado" >&2; exit 101 ;;
esac
EOF
cat >"$WORK/release/bin/fiscal_nfe_hml" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "status-servico" ]; then
	case "$(cat @WORK@/modo-status)" in
	ok) echo "status_servico situacao=em_operacao" ;;
	paralisado) echo "status_servico situacao=paralisado" ;;
	erro) echo "OPENBAO_ADDR nao configurada" >&2; exit 1 ;;
	esac
	exit 0
fi
printf '%s\n' "$*" >>@WORK@/tmp/nfe-args
for ((i = 1; i <= $#; i++)); do
	if [ "${!i}" = "--arquivo" ]; then
		j=$((i + 1))
		cp "${!j}" @WORK@/tmp/nfe-arquivo-copia
		printf '%s' "${!j}" >@WORK@/tmp/nfe-arquivo-caminho
	fi
done
echo "ok-$1"
EOF
# os stubs rodam sob env -i: caminhos fixos (nao dependem de variaveis de ambiente)
sed -i "s|@WORK@|$WORK|g" "$WORK/release/bin/fiscal_a1_cofre" "$WORK/release/bin/fiscal_nfe_hml"
chmod +x "$WORK/stubs/psql" "$WORK/release/bin/"*

export ERP_FISCAL_HML_ETC="$WORK/etc" ERP_FISCAL_HML_RECEPCAO="$WORK/recepcao" ERP_FISCAL_HML_RELEASE="$WORK/release"
export PATH="$WORK/stubs:$PATH"
export SEGREDO_DE_TESTE="nao-deve-chegar-na-cli"

importar() { # args... ; roda sob pseudo-terminal; devolve codigo; saida em tmp/imp.out
	set +e
	script -qec "$BIN/erp-fiscal-hml-importar-a1.sh $*" /dev/null >"$WORK/tmp/imp.out" 2>&1 </dev/null
	local c=$?
	set -e
	tr -d '\r' <"$WORK/tmp/imp.out" >"$WORK/tmp/imp.limpo"
	return "$c"
}
pfx_falso() { head -c 2000 /dev/urandom >"$WORK/recepcao/$1"; }
limpa_recepcao() { rm -rf "$WORK/recepcao"/*; }

# W01..: validacoes de entrada
limpa_recepcao
STUB_IDENT=hml-teste importar --empresa 1 --sem-verificar && c=0 || c=$?
if [ "$c" -ne 0 ] && grep -q 'exatamente UM' "$WORK/tmp/imp.limpo"; then teste W01 PASSOU "sem arquivo na recepcao: recusa clara"; else teste W01 FALHOU "sem arquivo" "c=$c"; fi
pfx_falso a.pfx; pfx_falso b.p12
STUB_IDENT=hml-teste importar --empresa 1 --sem-verificar && c=0 || c=$?
if [ "$c" -ne 0 ] && grep -q 'exatamente UM' "$WORK/tmp/imp.limpo" && [ -e "$WORK/recepcao/a.pfx" ]; then teste W02 PASSOU "dois arquivos: recusa e nada e removido"; else teste W02 FALHOU "dois arquivos" "c=$c"; fi
limpa_recepcao
head -c 70000 /dev/urandom >"$WORK/recepcao/grande.pfx"
STUB_IDENT=hml-teste importar --empresa 1 --sem-verificar && c=0 || c=$?
if [ "$c" -ne 0 ] && grep -q 'tamanho incompativel' "$WORK/tmp/imp.limpo"; then teste W03 PASSOU "arquivo maior que 64 KiB recusado"; else teste W03 FALHOU "arquivo grande" "c=$c"; fi
limpa_recepcao
pfx_falso real.pfx
ln -s "$WORK/recepcao/real.pfx" "$WORK/recepcao/atalho.pfx"
STUB_IDENT=hml-teste importar --empresa 1 --arquivo "$WORK/recepcao/atalho.pfx" --sem-verificar && c=0 || c=$?
if [ "$c" -ne 0 ]; then teste W04 PASSOU "link simbolico recusado"; else teste W04 FALHOU "symlink aceito"; fi
limpa_recepcao
pfx_falso ../fora.pfx 2>/dev/null || true
head -c 1000 /dev/urandom >"$WORK/fora.pfx"
STUB_IDENT=hml-teste importar --empresa 1 --arquivo "$WORK/fora.pfx" --sem-verificar && c=0 || c=$?
if [ "$c" -ne 0 ] && grep -q 'dentro de' "$WORK/tmp/imp.limpo"; then teste W05 PASSOU "arquivo fora da recepcao recusado"; else teste W05 FALHOU "fora da recepcao" "c=$c"; fi
STUB_IDENT=hml-teste importar --empresa abc --sem-verificar && c=0 || c=$?
if [ "$c" -ne 0 ]; then teste W06 PASSOU "empresa nao numerica recusada (sem injecao)"; else teste W06 FALHOU "empresa invalida aceita"; fi

# W07..: referencia cadastrada e prefixo hml-
limpa_recepcao; pfx_falso a1.pfx
printf 'ok' >"$WORK/modo"
STUB_IDENT="" importar --empresa 1 --sem-verificar && c=0 || c=$?
if [ "$c" -ne 0 ] && grep -q 'NAO tem certificado-referencia' "$WORK/tmp/imp.limpo" && [ -e "$WORK/recepcao/a1.pfx" ]; then teste W07 PASSOU "sem referencia cadastrada: mensagem clara, arquivo mantido"; else teste W07 FALHOU "sem referencia" "c=$c"; fi
STUB_IDENT="empresa1" importar --empresa 1 --sem-verificar && c=0 || c=$?
if [ "$c" -ne 0 ] && grep -q "comecar com 'hml-'" "$WORK/tmp/imp.limpo" && [ -e "$WORK/recepcao/a1.pfx" ]; then teste W08 PASSOU "identificador sem prefixo hml-: recusado antes de tocar o cofre"; else teste W08 FALHOU "prefixo hml-" "c=$c"; fi

# W09..: execucao da CLI
printf 'falha' >"$WORK/modo"
STUB_IDENT=hml-teste importar --empresa 1 --sem-verificar && c=0 || c=$?
if [ "$c" -ne 0 ] && [ -e "$WORK/recepcao/a1.pfx" ]; then teste W09 PASSOU "CLI falhou: copia de recepcao MANTIDA"; else teste W09 FALHOU "falha da CLI" "c=$c"; fi
printf 'semconfirmacao' >"$WORK/modo"
STUB_IDENT=hml-teste importar --empresa 1 --sem-verificar && c=0 || c=$?
if [ "$c" -ne 0 ] && [ -e "$WORK/recepcao/a1.pfx" ]; then teste W10 PASSOU "CLI saiu 0 sem confirmar a gravacao: copia MANTIDA (nao assume sucesso)"; else teste W10 FALHOU "sem confirmacao" "c=$c"; fi
printf 'ok' >"$WORK/modo"
rm -f "$WORK/tmp/vazamento-env"
STUB_IDENT=hml-teste importar --empresa 1 --sem-verificar && c=0 || c=$?
if [ "$c" -eq 0 ] && [ ! -e "$WORK/recepcao/a1.pfx" ] && grep -q 'REMOVIDA' "$WORK/tmp/imp.limpo" && grep -q 'rm' "$WORK/tmp/imp.limpo"; then
	teste W11 PASSOU "sucesso confirmado: copia removida, aviso honesto sobre apagamento fisico e custodia do original"
else
	teste W11 FALHOU "sucesso" "c=$c"
fi
if [ ! -e "$WORK/tmp/vazamento-env" ] && [ "$(cat "$WORK/tmp/openbao-vars")" = "4" ]; then
	teste W12 PASSOU "ambiente da CLI isolado (env -i): so as 4 variaveis OPENBAO_* esperadas; variavel estranha NAO vazou"
else
	teste W12 FALHOU "isolamento de ambiente" "openbao_vars=$(cat "$WORK/tmp/openbao-vars") vazou=$([ -e "$WORK/tmp/vazamento-env" ] && echo sim || echo nao)"
fi
if grep -qE 'senha|password' "$WORK/tmp/imp.limpo" && grep -qE '^[^S]*Senha do PFX' "$WORK/tmp/imp.limpo"; then :; fi

# V01..: verificacao pela identidade do worker
verificar() { # args...
	set +e
	"$BIN/erp-fiscal-hml-verificar-a1.sh" "$@" >"$WORK/tmp/ver.out" 2>&1
	local c=$?
	set -e
	return "$c"
}
printf 'ok' >"$WORK/modo"; printf 'ok' >"$WORK/modo-status"
verificar --empresa 1 && c=0 || c=$?
if [ "$c" -eq 0 ] && grep -q 'VERIFICACAO_A1_OK' "$WORK/tmp/ver.out" && grep -q 'NAO e homologacao' "$WORK/tmp/ver.out"; then
	teste V01 PASSOU "tudo ok: VERIFICACAO_A1_OK, com a ressalva de que ainda NAO e homologacao (falta cStat=100)"
else
	teste V01 FALHOU "verificacao ok" "c=$c $(tail -3 "$WORK/tmp/ver.out" | tr '\n' '|')"
fi
printf 'pendente' >"$WORK/modo"
verificar --empresa 1 && c=0 || c=$?
if [ "$c" -ne 0 ] && grep -q 'VERIFICACAO_A1_FALHOU' "$WORK/tmp/ver.out" && grep -q 'PENDENTE_INSUMO' "$WORK/tmp/ver.out"; then
	teste V02 PASSOU "CLI saiu 0 mas so registrou HOMOLOGACAO_REAL_PENDENTE_INSUMO: verificacao FALHA (exige cStat=107 de verdade)"
else
	teste V02 FALHOU "pendente tratado como sucesso" "c=$c"
fi
printf 'ok' >"$WORK/modo"; printf 'paralisado' >"$WORK/modo-status"
verificar --empresa 1 && c=0 || c=$?
if [ "$c" -ne 0 ] && grep -q 'status-servico nao retornou em_operacao' "$WORK/tmp/ver.out"; then teste V03 PASSOU "status-servico diferente de em_operacao: FALHA"; else teste V03 FALHOU "status paralisado" "c=$c"; fi
printf 'panico' >"$WORK/modo"; printf 'ok' >"$WORK/modo-status"
verificar --empresa 1 && c=0 || c=$?
if [ "$c" -ne 0 ] && grep -q 'nao resolvido pelo worker' "$WORK/tmp/ver.out"; then teste V04 PASSOU "worker sem acesso ao cofre (CLI em panico): FALHA explicita"; else teste V04 FALHOU "panico" "c=$c"; fi
verificar --empresa 1 --extra x && c=0 || c=$?
if [ "$c" -ne 0 ]; then teste V05 PASSOU "argumento extra recusado (superficie do sudoers)"; else teste V05 FALHOU "argumento extra aceito"; fi
verificar --empresa "1;id" && c=0 || c=$?
if [ "$c" -ne 0 ]; then teste V06 PASSOU "empresa nao numerica recusada na verificacao"; else teste V06 FALHOU "empresa invalida"; fi

# N01..: erp-fiscal-hml-nfe (ciclo de emissao pela identidade do worker) — allowlist estrita
export ERP_FISCAL_HML_TMP="$WORK/nfetmp"
nfe() { # args... (stdin herdado)
	set +e
	"$BIN/erp-fiscal-hml-nfe.sh" "$@" >"$WORK/tmp/nfe.out" 2>&1
	local c=$?
	set -e
	return "$c"
}
rm -f "$WORK/tmp/nfe-args"
printf 'ok' >"$WORK/modo-status"
nfe status-servico --empresa-id 1 --uf SC </dev/null && c=0 || c=$?
if [ "$c" -eq 0 ] && grep -q 'em_operacao' "$WORK/tmp/nfe.out"; then teste N01 PASSOU "status-servico permitido (empresa numerica, UF 2 letras)"; else teste N01 FALHOU "status-servico" "c=$c"; fi
nfe status --empresa-id 1 --documento 7 </dev/null && c=0 || c=$?
if [ "$c" -eq 0 ] && grep -q '^status --empresa-id 1 --documento 7$' "$WORK/tmp/nfe-args"; then teste N02 PASSOU "status repassa exatamente os flags validados"; else teste N02 FALHOU "status" "c=$c"; fi
for ruim in "producao" "migrar" "rm" "--help"; do
	nfe "$ruim" --empresa-id 1 </dev/null && c=0 || c=$?
	if [ "$c" -eq 0 ]; then teste N03 FALHOU "subcomando indevido aceito: $ruim"; fi
done
teste N03 PASSOU "subcomandos fora da allowlist recusados (producao, migrar, rm, --help)"
nfe status --empresa-id 1 --documento 7 --ambiente producao </dev/null && c=0 || c=$?
if [ "$c" -ne 0 ]; then teste N04 PASSOU "flag extra/ambiente recusada (nao existe selecao de producao)"; else teste N04 FALHOU "flag extra aceita"; fi
nfe status --empresa-id "1 --x" --documento 7 </dev/null && c=0 || c=$?
if [ "$c" -ne 0 ]; then teste N05 PASSOU "valor com espaco/injecao recusado"; else teste N05 FALHOU "valor invalido aceito"; fi
nfe status --empresa-id 1 --empresa-id 2 --documento 7 </dev/null && c=0 || c=$?
if [ "$c" -ne 0 ]; then teste N06 PASSOU "flag repetida recusada"; else teste N06 FALHOU "flag repetida aceita"; fi
nfe preparar --usuario-id 3 <"$WORK/etc/importador.env" && c=0 || c=$?
if [ "$c" -ne 0 ] && grep -q 'JSON valido' "$WORK/tmp/nfe.out"; then teste N07 PASSOU "stdin que nao e JSON recusado"; else teste N07 FALHOU "stdin invalido" "c=$c"; fi
printf '{"cenario":"sintetico","itens":[]}' >"$WORK/tmp/entrada.json"
nfe preparar --usuario-id 3 <"$WORK/tmp/entrada.json" && c=0 || c=$?
caminho="$(cat "$WORK/tmp/nfe-arquivo-caminho" 2>/dev/null || true)"
if [ "$c" -eq 0 ] && cmp -s "$WORK/tmp/entrada.json" "$WORK/tmp/nfe-arquivo-copia" && [ -n "$caminho" ] && [ ! -e "$caminho" ] && [ "${caminho#"$WORK"/nfetmp/}" != "$caminho" ]; then
	teste N08 PASSOU "preparar: JSON por stdin vira arquivo temporario privado do worker, entregue a CLI e REMOVIDO ao sair"
else
	teste N08 FALHOU "preparar via stdin" "c=$c caminho=$caminho"
fi
nfe preparar --usuario-id 3 --arquivo /etc/passwd <"$WORK/tmp/entrada.json" && c=0 || c=$?
if [ "$c" -ne 0 ]; then teste N09 PASSOU "o chamador NAO pode indicar caminho de arquivo (--arquivo recusado)"; else teste N09 FALHOU "--arquivo aceito do chamador"; fi
set +e
script -qec "$BIN/erp-fiscal-hml-nfe.sh preparar --usuario-id 3" /dev/null >"$WORK/tmp/nfe-tty.out" 2>&1 </dev/null
c=$?
set -e
if [ "$c" -ne 0 ] && tr -d '\r' <"$WORK/tmp/nfe-tty.out" | grep -q 'envie o JSON por stdin'; then
	teste N10 PASSOU "sem JSON em stdin (stdin e um terminal) a execucao e recusada com mensagem clara"
else
	teste N10 FALHOU "stdin terminal" "c=$c"
fi

total="$(wc -l <"$REGISTRO")"
passou="$(awk -F'\t' '$2=="PASSOU"' "$REGISTRO" | wc -l)"
falhou="$(awk -F'\t' '$2=="FALHOU"' "$REGISTRO" | wc -l)"
printf '== RESUMO: %s testes, %s PASSOU, %s FALHOU ==\n' "$total" "$passou" "$falhou"
[ "$falhou" -eq 0 ]
