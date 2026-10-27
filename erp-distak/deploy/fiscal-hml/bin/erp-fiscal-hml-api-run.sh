#!/usr/bin/env bash
# [FISCAL-I3-HML-INFRA-DSTK-SERVER-01] Inicia a API do ERP (erp_backend) de HOMOLOGACAO, SO em
# loopback (127.0.0.1:8080), para o CADASTRO fiscal (empresa, perfil fiscal, certificado-referencia,
# endereco do estabelecimento) pela tela do ERP. Servico TEMPORARIO e opt-in: suba, cadastre, pare.
# A API NUNCA constroi o provedor do cofre/A1 (guarda arquitetural: so o worker e as CLIs).
#
# A senha inicial do administrador do ERP (so necessaria no 1o boot, quando o admin ainda nao
# existe) e lida de um arquivo 0600 do proprio usuario do servico e entra SO no ambiente deste
# processo — nunca em argv, unidade ou log. Apos o 1o boot bem-sucedido, apague o arquivo.
set -euo pipefail
umask 077
cd /

release="${ERP_FISCAL_HML_RELEASE:-/opt/erp-fiscal-hml/current}"
credencial="${ERP_FISCAL_HML_API_ADMIN_INICIAL:-/var/lib/erp-fiscal-api/credenciais/admin-inicial}"
if [ -s "$credencial" ]; then
	ERP_ADMIN_INITIAL_PASSWORD="$(cat "$credencial")"
	export ERP_ADMIN_INITIAL_PASSWORD
fi
exec "$release/bin/erp_backend"
