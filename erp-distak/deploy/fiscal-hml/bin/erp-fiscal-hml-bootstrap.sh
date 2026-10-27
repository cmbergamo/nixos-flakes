#!/usr/bin/env bash
# [FISCAL-I3-HML-INFRA-DSTK-SERVER-01] Bootstrap UNICO do cofre (executar como root, uma vez, com o
# openbao.service ativo, selado e NAO inicializado).
#
#   1. bao operator init (5 chaves de recuperacao, limiar 3) -> JSON so em tmpfs (/run), 0600;
#   2. EXIBE as chaves UMA vez no terminal do administrador e exige confirmacao — ANTES de
#      qualquer outro passo (se algo falhar adiante, as chaves ja estao com o operador);
#   3. destrava com 3 chaves (corpo JSON por pipe para a API, nunca argv), provisiona (erp-fiscal-hml-provisionar);
#   4. REVOGA o root token (nenhum root token persiste) e apaga o JSON do tmpfs.
#
# As chaves de recuperacao NUNCA vao para Git, Nix store, log, variavel persistente ou arquivo no
# disco. Distribua em custodias DIFERENTES (limiar 3 de 5; ver evidencias/.../recuperacao.md).
# Apos CADA reinicio do servidor o cofre volta SELADO: erp-fiscal-hml-unseal (3 chaves).
set -euo pipefail
umask 077

die() {
	printf 'ERRO: %s\n' "$*" >&2
	exit 1
}

# ERP_FISCAL_HML_BOOTSTRAP_TESTE=1 existe SO para o ensaio (sem root, sem usuarios do host)
[ "$(id -u)" -eq 0 ] || [ "${ERP_FISCAL_HML_BOOTSTRAP_TESTE:-0}" = "1" ] || die "execute como root"
[ -t 1 ] && [ -t 0 ] || die "execute em um terminal interativo (as chaves sao exibidas uma unica vez)"
# Multiplexadores guardam o historico (scrollback) do painel: as chaves ficariam legiveis depois.
# Sob "sudo" o env_reset remove TMUX/STY, entao a deteccao olha tambem a CADEIA DE PROCESSOS ancestrais.
em_multiplexador() {
	local pid="$PPID" nome
	[ -z "${TMUX:-}" ] && [ -z "${STY:-}" ] || return 0
	# SO ensaio: ignora a varredura de ancestrais (a sessao de teste pode estar dentro de tmux)
	[ "${ERP_FISCAL_HML_IGNORAR_ANCESTRAIS_TESTE:-0}" = "1" ] && return 1
	while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
		nome="$(cat "/proc/$pid/comm" 2>/dev/null || true)"
		case "$nome" in tmux* | screen* | byobu*) return 0 ;; esac
		pid="$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null || true)"
	done
	return 1
}
if em_multiplexador; then
	die "dentro de tmux/screen o historico do painel guardaria as chaves de recuperacao; use uma sessao SSH simples (sem multiplexador)"
fi

etc="${ERP_FISCAL_HML_ETC:-/etc/erp-fiscal-hml}"
export BAO_ADDR="${BAO_ADDR:-https://127.0.0.1:8200}"
export BAO_CACERT="${BAO_CACERT:-$etc/openbao-ca.pem}"
politicas="${ERP_FISCAL_HML_POLITICAS:-$etc/politicas}"
sid_worker="${ERP_FISCAL_HML_SID_WORKER:-/var/lib/erp-fiscal/credenciais/openbao-secret-id}"
sid_importador="${ERP_FISCAL_HML_SID_IMPORTADOR:-/var/lib/erp-fiscal-a1/credenciais/openbao-secret-id}"
sid_backup="${ERP_FISCAL_HML_SID_BACKUP:-$etc/credenciais/backup-secret-id}"
sid_recuperacao="${ERP_FISCAL_HML_SID_RECUPERACAO:-$etc/credenciais/recuperacao-secret-id}"
dono_worker="${ERP_FISCAL_HML_DONO_WORKER-erp-fiscal:erp-fiscal}"
dono_importador="${ERP_FISCAL_HML_DONO_IMPORTADOR-fiscal-a1:fiscal-a1}"

