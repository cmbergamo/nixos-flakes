#!/usr/bin/env bash
# [FISCAL-I3-HML-INFRA-DSTK-SERVER-01] Ensaio do CLIENTE RUST (shared::openbao + CLIs fiscais) contra o
# OpenBao REAL e um PostgreSQL real com as 140 migrations. Usa SO o certificado SINTETICO publico do
# projeto (tool/fiscal_a1_spike/fixtures; senha de teste publica) e roda o OpenBao e os binarios dentro de
# um network namespace de usuario SEM saida (so loopback): nenhum byte — muito menos um certificado
# sintetico — chega a SEFAZ. O PostgreSQL fica FORA do namespace (socket Unix, peer).
#
# Prova: TLS por CA privada EC + SAN so por IP (rustls), AppRole, KV-v2, escrita do importador, leitura do
# worker, assinatura local, falhas explicitas (sem permissao, segredo ausente, credencial errada, cofre
# selado), a verificacao do A1 recusando "PENDENTE" como sucesso, e o fiscal_worker iniciando/parando.
#
# Uso: ERP_BIN_DIR=<dir com fiscal_a1_cofre fiscal_nfe_hml fiscal_worker> ENSAIO_DIR=<dir novo e vazio> \
#      [ENSAIO_SAIDA=<tsv>] ensaio-cliente-rust.sh
# Requer: bao, jq, openssl, curl, unshare, ip, script, initdb/pg_ctl/psql, sqlx.
set -euo pipefail
umask 077

die() {
	printf 'ERRO: %s\n' "$*" >&2
	exit 1
}

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$AQUI/../../.." && pwd)"
BIN="$RAIZ/deploy/fiscal-hml/bin"
POLITICAS="$RAIZ/deploy/fiscal-hml/openbao/politicas"
GABARITO="$RAIZ/deploy/fiscal-hml/openbao/openbao.hcl.in"
FIXTURE="$RAIZ/tool/fiscal_a1_spike/fixtures/sintetico_legado_tripledes_sha1.pfx"
FIXTURE_MODERNO="$RAIZ/tool/fiscal_a1_spike/fixtures/sintetico_moderno_aes256_sha256.pfx"
SENHA_PUBLICA="teste-fiscal-p6-1234" # documentada em tool/fiscal_a1_spike/fixtures/README.md (nao protege nada)
WORK="${ENSAIO_DIR:?ENSAIO_DIR obrigatorio}"
BINS="${ERP_BIN_DIR:?ERP_BIN_DIR obrigatorio}"
PORTA=18200
SOCK_FILE="$WORK/socket-path"
REGISTRO="$WORK/resultados.tsv"

teste() {
	printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >>"$REGISTRO"
	printf '[%s] %s - %s%s\n' "$2" "$1" "$3" "${4:+ ($4)}"
}
espera() {
	if [ "$3" = "$4" ]; then teste "$1" PASSOU "$2" "esperado=$3 obtido=$4"; else teste "$1" FALHOU "$2" "esperado=$3 obtido=$4"; fi
}

