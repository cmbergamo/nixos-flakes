#!/usr/bin/env bash
# [FISCAL-I3-HML-INFRA-DSTK-SERVER-01] ENSAIO do cofre OpenBao com OpenBao REAL (nao mock), usando
# EXATAMENTE o gabarito de configuracao, as politicas e os scripts que serao implantados. Roda sem
# privilegio, em loopback, em diretorio descartavel; usa UM segredo sintetico claramente
# identificado ("hml-ensaio-sintetico") e destroi tudo ao final.
#
# ATENCAO — o ensaio NAO substitui a implantacao: roda sob o usuario de quem o executa, entao NAO
# prova a segregacao de usuarios/diretorios do servidor (isso exige o modulo NixOS aplicado por um
# administrador). Ele prova a LOGICA: TLS, AppRole, KV-v2, politicas, auditoria, persistencia,
# selagem apos reinicio, rotacao, backup cifrado e restauracao.
#
# Uso: ENSAIO_DIR=<dir novo e vazio> [ENSAIO_PORTA=18200] [ENSAIO_SAIDA=<arquivo.tsv>] \
#      ensaio-openbao.sh
# Requer no PATH: bao, jq, openssl, curl, age, age-keygen, script (util-linux).
# Achado do proprio ensaio: "bao operator unseal" so aceita a chave por TTY ou argv (nao por pipe);
# a automacao usa a API /v1/sys/unseal com o corpo JSON por pipe.
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

for ferramenta in bao jq openssl curl age age-keygen script; do
	command -v "$ferramenta" >/dev/null || die "ferramenta ausente no PATH: $ferramenta"
done
WORK="${ENSAIO_DIR:?ENSAIO_DIR obrigatorio (diretorio novo e vazio, fora do repositorio)}"
mkdir -p "$WORK"
[ -z "$(ls -A "$WORK")" ] || die "ENSAIO_DIR precisa estar vazio"
PORTA="${ENSAIO_PORTA:-18200}"
PORTA_B=$((PORTA + 10))
for p in "$PORTA" $((PORTA + 1)) "$PORTA_B" $((PORTA_B + 1)); do
	if ss -ltn 2>/dev/null | grep -q ":$p "; then die "porta $p ocupada"; fi
done

mkdir -p "$WORK"/{bin,ca,tls,estado,estadoB,etc,cred,audit,tmp}
ln -s "$BIN/erp-fiscal-hml-provisionar.sh" "$WORK/bin/erp-fiscal-hml-provisionar"
ln -s "$BIN/erp-fiscal-hml-tls.sh" "$WORK/bin/erp-fiscal-hml-tls"
export PATH="$WORK/bin:$PATH"
CA="$WORK/etc/openbao-ca.pem"
ADDR="https://127.0.0.1:$PORTA"
export BAO_ADDR="$ADDR" BAO_CACERT="$CA"
unset BAO_TOKEN || true
REGISTRO="$WORK/resultados.tsv"
: >"$REGISTRO"
PIDS=()

limpar() {
	local pid
	for pid in "${PIDS[@]:-}"; do
		# so mata processos que ESTE ensaio iniciou e que continuam sendo o "bao" (nunca so por PID)
		if [ -n "$pid" ] && [ "$(cat "/proc/$pid/comm" 2>/dev/null || true)" = "bao" ]; then
			kill -TERM "$pid" 2>/dev/null || true
		fi
	done
	if [ -n "${ENSAIO_SAIDA:-}" ] && [ -f "$REGISTRO" ]; then cp "$REGISTRO" "$ENSAIO_SAIDA"; fi
	if [ "${ENSAIO_MANTER:-0}" != "1" ]; then rm -rf "$WORK"; fi
}
trap limpar EXIT

teste() { # id status descricao [detalhe]
	printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >>"$REGISTRO"
	printf '[%s] %s - %s%s\n' "$2" "$1" "$3" "${4:+ ($4)}"
}
espera() { # id descricao esperado obtido [detalhe]
	if [ "$3" = "$4" ]; then
		teste "$1" PASSOU "$2" "esperado=$3 obtido=$4${5:+; $5}"
	else
		teste "$1" FALHOU "$2" "esperado=$3 obtido=$4${5:+; $5}"
	fi
}

api() { # token_file metodo caminho [arquivo_json]  -> imprime o codigo HTTP; corpo em tmp/corpo
	local tokenf="$1" metodo="$2" caminho="$3" dados="${4:-}" hdr="$WORK/tmp/hdr" base="${API_BASE:-$ADDR}"
	if [ -n "$tokenf" ]; then printf 'X-Vault-Token: %s\n' "$(cat "$tokenf")" >"$hdr"; else : >"$hdr"; fi
	local args=(-sS --cacert "$CA" -o "$WORK/tmp/corpo" -w '%{http_code}' -X "$metodo" -H "@$hdr")
	[ -z "$dados" ] || args+=(-H 'Content-Type: application/json' --data-binary "@$dados")
	curl "${args[@]}" "$base/v1/$caminho" 2>"$WORK/tmp/curl.err" || true
}

login() { # role -> codigo; token em tmp/token-<role>
	local role="$1" codigo
	jq -n --rawfile r "$WORK/etc/$role.role-id" --rawfile s "$WORK/cred/$role.sid" \
		'{role_id: ($r|rtrimstr("\n")), secret_id: ($s|rtrimstr("\n"))}' >"$WORK/tmp/login.json"
	codigo="$(api "" POST auth/approle/login "$WORK/tmp/login.json")"
	rm -f "$WORK/tmp/login.json"
	if [ "$codigo" = "200" ]; then jq -r .auth.client_token "$WORK/tmp/corpo" >"$WORK/tmp/token-$role"; fi
	printf '%s' "$codigo"
}

