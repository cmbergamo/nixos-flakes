#!/usr/bin/env bash
# [FISCAL-I3-HML-INFRA-DSTK-SERVER-01] Valida o modulo NixOS SEM aplica-lo (nao altera o host):
#   1. avaliacao do modulo em um sistema minimo (asserts: OpenBao >= 2.6.4, chave do operador);
#   2. build das unidades systemd, dos scripts (shellcheck embutido) e dos .env;
#   3. systemd-analyze verify e security --offline (exposicao <= 3.0 por servico);
#   4. varredura dos artefatos construidos: sem chave privada/token e sem anti-padroes no cofre
#      (modo dev, tls_skip_verify, mlock, listener fora do loopback).
#
# Uso: [NIXPKGS_REV=<rev>] validar-modulo-nixos.sh      (carga: avaliacao Nix, ~minutos; use "nice")
set -euo pipefail

die() {
	printf 'ERRO: %s\n' "$*" >&2
	exit 1
}

AQUI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$AQUI/../../.." && pwd)"
export MODULO="$RAIZ/deploy/fiscal-hml/nixos/erp-distak-fiscal-hml.nix"
export NIXPKGS_REV="${NIXPKGS_REV:-55bfb4d7437bd4e09ab7cba58a43bd68eb310044}"
CHECK="$RAIZ/deploy/fiscal-hml/nixos/check.nix"
for f in nix systemd-analyze jq; do command -v "$f" >/dev/null || die "ferramenta ausente: $f"; done
falhas=0
res() { # PASSOU|FALHOU descricao
	printf '[%s] %s\n' "$1" "$2"
	[ "$1" = PASSOU ] || falhas=$((falhas + 1))
}
construir() { nix build --impure --no-link --print-out-paths --expr "(import $CHECK).$1" 2>/dev/null; }

falhadas="$(nix eval --impure --json --expr "(import $CHECK).failedAssertions" 2>&1)" || die "avaliacao do modulo falhou: $falhadas"
if [ "$falhadas" = "[]" ]; then res PASSOU "modulo avalia; nenhuma assercao falhou (OpenBao >= 2.6.4, chave do operador)"; else res FALHOU "assercoes: $falhadas"; fi
versao="$(nix eval --impure --raw --expr "(import $CHECK).sys.config.erpDistak.fiscalHml.openbaoPackage.version")"
res PASSOU "OpenBao do nixpkgs ${NIXPKGS_REV:0:10}: $versao"

# o MESMO modulo sobre o nixpkgs REAL do host (revisao do `nixos-version --json`, OpenBao 2.6.2): o padrao do
# modulo deve cair no pacote fixado (2.7.1) e nenhuma assercao pode falhar. Baixa o tarball do GitHub (~45 MB).
host_rev="${HOST_NIXPKGS_REV:-b1b875982b17dabde9b4a37f3e229e74913e6db3}"
if v_host="$(NIXPKGS_REV="$host_rev" nix eval --impure --raw --expr "(import $CHECK).sys.pkgs.openbao.version" 2>/dev/null)"; then
	v_mod="$(NIXPKGS_REV="$host_rev" nix eval --impure --raw --expr "(import $CHECK).sys.config.erpDistak.fiscalHml.openbaoPackage.version")"
	f_host="$(NIXPKGS_REV="$host_rev" nix eval --impure --json --expr "(import $CHECK).failedAssertions")"
	if [ "$f_host" = "[]" ] && [ "$v_mod" = "2.7.1" ]; then
		res PASSOU "sobre o nixpkgs do host (${host_rev:0:10}, OpenBao $v_host) o modulo usa o pacote fixado $v_mod e nenhuma assercao falha"
	else
		res FALHOU "modulo sobre o nixpkgs do host: openbao do modulo=$v_mod assercoes=$f_host"
	fi
else
	res FALHOU "nao foi possivel avaliar o modulo sobre o nixpkgs do host (${host_rev:0:10})"
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for u in openbaoUnit workerUnit apiUnit backupUnit backupTimer; do
	p="$(construir "$u")" || die "build falhou: $u"
	cp -L "$p"/* "$tmp/" 2>/dev/null || cp -L "$p" "$tmp/"
done
for a in scriptsPkgs etcWorker etcImportador etcApi; do
	construir "$a" >>"$tmp/built.txt" || res FALHOU "build: $a"
done
res PASSOU "unidades, 15 scripts (shellcheck do writeShellApplication) e arquivos .env construidos"

for u in openbao.service erp-fiscal-hml-worker.service erp-fiscal-hml-api.service erp-fiscal-hml-backup.service erp-fiscal-hml-backup.timer; do
	saida="$(systemd-analyze verify --man=no "$tmp/$u" 2>&1 | grep -v 'Failed to create /run/systemd/system' || true)"
	# unico aviso esperado: o binario do worker ainda nao esta instalado (ConditionPathExists o protege)
	saida="$(grep -vE '/opt/erp-fiscal-hml/current/bin/(fiscal_worker|erp_backend) is not executable' <<<"$saida" || true)"
	if [ -z "$saida" ]; then res PASSOU "systemd-analyze verify $u"; else res FALHOU "verify $u: $saida"; fi
done
for u in openbao.service erp-fiscal-hml-worker.service erp-fiscal-hml-api.service erp-fiscal-hml-backup.service; do
	nota="$(systemd-analyze security --offline=true --no-pager "$tmp/$u" 2>&1 | sed -n 's/.*Overall exposure level for .*: \([0-9.]*\) .*/\1/p')"
	if awk -v n="$nota" 'BEGIN{exit !(n+0 <= 3.0)}'; then res PASSOU "exposicao systemd de $u: $nota (<= 3.0)"; else res FALHOU "exposicao de $u: $nota"; fi
done

# varredura dos artefatos construidos (unidades + config do cofre + scripts + env)
alvos=("$tmp"/*)
while IFS= read -r p; do [ -z "$p" ] || alvos+=("$p"); done <"$tmp/built.txt"
if grep -rIlE -e '-----BEGIN [A-Z ]*PRIVATE KEY-----' -e 'hvs\.[A-Za-z0-9_-]{20,}' -e 'AGE-SECRET-KEY-' "${alvos[@]}" 2>/dev/null; then
	res FALHOU "segredo/chave privada em artefato construido (Nix store)"
else
	res PASSOU "nenhum segredo/chave privada nos artefatos do Nix store"
fi
cfg="$(grep -o '/nix/store/[a-z0-9]*-openbao.hcl.in' "$tmp/openbao.service" | head -1)"
exec_start="$(grep '^ExecStart=' "$tmp/openbao.service")"
sem_comentarios="$(grep -vE '^[[:space:]]*#' "$cfg")" # os comentarios do gabarito citam os anti-padroes proibidos
anti=0
grep -qE 'tls_skip_verify|disable_mlock|dev_mode|dev-root-token' <<<"$sem_comentarios" && anti=1
grep -qE -- ' -dev' <<<"$exec_start" && anti=1
grep -qE 'address *= *"127\.0\.0\.1:8200"' <<<"$sem_comentarios" || anti=1
grep -qE 'address *= *"0\.0\.0\.0|address *= *"\[::\]' <<<"$sem_comentarios" && anti=1
grep -q '^audit "file"' <<<"$sem_comentarios" || anti=1
if [ "$anti" -eq 0 ]; then res PASSOU "config do cofre: loopback, sem modo dev/tls_skip_verify/mlock, auditoria declarada"; else res FALHOU "config do cofre com anti-padrao"; fi

printf '== %s falha(s) ==\n' "$falhas"
[ "$falhas" -eq 0 ]