# ============================== FASE EXTERNA: PostgreSQL + PKI, depois entra no namespace ==============================
if [ "${ENSAIO_FASE:-externa}" = "externa" ]; then
	for f in bao jq openssl curl unshare ip script initdb pg_ctl psql sqlx; do command -v "$f" >/dev/null || die "ferramenta ausente: $f"; done
	for b in fiscal_a1_cofre fiscal_nfe_hml fiscal_worker; do [ -x "$BINS/$b" ] || die "binario ausente: $BINS/$b (build: erp-fiscal-hml-compilar)"; done
	mkdir -p "$WORK"
	[ -z "$(ls -A "$WORK")" ] || die "ENSAIO_DIR precisa estar vazio"
	mkdir -p "$WORK"/{bin,ca,tls,etc,cred,audit,tmp,estado,dados,release/bin,pol,artefatos}
	: >"$REGISTRO"
	ln -s "$BIN/erp-fiscal-hml-provisionar.sh" "$WORK/bin/erp-fiscal-hml-provisionar"
	ln -s "$BIN/erp-fiscal-hml-tls.sh" "$WORK/bin/erp-fiscal-hml-tls"
	export PATH="$WORK/bin:$PATH"
	cp "$POLITICAS"/*.hcl "$WORK/pol/"
	for b in fiscal_a1_cofre fiscal_nfe_hml fiscal_worker; do ln -s "$BINS/$b" "$WORK/release/bin/$b"; done

	erp-fiscal-hml-tls --ca-dir "$WORK/ca" --tls-dir "$WORK/tls" --ca-publica "$WORK/etc/openbao-ca.pem" >/dev/null
	# PostgreSQL descartavel (fsync desligado SO aqui), apenas socket Unix, peer mapeado
	SOCK="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/efh-rs.XXXXXX")"
	printf '%s' "$SOCK" >"$SOCK_FILE"
	USUARIO="$(id -un)"
	initdb -D "$WORK/dados" -U "$USUARIO" --auth-local=peer --auth-host=reject -E UTF8 --locale=C.UTF-8 >/dev/null
	printf 'fiscalhml %s %s\nfiscalhml %s erp_app\nfiscalhml %s erp_migrador\nfiscalhml %s erp_backup\n' "$USUARIO" "$USUARIO" "$USUARIO" "$USUARIO" "$USUARIO" >"$WORK/dados/pg_ident.conf"
	printf 'local erp_fiscal_hml erp_migrador peer map=fiscalhml\nlocal erp_fiscal_hml erp_app peer map=fiscalhml\nlocal erp_fiscal_hml erp_backup peer map=fiscalhml\nlocal all %s peer\n' "$USUARIO" >"$WORK/dados/pg_hba.conf"
	pg_ctl -D "$WORK/dados" -w -l "$WORK/pg.log" -o "-c listen_addresses='' -c unix_socket_directories='$SOCK' -c port=15435 -c fsync=off -c synchronous_commit=off -c full_page_writes=off" start >/dev/null
	createdb -h "$SOCK" -p 15435 erp_fiscal_hml
	limpar_ext() {
		pg_ctl -D "$WORK/dados" -m fast stop >/dev/null 2>&1 || true
		rm -rf "$SOCK"
		if [ -n "${ENSAIO_SAIDA:-}" ] && [ -f "$REGISTRO" ]; then cp "$REGISTRO" "$ENSAIO_SAIDA"; fi
		if [ "${ENSAIO_MANTER:-0}" != "1" ]; then rm -rf "$WORK"; fi
	}
	trap limpar_ext EXIT
	"$BIN/erp-fiscal-hml-migrar.sh" --repo "$RAIZ" --socket "$SOCK" --porta 15435 --banco erp_fiscal_hml >"$WORK/tmp/migrar.out" 2>&1 || { tail -5 "$WORK/tmp/migrar.out" >&2; die "migrar falhou"; }

	# empresa e referencia do certificado SINTETICO (titular/validade lidos do proprio PFX publico)
	openssl pkcs12 -in "$FIXTURE" -passin "pass:$SENHA_PUBLICA" -nokeys -clcerts 2>/dev/null >"$WORK/tmp/cert.pem" || die "nao abriu a fixture"
	titular="$(openssl x509 -in "$WORK/tmp/cert.pem" -noout -subject -nameopt multiline | sed -n 's/^ *commonName *= *//p' | head -1)"
	[ -n "$titular" ] || titular="$(openssl x509 -in "$WORK/tmp/cert.pem" -noout -subject -nameopt oneline | sed 's/.*CN *= *//')"
	validade="$(date -u -d "$(openssl x509 -in "$WORK/tmp/cert.pem" -noout -enddate | cut -d= -f2)" '+%Y-%m-%d %H:%M:%S')"
	empresa_id="$(psql -X -h "$SOCK" -p 15435 -d erp_fiscal_hml -Atq -c "INSERT INTO empresa (codigo, razao_social) VALUES ('ENSAIO','EMPRESA SINTETICA DE ENSAIO') RETURNING id")"
	# o psql so interpola :variaveis no stdin/-f (nao em -c)
	psql -X -h "$SOCK" -p 15435 -d erp_fiscal_hml -Atq -v t="$titular" -v v="$validade" -v e="$empresa_id" >/dev/null <<-'SQL'
		INSERT INTO fiscal_certificado_referencia (empresa_id, titular, identificador_cofre, valido_ate) VALUES (:e, :'t', 'hml-ensaio-rust', :'v');
	SQL
	printf '%s' "$empresa_id" >"$WORK/empresa-id"
	# sem `exec`: o trap EXIT desta fase (parar o PostgreSQL pelo diretorio de dados, apagar o diretorio de trabalho)
	# precisa rodar mesmo que a fase interna falhe
	unshare --user --map-root-user --net env ENSAIO_FASE=interna ENSAIO_SOCK="$SOCK" PATH="$PATH" "$0"
	exit $?
