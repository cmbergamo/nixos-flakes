#!/usr/bin/env bash
# [FISCAL-I3-HML-INFRA-DSTK-SERVER-01] Provisiona o OpenBao ja inicializado e destravado:
# confere o dispositivo de auditoria declarativo, KV-v2 em secret/, politicas de menor privilegio e
# os tres AppRoles (worker, importador, backup). Idempotente. Nunca imprime secret_id/token; os secret_ids vao
# direto do stdout do "bao" para arquivos 0400 (nunca argv, nunca variavel exportada).
#
# Ambiente exigido (herdado pelo "bao"): BAO_ADDR, BAO_CACERT e BAO_TOKEN (token de administracao,
# normalmente o root token do bootstrap — que o chamador revoga logo depois).
#
# Uso:
#   erp-fiscal-hml-provisionar --politicas DIR --role-ids-dir DIR \
#       --secret-id-worker ARQ --secret-id-importador ARQ --secret-id-backup ARQ --secret-id-recuperacao ARQ \
#       [--dono-worker U:G] [--dono-importador U:G] [--dono-backup U:G] [--dono-recuperacao U:G] [--rotacionar]
set -euo pipefail
umask 077

die() {
	printf 'ERRO: %s\n' "$*" >&2
	exit 1
}

politicas=""
role_ids_dir=""
dest_worker=""
dest_importador=""
dest_backup=""
dest_recuperacao=""
dono_recuperacao=""
dono_worker=""
dono_importador=""
dono_backup=""
rotacionar=0
while [ "$#" -gt 0 ]; do
	case "$1" in
	--politicas) politicas="${2:-}"; shift 2 ;;
	--role-ids-dir) role_ids_dir="${2:-}"; shift 2 ;;
	--secret-id-worker) dest_worker="${2:-}"; shift 2 ;;
	--secret-id-importador) dest_importador="${2:-}"; shift 2 ;;
	--secret-id-backup) dest_backup="${2:-}"; shift 2 ;;
	--secret-id-recuperacao) dest_recuperacao="${2:-}"; shift 2 ;;
	--dono-recuperacao) dono_recuperacao="${2:-}"; shift 2 ;;
	--dono-worker) dono_worker="${2:-}"; shift 2 ;;
	--dono-importador) dono_importador="${2:-}"; shift 2 ;;
	--dono-backup) dono_backup="${2:-}"; shift 2 ;;
	--rotacionar) rotacionar=1; shift ;;
	*) die "argumento desconhecido: $1" ;;
	esac
done

caminho_ok='^/[A-Za-z0-9_./-]+$'
for v in "$politicas" "$role_ids_dir" "$dest_worker" "$dest_importador" "$dest_backup" "$dest_recuperacao"; do
	[[ "$v" =~ $caminho_ok ]] || die "todos os caminhos sao obrigatorios e absolutos simples (veja o cabecalho)"
done
for v in "$dono_worker" "$dono_importador" "$dono_backup" "$dono_recuperacao"; do
	[ -z "$v" ] || [[ "$v" =~ ^[a-z_][a-z0-9_-]*:[a-z_][a-z0-9_-]*$ ]] || die "dono invalido (use usuario:grupo)"
done
: "${BAO_ADDR:?BAO_ADDR obrigatorio}"
: "${BAO_CACERT:?BAO_CACERT obrigatorio}"
: "${BAO_TOKEN:?BAO_TOKEN obrigatorio (token de administracao)}"
for p in fiscal-worker fiscal-importador fiscal-backup fiscal-recuperacao; do
	[ -f "$politicas/$p.hcl" ] || die "politica ausente: $politicas/$p.hcl"
done

# --- auditoria: declarativa no config (openbao.hcl); aqui so se EXIGE que esteja ativa --------
bao audit list -format=json | jq -e 'has("arquivo/")' >/dev/null ||
	die "dispositivo de auditoria 'arquivo' ausente — declare o bloco audit no openbao.hcl e reinicie/SIGHUP"
printf 'auditoria: dispositivo declarativo "arquivo" ativo\n'

