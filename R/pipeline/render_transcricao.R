# =============================================================================
# render_transcricao.R  -  Gera transcricao/run_all.html a partir do .Rout
# -----------------------------------------------------------------------------
# Apenas embrulha o run_all.Rout (codigo + saida) em HTML; NAO reexecuta o
# pipeline. Sem dependencia nova (so base R).
# =============================================================================
# Uso: Rscript R/pipeline/render_transcricao.R [pasta_de_saida]
# (padrao: execucao/ na raiz do repositorio ou IMPULSIONAMENTO_SAIDA)
args <- commandArgs(trailingOnly = TRUE)
ROOT <- if (length(args)) args[1] else Sys.getenv("IMPULSIONAMENTO_SAIDA", unset = "execucao")
setwd(ROOT)
rout <- file.path("transcricao","run_all.Rout")
if (!file.exists(rout)) { cat("run_all.Rout ausente; nada a renderizar.\n"); quit(save="no") }
txt <- readLines(rout, warn=FALSE)
esc <- function(s){ s<-gsub("&","&amp;",s,fixed=TRUE); s<-gsub("<","&lt;",s,fixed=TRUE); gsub(">","&gt;",s,fixed=TRUE) }
html <- c("<!doctype html>","<html><head><meta charset='utf-8'>",
  "<title>Transcricao do pipeline</title>",
  "<style>body{font-family:Consolas,monospace;margin:24px;color:#111}",
  "pre{white-space:pre-wrap;word-wrap:break-word;font-size:12px;line-height:1.35;",
  "border:1px solid #ddd;padding:16px;background:#fafafa}</style></head><body>",
  "<h2>Transcricao auditavel do pipeline</h2>",
  "<p>Codigo e saida de R CMD BATCH R/pipeline/run_all.R. Nao reexecutado.</p>",
  "<pre>", esc(txt), "</pre></body></html>")
writeLines(html, file.path("transcricao","run_all.html"))
cat("run_all.html gerado (", length(txt), "linhas ).\n")