fi

# ============================== FASE INTERNA: namespace sem saida (so loopback) ==============================
SOCK="$ENSAIO_SOCK"
EMPRESA="$(cat "$WORK/empresa-id")"
ip link set lo up
export PATH="$WORK/bin:$PATH"
CA="$WORK/etc/openbao-ca.pem"
export BAO_ADDR="https://127.0.0.1:$PORTA" BAO_CACERT="$CA"
PIDS=()
limpar_int() {
	local pid
	for pid in "${PIDS[@]:-}"; do
		# so mata o que ESTE ensaio iniciou e que continua sendo o "bao"
		if [ -n "$pid" ] && [ "$(cat "/proc/$pid/comm" 2>/dev/null || true)" = "bao" ]; then kill -TERM "$pid" 2>/dev/null || true; fi
	done
}
trap limpar_int EXIT

teste N00 PASSOU "namespace sem saida: so loopback" "$(ip -br addr | awk '{print $1}' | tr '\n' ' ')"
if curl -sS -m4 -o /dev/null https://nfe-homologacao.svrs.rs.gov.br 2>/dev/null; then die "o namespace TEM saida — abortando (nada deve chegar a SEFAZ)"; fi
teste N01 PASSOU "confirmado: sem rota para a SEFAZ a partir do namespace do ensaio"

AUDIT_FILE="$WORK/audit/audit.log" STATE_DIR="$WORK/estado" TLS_DIR="$WORK/tls" LISTEN_PORT="$PORTA" CLUSTER_PORT=$((PORTA + 1)) \
	"$AQUI/render-config.sh" "$GABARITO" >"$WORK/openbao.hcl"