# ENSAIO_SANDBOX=1: sobe o servidor como unidade systemd TRANSITORIA DE USUARIO com as mesmas
# propriedades de endurecimento do modulo NixOS (endurecimento em nixos/erp-distak-fiscal-hml.nix),
# provando que o OpenBao funciona dentro do sandbox (SystemCallFilter, ProtectSystem=strict etc.).
sandbox_props=(
	-p NoNewPrivileges=yes -p PrivateDevices=yes -p ProtectSystem=strict -p "ReadWritePaths=$WORK"
	-p ProtectHome=yes -p ProtectKernelTunables=yes -p ProtectKernelModules=yes -p ProtectKernelLogs=yes
	-p ProtectControlGroups=yes -p ProtectClock=yes -p ProtectHostname=yes -p ProtectProc=invisible
	-p ProcSubset=pid -p RestrictNamespaces=yes -p RestrictRealtime=yes -p RestrictSUIDSGID=yes
	-p LockPersonality=yes -p SystemCallArchitectures=native
	-p "SystemCallFilter=@system-service" -p "SystemCallFilter=~@privileged" -p "SystemCallFilter=~@resources"
	-p CapabilityBoundingSet= -p "RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX"
	-p MemorySwapMax=0 -p LimitCORE=0 -p UMask=0077
	-p IPAddressDeny=any -p "IPAddressAllow=127.0.0.0/8 ::1/128"
)

iniciar() { # pasta_config porta
	local cfg="$1" porta="$2"
	if [ "${ENSAIO_SANDBOX:-0}" = "1" ]; then
		# o restore de snapshot grava um arquivo temporario em TMPDIR (no modulo: PrivateTmp=true)
		systemd-run --user --quiet --collect --unit="efh-bao-$porta" "${sandbox_props[@]}" --setenv=TMPDIR="$WORK/tmp" \
			-p "StandardOutput=append:$WORK/server-$porta.log" -p "StandardError=append:$WORK/server-$porta.log" \
			"$(command -v bao)" server -config="$cfg"
		local i
		for i in $(seq 1 20); do
			systemctl --user show -p MainPID --value "efh-bao-$porta.service" >"$WORK/server-$porta.pid" 2>/dev/null
			[ "$(cat "$WORK/server-$porta.pid")" != "0" ] && break
			sleep 0.25
		done
	else
		( bao server -config="$cfg" >>"$WORK/server-$porta.log" 2>&1 & echo $! >"$WORK/server-$porta.pid" )
	fi
	local pid
	pid="$(cat "$WORK/server-$porta.pid")"
	PIDS+=("$pid")
	local i
	for i in $(seq 1 60); do
		if curl -s --cacert "$CA" -o /dev/null "https://127.0.0.1:$porta/v1/sys/health" 2>/dev/null; then return 0; fi
		sleep 0.5
	done
	[ "${ENSAIO_SANDBOX:-0}" != "1" ] || systemctl --user status "efh-bao-$porta.service" --no-pager 2>&1 | head -12 >&2 || true
	die "servidor nao ficou acessivel na porta $porta (ver server-$porta.log)"
}
parar() { # porta
	local pid
	pid="$(cat "$WORK/server-$1.pid")"
	kill -"${2:-TERM}" "$pid" 2>/dev/null || true
	local i
	for i in $(seq 1 60); do
		kill -0 "$pid" 2>/dev/null || return 0
		sleep 0.5
	done
	die "processo $pid nao terminou"
}
destravar() { # init_json addr   (3 chaves via API, corpo por pipe — nunca argv)
	local json="$1" i
	for i in 0 1 2; do
		jq -r ".unseal_keys_b64[$i]" "$json" | jq -Rn '{key: input}' |
			curl -sS --fail --cacert "$CA" -X PUT -H 'Content-Type: application/json' \
				--data-binary @- "$2/v1/sys/unseal" >/dev/null
	done
	for i in $(seq 1 40); do
		[ "$(BAO_ADDR="$2" bao status -format=json | jq -r '.sealed')" = "false" ] &&
			[ "$(curl -s --cacert "$CA" -o /dev/null -w '%{http_code}' "$2/v1/sys/health")" = "200" ] && return 0
		sleep 0.5
	done
	die "cofre nao ficou ativo apos unseal ($2)"
}

status_script() { ERP_FISCAL_HML_ETC="$WORK/etc" "$BIN/erp-fiscal-hml-status.sh" 2>&1 || true; }

printf '== ENSAIO OpenBao (real) — %s ==\n' "$(date +%Y-%m-%dT%H:%M:%S)"
printf 'bao: %s\n' "$(bao version)"
printf 'openssl: %s\n' "$(openssl version)"
[ "${ENSAIO_SANDBOX:-0}" != "1" ] || printf 'MODO SANDBOX: servidor sob unidade systemd transitoria endurecida (mesmas propriedades do modulo)\n'
[ -z "${ENSAIO_NIXPKGS_REV:-}" ] || printf 'nixpkgs rev: %s\n' "$ENSAIO_NIXPKGS_REV"

# ------------------------------------------------------------------ preparacao (PKI + config) ---
erp-fiscal-hml-tls --ca-dir "$WORK/ca" --tls-dir "$WORK/tls" --ca-publica "$CA" >"$WORK/tmp/tls.out"
sed -n 's/^\(servidor_valido_ate\|ca_sha256\)=/\1: /p' "$WORK/tmp/tls.out"

AUDIT_FILE="$WORK/audit/audit.log" STATE_DIR="$WORK/estado" TLS_DIR="$WORK/tls" LISTEN_PORT="$PORTA" CLUSTER_PORT=$((PORTA + 1)) \
	"$AQUI/render-config.sh" "$GABARITO" >"$WORK/openbao.hcl"
AUDIT_FILE="$WORK/audit/audit.log" STATE_DIR="$WORK/estadoB" TLS_DIR="$WORK/tls" LISTEN_PORT="$PORTA_B" CLUSTER_PORT=$((PORTA_B + 1)) \
	NODE_ID=erp-fiscal-hml-restauro "$AQUI/render-config.sh" "$GABARITO" >"$WORK/openbaoB.hcl"
grep -E 'tls_(min_version|disable_client_certs)|^storage|address' "$WORK/openbao.hcl" | sed 's/^/config: /'

iniciar "$WORK/openbao.hcl" "$PORTA"
[ "$(bao status -format=json | jq -r '.initialized')" = "false" ] || die "esperava cofre nao inicializado"
bao operator init -key-shares=5 -key-threshold=3 -format=json >"$WORK/init.json"
destravar "$WORK/init.json" "$ADDR"
jq -r .root_token "$WORK/init.json" >"$WORK/tmp/token-root"
export BAO_TOKEN
BAO_TOKEN="$(cat "$WORK/tmp/token-root")"
teste T00 PASSOU "init (5 chaves, limiar 3) e unseal via API com corpo por pipe, sem argv" "versao=$(bao status -format=json | jq -r .version) storage=$(bao status -format=json | jq -r .storage_type)"