# --- KV-v2 em secret/ -------------------------------------------------------------------------
if ! bao secrets list -format=json | jq -e 'has("secret/")' >/dev/null; then
	bao secrets enable -path=secret -version=2 kv >/dev/null
	printf 'kv: secret/ (v2) habilitado\n'
else
	[ "$(bao secrets list -format=json | jq -r '.["secret/"].options.version // "1"')" = "2" ] ||
		die "secret/ existe mas nao e KV v2"
	printf 'kv: secret/ (v2) ja habilitado\n'
fi

# --- politicas --------------------------------------------------------------------------------
for p in fiscal-worker fiscal-importador fiscal-backup fiscal-recuperacao; do
	bao policy write "$p" "$politicas/$p.hcl" >/dev/null
	printf 'politica: %s gravada\n' "$p"
done

# --- AppRole ----------------------------------------------------------------------------------
if ! bao auth list -format=json | jq -e 'has("approle/")' >/dev/null; then
	bao auth enable approle >/dev/null
	printf 'auth: approle habilitado\n'
fi

mkdir -p "$role_ids_dir"

cria_role() {
	local nome="$1" politica="$2"
	# Tokens curtos (o cliente reautentica sozinho), presos ao loopback; secret_id sem expiracao e
	# sem limite de usos para o servico permanente sobreviver a reinicios — rotacao manual
	# documentada (--rotacionar), com destruicao dos secret_ids anteriores.
	bao write "auth/approle/role/$nome" \
		token_policies="$politica" token_ttl=15m token_max_ttl=1h token_num_uses=0 \
		secret_id_ttl=0 secret_id_num_uses=0 \
		token_bound_cidrs="127.0.0.1/32,::1/128" secret_id_bound_cidrs="127.0.0.1/32,::1/128" >/dev/null
	bao read -field=role_id "auth/approle/role/$nome/role-id" >"$role_ids_dir/$nome.role-id"
	chmod 0644 "$role_ids_dir/$nome.role-id"
	printf 'approle: %s -> politica %s (role_id em %s)\n' "$nome" "$politica" "$role_ids_dir/$nome.role-id"
}

entrega_secret_id() {
	local nome="$1" destino="$2" dono="$3" tmp antigos
	if [ -e "$destino" ] && [ "$rotacionar" -eq 0 ]; then
		printf 'secret_id: %s mantido (use --rotacionar para emitir outro)\n' "$nome"
		return 0
	fi
	antigos="$(bao list -format=json "auth/approle/role/$nome/secret-id" 2>/dev/null | jq -r '.[]?' || true)"
	tmp="$(mktemp "$destino.XXXXXX")"
	bao write -f -field=secret_id "auth/approle/role/$nome/secret-id" >"$tmp"
	[ -s "$tmp" ] || { rm -f "$tmp"; die "secret_id vazio para $nome"; }
	chmod 0400 "$tmp"
	[ -z "$dono" ] || chown "$dono" "$tmp"
	mv -f "$tmp" "$destino"
	# Rotacao: destroi os secret_ids anteriores (accessors listados ANTES da emissao nova).
	local acessor
	for acessor in $antigos; do
		bao write "auth/approle/role/$nome/secret-id-accessor/destroy" secret_id_accessor="$acessor" >/dev/null
	done
	printf 'secret_id: %s emitido em %s (modo 0400)\n' "$nome" "$destino"
}

cria_role fiscal-worker fiscal-worker
cria_role fiscal-importador fiscal-importador
cria_role fiscal-backup fiscal-backup
cria_role fiscal-recuperacao fiscal-recuperacao
entrega_secret_id fiscal-worker "$dest_worker" "$dono_worker"
entrega_secret_id fiscal-importador "$dest_importador" "$dono_importador"
entrega_secret_id fiscal-backup "$dest_backup" "$dono_backup"
entrega_secret_id fiscal-recuperacao "$dest_recuperacao" "$dono_recuperacao"
printf 'OK: provisionamento concluido.\n'
