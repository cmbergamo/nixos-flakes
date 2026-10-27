# Infraestrutura fiscal de homologação (HML) — `dstk-server`

Artefatos da rodada `FISCAL-I3-HML-INFRA-DSTK-SERVER-01` (IDOC 8.350): cofre **OpenBao**, **PostgreSQL**
dedicado, **worker fiscal**, backup cifrado e a conta do operador do A1 — tudo **segregado do usuário
dos Quality Gates** (UID próprio por serviço). Evidência, procedimentos e resultados dos ensaios:
[`evidencias/fiscal/fiscal-i3-hml-infra-dstk-server-01/`](../../evidencias/fiscal/fiscal-i3-hml-infra-dstk-server-01/README.md).

> **Estado:** `I3-INFRA = BLOQUEADA (acesso administrativo)`. Nada daqui está implantado no host: exige
> `sudo`/`wheel` (`cmbergamo`) para aplicar o módulo NixOS. Os artefatos foram ensaiados com OpenBao 2.7.1 e
> PostgreSQL 16 **reais** e o módulo foi validado offline (avaliação, build, `systemd-analyze`); ver `testes.md`.

## Layout

| Caminho | Conteúdo |
|---|---|
| `nixos/erp-distak-fiscal-hml.nix` | Módulo NixOS autocontido (usuários, diretórios, `openbao.service`, PostgreSQL dedicado, worker, API de cadastro opt-in, backup, `sudo` restrito). `nixos/check.nix` é só o harness de validação. |
| `openbao/openbao.hcl.in` | Gabarito **único** da configuração do servidor (o módulo e o ensaio renderizam o mesmo arquivo). |
| `openbao/politicas/*.hcl` | Políticas de menor privilégio: `fiscal-worker` (lê `hml-*`), `fiscal-importador` (grava `hml-*`, lê metadados), `fiscal-backup` (só snapshot). |
| `bin/erp-fiscal-hml-*.sh` | Scripts operacionais (instalados sem `.sh` em `/run/current-system/sw/bin`). |
| `ensaio/` | Ensaios reproduzíveis: `ensaio-openbao.sh`, `ensaio-postgres.sh`, `ensaio-wrappers.sh`, `validar-modulo-nixos.sh`. |

## Scripts

| Comando | Quem | Função |
|---|---|---|
| `erp-fiscal-hml-tls` | admin (root) | PKI privada do cofre: CA + certificado do servidor (SAN `IP:127.0.0.1`, `IP:::1`). |
| `erp-fiscal-hml-bootstrap` | admin (root), **uma vez** | `init` (5 chaves, limiar 3), exibe as chaves uma única vez, destrava, provisiona e **revoga o root token**. Recusa `tmux`/`screen`. |
| `erp-fiscal-hml-provisionar` | chamado pelo bootstrap | Política, KV-v2, AppRoles (worker/importador/backup), `secret_id` em arquivo `0400`. Idempotente; `--rotacionar`. |
| `erp-fiscal-hml-unseal` | quem tem as chaves | Destrava após reinício (prompt oculto) e espera o cofre ficar **ativo**. |
| `erp-fiscal-hml-status` | qualquer usuário | Diagnóstico somente leitura (`OK/ATENCAO/FALHA/N/A`). |
| `erp-fiscal-hml-migrar` | `postgres` | Papéis → migrations (sqlx) → grants → verificação, pelo procedimento oficial. |
| `erp-fiscal-hml-compilar` | admin | Build rastreável (`build-info.json`, SHA-256); recusa rodar com Gate ativo. |
| `erp-fiscal-hml-backup` | `root` (timer 03:30) | Snapshot do cofre + `pg_dump` + artefatos, cifrados com `age` para chaves **públicas**. |
| `erp-fiscal-hml-importar-a1` | `fiscal-a1` (dono) | Importa o A1 com a CLI existente (senha por prompt sem eco); pré-checa a referência e o prefixo `hml-`. |
| `erp-fiscal-hml-verificar-a1` | `erp-fiscal` (via `sudo`) | Verifica cofre + assinatura + mTLS + status SEFAZ; **só cStat=107 real conta como sucesso**. |
| `erp-fiscal-hml-nfe` | `erp-fiscal` (via `sudo`) | Ciclo da NF-e HML (allowlist de subcomandos/flags; JSON por stdin). |
| `erp-fiscal-hml-api-run` | unidade `erp-fiscal-hml-api` | API do ERP em `127.0.0.1:8080`, **temporária**, só para o cadastro fiscal. |
| `erp-fiscal-hml-logs` | admin | Logs do journal sanitizados (token, `secret_id`, senha, base64, ANSI). |
| `erp-fiscal-hml-admin` | admin (root) | Sessão administrativa **temporária** (*break-glass*): identidade de recuperação + quórum de 3 chaves → root token efêmero, **revogado ao sair**. |
| `erp-fiscal-hml-verificar-isolamento` | usuário dos Gates (e `--root` do admin) | **Prova** o isolamento: tenta ler segredos/credenciais, usar o cofre/banco, espiar processos, `sudo`, sockets de contêiner e entrar como `fiscal-a1` com cada chave legível. **Portão do A1.** |

## Convenções do desenho

- **Loopback apenas** (D31): `127.0.0.1`, nunca `localhost`; o certificado do cofre tem SAN só por IP.
- **`identificador_cofre` de HML começa com `hml-`**: as políticas `fiscal-worker`/`fiscal-importador` só enxergam
  `secret/data/fiscal/certificados/hml-*`. Um futuro worker de produção terá política e prefixo próprios.
  O cliente Rust aceita `[A-Za-z0-9_.-]` (sem `/`), portanto `hml-<empresa>` é válido.
- **Banco**: cluster PostgreSQL novo, **só socket Unix**, autenticação **peer** com `pg_ident` (o papel do banco
  deriva do usuário do SO; sem senha). URL no formato canônico do sqlx para socket:
  `postgres://erp_app@%2Frun%2Fpostgresql:5434/erp_fiscal_hml` (o diretório do socket vai percent-encoded;
  `usuario@` com host vazio é inválido). `ERP_ENV=homologacao`.
- **Segredos**: nunca em Git, Nix store, argv ou log. O `secret_id` do worker fica em
  `/var/lib/erp-fiscal/credenciais/openbao-secret-id` (`0400`, dono `erp-fiscal`); o do importador em
  `/var/lib/erp-fiscal-a1/credenciais/`; o de backup em `/etc/erp-fiscal-hml/credenciais/` (`root`).
- **Cofre selado após reinício**: não há auto-unseal aprovado neste host (sem KMS/HSM/TPM). A recuperação é humana
  (`erp-fiscal-hml-unseal`, 3 de 5 chaves). O worker falha de forma explícita e retenta enquanto estiver selado.
- **OpenBao ≥ 2.6.4** (assertion do módulo): o `nixpkgs` do host traz 2.6.2, **vulnerável** (RCE crítica em `snapshot-force`, bypass de ACL). O padrão do módulo usa
  `pkgs.openbao` se já for corrigido e, senão, o **2.7.1 do nixpkgs fixado por revisão + hash** — sem override do administrador; ver `openbao-versao.md`.

## Como aplicar

Somente o administrador (`wheel`). Passo a passo completo e rollback em
[`bloqueio-e-desbloqueio.md`](../../evidencias/fiscal/fiscal-i3-hml-infra-dstk-server-01/bloqueio-e-desbloqueio.md).
Antes de aplicar, valide o módulo sem tocar o host: `deploy/fiscal-hml/ensaio/validar-modulo-nixos.sh`.