# ------------------------------------------------------- provisionamento (script de producao) ---
provisionar() {
	erp-fiscal-hml-provisionar --politicas "$POLITICAS" \
		--role-ids-dir "$WORK/etc" \
		--secret-id-worker "$WORK/cred/fiscal-worker.sid" \
		--secret-id-importador "$WORK/cred/fiscal-importador.sid" \
		--secret-id-backup "$WORK/cred/fiscal-backup.sid" \
		--secret-id-recuperacao "$WORK/cred/fiscal-recuperacao.sid" "$@"
}
provisionar >"$WORK/tmp/prov1.out"
sed 's/^/provisionar: /' "$WORK/tmp/prov1.out"
provisionar >"$WORK/tmp/prov2.out"
if grep -q 'mantido' "$WORK/tmp/prov2.out" && grep -q '^OK' "$WORK/tmp/prov2.out"; then
	teste T01 PASSOU "provisionar e idempotente (2a execucao mantem secret_ids e conclui OK)"
else
	teste T01 FALHOU "provisionar nao idempotente" "$(tr '\n' '|' <"$WORK/tmp/prov2.out")"
fi

# ----------------------------------------- CIDR: o vinculo de origem e realmente aplicado ------
bao write auth/approle/role/ensaio-cidr token_policies=default \
	secret_id_bound_cidrs=10.255.255.0/24 >/dev/null
bao read -field=role_id auth/approle/role/ensaio-cidr/role-id >"$WORK/etc/ensaio-cidr.role-id"
bao write -f -field=secret_id auth/approle/role/ensaio-cidr/secret-id >"$WORK/cred/ensaio-cidr.sid"
cod="$(login ensaio-cidr)"
bao delete auth/approle/role/ensaio-cidr >/dev/null
rm -f "$WORK/cred/ensaio-cidr.sid" "$WORK/etc/ensaio-cidr.role-id"
if [ "$cod" = "400" ] || [ "$cod" = "403" ]; then
	teste T02 PASSOU "secret_id preso a CIDR e recusado fora do CIDR (login de 127.0.0.1 em role 10.255.255.0/24)" "http=$cod"
else
	teste T02 FALHOU "vinculo de CIDR nao aplicado" "http=$cod"
fi
for r in fiscal-worker fiscal-importador fiscal-backup; do
	cfg="$(bao read -format=json "auth/approle/role/$r" | jq -c '.data | {token_policies, token_bound_cidrs, secret_id_bound_cidrs, token_ttl, token_max_ttl, secret_id_ttl, secret_id_num_uses}')"
	teste T03 PASSOU "configuracao do AppRole $r" "$cfg"
done

# ------------------------------------------------- rotacao do secret_id (antes de revogar root) ---
cp "$WORK/cred/fiscal-worker.sid" "$WORK/tmp/worker-antigo.sid"
provisionar --rotacionar >"$WORK/tmp/prov3.out"
cod_novo="$(login fiscal-worker)"
cp "$WORK/cred/fiscal-worker.sid" "$WORK/tmp/worker-novo.sid"
cp -f "$WORK/tmp/worker-antigo.sid" "$WORK/cred/fiscal-worker.sid"
cod_antigo="$(login fiscal-worker)"
cp -f "$WORK/tmp/worker-novo.sid" "$WORK/cred/fiscal-worker.sid"
rm -f "$WORK/tmp/worker-antigo.sid" "$WORK/tmp/worker-novo.sid"
if [ "$cod_novo" = "200" ] && { [ "$cod_antigo" = "400" ] || [ "$cod_antigo" = "403" ]; }; then
	teste T04 PASSOU "rotacao: secret_id novo autentica e o anterior foi destruido" "novo=$cod_novo antigo=$cod_antigo"
else
	teste T04 FALHOU "rotacao do secret_id" "novo=$cod_novo antigo=$cod_antigo"
fi

# --------------------------------------------------------------- nenhum root token persistente ---
bao token revoke -self >/dev/null
unset BAO_TOKEN
cod="$(api "$WORK/tmp/token-root" GET auth/token/lookup-self)"
espera T05 "root token revogado (nao persiste)" 403 "$cod"

# ----------------------------------------------------------------------------- AppRole logins ---
for r in fiscal-worker fiscal-importador fiscal-backup; do
	espera "T06-$r" "login AppRole $r" 200 "$(login "$r")"
done

# ------------------------------------ importador grava o segredo SINTETICO; worker le; escrita nega ---
SEG="secret/data/fiscal/certificados/hml-ensaio-sintetico"
PFX_FALSO="SINTETICO-ENSAIO-NAO-E-A1-REAL"
SENHA_FALSA="senha-sintetica-ensaio-1"
jq -n --arg p "$(printf '%s' "$PFX_FALSO" | base64 -w0)" --arg s "$SENHA_FALSA" \
	'{data: {pfx_base64: $p, senha: $s}}' >"$WORK/tmp/seg.json"
espera T07 "importador GRAVA (create) em hml-*" 200 "$(api "$WORK/tmp/token-fiscal-importador" POST "$SEG" "$WORK/tmp/seg.json")"
espera T08 "importador regrava (update -> nova versao)" 200 "$(api "$WORK/tmp/token-fiscal-importador" POST "$SEG" "$WORK/tmp/seg.json")"
espera T09 "worker LE o segredo autorizado" 200 "$(api "$WORK/tmp/token-fiscal-worker" GET "$SEG")"
lido="$(jq -r '.data.data.pfx_base64' "$WORK/tmp/corpo" | base64 -d)"
espera T10 "conteudo lido pelo worker confere (comparado sem imprimir o segredo)" "$(printf '%s' "$PFX_FALSO" | sha256sum | cut -c1-16)" "$(printf '%s' "$lido" | sha256sum | cut -c1-16)"
espera T11 "importador le METADADOS (verificacao)" 200 "$(api "$WORK/tmp/token-fiscal-importador" GET secret/metadata/fiscal/certificados/hml-ensaio-sintetico)"
espera T11b "metadados mostram 2 versoes" 2 "$(jq -r '.data.current_version' "$WORK/tmp/corpo")"