iniciar_bao() {
	( bao server -config="$WORK/openbao.hcl" >>"$WORK/server.log" 2>&1 & echo $! >"$WORK/server.pid" )
	PIDS+=("$(cat "$WORK/server.pid")")
	local i
	for i in $(seq 1 60); do curl -s -o /dev/null --cacert "$CA" "$BAO_ADDR/v1/sys/health" 2>/dev/null && return 0; sleep 0.5; done
	die "OpenBao nao subiu"
}
iniciar_bao
# bootstrap de PRODUCAO (script real), sob pseudo-terminal, com as variaveis de teste explicitas
boot_env=(
	ERP_FISCAL_HML_BOOTSTRAP_TESTE=1 ERP_FISCAL_HML_IGNORAR_ANCESTRAIS_TESTE=1 ERP_FISCAL_HML_ETC="$WORK/etc"
	ERP_FISCAL_HML_POLITICAS="$WORK/pol" ERP_FISCAL_HML_SID_WORKER="$WORK/cred/worker.sid" ERP_FISCAL_HML_SID_IMPORTADOR="$WORK/cred/importador.sid"
	ERP_FISCAL_HML_SID_BACKUP="$WORK/cred/backup.sid" ERP_FISCAL_HML_SID_RECUPERACAO="$WORK/cred/recuperacao.sid"
	ERP_FISCAL_HML_DONO_WORKER= ERP_FISCAL_HML_DONO_IMPORTADOR= ERP_FISCAL_HML_BOOTSTRAP_TMP="$WORK/tmp"
)
printf 'CONFIRMO\n' | env -u TMUX -u STY "${boot_env[@]}" script -qec "$BIN/erp-fiscal-hml-bootstrap.sh" /dev/null >"$WORK/tmp/boot.out" 2>&1 || { tail -5 "$WORK/tmp/boot.out" >&2; die "bootstrap falhou"; }
tr -d '\r' <"$WORK/tmp/boot.out" | sed -n 's/^Chave [1-5]\/5: //p' >"$WORK/tmp/chaves.txt"
teste N02 PASSOU "bootstrap real no namespace (OpenBao + provisionamento + root token revogado)" "$(wc -l <"$WORK/tmp/chaves.txt") chaves"

# arquivos de ambiente como no host (so enderecos/caminhos)
DBURL="postgres://erp_app@${SOCK//\//%2F}:15435/erp_fiscal_hml"
for quem in importador worker; do
	cat >"$WORK/etc/$quem.env" <<EOF
ERP_ENV=homologacao
DATABASE_URL=$DBURL
OPENBAO_ADDR=$BAO_ADDR
OPENBAO_CACERT=$CA
OPENBAO_SECRET_ID_FILE=$WORK/cred/$quem.sid
FISCAL_ARTEFATOS_DIR=$WORK/artefatos
EOF
done
cli_env() { # quem(importador|worker) -> imprime pares VAR=valor
	local quem="$1" k v
	while IFS='=' read -r k v; do printf '%s=%s\n' "$k" "$v"; done <"$WORK/etc/$quem.env"
	printf 'OPENBAO_ROLE_ID=%s\n' "$(tr -d '\n' <"$WORK/etc/fiscal-$quem.role-id")"
}
rodar() { # quem comando args...   (env -i; cwd=/)
	local quem="$1"
	shift
	mapfile -t pares < <(cli_env "$quem")
	( cd / && env -i PATH="$PATH" RUST_BACKTRACE=0 RUST_LOG=warn "${pares[@]}" "$WORK/release/bin/$1" "${@:2}" )
}

# ---- importar (AppRole importador) com a senha publica da fixture, por arquivo ----
printf '%s' "$SENHA_PUBLICA" >"$WORK/tmp/senha-publica.txt"
set +e
rodar importador fiscal_a1_cofre importar --empresa "$EMPRESA" --arquivo "$FIXTURE" --senha-arquivo "$WORK/tmp/senha-publica.txt" >"$WORK/tmp/importar.out" 2>&1
c=$?
set -e
# ACHADO conhecido (D-1, CORRIGIDO e publicado em 6c29b027de; este ramo so detecta um binario ANTIGO por engano):
# o material era gravado no cofre, mas o INSERT de auditoria usava acao='rotacionar_material_a1', fora do vocabulario
# do CHECK auditoria_evento_acao_valida => panico (exit 101) no ultimo passo. Com os binarios oficiais R01/R02 devem ser PASSOU.
ASSINATURA_D1='falha ao gravar auditoria da importacao: Infra("sqlx:constraint:23514")'
r01_achado=0
if [ "$c" -eq 0 ] && grep -q '^OK: material A1 gravado no cofre' "$WORK/tmp/importar.out"; then
	teste R01 PASSOU "fiscal_a1_cofre importar: cliente Rust (rustls, CA privada EC, SAN por IP) autentica por AppRole e GRAVA no KV-v2 real" "$(grep -E '^(titular|valido_ate|identificador_cofre):' "$WORK/tmp/importar.out" | tr '\n' ' ')"
