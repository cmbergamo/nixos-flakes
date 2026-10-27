#!/usr/bin/env bash
# [FISCAL-I3-HML-INFRA-DSTK-SERVER-01] PKI privada do cofre OpenBao (HML): uma CA propria e um
# certificado de servidor com SAN IP:127.0.0.1 e IP:::1 (D31: nunca "localhost"). O cliente Rust
# (shared::openbao) confia SO nessa CA, via OPENBAO_CACERT — nunca tls_skip_verify. A chave da CA
# fica num diretorio do administrador (0700) e NUNCA no diretorio do servico; o servico recebe
# apenas a chave do certificado do servidor. A CA publica (sem chave) vai para --ca-publica.
#
# Uso:
#   erp-fiscal-hml-tls --ca-dir DIR --tls-dir DIR --ca-publica ARQ [--dono-tls USUARIO:GRUPO]
#                      [--renovar-servidor]
set -euo pipefail
umask 077

die() {
	printf 'ERRO: %s\n' "$*" >&2
	exit 1
}

ca_dir=""
tls_dir=""
ca_publica=""
dono_tls=""
renovar=0
while [ "$#" -gt 0 ]; do
	case "$1" in
	--ca-dir) ca_dir="${2:-}"; shift 2 ;;
	--tls-dir) tls_dir="${2:-}"; shift 2 ;;
	--ca-publica) ca_publica="${2:-}"; shift 2 ;;
	--dono-tls) dono_tls="${2:-}"; shift 2 ;;
	--renovar-servidor) renovar=1; shift ;;
	*) die "argumento desconhecido: $1" ;;
	esac
done

caminho_ok='^/[A-Za-z0-9_./-]+$'
for v in "$ca_dir" "$tls_dir" "$ca_publica"; do
	[[ "$v" =~ $caminho_ok ]] || die "uso: --ca-dir, --tls-dir e --ca-publica sao obrigatorios (caminhos absolutos simples)"
done
if [ -n "$dono_tls" ]; then
	[[ "$dono_tls" =~ ^[a-z_][a-z0-9_-]*:[a-z_][a-z0-9_-]*$ ]] || die "--dono-tls invalido (use usuario:grupo)"
fi

dias_ca=3650
dias_servidor=730

mkdir -p "$ca_dir" "$tls_dir"
chmod 0700 "$ca_dir" "$tls_dir"

trabalho="$(mktemp -d "$tls_dir/.tls-trabalho.XXXXXX")"
trap 'rm -rf "$trabalho"' EXIT

if [ ! -f "$ca_dir/ca.key" ] || [ ! -f "$ca_dir/ca.crt" ]; then
	[ -e "$ca_dir/ca.key" ] || [ -e "$ca_dir/ca.crt" ] && die "CA incompleta em $ca_dir (so um dos arquivos existe) — resolva manualmente"
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -noenc \
		-keyout "$ca_dir/ca.key" -out "$ca_dir/ca.crt" -days "$dias_ca" \
		-subj "/O=ERP Distak/OU=Fiscal HML/CN=ERP Distak Fiscal HML - CA do cofre" \
		-addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
		-addext "keyUsage=critical,keyCertSign,cRLSign" \
		-addext "subjectKeyIdentifier=hash" 2>/dev/null
	chmod 0400 "$ca_dir/ca.key"
	chmod 0444 "$ca_dir/ca.crt"
	printf 'CA criada em %s\n' "$ca_dir"
elif [ "$renovar" -eq 0 ] && [ -f "$tls_dir/server.crt" ]; then
	die "certificado do servidor ja existe em $tls_dir (use --renovar-servidor para reemitir)"
fi

cat >"$trabalho/ext.cnf" <<'EOF'
basicConstraints = critical,CA:FALSE
keyUsage = critical,digitalSignature
extendedKeyUsage = serverAuth
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid,issuer
subjectAltName = IP:127.0.0.1,IP:::1
EOF

openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -noenc \
	-keyout "$trabalho/server.key" -out "$trabalho/server.csr" \
	-subj "/O=ERP Distak/OU=Fiscal HML/CN=openbao-fiscal-hml" 2>/dev/null
openssl x509 -req -in "$trabalho/server.csr" -CA "$ca_dir/ca.crt" -CAkey "$ca_dir/ca.key" \
	-CAcreateserial -CAserial "$trabalho/ca.srl" -out "$trabalho/server.crt" \
	-days "$dias_servidor" -extfile "$trabalho/ext.cnf" 2>/dev/null

# Verificacoes antes de publicar: cadeia valida e SAN correto (o cliente exige IP SAN).
openssl verify -CAfile "$ca_dir/ca.crt" "$trabalho/server.crt" >/dev/null ||
	die "certificado do servidor nao valida contra a CA"
openssl x509 -in "$trabalho/server.crt" -noout -ext subjectAltName | grep -q 'IP Address:127.0.0.1' ||
	die "SAN IP:127.0.0.1 ausente no certificado do servidor"

install -m 0444 "$trabalho/server.crt" "$tls_dir/server.crt"
install -m 0400 "$trabalho/server.key" "$tls_dir/server.key"
install -m 0644 "$ca_dir/ca.crt" "$ca_publica"
if [ -n "$dono_tls" ]; then
	chown "$dono_tls" "$tls_dir" "$tls_dir/server.crt" "$tls_dir/server.key"
fi

printf 'servidor_valido_ate=%s\n' "$(openssl x509 -in "$tls_dir/server.crt" -noout -enddate | cut -d= -f2)"
printf 'ca_sha256=%s\n' "$(openssl x509 -in "$ca_publica" -noout -fingerprint -sha256 | cut -d= -f2)"
printf 'servidor_sha256=%s\n' "$(openssl x509 -in "$tls_dir/server.crt" -noout -fingerprint -sha256 | cut -d= -f2)"
printf 'OK: PKI do cofre pronta (CA publica em %s).\n' "$ca_publica"