negado() { # id descricao token metodo caminho [json]
	espera "$1" "$2" 403 "$(api "$WORK/tmp/token-$3" "$4" "$5" "${6:-}")"
}
negado T12a "worker NAO grava" fiscal-worker POST "$SEG" "$WORK/tmp/seg.json"
negado T12b "worker NAO lista segredos" fiscal-worker GET "secret/metadata/fiscal/certificados?list=true"
negado T12c "worker NAO le fora do prefixo hml-" fiscal-worker GET secret/data/fiscal/certificados/prod-qualquer
negado T12d "worker NAO le segredo de outro modulo" fiscal-worker GET secret/data/logistica/frete
negado T12e "worker NAO le metadados" fiscal-worker GET secret/metadata/fiscal/certificados/hml-ensaio-sintetico
negado T12f "worker NAO administra montagens (sys/mounts)" fiscal-worker GET sys/mounts
negado T12g "worker NAO le politicas" fiscal-worker GET sys/policies/acl/fiscal-worker
printf '{"policy":"path \\"*\\" { capabilities = [\\"sudo\\"] }"}' >"$WORK/tmp/pol.json"
negado T12h "worker NAO altera politicas (sys/policies)" fiscal-worker PUT sys/policies/acl/evil "$WORK/tmp/pol.json"
negado T12i "worker NAO le a auditoria (sys/audit)" fiscal-worker GET sys/audit
negado T12j "worker NAO emite secret_id" fiscal-worker POST auth/approle/role/fiscal-worker/secret-id
negado T12k "worker NAO cria tokens" fiscal-worker POST auth/token/create

negado T13a "importador NAO le o CONTEUDO" fiscal-importador GET "$SEG"
negado T13b "importador NAO grava fora do prefixo hml-" fiscal-importador POST secret/data/fiscal/certificados/prod-qualquer "$WORK/tmp/seg.json"
negado T13c "importador NAO grava em outro modulo" fiscal-importador POST secret/data/logistica/frete "$WORK/tmp/seg.json"
negado T13d "importador NAO apaga versoes" fiscal-importador DELETE "$SEG"
negado T13e "importador NAO destroi metadados" fiscal-importador DELETE secret/metadata/fiscal/certificados/hml-ensaio-sintetico
negado T13f "importador NAO altera politicas" fiscal-importador PUT sys/policies/acl/evil "$WORK/tmp/pol.json"
negado T13g "importador NAO administra montagens" fiscal-importador GET sys/mounts
negado T13h "importador NAO lista segredos" fiscal-importador GET "secret/metadata/fiscal/certificados?list=true"

negado T14a "backup NAO le KV" fiscal-backup GET "$SEG"
negado T14b "backup NAO grava KV" fiscal-backup POST "$SEG" "$WORK/tmp/seg.json"
negado T14c "backup NAO altera politicas" fiscal-backup PUT sys/policies/acl/evil "$WORK/tmp/pol.json"
negado T14d "backup NAO restaura snapshot (sys/storage/raft/snapshot POST)" fiscal-backup POST sys/storage/raft/snapshot

# ------------------------------------------------ falhas explicitas: credenciais invalidas/ausentes ---
jq -n --rawfile r "$WORK/etc/fiscal-worker.role-id" '{role_id: ($r|rtrimstr("\n")), secret_id: "00000000-0000-0000-0000-000000000000"}' >"$WORK/tmp/ruim.json"
cod="$(api "" POST auth/approle/login "$WORK/tmp/ruim.json")"
if [ "$cod" = 400 ] || [ "$cod" = 403 ]; then teste T15a PASSOU "login com secret_id invalido falha explicitamente" "http=$cod"; else teste T15a FALHOU "login invalido" "http=$cod"; fi
printf '{"role_id":"inexistente","secret_id":"x"}' >"$WORK/tmp/ruim.json"
cod="$(api "" POST auth/approle/login "$WORK/tmp/ruim.json")"
if [ "$cod" = 400 ] || [ "$cod" = 403 ]; then teste T15b PASSOU "login com role_id inexistente falha explicitamente" "http=$cod"; else teste T15b FALHOU "role inexistente" "http=$cod"; fi
cod="$(api "" POST auth/approle/login)"
if [ "$cod" -ge 400 ] && ! jq -e '.auth.client_token' "$WORK/tmp/corpo" >/dev/null 2>&1; then
	teste T15c PASSOU "login sem credenciais falha explicitamente e nao emite token" "http=$cod (OpenBao responde 5xx a corpo vazio; o cliente Rust sempre envia role_id/secret_id)"
else
	teste T15c FALHOU "login vazio" "http=$cod"
fi
cod="$(api "" GET "$SEG")"
espera T15d "leitura sem token e negada" 403 "$cod"

# ------------------------------------------------ sanitizacao dos logs (defesa em profundidade) ---
{
	printf '2026-10-17T10:00:00 client_token=hvs.CAESIFakeFakeFakeFakeFakeFakeFake1234567890 ok\n'
	printf '2026-10-17T10:00:01 secret_id: 11111111-2222-3333-4444-555555555555 emitido\n'
	printf '2026-10-17T10:00:02 {"senha":"minha-senha-do-pfx","pfx_base64":"%s"}\n' "$(head -c 120 /dev/zero | tr '\0' 'A')"
	printf '2026-10-17T10:00:03 X-Vault-Token: s.AbCdEfGhIjKlMnOpQrStUvWx\n'
	printf '\033[31mlinha-com-ansi\033[0m\n'
} >"$WORK/tmp/log-sujo.txt"
"$BIN/erp-fiscal-hml-logs.sh" --filtrar <"$WORK/tmp/log-sujo.txt" >"$WORK/tmp/log-limpo.txt"
if grep -qE 'hvs\.|minha-senha-do-pfx|AAAAAAAAAAAAAAAAAAAA|11111111-2222|s\.AbCd' "$WORK/tmp/log-limpo.txt" || grep -q "$(printf '\033')" "$WORK/tmp/log-limpo.txt"; then
	teste T22 FALHOU "sanitizacao de logs deixou passar valor sensivel" "$(head -5 "$WORK/tmp/log-limpo.txt" | tr '\n' '|')"
else
	teste T22 PASSOU "erp-fiscal-hml-logs mascara token, secret_id, senha, PFX (base64) e escapes ANSI" "$(wc -l <"$WORK/tmp/log-limpo.txt") linhas"
fi

# ----------------------------------------------------------------------------------------- TLS ---
if curl -sS --max-time 10 -o /dev/null "$ADDR/v1/sys/health" 2>"$WORK/tmp/tls-sem-ca.err"; then
	teste T16a FALHOU "cliente sem a CA privada NAO deveria conseguir conectar"