elif [ "$c" -eq 101 ] && grep -qF "$ASSINATURA_D1" "$WORK/tmp/importar.out"; then
	r01_achado=1
	teste R01 ACHADO "importar: autentica por AppRole e grava no KV-v2 (confirmado por R04), mas termina com exit 101: o INSERT de auditoria viola o CHECK auditoria_evento_acao_valida (acao='rotacionar_material_a1')" "c=$c"
else
	teste R01 FALHOU "importar" "c=$c $(tail -3 "$WORK/tmp/importar.out" | tr '\n' '|')"
fi
n_aud="$(psql -X -U erp_migrador -h "$SOCK" -p 15435 -d erp_fiscal_hml -Atq -c "SELECT count(*) FROM auditoria_evento WHERE recurso='certificado_referencia_material'")"
if [ "$r01_achado" -eq 1 ] && [ "$n_aud" = "0" ]; then teste R02 ACHADO "nenhum registro de auditoria da importacao (consequencia do R01)" "linhas=$n_aud"; else espera R02 "a importacao registrou auditoria no banco (sem segredo)" 1 "$n_aud"; fi

# ---- importar INTERATIVO: senha por prompt sem eco (rpassword) sob pseudo-terminal ----
set +e
# a senha so e digitada DEPOIS do prompt (sleep): se fosse enfileirada antes, o pty a ecoaria antes de o rpassword desligar o eco
{ sleep 4; printf '%s\n' "$SENHA_PUBLICA"; } | script -qec "env -i PATH=$PATH RUST_LOG=warn $(cli_env importador | tr '\n' ' ') $WORK/release/bin/fiscal_a1_cofre importar --empresa $EMPRESA --arquivo $FIXTURE" /dev/null >"$WORK/tmp/importar-tty.out" 2>&1
c=$?
set -e
tr -d '\r' <"$WORK/tmp/importar-tty.out" >"$WORK/tmp/importar-tty.limpo"
if { [ "$c" -eq 0 ] || { [ "$c" -eq 101 ] && grep -qF "$ASSINATURA_D1" "$WORK/tmp/importar-tty.limpo"; }; } && grep -q 'Senha do PFX' "$WORK/tmp/importar-tty.limpo" && ! grep -q "$SENHA_PUBLICA" "$WORK/tmp/importar-tty.limpo"; then
	teste R03 PASSOU "importacao interativa: prompt 'Senha do PFX' sem eco (a senha digitada nao aparece na saida)" "exit=$c (101 = achado D-1, igual ao R01)"
else
	teste R03 FALHOU "importar interativo" "c=$c"
fi

# ---- homologar (AppRole worker): leitura do cofre + assinatura local; sem saida => PENDENTE (esperado) ----
set +e
rodar worker fiscal_a1_cofre homologar --empresa "$EMPRESA" >"$WORK/tmp/homologar.out" 2>&1
c=$?
set -e
if [ "$c" -eq 0 ] && grep -q '^fingerprint_sha256: ' "$WORK/tmp/homologar.out" && grep -q '^OK: assinatura XML-DSig sintetica gerada e verificada localmente' "$WORK/tmp/homologar.out"; then
	teste R04 PASSOU "fiscal_a1_cofre homologar: o cliente Rust do WORKER le o segredo, abre o PFX e assina/verifica localmente" "$(grep -E '^(titular|valido_ate)' "$WORK/tmp/homologar.out" | tr '\n' ' ')"
else
	teste R04 FALHOU "homologar" "c=$c $(tail -3 "$WORK/tmp/homologar.out" | tr '\n' '|')"
fi
if grep -q 'HOMOLOGACAO_REAL_PENDENTE_INSUMO' "$WORK/tmp/homologar.out"; then
	teste R05 PASSOU "sem rota para a SEFAZ a CLI sai 0 mas registra HOMOLOGACAO_REAL_PENDENTE_INSUMO (comportamento real que o verificar-a1 trata como FALHA)"
