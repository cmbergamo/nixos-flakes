#!/usr/bin/env bash
# [FISCAL-I3-HML-INFRA-DSTK-SERVER-01] PROVA do isolamento entre o executor de Gates e os servicos
# fiscais, DEPOIS que o modulo NixOS estiver aplicado. Condicao do dono para importar o A1 real:
# so se esta verificacao passar (e a parte --root conferir o inventario).
#
# Modo padrao (executar como o usuario DOS GATES, p.ex. rmbergamo; nao precisa de root): tenta, como
# faria um candidato malicioso, ler segredos/chaves/credenciais, falar com o cofre e o banco, espiar
# processos, usar sudo, usar sockets de conteiner e entrar por SSH como o operador do A1 com CADA
# chave privada legivel por este usuario. Tudo deve ser NEGADO. "Caminho inexistente" conta como
# FALHA (modulo nao aplicado), nunca como sucesso.
# Modo --root (administrador): inventario de dono/modo/ACL, grupos privilegiados, exposicao de portas.
#
# Uso: erp-fiscal-hml-verificar-isolamento [--root]
set -uo pipefail
export LC_ALL=C

falhas=0
res() { # PASSOU|FALHOU descricao [detalhe]
	printf '[%s] %s%s\n' "$1" "$2" "${3:+ ($3)}"
	[ "$1" = PASSOU ] || falhas=$((falhas + 1))
}

modo_root=0
[ "${1:-}" = "--root" ] && modo_root=1

if [ "$modo_root" -eq 1 ]; then
	[ "$(id -u)" -eq 0 ] || { echo "ERRO: --root exige root" >&2; exit 2; }
	# --- inventario: dono/modo esperados --------------------------------------------------------
	confere() { # caminho dono:grupo modo
		local atual
		atual="$(stat -c '%U:%G %a' "$1" 2>/dev/null || echo ausente)"
		if [ "$atual" = "$2 $3" ]; then res PASSOU "$1 -> $2 $3"; else res FALHOU "$1" "esperado '$2 $3', atual '$atual'"; fi
	}
	confere /var/lib/openbao openbao:openbao 700
	confere /var/lib/openbao/tls openbao:openbao 700
	confere /var/lib/openbao/tls/server.key openbao:openbao 400
	confere /var/log/openbao openbao:openbao 750
	confere /var/lib/erp-fiscal-hml-pki root:root 700
	confere /etc/erp-fiscal-hml/credenciais root:root 700
	confere /var/lib/erp-fiscal erp-fiscal:erp-fiscal 750
	confere /var/lib/erp-fiscal/credenciais erp-fiscal:erp-fiscal 700
	confere /var/lib/erp-fiscal/artefatos erp-fiscal:erp-fiscal 750
	confere /var/lib/erp-fiscal/tmp erp-fiscal:erp-fiscal 700
	confere /var/lib/erp-fiscal-a1 fiscal-a1:fiscal-a1 700
	confere /var/lib/erp-fiscal-a1/recepcao fiscal-a1:fiscal-a1 700
	confere /var/lib/erp-fiscal-a1/credenciais fiscal-a1:fiscal-a1 700
	confere /var/lib/erp-fiscal-api/credenciais erp-fiscal-api:erp-fiscal-api 700
	confere /var/backups/erp-fiscal-hml root:root 700
	# --- ACL herdada/estendida e permissao para "outros" --------------------------------------
	for d in /var/lib/openbao /var/lib/erp-fiscal /var/lib/erp-fiscal-a1 /var/lib/erp-fiscal-api /var/lib/erp-fiscal-hml-pki /var/backups/erp-fiscal-hml /etc/erp-fiscal-hml/credenciais; do
		extra="$(getfacl -p -R "$d" 2>/dev/null | grep -E '^(user|group):[^:]' | grep -vE '^(user|group)::' || true)"
		if [ -z "$extra" ]; then res PASSOU "sem ACL estendida em $d"; else res FALHOU "ACL estendida em $d" "$(head -1 <<<"$extra")"; fi
		aberto="$(find "$d" \( -perm -o+r -o -perm -o+w -o -perm -o+x \) ! -type l 2>/dev/null | head -3)"
		if [ -z "$aberto" ]; then res PASSOU "nenhum arquivo/dir legivel por 'outros' em $d"; else res FALHOU "permissao para 'outros' em $d" "$(head -1 <<<"$aberto")"; fi
	done
	# --- identidades: sem shell/sudo indevido, grupos privilegiados sem o uid dos Gates -------
	for u in openbao erp-fiscal erp-fiscal-api; do
		sh="$(getent passwd "$u" | cut -d: -f7)"
		case "$sh" in */nologin | */false) res PASSOU "$u sem shell de login" "$sh" ;; *) res FALHOU "$u com shell de login" "$sh" ;; esac
	done
	for g in wheel podman docker disk systemd-journal adm; do
		for m in $(getent group "$g" | cut -d: -f4 | tr ',' ' '); do
			case "$m" in
			cmbergamo) ;; # administrador legitimo
			*) res FALHOU "membro '$m' no grupo privilegiado '$g'" ;;
			esac
		done
	done
	res PASSOU "grupos privilegiados (wheel/podman/docker/disk/systemd-journal/adm) sem membros inesperados"
	sudo_fa1="$(sudo -l -U fiscal-a1 2>/dev/null | grep -E '^\s+\(' | sed 's/^ *//')"
	res PASSOU "regras sudo de fiscal-a1 (revisar a lista)" "$(tr '\n' ';' <<<"$sudo_fa1" | cut -c1-300)"
	if sudo -l -U rmbergamo 2>/dev/null | grep -qE 'NOPASSWD|\(ALL'; then res FALHOU "usuario dos Gates com sudo"; else res PASSOU "usuario dos Gates sem sudo"; fi
	# --- exposicao -------------------------------------------------------------------------
	exposto="$(ss -ltnH 2>/dev/null | awk '{print $4}' | grep -E ':(8200|8201|8080|5434)$' | grep -vE '^(127\.0\.0\.1|\[::1\]):' || true)"
	if [ -z "$exposto" ]; then res PASSOU "portas 8200/8201/8080/5434 nao expostas fora do loopback"; else res FALHOU "porta exposta" "$exposto"; fi
	if ss -ltnH 2>/dev/null | awk '{print $4}' | grep -qE ':5434$'; then res FALHOU "PostgreSQL de homologacao escutando em TCP"; else res PASSOU "PostgreSQL de homologacao sem listener TCP"; fi
	sshd -T 2>/dev/null | grep -Ei '^(allowusers|allowgroups|allowtcpforwarding|passwordauthentication)' | sed 's/^/    sshd: /'
	printf '== %s falha(s) (modo --root) ==\n' "$falhas"
	[ "$falhas" -eq 0 ]
	exit
