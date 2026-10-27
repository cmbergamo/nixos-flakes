#!/usr/bin/env bash
# [FISCAL-I3-HML-INFRA-DSTK-SERVER-01] Backup CIFRADO do ambiente fiscal HML (executar como root,
# normalmente pelo erp-fiscal-hml-backup.timer):
#   * snapshot Raft do OpenBao (identidade AppRole "fiscal-backup", so le o snapshot);
#   * pg_dump do banco de homologacao;
#   * tar dos artefatos fiscais (XML, protocolos).
# Tudo e cifrado com age para DESTINATARIOS PUBLICOS (--recipients-file): o servidor NUNCA possui a
# chave de decifrar. O texto claro so existe em tmpfs (RuntimeDirectory) ou em pipe; sem
# destinatarios configurados o script FALHA (nunca grava texto claro).
#
# IMPORTANTE (honestidade): backup so e "operacional" depois de (1) o primeiro ciclo concluir E
# (2) a RESTAURACAO ser testada pelo dono da chave (evidencias/.../recuperacao.md §Restauracao).
# O snapshot do cofre protege o cofre; as chaves de recuperacao (unseal) NAO estao no backup.
#
# Uso: erp-fiscal-hml-backup [--sem-cofre] [--sem-postgres] [--sem-artefatos]
set -euo pipefail
umask 077

die() {
	printf 'ERRO: %s\n' "$*" >&2
	exit 1
}

[ "$(id -u)" -eq 0 ] || [ "${ERP_FISCAL_HML_BACKUP_TESTE:-0}" = "1" ] || die "executar como root (o mapeamento peer root -> erp_backup e do pg_ident)"
etc="${ERP_FISCAL_HML_ETC:-/etc/erp-fiscal-hml}"
destino="${ERP_FISCAL_HML_BACKUP_DIR:-/var/backups/erp-fiscal-hml}"
tmpfs="${RUNTIME_DIRECTORY:-/run/erp-fiscal-hml-backup}"
destinatarios="${ERP_FISCAL_HML_BACKUP_DESTINATARIOS:-$etc/backup-recipients.txt}"
sid_arquivo="${ERP_FISCAL_HML_SID_BACKUP:-$etc/credenciais/backup-secret-id}"
role_id_arquivo="${ERP_FISCAL_HML_ROLE_BACKUP:-$etc/fiscal-backup.role-id}"
artefatos="${FISCAL_ARTEFATOS_DIR:-/var/lib/erp-fiscal/artefatos}"
pg_socket="${ERP_FISCAL_HML_PG_SOCKET:-/run/postgresql}"
pg_porta="${ERP_FISCAL_HML_PG_PORTA:-5434}"
pg_banco="${ERP_FISCAL_HML_PG_BANCO:-erp_fiscal_hml}"
retencao_dias="${ERP_FISCAL_HML_BACKUP_RETENCAO_DIAS:-30}"
retencao_minimo="${ERP_FISCAL_HML_BACKUP_RETENCAO_MINIMO:-7}"
export BAO_ADDR="${BAO_ADDR:-https://127.0.0.1:8200}"
export BAO_CACERT="${BAO_CACERT:-$etc/openbao-ca.pem}"

com_cofre=1
com_pg=1
com_art=1
for a in "$@"; do
	case "$a" in
	--sem-cofre) com_cofre=0 ;;
	--sem-postgres) com_pg=0 ;;
	--sem-artefatos) com_art=0 ;;
	*) die "argumento desconhecido: $a" ;;
	esac
done

[[ "$retencao_dias" =~ ^[0-9]+$ && "$retencao_minimo" =~ ^[0-9]+$ ]] || die "retencao invalida"
[ -s "$destinatarios" ] || die "BACKUP_SEM_DESTINATARIO: $destinatarios ausente/vazio (chaves PUBLICAS age do dono); nada foi gravado em claro"
grep -qE '^age1[a-z0-9]+' "$destinatarios" || die "destinatarios sem chave publica age valida"

mkdir -p "$destino" "$tmpfs"
chmod 0700 "$destino" "$tmpfs"
carimbo="$(date +%Y%m%d_%H%M%S)"
token_arquivo="$tmpfs/token"
trap 'rm -rf "$tmpfs"/* 2>/dev/null || true' EXIT