status="$(bao status -format=json 2>/dev/null || true)"
[ -n "$status" ] || die "OpenBao inacessivel em $BAO_ADDR (servico ativo? CA em $BAO_CACERT?)"
if [ "$(jq -r .initialized <<<"$status")" = "true" ]; then
	die "OpenBao ja inicializado — bootstrap nao se repete (ver recuperacao.md para generate-root / rotacao)"
fi

trabalho="$(mktemp -d "${ERP_FISCAL_HML_BOOTSTRAP_TMP:-/run}/erp-fiscal-hml-bootstrap.XXXXXX")"
init_json="$trabalho/init.json"
bao operator init -key-shares=5 -key-threshold=3 -format=json >"$init_json"
printf 'cofre inicializado.\n\n'

cat <<'EOF'
================================ CHAVES DE RECUPERACAO ================================
Estas 5 chaves sao exibidas UMA UNICA VEZ. Qualquer 3 destravam o cofre; sem 3 delas o cofre
(e o A1 dentro dele) e IRRECUPERAVEL. Copie cada uma para uma custodia DIFERENTE (gerenciador de
senhas do dono, cofre fisico, segundo administrador). NAO guarde todas no mesmo lugar, NAO as
envie por chat/e-mail, NAO as grave neste servidor.
=======================================================================================
EOF
jq -r '.unseal_keys_b64 | to_entries[] | "Chave \(.key + 1)/5: \(.value)"' "$init_json"
printf '\nDigite CONFIRMO depois de guardar as 5 chaves: '
read -r resposta </dev/tty
[ "$resposta" = "CONFIRMO" ] || die "nao confirmado — JSON mantido em $init_json (apague-o depois de guardar as chaves!)"
printf '\033c\033[3J' # limpa a tela e o scrollback do terminal (xterm-compativel); limpe tambem o do seu emulador

# Destrava com 3 chaves. O "bao operator unseal" so aceita a chave por TTY ou argv; aqui usamos a
# API (PUT /v1/sys/unseal) com o corpo JSON vindo por pipe — a chave nunca aparece em argv.
for i in 0 1 2; do
	jq -r ".unseal_keys_b64[$i]" "$init_json" | jq -Rn '{key: input}' |
		curl -sS --fail --cacert "$BAO_CACERT" -X PUT -H 'Content-Type: application/json' \
			--data-binary @- "$BAO_ADDR/v1/sys/unseal" >/dev/null
done
for _ in $(seq 1 30); do
	if [ "$(bao status -format=json | jq -r .sealed)" = "false" ] && BAO_TOKEN="$(jq -r .root_token "$init_json")" bao token lookup >/dev/null 2>&1; then
		break
	fi
	sleep 1
done

BAO_TOKEN="$(jq -r .root_token "$init_json")"
export BAO_TOKEN
bao token lookup >/dev/null || die "cofre nao ficou ativo apos o unseal — JSON mantido em $init_json"

erp-fiscal-hml-provisionar \
	--politicas "$politicas" --role-ids-dir "$etc" \
	--secret-id-worker "$sid_worker" --dono-worker "$dono_worker" \
	--secret-id-importador "$sid_importador" --dono-importador "$dono_importador" \
	--secret-id-backup "$sid_backup" --secret-id-recuperacao "$sid_recuperacao"

# Nenhum root token persistente: revoga e prova que morreu.
bao token revoke -self >/dev/null
if BAO_TOKEN="$BAO_TOKEN" bao token lookup >/dev/null 2>&1; then
	die "root token ainda valido apos revogacao"
fi
unset BAO_TOKEN
rm -rf "$trabalho"
printf 'root token revogado; JSON temporario removido.\n'
printf 'OK: bootstrap concluido. Proximo: erp-fiscal-hml-status; depois (A1) erp-fiscal-hml-importar-a1.\n'