fi

# =============================== modo padrao: como o usuario DOS GATES ===============================
[ "$(id -u)" -ne 0 ] || { echo "ERRO: execute como o usuario dos Gates, nao como root" >&2; exit 2; }
printf '== isolamento visto pelo usuario %s (uid %s, grupos: %s) ==\n' "$(id -un)" "$(id -u)" "$(id -Gn)"

for g in wheel podman docker disk systemd-journal adm; do
	if id -Gn | tr ' ' '\n' | grep -qx "$g"; then res FALHOU "usuario dos Gates pertence ao grupo privilegiado '$g'"; fi
done
res PASSOU "usuario dos Gates fora dos grupos privilegiados (wheel/podman/docker/disk/systemd-journal/adm)"

nega() { # descricao caminho  (o acesso deve dar EACCES; ENOENT = modulo nao aplicado = FALHA)
	local desc="$1" caminho="$2" saida
	saida="$(ls -ld -- "$caminho" 2>&1 >/dev/null; cat -- "$caminho" 2>&1 >/dev/null)"
	if grep -qiE 'No such file' <<<"$saida"; then
		res FALHOU "$desc" "caminho inexistente — modulo nao aplicado? ($caminho)"
	elif grep -qiE 'Permission denied' <<<"$saida"; then
		res PASSOU "$desc" "negado"
	elif [ -d "$caminho" ] && ls -- "$caminho" >/dev/null 2>&1; then
		res FALHOU "$desc" "LISTAGEM PERMITIDA: $caminho"
	elif [ -f "$caminho" ] && cat -- "$caminho" >/dev/null 2>&1; then
		res FALHOU "$desc" "LEITURA PERMITIDA: $caminho"
	else
		res PASSOU "$desc" "negado"
	fi
}
nega "chave TLS do cofre" /var/lib/openbao/tls/server.key
nega "dados Raft do cofre" /var/lib/openbao/raft
nega "auditoria do cofre" /var/log/openbao/audit.log
nega "chave da CA privada" /var/lib/erp-fiscal-hml-pki/ca/ca.key
nega "secret_id do worker" /var/lib/erp-fiscal/credenciais/openbao-secret-id
nega "artefatos fiscais (XML)" /var/lib/erp-fiscal/artefatos
nega "temporario do worker" /var/lib/erp-fiscal/tmp
nega "recepcao do A1" /var/lib/erp-fiscal-a1/recepcao
nega "secret_id do importador" /var/lib/erp-fiscal-a1/credenciais/openbao-secret-id
nega "credencial da API de cadastro" /var/lib/erp-fiscal-api/credenciais
nega "secret_id de backup/recuperacao" /etc/erp-fiscal-hml/credenciais/backup-secret-id
nega "backups cifrados" /var/backups/erp-fiscal-hml