else
	teste T16a PASSOU "cliente sem a CA privada recusa o certificado (sem skip-verify)" "$(head -c 120 "$WORK/tmp/tls-sem-ca.err" | tr -d '\n')"
fi
openssl s_client -connect "127.0.0.1:$PORTA" -CAfile "$CA" -verify_return_error -verify_ip 127.0.0.1 -brief </dev/null >"$WORK/tmp/sclient.out" 2>&1 || true
if grep -q 'Verification: OK' "$WORK/tmp/sclient.out"; then
	teste T16b PASSOU "TLS valido: cadeia + SAN IP 127.0.0.1 verificados" "$(grep -E 'Protocol version|Ciphersuite' "$WORK/tmp/sclient.out" | tr '\n' ' ')"
else
	teste T16b FALHOU "verificacao TLS" "$(head -c 200 "$WORK/tmp/sclient.out" | tr '\n' ' ')"
fi
openssl s_client -connect "127.0.0.1:$PORTA" -CAfile "$CA" -verify_return_error -verify_hostname localhost -brief </dev/null >"$WORK/tmp/sclient2.out" 2>&1 || true
if grep -q 'Verification: OK' "$WORK/tmp/sclient2.out"; then
	teste T16c FALHOU "o certificado nao deveria validar o nome 'localhost' (D31: so IP)"
else
	teste T16c PASSOU "o certificado nao autoriza o nome 'localhost' (so IP 127.0.0.1/::1, D31)"
fi

# --------------------------------------------------------------------------------- auditoria ---
if [ -s "$WORK/audit/audit.log" ] && jq -e . "$WORK/audit/audit.log" >/dev/null 2>&1; then
	vazou=0
	for valor in "$SENHA_FALSA" "$PFX_FALSO" "$(printf '%s' "$PFX_FALSO" | base64 -w0)" "$(cat "$WORK/cred/fiscal-worker.sid")" "$(cat "$WORK/cred/fiscal-importador.sid")" "$(cat "$WORK/tmp/token-fiscal-worker")" "$(cat "$WORK/tmp/token-fiscal-importador")"; do
		if grep -qF -- "$valor" "$WORK/audit/audit.log"; then vazou=1; fi
	done
	linhas="$(wc -l <"$WORK/audit/audit.log")"
	if [ "$vazou" = 0 ]; then
		teste T17 PASSOU "auditoria registra as requisicoes e NAO contem senha/PFX/secret_id/token em claro" "linhas=$linhas hmac=$(grep -c 'hmac-sha256:' "$WORK/audit/audit.log")"
	else
		teste T17 FALHOU "VAZAMENTO de valor sensivel na auditoria"
	fi
else
	teste T17 FALHOU "arquivo de auditoria ausente/vazio/invalido"
fi

# ------------------------------------------------------------ permissoes dos arquivos entregues ---
perm() { stat -c '%a' "$1"; }
espera T18a "secret_id do worker 0400" 400 "$(perm "$WORK/cred/fiscal-worker.sid")"
espera T18b "chave privada do servidor 0400" 400 "$(perm "$WORK/tls/server.key")"
espera T18c "chave da CA 0400 em diretorio 0700" "400/700" "$(perm "$WORK/ca/ca.key")/$(perm "$WORK/ca")"
espera T18d "CA publica 0644 e sem chave privada" "644/0" "$(perm "$CA")/$(grep -c 'PRIVATE KEY' "$CA")"

# ----------------------------------------- reinicio gracioso: persiste, volta SELADO, exige unseal ---
parar "$PORTA"
iniciar "$WORK/openbao.hcl" "$PORTA"
st="$(bao status -format=json || true)"
espera T19a "apos restart: dados persistidos (initialized=true)" true "$(jq -r .initialized <<<"$st")"
espera T19b "apos restart: cofre volta SELADO (sem auto-unseal; recuperacao e humana)" true "$(jq -r .sealed <<<"$st")"
if status_script | grep -q '^\[FALHA\] cofre SELADO'; then
	teste T19b2 PASSOU "erp-fiscal-hml-status acusa 'cofre SELADO' apos o restart"
else
	teste T19b2 FALHOU "status nao acusou o cofre selado"
fi
cod="$(login fiscal-worker)"
if [ "$cod" != "200" ]; then teste T19c PASSOU "com o cofre selado o login do worker falha de forma explicita" "http=$cod"; else teste T19c FALHOU "login funcionou com o cofre selado"; fi
destravar "$WORK/init.json" "$ADDR"
espera T19d "apos unseal: worker autentica" 200 "$(login fiscal-worker)"
status_script >"$WORK/tmp/status.out"
if grep -q '^\[OK\] cofre destravado e ATIVO' "$WORK/tmp/status.out" && grep -q '^\[OK\] certificado TLS do cofre valido' "$WORK/tmp/status.out"; then
	teste T19g PASSOU "erp-fiscal-hml-status: cofre ATIVO e TLS valido" "$(grep -E 'cofre destravado|certificado TLS' "$WORK/tmp/status.out" | cut -c1-110 | tr '\n' '|')"
else
	teste T19g FALHOU "erp-fiscal-hml-status" "$(head -6 "$WORK/tmp/status.out" | tr '\n' '|')"
fi
espera T19e "apos unseal: segredo persistiu" 200 "$(api "$WORK/tmp/token-fiscal-worker" GET "$SEG")"
espera T19f "conteudo identico apos restart" "$(printf '%s' "$PFX_FALSO" | sha256sum | cut -c1-16)" "$(jq -r '.data.data.pfx_base64' "$WORK/tmp/corpo" | base64 -d | sha256sum | cut -c1-16)"

# ----------------------------------------------------------------------------- queda abrupta ---
parar "$PORTA" KILL
iniciar "$WORK/openbao.hcl" "$PORTA"
# usa o wrapper operacional de unseal sob um pseudo-terminal (prompt oculto), 3 chaves por stdin
for i in 0 1 2; do jq -r ".unseal_keys_b64[$i]" "$WORK/init.json"; done >"$WORK/tmp/chaves.txt"
if script -qec "$BIN/erp-fiscal-hml-unseal.sh" /dev/null <"$WORK/tmp/chaves.txt" >"$WORK/tmp/unseal-wrapper.out" 2>&1; then
	teste T20a PASSOU "erp-fiscal-hml-unseal destrava via prompt oculto (pseudo-terminal)" "$(tr -d '\r' <"$WORK/tmp/unseal-wrapper.out" | grep -E 'progresso|DESTRAVADO' | tr '\n' '|')"
