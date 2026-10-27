#!/usr/bin/env bash
# [FISCAL-I3-HML-INFRA-DSTK-SERVER-01] Compila os binarios fiscais (fiscal_worker,
# fiscal_nfe_hml, fiscal_a1_cofre) e a API de cadastro (erp_backend) de forma RASTREAVEL e gera build-info.json com commit, tree,
# hash do Cargo.lock, versoes das ferramentas e SHA-256 de cada binario.
#
# SEGURANCA: o build roda codigo arbitrario (build.rs, proc-macros). Para instalar binarios que
# verao o A1 REAL, compile num ambiente do ADMINISTRADOR (nao no home do usuario dos Gates, cujo
# cargo/rustup/cache e acessivel a codigo de candidatos). CARGO_HOME e a pasta de destino sao
# novos (cada crate e verificado pelo checksum do Cargo.lock; --locked). Compilar no usuario dos
# Gates serve apenas para ensaio.
#
# CARGA: build release e pesado (CPU/IO). Este script RECUSA rodar com Gate/cargo ativo no host,
# salvo --janela-confirmada (use apenas depois que a administradora dos Gates liberar a janela).
#
# Uso: erp-fiscal-hml-compilar --repo <checkout limpo no commit> --saida <dir> [--jobs N] [--janela-confirmada]
#        [--target-dir <dir> [--cargo-home <dir>]]   (build REUTILIZADO: so para ENSAIO; ver abaixo)
#
# Modo padrao = build FRESCO (CARGO_HOME e target novos): unico aceito para instalar em /opt. Com
# --target-dir/--cargo-home o build reaproveita cache (mais rapido, p.ex. o target gerido do projeto) e o
# build-info.json registra "ambiente":"reutilizado" — o erp-fiscal-hml-status acusa ATENCAO se um build
# assim estiver instalado: ele serve para testar o cliente Rust, NUNCA para ver o A1 real.
set -euo pipefail
umask 022

die() {
	printf 'ERRO: %s\n' "$*" >&2
	exit 1
}

repo=""
saida=""
jobs="2"
janela=0
target_dir=""
cargo_home=""
while [ "$#" -gt 0 ]; do
	case "$1" in
	--repo) repo="${2:-}"; shift 2 ;;
	--saida) saida="${2:-}"; shift 2 ;;
	--jobs) jobs="${2:-}"; shift 2 ;;
	--janela-confirmada) janela=1; shift ;;
	--target-dir) target_dir="${2:-}"; shift 2 ;;
	--cargo-home) cargo_home="${2:-}"; shift 2 ;;
	*) die "argumento desconhecido: $1" ;;
	esac
done
[[ "$repo" =~ ^/[A-Za-z0-9_./-]+$ && "$saida" =~ ^/[A-Za-z0-9_./-]+$ ]] || die "uso: --repo e --saida (caminhos absolutos simples)"
[[ "$jobs" =~ ^[1-9][0-9]?$ ]] || die "--jobs invalido"
[ -f "$repo/backend/Cargo.toml" ] || die "$repo nao e um checkout do ERP_distak"

commit="$(git -C "$repo" rev-parse HEAD)"
tree="$(git -C "$repo" rev-parse 'HEAD^{tree}')"
[ -z "$(git -C "$repo" status --porcelain)" ] || die "checkout sujo — compile somente de um commit limpo (rastreabilidade)"
canal="$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$repo/backend/rust-toolchain.toml")"
[ -n "$canal" ] || die "backend/rust-toolchain.toml sem channel"
for f in cargo rustc flatc git sha256sum jq; do command -v "$f" >/dev/null || die "ferramenta ausente no PATH: $f"; done
rustc_v="$(cd "$repo/backend" && rustc -V)"
case "$rustc_v" in *" $canal "*) ;; *) die "rustc ($rustc_v) difere do canal fixado ($canal)" ;; esac

