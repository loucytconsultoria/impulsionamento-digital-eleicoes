# =============================================================================
# 00_setup.R  -  Ambiente, pacotes, determinismo e proveniencia
# -----------------------------------------------------------------------------
# Define os caminhos canonicos, fixa a semente e carrega os pacotes.
#
#   RAIZ       raiz do repositorio (detectada a partir do diretorio de trabalho,
#              ou da variavel de ambiente IMPULSIONAMENTO_RAIZ)
#   DIR_BRUTO  microdados brutos do TSE, somente leitura
#              (variavel TSE_DADOS; padrao: <RAIZ>/dados)
#   ROOT       pasta onde o pipeline escreve tudo o que gera
#              (variavel IMPULSIONAMENTO_SAIDA; padrao: <RAIZ>/execucao)
#   DIR_DICT   dicionarios versionados do repositorio (<RAIZ>/dicionarios)
#
# Ao final grava sessionInfo.txt na pasta de saida.
# =============================================================================

if (!exists("RAIZ")) {
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
}

ROOT <- normalizePath(Sys.getenv("IMPULSIONAMENTO_SAIDA", unset = file.path(RAIZ, "execucao")),
                      winslash = "/", mustWork = FALSE)
dir.create(ROOT, recursive = TRUE, showWarnings = FALSE)
setwd(ROOT)

# Caminhos canonicos -----------------------------------------------------------
DIR_BRUTO   <- Sys.getenv("TSE_DADOS", unset = file.path(RAIZ, "dados"))  # BRUTO do TSE (somente leitura)
DIR_DICT    <- file.path(RAIZ, "dicionarios")                              # dicionarios versionados
DIR_TRATADO <- "dados_tratados"
DIR_SAIDA   <- "saidas"
DIR_FIG     <- "figuras"
DIR_LOG     <- "logs"
DIR_TRANSC  <- "transcricao"
for (d in c(DIR_TRATADO, DIR_SAIDA, DIR_FIG, DIR_LOG, DIR_TRANSC))
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
if (!dir.exists(DIR_BRUTO))
  stop("Microdados do TSE nao encontrados em '", DIR_BRUTO, "'. Veja o README (secao 'Como rodar') ",
       "e defina TSE_DADOS.")

# Determinismo -----------------------------------------------------------------
set.seed(20260629)
options(echo = TRUE, width = 200, scipen = 999, stringsAsFactors = FALSE,
        warn = 1, digits = 7)

# Pacotes ----------------------------------------------------------------------
suppressWarnings(suppressMessages({
  library(data.table)   # IO e manipulacao
  library(stringi)      # normalizacao de texto (nomes)
  library(glmmTMB)      # Binomial Negativa (NB2) do modelo de votos
  library(MASS)         # negative.binomial (pseudo-R2)
  library(logistf)      # logit de Firth (sucesso)
  library(pROC)         # AUC
  library(abjData)      # crosswalk TSE<->IBGE (moderadores municipais)
}))

cat("\n[setup] R", as.character(getRversion()), "| libPaths[1] =", .libPaths()[1], "\n")
cat("[setup] saida =", ROOT, "\n[setup] bruto =", DIR_BRUTO, "\n")
cat("[setup] seed = 20260629\n")

writeLines(capture.output(sessionInfo()), file.path(ROOT, "sessionInfo.txt"))