# arquivos de configuracao LEGIVEIS por desenho: nao podem conter segredo
for f in /etc/erp-fiscal-hml/worker.env /etc/erp-fiscal-hml/importador.env /etc/erp-fiscal-hml/api.env; do
	if [ ! -r "$f" ]; then res FALHOU "config publica ausente" "$f"; continue; fi
	if grep -qiE '(senha|secret|token|pass)[a-z_]*=[^/]|BEGIN [A-Z ]*PRIVATE' "$f"; then res FALHOU "possivel segredo em $f"; else res PASSOU "$f so contem enderecos/caminhos (sem segredo)"; fi
done
for d in /opt/erp-fiscal-hml /etc/erp-fiscal-hml /run/postgresql; do
	if [ -w "$d" ]; then res FALHOU "usuario dos Gates pode ESCREVER em $d"; else res PASSOU "sem escrita em $d (nao planta binario/config/socket)"; fi
done

# --- cofre pela API (loopback): sem credencial, nada alem de saude -------------------------------
CA=/etc/erp-fiscal-hml/openbao-ca.pem
codigo() { curl -sS -o /dev/null -w '%{http_code}' --max-time 8 --cacert "$CA" "$@" 2>/dev/null || true; }
if [ ! -r "$CA" ]; then res FALHOU "CA publica ausente" "$CA"; else
	for alvo in "GET v1/secret/data/fiscal/certificados/hml-x" "GET v1/sys/mounts" "GET v1/sys/policies/acl/fiscal-worker" "GET v1/sys/audit" "PUT v1/sys/seal" "GET v1/sys/generate-root-token/attempt" "POST v1/auth/token/create"; do
		m="${alvo%% *}"; p="${alvo#* }"
		c="$(codigo -X "$m" "https://127.0.0.1:8200/$p")"
		if [ "$c" = "403" ]; then res PASSOU "cofre sem token: $m /$p" "403"; else res FALHOU "cofre sem token: $m /$p" "http=$c (esperado 403)"; fi
	done
	for corpo in '{"role_id":"x","secret_id":"y"}' '{"role_id":"fiscal-worker","secret_id":"00000000-0000-0000-0000-000000000000"}'; do
		c="$(codigo -X POST -H 'Content-Type: application/json' --data "$corpo" https://127.0.0.1:8200/v1/auth/approle/login)"
		case "$c" in 400 | 403) res PASSOU "login AppRole com credencial forjada recusado" "http=$c" ;; *) res FALHOU "login forjado" "http=$c" ;; esac
	done
fi
# o certificado do servico so confia na CA privada: um impostor na porta nao passa na verificacao
if curl -sS --max-time 8 -o /dev/null https://127.0.0.1:8200/v1/sys/health 2>/dev/null; then res FALHOU "TLS do cofre valida sem a CA privada"; else res PASSOU "TLS do cofre exige a CA privada (impostor na porta nao e aceito)"; fi

# --- banco: nao ha mapeamento peer para o usuario dos Gates --------------------------------------
for u in erp_app erp_migrador erp_backup postgres; do
	if psql -X -h /run/postgresql -p 5434 -U "$u" -d erp_fiscal_hml -Atqc 'select 1' >/dev/null 2>&1; then res FALHOU "PostgreSQL de homologacao aceitou o usuario dos Gates como $u"; else res PASSOU "PostgreSQL de homologacao recusa o usuario dos Gates como $u (peer sem mapa)"; fi
done

# --- processos de outros usuarios: sem /proc/<pid>/environ|fd e sem segredo em argv ---------------
for u in openbao erp-fiscal erp-fiscal-api; do
	for pid in $(pgrep -u "$u" 2>/dev/null | head -3); do
		if cat "/proc/$pid/environ" >/dev/null 2>&1; then res FALHOU "le /proc/$pid/environ de $u"; else res PASSOU "sem acesso a /proc/$pid/environ de $u"; fi
		if ls "/proc/$pid/fd" >/dev/null 2>&1; then res FALHOU "lista /proc/$pid/fd de $u"; else res PASSOU "sem acesso a /proc/$pid/fd de $u"; fi
	done
