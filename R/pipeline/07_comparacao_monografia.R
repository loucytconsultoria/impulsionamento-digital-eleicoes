# =============================================================================
# 07_comparacao_monografia.R  -  Comparacao com a especificacao da monografia
# -----------------------------------------------------------------------------
# A monografia usava NB2 com log1p(gasto) UNICO por categoria (sem hurdle) e
# capital politico = reeleicao (dummy unica), com os mesmos controles
# individuais. Reajusta-se AQUELA especificacao nos MESMOS paineis e na MESMA
# amostra (total_votos>0) de cada recorte/porte, para a comparacao ser de
# especificacao e nao de dado. No vereador, l_apto entra nas duas (faz parte do
# desenho por porte, nao da mudanca comparada). AIC e' comparavel (mesma
# amostra, mesma familia NB2).
# Comparacao reportada, por recorte/porte:
#   - elasticidade log1p unica da monografia vs dose intensiva atual (entre
#     usuarios) e efeito combinado atual (fator no gasto de referencia unico);
#   - reeleicao na monografia vs reeleicao + l_votos_mesmo_cargo_ultima atuais;
#   - AIC e theta das duas especificacoes.
# Saida: saidas/comparacao_monografia_<TAG>.csv (uma tabela longa por recorte).
# =============================================================================

comparar_monografia <- function(M){
  spec <- M$spec; df <- copy(M$df_est)
  for (cl in CATS) set(df, j=paste0("lp_",cl), value=log1p(df[[cl]]))
  termos_mono <- c(paste0("lp_",CATS), "reeleicao", intersect(CONTROLES, names(df)),
                   if (spec$ehver) "l_apto")
  fc <- filtrar_constantes(df, termos_mono)
  f  <- as.formula(paste("total_votos ~", paste(fc$manter, collapse=" + ")))
  m  <- tryCatch(fit_nb(f, df), error=function(e){ message("  [mono erro fit] ",e$message); NULL })
  if (is.null(m)) return(NULL)
  s  <- summary(m)$coefficients$cond
  bm <- function(t) if (t %in% rownames(s)) s[t,1] else NA_real_
  pm <- function(t) if (t %in% rownames(s)) s[t,4] else NA_real_
  ca <- M$coef; ea <- M$efeito
  ba <- function(t) if (t %in% ca$termo) ca[termo==t, estimativa] else NA_real_
  pa <- function(t) if (t %in% ca$termo) ca[termo==t, p] else NA_real_
  linhas <- list()
  addl <- function(medida, vm, pvm, va, pva) linhas[[length(linhas)+1]] <<- data.table(
    medida=medida, monografia=vm, p_monografia=pvm, sig_monografia=estrelas(pvm),
    atual=va, p_atual=pva, sig_atual=estrelas(pva))
  for (cl in CATS){
    addl(paste0("elasticidade_",cl," (mono: log1p unico; atual: dose intensiva lg)"),
         bm(paste0("lp_",cl)), pm(paste0("lp_",cl)), ba(paste0("lg_",cl)), pa(paste0("lg_",cl)))
    e <- ea[categoria==cl]
    addl(paste0("efeito_combinado_",cl," (fator de votos no gasto de referencia unico; so atual)"),
         NA_real_, NA_real_, e$efeito_mult, e$p)
  }
  addl("reeleicao", bm("reeleicao"), pm("reeleicao"), ba("reeleicao"), pa("reeleicao"))
  addl("l_votos_mesmo_cargo_ultima (so atual)", NA_real_, NA_real_,
       ba("l_votos_mesmo_cargo_ultima"), pa("l_votos_mesmo_cargo_ultima"))
  addl("AIC", AIC(m), NA_real_, M$meta$aic, NA_real_)
  addl("theta", as.numeric(glmmTMB::sigma(m)), NA_real_, M$meta$theta, NA_real_)
  out <- cbind(tag=spec$tag, cargo=spec$cargo, ano=spec$ano,
               porte=ifelse(is.na(spec$porte),"",spec$porte),
               n=nrow(df), rbindlist(linhas))
  fwrite(out, file.path(DIR_SAIDA, paste0("comparacao_monografia_",spec$tag,".csv")))
  out
}

# ------------------------------- EXECUCAO -----------------------------------
comp_mono <- rbindlist(lapply(MODELOS, comparar_monografia), fill=TRUE)
fwrite(comp_mono, file.path(DIR_SAIDA, "comparacao_monografia_resumo.csv"))
cat("\n[07] comparacao com a especificacao da monografia concluida:",
    uniqueN(comp_mono$tag), "recortes/portes.\n")
