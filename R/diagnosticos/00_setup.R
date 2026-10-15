# =====================================================================
# 00_setup.R -- Diagnosticos dos modelos econometricos ORIGINAIS do TCC
# =====================================================================
# Objetivo: reconstruir fielmente as bases e os modelos do TCC
# (dep. federal 2018/2022, dep. estadual 2018/2022, vereador 2020/2024
# por porte de municipio) e submete-los a uma bateria completa de
# testes de especificacao e diagnostico.
# =====================================================================

# ---- caminhos -------------------------------------------------------
# RAIZ    : raiz do repositorio (detectada, ou IMPULSIONAMENTO_RAIZ)
# DIR_DAD : zips brutos do TSE, somente leitura (TSE_DADOS; padrao <RAIZ>/dados)
# DIR_DIAG  : pasta onde esta bateria escreve tudo o que gera
#           (IMPULSIONAMENTO_SAIDA/diagnosticos; padrao <RAIZ>/execucao/diagnosticos)
# DIR_DIC : dicionarios versionados do repositorio (<RAIZ>/dicionarios)
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
SAIDA_BASE <- Sys.getenv("IMPULSIONAMENTO_SAIDA", unset = file.path(RAIZ, "execucao"))
DIR_DIAG    <- file.path(SAIDA_BASE, "diagnosticos")
DIR_DAD   <- Sys.getenv("TSE_DADOS", unset = file.path(RAIZ, "dados"))   # zips brutos do TSE
DIR_CACHE <- file.path(DIR_DIAG, "dados_cache")       # csv PR extraidos
DIR_TRAT  <- file.path(DIR_DIAG, "dados_tratados")
DIR_OUT   <- file.path(DIR_DIAG, "saidas")
DIR_FIG   <- file.path(DIR_DIAG, "figuras")
DIR_LOG   <- file.path(DIR_DIAG, "logs")
DIR_DIC   <- file.path(RAIZ, "dicionarios")
for (d in c(DIR_CACHE, DIR_TRAT, DIR_OUT, DIR_FIG, DIR_LOG))
  dir.create(d, recursive = TRUE, showWarnings = FALSE)
if (!dir.exists(DIR_DAD))
  stop("Microdados do TSE nao encontrados em '", DIR_DAD, "'. Veja o README (secao 'Como rodar').")

options(stringsAsFactors = FALSE, scipen = 999, warn = 1)
set.seed(20260809)

suppressPackageStartupMessages({
  library(data.table)
  library(dplyr)
  library(tidyr)
  library(stringr)
  library(stringi)
  library(tibble)
  library(purrr)
  library(MASS)
  library(glmmTMB)
  library(lmtest)
  library(sandwich)
  library(car)
  library(AER)
  library(performance)
  library(DHARMa)
  library(pROC)
  library(ResourceSelection)
  library(pscl)
  library(logistf)
  library(ggplot2)
})

# ---- utilidades ------------------------------------------------------
msg <- function(...) cat(sprintf("[%s] ", format(Sys.time(), "%H:%M:%S")), ..., "\n", sep = "")

limpar_nomes_robusta <- function(texto) {
  texto_sem_acento <- stri_trans_general(texto, "Latin-ASCII")
  gsub("[^A-Z0-9]", "", toupper(texto_sem_acento))
}

# extrai (uma vez) um arquivo PR de dentro de um zip do TSE
extrair_pr <- function(zipname, arquivo) {
  destino <- file.path(DIR_CACHE, arquivo)
  if (!file.exists(destino)) {
    zp <- file.path(DIR_DAD, zipname)
    if (!file.exists(zp)) stop("ZIP ausente: ", zp)
    msg("extraindo ", arquivo, " de ", zipname)
    utils::unzip(zp, files = arquivo, exdir = DIR_CACHE, junkpaths = TRUE)
  }
  if (!file.exists(destino)) stop("falha ao extrair ", arquivo)
  destino
}

ler_tse <- function(caminho) {
  data.table::fread(caminho, sep = ";", encoding = "Latin-1",
                    showProgress = FALSE, data.table = FALSE)
}

# grava csv determinstico
gravar <- function(x, nome, dir = DIR_OUT) {
  utils::write.csv(x, file.path(dir, nome), row.names = FALSE, fileEncoding = "UTF-8")
  invisible(x)
}

msg("setup OK | ", R.version.string, " | glmmTMB ", as.character(packageVersion("glmmTMB")))
