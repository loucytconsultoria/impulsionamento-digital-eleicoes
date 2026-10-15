# =====================================================================
# run_all.R -- executa toda a bateria de diagnosticos do zero
# Uso, a partir da raiz do repositorio:
#   Rscript R/diagnosticos/run_all.R
# Variaveis de ambiente (opcionais): TSE_DADOS (zips brutos do TSE; padrao
# dados/), IMPULSIONAMENTO_SAIDA (padrao execucao/).
# Etapas complementares (quantificacao do efeito de cada correcao e suporte
# da variavel de interesse) rodam ao final, sobre os ajustes salvos.
# =====================================================================
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
DIR_SCRIPTS <- file.path(RAIZ, "R", "diagnosticos")
src <- function(f) source(file.path(DIR_SCRIPTS, f))

t0 <- Sys.time()
src("00_setup.R")
src("01_populacao.R")          # dicionario de populacao (IBGE/SIDRA)
src("02_dados.R")              # reconstrucao das bases do TCC
src("03_modelos.R")            # reestimacao dos 12 recortes
src("04_diag_contagem.R")      # diagnosticos dos modelos de contagem
src("05_diag_logit.R")         # diagnosticos dos modelos logit
src("07_testes_complementares.R")
src("06_figuras.R")
src("09_explicacoes.R")        # efeito pratico de cada correcao (rubrica, Firth, agrupamento, EPV)
src("10_suporte_impulsionamento.R")  # suporte da variavel de interesse e margens separadas
msg("bateria completa em ", round(as.numeric(difftime(Sys.time(), t0, units = "mins")), 1), " minutos")
writeLines(capture.output(sessionInfo()), file.path(DIR_LOG, "sessionInfo.txt"))
