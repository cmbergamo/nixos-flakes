#!/usr/bin/env bash
# [FISCAL-I3-HML-INFRA-DSTK-SERVER-01] Diagnostico SOMENTE LEITURA da infraestrutura fiscal HML.
# Qualquer usuario pode executar; o que exigir permissao que o chamador nao tem aparece como
# "N/A" (nunca como falso OK). Nunca imprime segredo, token, secret_id ou conteudo de segredo.
#
# Saida: uma linha por verificacao: [OK] | [ATENCAO] | [FALHA] | [N/A]. Exit 1 se houver [FALHA].
#
# Uso: erp-fiscal-hml-status
set -uo pipefail

etc="${ERP_FISCAL_HML_ETC:-/etc/erp-fiscal-hml}"
export BAO_ADDR="${BAO_ADDR:-https://127.0.0.1:8200}"
export BAO_CACERT="${BAO_CACERT:-$etc/openbao-ca.pem}"
release="${ERP_FISCAL_HML_RELEASE:-/opt/erp-fiscal-hml/current}"
artefatos="${FISCAL_ARTEFATOS_DIR:-/var/lib/erp-fiscal/artefatos}"
pg_socket="${ERP_FISCAL_HML_PG_SOCKET:-/run/postgresql}"
pg_porta="${ERP_FISCAL_HML_PG_PORTA:-5434}"
pg_banco="${ERP_FISCAL_HML_PG_BANCO:-erp_fiscal_hml}"
sefaz_host="nfe-homologacao.svrs.rs.gov.br"

falhas=0
linha() { # nivel item detalhe
	printf '[%s] %s%s\n' "$1" "$2" "${3:+ — $3}"
	[ "$1" != "FALHA" ] || falhas=$((falhas + 1))
}

unidade() { # unidade
	systemctl show "$1" -p ActiveState -p SubState -p UnitFileState -p NRestarts --value 2>/dev/null | paste -sd' ' -
}

printf '== erp-fiscal-hml-status — %s (host %s) ==\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$(hostname)"

# --- OpenBao ----------------------------------------------------------------------------------
estado_bao="$(unidade openbao.service)"
if [ "$(systemctl is-active openbao.service 2>/dev/null)" = "active" ]; then
	linha OK "openbao.service" "$estado_bao"
else
	linha FALHA "openbao.service" "${estado_bao:-nao instalado/inativo}"
fi

st="$(bao status -format=json 2>/dev/null || true)"
if [ -z "$st" ]; then
	linha FALHA "cofre inacessivel" "$BAO_ADDR (servico parado, CA em $BAO_CACERT ausente ou TLS invalido)"
else
	if [ "$(jq -r .initialized <<<"$st")" != "true" ]; then
		linha FALHA "cofre NAO inicializado" "administrador deve rodar erp-fiscal-hml-bootstrap"
	elif [ "$(jq -r .sealed <<<"$st")" = "true" ]; then
		linha FALHA "cofre SELADO" "apos reinicio e normal; destravar com erp-fiscal-hml-unseal (3 chaves)"
	else
		codigo="$(curl -s -o /dev/null -w '%{http_code}' --cacert "$BAO_CACERT" "$BAO_ADDR/v1/sys/health" 2>/dev/null || true)"
		if [ "$codigo" = "200" ]; then
			linha OK "cofre destravado e ATIVO" "versao $(jq -r .version <<<"$st"), armazenamento $(jq -r .storage_type <<<"$st")"
		else
			linha ATENCAO "cofre destravado mas sys/health=$codigo" "pode estar em transicao (standby); repita em instantes"
		fi
	fi
fi

