# [FISCAL-I3-HML-INFRA-DSTK-SERVER-01] Politica do AppRole de BACKUP do cofre (HML).
# So tira o snapshot Raft (que ja e cifrado pela barreira do OpenBao). Nao le segredos pela API
# KV, nao grava, nao administra. O restore NAO usa esta identidade (exige token de administracao
# gerado com as chaves de recuperacao — ver evidencias/.../recuperacao.md).
path "sys/storage/raft/snapshot" {
	capabilities = ["read"]
}