# --- cofre: login com o AppRole de backup (secret_id por arquivo, nunca argv) ------------------
if [ "$com_cofre" -eq 1 ]; then
	jq -n --rawfile r "$role_id_arquivo" --rawfile s "$sid_arquivo" \
		'{role_id: ($r|rtrimstr("\n")), secret_id: ($s|rtrimstr("\n"))}' >"$tmpfs/login.json"
	curl -sS --fail --cacert "$BAO_CACERT" -X POST -H 'Content-Type: application/json' \
		--data-binary "@$tmpfs/login.json" "$BAO_ADDR/v1/auth/approle/login" | jq -r .auth.client_token >"$token_arquivo"
	rm -f "$tmpfs/login.json"
	[ -s "$token_arquivo" ] || die "login do AppRole de backup falhou (cofre selado? ver erp-fiscal-hml-status)"
	printf 'X-Vault-Token: %s\n' "$(cat "$token_arquivo")" >"$tmpfs/hdr"
	curl -sS --fail --cacert "$BAO_CACERT" -H "@$tmpfs/hdr" -o "$tmpfs/cofre.snap" "$BAO_ADDR/v1/sys/storage/raft/snapshot"
	age -R "$destinatarios" -o "$destino/${carimbo}_openbao.snap.age" "$tmpfs/cofre.snap"
	rm -f "$tmpfs/cofre.snap"
	# revoga o token de backup (vida curta, uso unico)
	curl -sS --cacert "$BAO_CACERT" -H "@$tmpfs/hdr" -X POST "$BAO_ADDR/v1/auth/token/revoke-self" >/dev/null || true
	rm -f "$tmpfs/hdr" "$token_arquivo"
fi

# --- banco de homologacao ---------------------------------------------------------------------
if [ "$com_pg" -eq 1 ]; then
	# peer por socket Unix: o usuario do SO (root) e mapeado pelo pg_ident ao papel erp_backup
	# (somente leitura, pg_read_all_data) — sem senha e sem trocar de usuario.
	pg_dump -Fc -U erp_backup -h "$pg_socket" -p "$pg_porta" -d "$pg_banco" |
		age -R "$destinatarios" -o "$destino/${carimbo}_postgres.dump.age"
fi

# --- artefatos fiscais (XML autorizado, protocolos) -------------------------------------------
if [ "$com_art" -eq 1 ] && [ -d "$artefatos" ]; then
	tar -C "$artefatos" -cf - . | age -R "$destinatarios" -o "$destino/${carimbo}_artefatos.tar.age"
fi

# --- retencao: remove os mais antigos que N dias, preservando SEMPRE os N mais recentes por tipo ---
for tipo in openbao.snap postgres.dump artefatos.tar; do
	mapfile -t todos < <(find "$destino" -maxdepth 1 -name "*_${tipo}.age" -printf '%T@ %p\n' | sort -rn | cut -d' ' -f2-)
	idx=0
	for f in "${todos[@]:-}"; do
		[ -n "$f" ] || continue
		idx=$((idx + 1))
		if [ "$idx" -gt "$retencao_minimo" ] && [ -n "$(find "$f" -mtime +"$retencao_dias" -print)" ]; then
			rm -f -- "$f"
		fi
	done
done

# --- registro (sem segredo): para o erp-fiscal-hml-status ------------------------------------
registro="$(jq -n --arg quando "$(date +%Y-%m-%dT%H:%M:%S)" --arg c "$carimbo" \
	--argjson arquivos "$(find "$destino" -maxdepth 1 -name "${carimbo}_*.age" -printf '%f %s\n' | jq -R 'split(" ") | {nome: .[0], bytes: (.[1]|tonumber)}' | jq -s .)" \
	'{concluido_em: $quando, ciclo: $c, arquivos: $arquivos}')"
printf '%s\n' "$registro" >"$destino/ultimo-backup.json"
install -m 0644 "$destino/ultimo-backup.json" "$etc/ultimo-backup.json" 2>/dev/null || true
printf 'OK: backup %s concluido em %s\n' "$carimbo" "$destino"