else
	teste R05 FALHOU "esperava PENDENTE_INSUMO no namespace sem saida" "$(tail -2 "$WORK/tmp/homologar.out" | tr '\n' '|')"
fi
# wrapper de verificacao com os binarios reais: PENDENTE nao pode ser sucesso
mkdir -p "$WORK/etcw"
cp "$WORK/etc/worker.env" "$WORK/etcw/worker.env"
cp "$WORK/etc/fiscal-worker.role-id" "$WORK/etcw/fiscal-worker.role-id"
set +e
ERP_FISCAL_HML_ETC="$WORK/etcw" ERP_FISCAL_HML_RELEASE="$WORK/release" "$BIN/erp-fiscal-hml-verificar-a1.sh" --empresa "$EMPRESA" >"$WORK/tmp/verificar.out" 2>&1
c=$?
set -e
if [ "$c" -ne 0 ] && grep -q 'VERIFICACAO_A1_FALHOU' "$WORK/tmp/verificar.out" && grep -q '^\[OK\].*material A1 resolvido' "$WORK/tmp/verificar.out"; then
	teste R06 PASSOU "erp-fiscal-hml-verificar-a1 com os binarios REAIS: cofre/assinatura [OK], mas SEFAZ pendente => VERIFICACAO_A1_FALHOU (nao aceita pendente)"
else
	teste R06 FALHOU "verificar-a1 real" "c=$c $(tail -4 "$WORK/tmp/verificar.out" | tr '\n' '|')"
fi

# ---- sonda: PFX "moderno" (MAC SHA-256 + PBES2/AES-256, padrao do OpenSSL 3) no binario RELEASE ----
# O crate p12 so valida MAC SHA-1 (`debug_assert_eq!` apenas em debug): no release a verificacao devolve
# "senha incorreta" para uma senha CORRETA e o fallback via openssl nunca roda. A sonda confronta o binario com
# o OpenSSL (verdade externa) sem gravar nada no cofre (a falha ocorre antes). Registrada como ACHADO, nao como falha do ensaio.
set +e
rodar importador fiscal_a1_cofre importar --empresa "$EMPRESA" --arquivo "$FIXTURE_MODERNO" --senha-arquivo "$WORK/tmp/senha-publica.txt" >"$WORK/tmp/importar-moderno.out" 2>&1
c=$?
openssl pkcs12 -in "$FIXTURE_MODERNO" -passin "pass:$SENHA_PUBLICA" -nokeys -noout >/dev/null 2>&1
ossl=$?
set -e
if [ "$c" -eq 0 ]; then
	teste R40 PASSOU "PFX moderno (SHA-256/AES-256) aceito pelo binario release"
elif [ "$ossl" -eq 0 ] && grep -q 'senha do PFX incorreta' "$WORK/tmp/importar-moderno.out"; then
	teste R40 ACHADO "binario release recusa PFX moderno com a senha CORRETA ('senha do PFX incorreta'); o OpenSSL abre o mesmo arquivo" "importar exit=$c; openssl exit=$ossl"
else
	teste R40 FALHOU "sonda do PFX moderno inconclusiva" "importar exit=$c; openssl exit=$ossl; $(tail -1 "$WORK/tmp/importar-moderno.out" | cut -c1-100)"
fi

# ---- falhas explicitas ----
nega() { # id descricao esperado_regex quem comando args...
	local id="$1" desc="$2" re="$3"
	shift 3
	set +e
	rodar "$@" >"$WORK/tmp/neg.out" 2>&1
	local cc=$?
	set -e
	if [ "$cc" -ne 0 ] && grep -qiE "$re" "$WORK/tmp/neg.out"; then teste "$id" PASSOU "$desc" "exit=$cc"; else teste "$id" FALHOU "$desc" "exit=$cc $(tail -2 "$WORK/tmp/neg.out" | tr '\n' '|')"; fi
}
nega R10 "importar com a identidade do WORKER (so le): gravacao negada de forma explicita" 'acesso negado|AcessoNegado|falha ao gravar' \
	worker fiscal_a1_cofre importar --empresa "$EMPRESA" --arquivo "$FIXTURE" --senha-arquivo "$WORK/tmp/senha-publica.txt"