done
if pgrep -af 'secret_id|hvs\.[A-Za-z0-9]|-otp=|BAO_TOKEN=|ERP_ADMIN_INITIAL_PASSWORD=' | grep -vE 'verificar-isolamento' >/dev/null; then
	res FALHOU "segredo visivel na linha de comando de algum processo"
else
	res PASSOU "nenhuma linha de comando exibe segredo/token/OTP"
fi

# --- privilegios: sudo, unidades do sistema, sockets de conteiner --------------------------------
if sudo -n -l >/dev/null 2>&1; then res FALHOU "usuario dos Gates tem sudo sem senha"; else res PASSOU "usuario dos Gates sem sudo"; fi
for u in erp-fiscal-hml-worker.service erp-fiscal-hml-api.service openbao.service; do
	if systemctl start "$u" >/dev/null 2>&1 || systemctl stop "$u" >/dev/null 2>&1; then res FALHOU "iniciou/parou $u"; else res PASSOU "sem direito de iniciar/parar $u"; fi
done
for s in /run/podman/podman.sock /var/run/docker.sock; do
	if [ -S "$s" ] && [ -r "$s" ] && [ -w "$s" ]; then res FALHOU "socket de contêiner rootful acessivel: $s (equivale a root)"; else res PASSOU "sem acesso r/w ao socket rootful $s"; fi
done
# o socket rootless do proprio usuario nao alcanca outros uids (user namespace do proprio subuid)
if grep -q "^$(id -un):" /etc/subuid 2>/dev/null; then
	inicio="$(grep "^$(id -un):" /etc/subuid | cut -d: -f2)"
	fim=$((inicio + $(grep "^$(id -un):" /etc/subuid | cut -d: -f3) - 1))
	conflito=0
	while IFS=: read -r _ _ uid _; do
		[ "$uid" -ge "$inicio" ] 2>/dev/null && [ "$uid" -le "$fim" ] && conflito=1
	done < <(getent passwd | grep -E '^(openbao|erp-fiscal|erp-fiscal-api|fiscal-a1):')
	if [ "$conflito" -eq 0 ]; then res PASSOU "faixa subuid dos contêineres rootless do usuario dos Gates nao inclui uids dos servicos fiscais"; else res FALHOU "subuid dos Gates sobrepoe um uid fiscal"; fi
fi

# --- SSH: NENHUMA chave privada legivel por este usuario pode entrar como o operador do A1 -------
opts=(-o BatchMode=yes -o ConnectTimeout=6 -o IdentitiesOnly=yes -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no
	-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
chaves=0
for k in "$HOME"/.ssh/*; do
	[ -f "$k" ] || continue
	case "$k" in *.pub | */known_hosts* | */config | */authorized_keys*) continue ;; esac
	head -c 40 "$k" 2>/dev/null | grep -q 'PRIVATE KEY' || continue
	chaves=$((chaves + 1))
	if ssh "${opts[@]}" -i "$k" fiscal-a1@127.0.0.1 true >/dev/null 2>&1; then
		res FALHOU "A CHAVE PRIVADA $(basename "$k") (legivel pelos Gates) ENTRA como fiscal-a1" "troque a chave do operador"
	else
		res PASSOU "chave privada $(basename "$k") nao entra como fiscal-a1"
	fi
done
res PASSOU "chaves privadas testadas contra fiscal-a1: $chaves (agente SSH do usuario: $( [ -n "${SSH_AUTH_SOCK:-}" ] && echo presente || echo ausente ))"
if [ -n "${SSH_AUTH_SOCK:-}" ] && SSH_AUTH_SOCK="$SSH_AUTH_SOCK" ssh "${opts[@]}" -o IdentitiesOnly=no fiscal-a1@127.0.0.1 true >/dev/null 2>&1; then
	res FALHOU "o agente SSH deste usuario entra como fiscal-a1"
fi
if ssh "${opts[@]}" fiscal-a1@127.0.0.1 true >/dev/null 2>&1; then res FALHOU "fiscal-a1 aceita login sem chave"; else res PASSOU "fiscal-a1 recusa login sem chave (senha bloqueada)"; fi

printf '== %s falha(s) ==\n' "$falhas"
[ "$falhas" -eq 0 ]
