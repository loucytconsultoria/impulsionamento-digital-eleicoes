# =============================================================================
# run_all.R  -  Orquestrador reproduzivel (00 a 08) com transcricao auditavel
# -----------------------------------------------------------------------------
# Rodar, a partir da raiz do repositorio:
#   Rscript R/pipeline/run_all.R
# ou, para gravar a transcricao completa (codigo + saida) em transcricao/:
#   R CMD BATCH --no-save --no-restore R/pipeline/run_all.R run_all.Rout
#
# Variaveis de ambiente (todas opcionais):
#   TSE_DADOS               pasta com os microdados brutos do TSE (padrao: dados/)
#   IMPULSIONAMENTO_SAIDA   pasta de saida (padrao: execucao/)
#   IMPULSIONAMENTO_RAIZ    raiz do repositorio (padrao: detectada)
#
# Cada script e' executado com echo=TRUE, de modo que a transcricao registra
# comando e saida. Ao final grava MANIFEST.md com o md5 de cada arquivo gerado.
# =============================================================================
.achar_raiz <- function() {
  env <- Sys.getenv("IMPULSIONAMENTO_RAIZ", unset = "")
  if (nzchar(env)) return(normalizePath(env, winslash = "/"))
  p <- normalizePath(getwd(), winslash = "/")
  repeat {
    if (file.exists(file.path(p, "dicionarios", "ipca_indice.csv"))) return(p)
    q <- dirname(p)
    if (q == p) stop("Raiz do repositorio nao encontrada: rode a partir da pasta do ",
                     "repositorio ou defina IMPULSIONAMENTO_RAIZ.")
    p <- q
  }
}
RAIZ <- .achar_raiz()
DIR_SCRIPTS <- file.path(RAIZ, "R", "pipeline")
op <- function(f) source(file.path(DIR_SCRIPTS, f), echo = TRUE, max.deparse.length = Inf)

op("00_setup.R")                 # define ROOT (pasta de saida) e muda o diretorio de trabalho
op("01_tratamento.R")
op("02_modelos_votos.R")
op("03_saturacao.R")
op("04_eleitorado_porte.R")
op("05_moderadores.R")
op("06_sucesso.R")
op("07_comparacao_monografia.R")
op("08_relatorio_resultados.R")

# ------------------------------- MANIFEST ------------------------------------
# Inventario reproduzivel: paineis, saidas, figuras, logs e os entregaveis
# estaticos (relatorio, sessionInfo). Reexecutar run_all reproduz este arquivo.
# O teste de determinismo cobre dados_tratados/, saidas/ e figuras/.
gather <- function(dir){ fs <- list.files(dir, full.names=TRUE, recursive=TRUE)
  if (!length(fs)) return(NULL)
  rel <- sub(paste0(ROOT,"/"), "", normalizePath(fs, winslash="/"), fixed=TRUE)
  data.table(arquivo=rel, md5=unname(tools::md5sum(fs)), bytes=file.info(fs)$size) }
man <- rbindlist(lapply(c("dados_tratados","saidas","figuras","logs"), gather), fill=TRUE)
extra <- c("RELATORIO_RESULTADOS.md","sessionInfo.txt"); extra <- extra[file.exists(extra)]
if (length(extra)) man <- rbind(man, data.table(arquivo=extra, md5=unname(tools::md5sum(extra)), bytes=file.info(extra)$size))
setorder(man, arquivo)
writeLines(c("# MANIFEST","",
             paste0("Gerado por run_all.R. ", nrow(man),
                    " arquivos (dados_tratados, saidas, figuras, logs, relatorio, sessionInfo)."),
             "","| arquivo | md5 | bytes |","|---|---|---:|",
             man[, paste0("| ",arquivo," | ",md5," | ",bytes," |")]),
           file.path(ROOT, "MANIFEST.md"))
cat("\n==== RUN_ALL OK :", nrow(man), "arquivos no MANIFEST ====\n")