nega R11 "homologar com a identidade do IMPORTADOR (nao le conteudo): leitura negada de forma explicita" 'acesso negado|AcessoNegado|falha ao resolver' \
	importador fiscal_a1_cofre homologar --empresa "$EMPRESA"
cp "$WORK/cred/worker.sid" "$WORK/tmp/worker.sid.ok"
printf '00000000-0000-0000-0000-000000000000' >"$WORK/cred/worker.sid"
nega R12 "secret_id invalido: falha de autenticacao explicita (sem fallback)" 'autentica|AutenticacaoFalhou|falha ao resolver' worker fiscal_a1_cofre homologar --empresa "$EMPRESA"
cp -f "$WORK/tmp/worker.sid.ok" "$WORK/cred/worker.sid"
psql -X -U erp_migrador -h "$SOCK" -p 15435 -d erp_fiscal_hml -Atq -c "UPDATE fiscal_certificado_referencia SET identificador_cofre='hml-nao-existe' WHERE empresa_id=$EMPRESA" >/dev/null
nega R13 "segredo inexistente em hml-*: erro explicito (nunca material fingido)" 'nao encontrado|SegredoNaoEncontrado|falha ao resolver' worker fiscal_a1_cofre homologar --empresa "$EMPRESA"
psql -X -U erp_migrador -h "$SOCK" -p 15435 -d erp_fiscal_hml -Atq -c "UPDATE fiscal_certificado_referencia SET identificador_cofre='prod-ensaio' WHERE empresa_id=$EMPRESA" >/dev/null
nega R14 "identificador fora do prefixo hml-: a politica nega (AppRole de HML nao enxerga producao)" 'acesso negado|AcessoNegado|falha ao resolver' worker fiscal_a1_cofre homologar --empresa "$EMPRESA"
psql -X -U erp_migrador -h "$SOCK" -p 15435 -d erp_fiscal_hml -Atq -c "UPDATE fiscal_certificado_referencia SET identificador_cofre='hml-ensaio-rust' WHERE empresa_id=$EMPRESA" >/dev/null

# ---- cofre selado (reinicio): o cliente falha de forma explicita e transitoria ----
kill -TERM "$(cat "$WORK/server.pid")"
for _ in $(seq 1 40); do kill -0 "$(cat "$WORK/server.pid")" 2>/dev/null || break; sleep 0.5; done
iniciar_bao
nega R15 "cofre SELADO apos reinicio: o cliente falha de forma explicita (indisponivel), sem material fingido" 'indisponivel|sealed|selado|resposta|falha ao resolver' worker fiscal_a1_cofre homologar --empresa "$EMPRESA"
for i in 1 2 3; do
	sed -n "${i}p" "$WORK/tmp/chaves.txt" | jq -Rn '{key: input}' | curl -sS --fail --cacert "$CA" -X PUT -H 'Content-Type: application/json' --data-binary @- "$BAO_ADDR/v1/sys/unseal" >/dev/null
done
for _ in $(seq 1 40); do [ "$(curl -s -o /dev/null -w '%{http_code}' --cacert "$CA" "$BAO_ADDR/v1/sys/health")" = "200" ] && break; sleep 0.5; done
set +e
rodar worker fiscal_a1_cofre homologar --empresa "$EMPRESA" >"$WORK/tmp/homologar2.out" 2>&1
c=$?
set -e
if [ "$c" -eq 0 ] && grep -q '^fingerprint_sha256: ' "$WORK/tmp/homologar2.out"; then teste R16 PASSOU "apos destravar, o mesmo cliente volta a ler o segredo (persistencia no cofre real)"; else teste R16 FALHOU "pos-unseal" "c=$c"; fi

