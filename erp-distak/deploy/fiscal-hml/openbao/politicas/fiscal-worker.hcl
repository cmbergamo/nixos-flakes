# [FISCAL-I3-HML-INFRA-DSTK-SERVER-01] Politica do AppRole do WORKER fiscal (HML).
# Menor privilegio: SO le o material A1 de HOMOLOGACAO. Nenhuma escrita, nenhuma listagem,
# nenhum acesso a sys/*, a metadados ou a segredos de outros modulos (negacao por padrao).
# Escopo por prefixo: o identificador_cofre de HML deve comecar com "hml-" (allowlist do cliente
# aceita [A-Za-z0-9_.-]); um futuro worker de producao tera politica e prefixo PROPRIOS.
# Cobre varias empresas: cada empresa usa seu proprio "hml-<empresa>" sob o mesmo prefixo.
path "secret/data/fiscal/certificados/hml-*" {
	capabilities = ["read"]
}