if [ -r "$BAO_CACERT" ] && [ -n "$st" ]; then
	fim="$(openssl s_client -connect "${BAO_ADDR#https://}" -CAfile "$BAO_CACERT" -verify_return_error -verify_ip 127.0.0.1 </dev/null 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)"
	if [ -n "$fim" ]; then
		dias=$((($(date -d "$fim" +%s) - $(date +%s)) / 86400))
		if [ "$dias" -lt 0 ]; then linha FALHA "certificado TLS do cofre EXPIRADO" "$fim"
		elif [ "$dias" -lt 30 ]; then linha ATENCAO "certificado TLS do cofre expira em $dias dias" "renovar: erp-fiscal-hml-tls --renovar-servidor"
		else linha OK "certificado TLS do cofre valido" "expira em $dias dias ($fim)"
		fi
	else
		linha FALHA "TLS do cofre" "cadeia/SAN nao verificados com a CA $BAO_CACERT"
	fi
fi

# --- PostgreSQL de homologacao ---------------------------------------------------------------
if pg_isready -q -h "$pg_socket" -p "$pg_porta" 2>/dev/null; then
	linha OK "PostgreSQL de homologacao aceita conexoes" "socket $pg_socket porta $pg_porta"
	head_esperado=""
	[ -r "$release/build-info.json" ] && head_esperado="$(jq -r '.migration_head // empty' "$release/build-info.json" 2>/dev/null)"
	versao="$(psql -h "$pg_socket" -p "$pg_porta" -d "$pg_banco" -Atqc 'SELECT max(version) FROM _sqlx_migrations' 2>/dev/null || true)"
	if [ -z "$versao" ]; then
		linha N/A "versao do schema" "sem permissao de leitura neste usuario (use fiscal-a1 ou erp-fiscal)"
	elif [ -n "$head_esperado" ] && [ "$versao" != "$head_esperado" ]; then
		linha FALHA "schema divergente" "banco=$versao esperado_pelo_build=$head_esperado"
	else
		linha OK "schema do banco" "versao $versao${head_esperado:+ (= build)}"
	fi
else
	linha FALHA "PostgreSQL de homologacao" "sem resposta em $pg_socket:$pg_porta"
fi

# --- worker -----------------------------------------------------------------------------------
estado_w="$(unidade erp-fiscal-hml-worker.service)"
case "$(systemctl is-active erp-fiscal-hml-worker.service 2>/dev/null)" in
active) linha OK "erp-fiscal-hml-worker.service ativo" "$estado_w" ;;
*) linha ATENCAO "erp-fiscal-hml-worker.service nao esta ativo" "${estado_w:-nao instalado} — por desenho so inicia depois do A1 importado e verificado" ;;
esac

# --- binarios (rastreabilidade do build) ------------------------------------------------------
if [ -r "$release/build-info.json" ]; then
	ok=1
	for b in $(jq -r '.binarios | keys[]' "$release/build-info.json"); do
		esperado="$(jq -r --arg b "$b" '.binarios[$b] // empty' "$release/build-info.json")"
		atual="$(sha256sum "$release/bin/$b" 2>/dev/null | cut -d' ' -f1)"
		[ -n "$esperado" ] && [ "$esperado" = "$atual" ] || ok=0
	done
	if [ "$ok" = 1 ] && [ "$(jq -r '.ambiente // "desconhecido"' "$release/build-info.json")" != "fresco" ]; then
		linha ATENCAO "binarios de ENSAIO instalados (build reutilizado/desconhecido)" "reinstale um build FRESCO antes de qualquer A1 real"
	elif [ "$ok" = 1 ]; then
		linha OK "binarios fiscais integros" "commit $(jq -r .commit "$release/build-info.json" | cut -c1-12), compilado em $(jq -r .compilado_em "$release/build-info.json")"
	else
		linha FALHA "binarios fiscais divergem do build-info.json" "$release"
	fi
else
	linha FALHA "binarios fiscais nao instalados" "$release/build-info.json ausente (erp-fiscal-hml-compilar + instalacao pelo administrador)"
fi

# --- artefatos --------------------------------------------------------------------------------
if [ -d "$artefatos" ]; then
	modo="$(stat -c '%a' "$artefatos")"
	livre="$(df -h --output=avail "$artefatos" | tail -1 | tr -d ' ')"
	case "$modo" in
	700 | 750) linha OK "diretorio de artefatos" "$artefatos modo $modo dono $(stat -c %U "$artefatos"), livre $livre" ;;
	*) linha FALHA "diretorio de artefatos com permissao frouxa" "$artefatos modo $modo (esperado 700/750)" ;;
	esac
else
	linha FALHA "diretorio de artefatos ausente" "$artefatos"
fi

# --- SEFAZ HML (so alcance TCP+TLS; nenhum certificado cliente, nenhum dado enviado) ----------
if timeout 15 openssl s_client -connect "$sefaz_host:443" -servername "$sefaz_host" </dev/null 2>/dev/null | grep -q 'Protocol *: TLSv\|New, TLSv'; then
	linha OK "SEFAZ homologacao alcancavel (TCP+TLS)" "$sefaz_host:443 — o mTLS com o A1 e provado pelo erp-fiscal-hml-verificar-a1"
else
	linha FALHA "SEFAZ homologacao inalcancavel" "$sefaz_host:443"
fi

# --- backup -----------------------------------------------------------------------------------
if [ -r "$etc/ultimo-backup.json" ]; then
	quando="$(jq -r .concluido_em "$etc/ultimo-backup.json")"
	idade=$((($(date +%s) - $(date -d "$quando" +%s)) / 3600))
	if [ "$idade" -le 30 ]; then linha OK "ultimo backup" "$quando (${idade} h)"
	else linha ATENCAO "ultimo backup antigo" "$quando (${idade} h)"
	fi
else
	linha ATENCAO "nenhum backup registrado" "backup NAO e operacional ate o primeiro ciclo e a restauracao testada"
fi

printf '== %s verificacao(oes) com FALHA ==\n' "$falhas"
[ "$falhas" -eq 0 ]
