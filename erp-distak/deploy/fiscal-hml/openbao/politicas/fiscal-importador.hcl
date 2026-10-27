# [FISCAL-I3-HML-INFRA-DSTK-SERVER-01] Politica do AppRole do IMPORTADOR do A1 (HML).
# So grava (nova versao) o material no prefixo de homologacao e consulta os METADADOS (versao,
# data) para verificar a gravacao. NAO le o conteudo (pfx/senha) — quem le e o worker.
# Nao compartilha identidade com o worker. Nenhum acesso a sys/*.
path "secret/data/fiscal/certificados/hml-*" {
	capabilities = ["create", "update"]
}
path "secret/metadata/fiscal/certificados/hml-*" {
	capabilities = ["read"]
}