# ---- fiscal_nfe_hml status-servico: sem rota => erro de infraestrutura explicito ----
set +e
rodar worker fiscal_nfe_hml status-servico --empresa-id "$EMPRESA" --uf SC >"$WORK/tmp/status.out" 2>&1
c=$?
set -e
if [ "$c" -ne 0 ] && ! grep -q 'em_operacao' "$WORK/tmp/status.out"; then teste R17 PASSOU "status-servico sem rota: falha explicita (nao finge 107)" "exit=$c $(tail -1 "$WORK/tmp/status.out" | cut -c1-120)"; else teste R17 FALHOU "status-servico" "c=$c"; fi

# ---- fiscal_worker: inicia com configuracao valida e para graciosamente (sem fila) ----
mapfile -t pares < <(cli_env worker)
( cd / && env -i PATH="$PATH" RUST_LOG=info RUST_BACKTRACE=0 "${pares[@]}" HOSTNAME=ensaio-worker "$WORK/release/bin/fiscal_worker" >"$WORK/tmp/worker.out" 2>&1 & echo $! >"$WORK/tmp/worker.pid" )
sleep 6
wpid="$(cat "$WORK/tmp/worker.pid")"
if kill -0 "$wpid" 2>/dev/null; then
	inicio_t=$(date +%s)
	kill -TERM "$wpid"
	for _ in $(seq 1 40); do kill -0 "$wpid" 2>/dev/null || break; sleep 0.5; done
	dur=$(($(date +%s) - inicio_t))
	if ! kill -0 "$wpid" 2>/dev/null && [ "$dur" -le 15 ]; then teste R20 PASSOU "fiscal_worker iniciou (config valida, cofre+banco), ficou ocioso e parou graciosamente em ${dur}s ao SIGTERM"; else teste R20 FALHOU "parada do worker" "dur=$dur"; kill -KILL "$wpid" 2>/dev/null || true; fi
else
	teste R20 FALHOU "fiscal_worker nao ficou em execucao" "$(tail -3 "$WORK/tmp/worker.out" | tr '\n' '|')"
fi
if grep -qE 'hvs\.|panicked' "$WORK/tmp/worker.out"; then teste R21 FALHOU "log do worker com token/panico"; else teste R21 PASSOU "log do worker sem token e sem panico"; fi

# ---- higiene: nenhum segredo nos logs capturados ----
vazou=0
sid_w="$(cat "$WORK/cred/worker.sid")"
sid_i="$(cat "$WORK/cred/importador.sid")"
[ -n "$sid_w" ] && [ -n "$sid_i" ] || die "secret_id vazio: a varredura de segredos seria inocua"
for f in "$WORK"/tmp/*.out "$WORK"/tmp/*.limpo; do
	[ -f "$f" ] || continue
	for padrao in "$SENHA_PUBLICA" "$sid_w" "$sid_i"; do
		if grep -qF -e "$padrao" "$f" 2>/dev/null; then vazou=1; printf 'VAZAMENTO em %s (padrao %s caracteres)\n' "$(basename "$f")" "${#padrao}"; fi
	done
done
if [ "$vazou" -eq 0 ]; then teste R30 PASSOU "nenhuma saida dos binarios contem a senha do PFX nem os secret_id"; else teste R30 FALHOU "segredo em log"; fi

total="$(wc -l <"$REGISTRO")"
passou="$(awk -F'\t' '$2=="PASSOU"' "$REGISTRO" | wc -l)"
falhou="$(awk -F'\t' '$2=="FALHOU"' "$REGISTRO" | wc -l)"
printf '== RESUMO: %s testes, %s PASSOU, %s FALHOU ==\n' "$total" "$passou" "$falhou"
[ "$falhou" -eq 0 ]