else
	teste T20a FALHOU "erp-fiscal-hml-unseal" "$(tr -d '\r' <"$WORK/tmp/unseal-wrapper.out" | head -c 300 | tr '\n' '|')"
fi
rm -f "$WORK/tmp/chaves.txt"
espera T20b "apos kill -9 + unseal: worker autentica" 200 "$(login fiscal-worker)"
espera T20c "apos kill -9 + unseal: segredo integro" 200 "$(api "$WORK/tmp/token-fiscal-worker" GET "$SEG")"

# ------------------------------- recuperacao do acesso administrativo (root token ja revogado) ---
# Achado do ensaio: no OpenBao >= 2.6 o generate-root e AUTENTICADO (sys/generate-root-token). Por isso
# existe a identidade fiscal-recuperacao e o script erp-fiscal-hml-admin (sessao temporaria).
espera T23a "recuperacao: AppRole fiscal-recuperacao autentica" 200 "$(login fiscal-recuperacao)"
negado T23b "recuperacao NAO le segredos" fiscal-recuperacao GET "$SEG"
negado T23c "recuperacao NAO grava segredos" fiscal-recuperacao POST "$SEG" "$WORK/tmp/seg.json"
negado T23d "recuperacao NAO altera politicas" fiscal-recuperacao PUT sys/policies/acl/evil "$WORK/tmp/pol.json"
negado T23e "recuperacao NAO administra montagens" fiscal-recuperacao GET sys/mounts
for i in 0 1 2; do jq -r ".unseal_keys_b64[$i]" "$WORK/init.json"; done >"$WORK/tmp/chaves-admin.txt"
set +e
env ERP_FISCAL_HML_ETC="$WORK/etc" ERP_FISCAL_HML_SID_RECUPERACAO="$WORK/cred/fiscal-recuperacao.sid" \
	script -qec "$BIN/erp-fiscal-hml-admin.sh -- sh -c 'printf %s \"\$BAO_TOKEN\" > $WORK/tmp/token-admin-sessao; bao policy read fiscal-worker'" /dev/null \
	<"$WORK/tmp/chaves-admin.txt" >"$WORK/tmp/admin.out" 2>&1
c=$?
set -e
rm -f "$WORK/tmp/chaves-admin.txt"
tr -d '\r' <"$WORK/tmp/admin.out" >"$WORK/tmp/admin.limpo"
if [ "$c" -eq 0 ] && grep -q 'hml-\*' "$WORK/tmp/admin.limpo" && [ -s "$WORK/tmp/token-admin-sessao" ]; then
	teste T23f PASSOU "erp-fiscal-hml-admin: 3 de 5 chaves -> token administrativo temporario que ADMINISTRA (le a politica do worker)"
else
	teste T23f FALHOU "erp-fiscal-hml-admin" "c=$c $(head -c 300 "$WORK/tmp/admin.limpo" | tr '\n' '|')"
fi
espera T23g "o token administrativo foi REVOGADO ao sair da sessao" 403 "$(api "$WORK/tmp/token-admin-sessao" GET sys/policies/acl/fiscal-worker)"
rm -f "$WORK/tmp/token-admin-sessao"

# ---------------------------------------- renovacao do certificado TLS por SIGHUP (sem selar o cofre) ---
serie_antes="$(openssl s_client -connect "127.0.0.1:$PORTA" -CAfile "$CA" </dev/null 2>/dev/null | openssl x509 -noout -serial)"
erp-fiscal-hml-tls --ca-dir "$WORK/ca" --tls-dir "$WORK/tls" --ca-publica "$CA" --renovar-servidor >"$WORK/tmp/tls-renovar.out"
kill -HUP "$(cat "$WORK/server-$PORTA.pid")"
sleep 2
serie_depois="$(openssl s_client -connect "127.0.0.1:$PORTA" -CAfile "$CA" </dev/null 2>/dev/null | openssl x509 -noout -serial)"
sel_depois="$(bao status -format=json | jq -r .sealed)"
if [ "$serie_antes" != "$serie_depois" ] && [ "$sel_depois" = "false" ]; then
	teste T24 PASSOU "renovar o certificado do servidor + SIGHUP: novo certificado em uso e o cofre PERMANECE destravado" "$serie_antes -> $serie_depois"
else
	teste T24 FALHOU "renovacao por SIGHUP" "antes=$serie_antes depois=$serie_depois selado=$sel_depois"
fi
espera T24b "apos a renovacao o cliente com a CA original segue autenticando" 200 "$(login fiscal-worker)"

# --------------------------------------------- backup cifrado (age) e RESTAURACAO em instancia nova ---
age-keygen -o "$WORK/tmp/age-ident.txt" 2>/dev/null
age-keygen -y "$WORK/tmp/age-ident.txt" >"$WORK/etc/backup-recipients.txt"
mkdir -p "$WORK/artefatos"
printf '<nfe-sintetica-ensaio/>' >"$WORK/artefatos/nfe-ensaio.xml"
backup_cofre() {
	ERP_FISCAL_HML_BACKUP_TESTE=1 ERP_FISCAL_HML_ETC="$WORK/etc" ERP_FISCAL_HML_BACKUP_DIR="$WORK/backups" \
		RUNTIME_DIRECTORY="$WORK/run-backup" ERP_FISCAL_HML_SID_BACKUP="$WORK/cred/fiscal-backup.sid" \
		FISCAL_ARTEFATOS_DIR="$WORK/artefatos" "$BIN/erp-fiscal-hml-backup.sh" --sem-postgres
}
if backup_cofre >"$WORK/tmp/backup.out" 2>&1; then
	snap_age="$(find "$WORK/backups" -name '*_openbao.snap.age' | head -1)"
	art_age="$(find "$WORK/backups" -name '*_artefatos.tar.age' | head -1)"
	teste T21a PASSOU "erp-fiscal-hml-backup (producao): snapshot do cofre + artefatos cifrados" "$(basename "$snap_age") $(stat -c %s "$snap_age")B; $(basename "$art_age") $(stat -c %s "$art_age")B"