if [ "$janela" -eq 0 ]; then
	if pgrep -x cargo >/dev/null || pgrep -x rustc >/dev/null; then
		die "ha cargo/rustc em execucao no host (possivel Gate): aguarde ou peca a janela a administradora dos Gates e use --janela-confirmada"
	fi
	for marcador in /tmp/qg_worker_wd_*/gate-progress.json; do
		if [ -e "$marcador" ] && [ -n "$(find "$marcador" -mmin -15 -print)" ]; then
			die "Gate ativo (marcador recente em $marcador): aguarde a janela e use --janela-confirmada"
		fi
	done
fi

curto="${commit:0:12}"
destino="$saida/$curto"
[ ! -e "$destino" ] || die "$destino ja existe"
trabalho="$(mktemp -d "${TMPDIR:-/var/tmp}/erp-fiscal-hml-build.XXXXXX")"
trap 'rm -rf "$trabalho"' EXIT
mkdir -p "$destino/bin"

printf 'Compilando commit %s (rustc %s) — jobs=%s, prioridade minima...\n' "$curto" "$canal" "$jobs"
ambiente="fresco"
alvo="$trabalho/target"
chome="$trabalho/cargo"
if [ -n "$target_dir" ]; then
	[[ "$target_dir" =~ ^/[A-Za-z0-9_./-]+$ ]] || die "--target-dir invalido"
	ambiente="reutilizado"
	alvo="$target_dir"
fi
if [ -n "$cargo_home" ]; then
	[[ "$cargo_home" =~ ^/[A-Za-z0-9_./-]+$ ]] || die "--cargo-home invalido"
	ambiente="reutilizado"
	chome="$cargo_home"
fi
(
	cd "$repo/backend"
	CARGO_HOME="$chome" CARGO_TARGET_DIR="$alvo" CARGO_BUILD_JOBS="$jobs" \
		nice -n 19 ionice -c 3 cargo build --release --locked \
		--bin fiscal_worker --bin fiscal_nfe_hml --bin fiscal_a1_cofre --bin erp_backend
)

for b in fiscal_worker fiscal_nfe_hml fiscal_a1_cofre erp_backend; do
	install -m 0755 "$alvo/release/$b" "$destino/bin/$b"
done

migration_head="$(find "$repo/backend/migrations" -maxdepth 1 -name '[0-9]*.sql' -printf '%f\n' | sed 's/_.*//' | sort | tail -1 | sed 's/^0*//')"
(
	cd "$destino"
	sha256sum bin/* >SHA256SUMS
	jq -n \
		--arg commit "$commit" --arg tree "$tree" \
		--arg lock "$(sha256sum "$repo/backend/Cargo.lock" | cut -d' ' -f1)" \
		--arg rustc "$rustc_v" --arg cargo "$(cd "$repo/backend" && cargo -V)" --arg flatc "$(flatc --version)" \
		--arg quando "$(date +%Y-%m-%dT%H:%M:%S)" --arg host "$(hostname)" --arg head "$migration_head" --arg amb "$ambiente" \
		--arg w "$(sha256sum bin/fiscal_worker | cut -d' ' -f1)" \
		--arg h "$(sha256sum bin/fiscal_nfe_hml | cut -d' ' -f1)" \
		--arg c "$(sha256sum bin/fiscal_a1_cofre | cut -d' ' -f1)" \
		--arg e "$(sha256sum bin/erp_backend | cut -d' ' -f1)" \
		'{commit: $commit, tree: $tree, cargo_lock_sha256: $lock, rustc: $rustc, cargo: $cargo, flatc: $flatc,
		  compilado_em: $quando, host: $host, migration_head: $head, ambiente: $amb,
		  binarios: {fiscal_worker: $w, fiscal_nfe_hml: $h, fiscal_a1_cofre: $c, erp_backend: $e}}' >build-info.json
)
printf 'OK: artefatos em %s (build-info.json + SHA256SUMS). Instalacao: ver evidencias/.../instalacao-binarios.md\n' "$destino"
