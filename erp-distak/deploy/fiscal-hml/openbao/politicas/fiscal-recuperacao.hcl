# [FISCAL-I3-HML-INFRA-DSTK-SERVER-01] Politica do AppRole de RECUPERACAO (break-glass) do cofre.
# No OpenBao >= 2.6 a geracao de root token usa o endpoint AUTENTICADO sys/generate-root-token: sem
# nenhum token com esta capacidade, depois de revogar o root token o cofre ficaria SEM caminho de
# administracao. Esta identidade so pode iniciar/atualizar/cancelar a geracao — e a geracao em si
# exige o QUORUM de 3 das 5 chaves de recuperacao. Sozinho o secret_id desta identidade nao
# permite ler segredo, escrever nada nem alterar politica. Uso: erp-fiscal-hml-admin (root).
path "sys/generate-root-token/attempt" {
	capabilities = ["create", "read", "update", "delete"]
}
path "sys/generate-root-token/update" {
	capabilities = ["create", "update"]
}