else
	teste T21a FALHOU "erp-fiscal-hml-backup" "$(tail -3 "$WORK/tmp/backup.out" | tr '\n' '|')"
	snap_age=""; art_age=""
fi
[ -n "$snap_age" ] || die "sem snapshot para restaurar"
if grep -aq 'SINTETICO\|raft\|xml' "$snap_age" "$art_age"; then
	teste T21b FALHOU "artefato cifrado contem texto reconhecivel"
else
	teste T21b PASSOU "backups cifrados com age para destinatario PUBLICO (a chave de decifrar nao fica no servidor)"
fi
age -d -i "$WORK/tmp/age-ident.txt" -o "$WORK/tmp/cofre.snap" "$snap_age"
mkdir -p "$WORK/tmp/art-restaurado"
age -d -i "$WORK/tmp/age-ident.txt" "$art_age" | tar -C "$WORK/tmp/art-restaurado" -xf -
espera T21c "artefatos decifrados identicos aos originais" "$(sha256sum <"$WORK/artefatos/nfe-ensaio.xml" | cut -c1-16)" "$(sha256sum <"$WORK/tmp/art-restaurado/nfe-ensaio.xml" | cut -c1-16)"
rm -f "$WORK/run-backup"/* 2>/dev/null || true
espera T21c2 "plaintext do backup nao sobra no diretorio temporario do servico" 0 "$(find "$WORK/run-backup" -type f 2>/dev/null | wc -l)"

# Achado do ensaio: o dataset restaurado carrega o dispositivo de auditoria DECLARATIVO do original e o
# OpenBao proibe modificar dispositivos declarativos — o config do alvo da restauracao deve declarar
# o MESMO bloco audit (mesmo path/options). No modulo NixOS isso e automatico (mesmo gabarito).
# A instancia original e parada antes (nunca duas instancias gravando o mesmo arquivo de auditoria).
parar "$PORTA"
iniciar "$WORK/openbaoB.hcl" "$PORTA_B"
BAO_ADDR="https://127.0.0.1:$PORTA_B" bao operator init -key-shares=1 -key-threshold=1 -format=json >"$WORK/initB.json"
jq -r '.unseal_keys_b64[0]' "$WORK/initB.json" | jq -Rn '{key: input}' |
	curl -sS --fail --cacert "$CA" -X PUT -H 'Content-Type: application/json' \
		--data-binary @- "https://127.0.0.1:$PORTA_B/v1/sys/unseal" >/dev/null
for _ in $(seq 1 40); do
	[ "$(curl -s --cacert "$CA" -o /dev/null -w '%{http_code}' "https://127.0.0.1:$PORTA_B/v1/sys/health")" = "200" ] && break
	sleep 0.5
done
BAO_TOKEN="$(jq -r .root_token "$WORK/initB.json")" BAO_ADDR="https://127.0.0.1:$PORTA_B" \
	bao operator raft snapshot restore -force "$WORK/tmp/cofre.snap" >"$WORK/tmp/restore.out" 2>&1 || true
# Achado do ensaio: apos o restore o no sela e o laco de HA para; o procedimento correto e REINICIAR
# o servico e destravar com as chaves ORIGINAIS (3 de 5) — a barreira passa a ser a do cofre original.
for _ in $(seq 1 20); do
	grep -q 'restored user snapshot' "$WORK/server-$PORTA_B.log" && break
	sleep 0.5
done
grep -q 'restored user snapshot' "$WORK/server-$PORTA_B.log" || die "restore nao confirmado no log da instancia B"
parar "$PORTA_B"
iniciar "$WORK/openbaoB.hcl" "$PORTA_B"
espera T21d0 "apos o restore a instancia nova exige a barreira ORIGINAL (selada ate o unseal com as chaves originais)" true "$(BAO_ADDR="https://127.0.0.1:$PORTA_B" bao status -format=json | jq -r .sealed)"
destravar "$WORK/init.json" "https://127.0.0.1:$PORTA_B"
espera T21d "restaurado em instancia NOVA: worker autentica (AppRole/politicas restaurados)" 200 "$(API_BASE="https://127.0.0.1:$PORTA_B" login fiscal-worker)"
espera T21e "restaurado em instancia NOVA: segredo sintetico presente" 200 "$(API_BASE="https://127.0.0.1:$PORTA_B" api "$WORK/tmp/token-fiscal-worker" GET "$SEG")"
espera T21f "conteudo restaurado identico" "$(printf '%s' "$PFX_FALSO" | sha256sum | cut -c1-16)" "$(jq -r '.data.data.pfx_base64' "$WORK/tmp/corpo" | base64 -d | sha256sum | cut -c1-16)"
parar "$PORTA_B"

# ----------------------------- bootstrap de PRODUCAO (o script real) numa instancia nova ---------
# Roda erp-fiscal-hml-bootstrap sob pseudo-terminal (como o administrador faria), com as variaveis
# de ensaio explicitas (sem root/usuarios do host): init, exibicao unica das chaves, unseal,
# provisionamento e REVOGACAO do root token.
PORTA_C=$((PORTA + 20))
mkdir -p "$WORK"/{estadoC,etcC,credC,bootC,politicasC}
cp "$POLITICAS"/*.hcl "$WORK/politicasC/"
cp "$CA" "$WORK/etcC/openbao-ca.pem"
AUDIT_FILE="$WORK/audit/auditC.log" STATE_DIR="$WORK/estadoC" TLS_DIR="$WORK/tls" LISTEN_PORT="$PORTA_C" CLUSTER_PORT=$((PORTA_C + 1)) \
	NODE_ID=erp-fiscal-hml-bootstrap "$AQUI/render-config.sh" "$GABARITO" >"$WORK/openbaoC.hcl"
parar "$PORTA_B" 2>/dev/null || true
iniciar "$WORK/openbaoC.hcl" "$PORTA_C"
boot_env=(
	ERP_FISCAL_HML_BOOTSTRAP_TESTE=1 ERP_FISCAL_HML_ETC="$WORK/etcC" ERP_FISCAL_HML_POLITICAS="$WORK/politicasC"
	ERP_FISCAL_HML_SID_WORKER="$WORK/credC/w.sid" ERP_FISCAL_HML_SID_IMPORTADOR="$WORK/credC/i.sid"
	ERP_FISCAL_HML_SID_BACKUP="$WORK/credC/b.sid" ERP_FISCAL_HML_SID_RECUPERACAO="$WORK/credC/r.sid" ERP_FISCAL_HML_DONO_WORKER= ERP_FISCAL_HML_DONO_IMPORTADOR=
	ERP_FISCAL_HML_BOOTSTRAP_TMP="$WORK/bootC" BAO_ADDR="https://127.0.0.1:$PORTA_C" BAO_CACERT="$CA"
)
set +e
env TMUX=/tmp/tmux-teste,1,0 "${boot_env[@]}" script -qec "$BIN/erp-fiscal-hml-bootstrap.sh" /dev/null </dev/null >"$WORK/tmp/boot-tmux.out" 2>&1
c=$?
set -e
init_c="$(BAO_ADDR="https://127.0.0.1:$PORTA_C" bao status -format=json 2>/dev/null | jq -r .initialized || true)"
if [ "$c" -ne 0 ] && grep -q 'tmux/screen' "$WORK/tmp/boot-tmux.out" && [ "$init_c" = "false" ]; then
	teste B01 PASSOU "bootstrap RECUSA rodar dentro de tmux/screen (variavel TMUX) antes de inicializar o cofre"
else
	teste B01 FALHOU "bootstrap em tmux" "c=$c init=$init_c"
fi
# sob sudo o env_reset remove TMUX: a deteccao tambem olha os processos ancestrais (aqui, um ancestral "tmux")
ln -sf "$(command -v bash)" "$WORK/bin/tmux"
set +e
env -u TMUX -u STY "${boot_env[@]}" "$WORK/bin/tmux" -c "script -qec '$BIN/erp-fiscal-hml-bootstrap.sh' /dev/null </dev/null" >"$WORK/tmp/boot-tmux2.out" 2>&1
c=$?
set -e
init_c="$(BAO_ADDR="https://127.0.0.1:$PORTA_C" bao status -format=json 2>/dev/null | jq -r .initialized || true)"
if [ "$c" -ne 0 ] && grep -q 'tmux/screen' "$WORK/tmp/boot-tmux2.out" && [ "$init_c" = "false" ]; then
	teste B01b PASSOU "bootstrap RECUSA tambem sem a variavel TMUX (ancestral 'tmux' na cadeia de processos, como sob sudo)"
else
	teste B01b FALHOU "bootstrap com ancestral tmux" "c=$c init=$init_c"
fi
set +e
printf 'CONFIRMO\n' | env -u TMUX -u STY ERP_FISCAL_HML_IGNORAR_ANCESTRAIS_TESTE=1 "${boot_env[@]}" script -qec "$BIN/erp-fiscal-hml-bootstrap.sh" /dev/null >"$WORK/tmp/boot.out" 2>&1
c=$?
set -e
tr -d '\r' <"$WORK/tmp/boot.out" >"$WORK/tmp/boot.limpo"
espera B02 "erp-fiscal-hml-bootstrap (producao) conclui com exit 0" 0 "$c"
espera B03 "exibe 5 chaves de recuperacao uma unica vez" 5 "$(grep -cE '^Chave [1-5]/5: ' "$WORK/tmp/boot.limpo")"
espera B04 "JSON temporario de init removido do tmpfs" 0 "$(find "$WORK/bootC" -type f | wc -l)"
if grep -q 'root token revogado' "$WORK/tmp/boot.limpo"; then
	teste B05 PASSOU "root token revogado e provado (lookup falha) dentro do proprio script"
else
	teste B05 FALHOU "root token"
fi
login_c() { # role sidfile
	jq -n --rawfile r "$WORK/etcC/$1.role-id" --rawfile s "$2" '{role_id: ($r|rtrimstr("\n")), secret_id: ($s|rtrimstr("\n"))}' >"$WORK/tmp/login.json"
	API_BASE="https://127.0.0.1:$PORTA_C" api "" POST auth/approle/login "$WORK/tmp/login.json"
	jq -r '.auth.client_token // empty' "$WORK/tmp/corpo" >"$WORK/tmp/token-C-$1"
}
espera B06a "pos-bootstrap: AppRole worker autentica com o secret_id entregue" 200 "$(login_c fiscal-worker "$WORK/credC/w.sid")"
espera B06b "pos-bootstrap: AppRole importador autentica" 200 "$(login_c fiscal-importador "$WORK/credC/i.sid")"
espera B06c "pos-bootstrap: AppRole backup autentica" 200 "$(login_c fiscal-backup "$WORK/credC/b.sid")"
espera B07 "pos-bootstrap: importador grava e worker le em hml-* (politicas instaladas)" "200/200" "$(API_BASE="https://127.0.0.1:$PORTA_C" api "$WORK/tmp/token-C-fiscal-importador" POST "$SEG" "$WORK/tmp/seg.json")/$(API_BASE="https://127.0.0.1:$PORTA_C" api "$WORK/tmp/token-C-fiscal-worker" GET "$SEG")"
espera B08 "modos: secret_ids 0400 e role_ids 0644" "400/400/400/644" "$(perm "$WORK/credC/w.sid")/$(perm "$WORK/credC/i.sid")/$(perm "$WORK/credC/b.sid")/$(perm "$WORK/etcC/fiscal-worker.role-id")"
set +e
printf 'CONFIRMO\n' | env -u TMUX -u STY ERP_FISCAL_HML_IGNORAR_ANCESTRAIS_TESTE=1 "${boot_env[@]}" script -qec "$BIN/erp-fiscal-hml-bootstrap.sh" /dev/null >"$WORK/tmp/boot2.out" 2>&1
c=$?
set -e
if [ "$c" -ne 0 ] && grep -q 'ja inicializado' "$WORK/tmp/boot2.out"; then teste B09 PASSOU "bootstrap nao se repete (cofre ja inicializado)"; else teste B09 FALHOU "bootstrap repetido" "c=$c"; fi
parar "$PORTA_C"

# ---------------------------------------------------------------------------------- resumo ---
total="$(wc -l <"$REGISTRO")"
passou="$(awk -F'\t' '$2=="PASSOU"' "$REGISTRO" | wc -l)"
falhou="$(awk -F'\t' '$2=="FALHOU"' "$REGISTRO" | wc -l)"
printf '== RESUMO: %s testes, %s PASSOU, %s FALHOU ==\n' "$total" "$passou" "$falhou"
printf 'segredo sintetico e todo o diretorio do ensaio serao destruidos ao final.\n'
[ "$falhou" -eq 0 ]
