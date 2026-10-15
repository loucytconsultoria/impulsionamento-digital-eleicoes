# =============================================================================
# 05_moderadores.R  -  Moderadores municipais, DENTRO de cada porte
# -----------------------------------------------------------------------------
# So vereador, e so por porte (nunca juntando portes). Para cada moderador
# (densidade e penetracao de internet; IDHM e Gini exploratorios) testa-se a
# interacao com a dose intensiva de CADA um dos tres gastos, sobre o hurdle do
# porte. Reporta coef, EP, p, LRT e dAIC, e a comparacao entre os tres gastos no
# mesmo porte. METROPOLE (um municipio) tem moderadores constantes e e' pulada.
# =============================================================================

MODERADORES <- c("densidade","penetracao_internet","idhm","gini")

# Moderadores municipais: dicionarios offline (por codigo IBGE) + crosswalk
# TSE<->IBGE (abjData). Sem chamada de API em tempo de execucao (determinismo).
carregar_moderadores <- function(){
  dens <- fread(file.path(DIR_DICT,"densidade_municipios_PR.csv"), colClasses=list(character="cod_ibge"))
  ex   <- fread(file.path(DIR_DICT,"dados_municipios_extra.csv"),  colClasses=list(character="cod_mun"))
  setnames(ex,"cod_mun","cod_ibge")
  mod <- merge(dens, ex, by="cod_ibge", all=TRUE)
  e<-new.env(); utils::data("muni", package="abjData", envir=e)
  xw <- as.data.table(e$muni)[, .(cod_ibge=as.character(muni_id), cod_mun=as.character(tse_id))]
  mod <- merge(mod, xw, by="cod_ibge", all.x=TRUE)[!is.na(cod_mun)]
  unique(mod[, .(cod_mun, densidade, penetracao_internet, idhm, gini)], by="cod_mun")
}
MOD_TAB <- carregar_moderadores()

# Teste da interacao moderador x dose de um gasto, sobre o hurdle do porte.
testar_interacao <- function(base_terms, df, md, cl){
  vazio <- function(nota) data.table(moderador=md, gasto=cl, coef_interacao=NA_real_, ep=NA_real_,
                                      p=NA_real_, lrt_p=NA_real_, dAIC=NA_real_, n=nrow(df), nota=nota)
  lgcl <- paste0("lg_",cl)
  if (!(lgcl %in% base_terms)) return(vazio("gasto ausente no porte"))
  d <- df[is.finite(get(md))]
  if (length(unique(d[[md]]))<2) return(vazio("moderador constante"))
  f0 <- as.formula(paste("total_votos ~", paste(c(base_terms, md), collapse=" + ")))
  f1 <- as.formula(paste("total_votos ~", paste(c(base_terms, md, paste0(md,":",lgcl)), collapse=" + ")))
  m0 <- tryCatch(fit_nb(f0,d), error=function(e) NULL)
  m1 <- tryCatch(fit_nb(f1,d), error=function(e) NULL)
  if (is.null(m0) || is.null(m1)) return(vazio("nao convergiu"))
  s <- summary(m1)$coefficients$cond
  it <- intersect(c(paste0(md,":",lgcl), paste0(lgcl,":",md)), rownames(s))
  a  <- tryCatch(stats::anova(m0,m1), error=function(e) NULL)
  lrtp <- if (!is.null(a) && "Pr(>Chisq)" %in% names(a)) a[["Pr(>Chisq)"]][2] else NA_real_
  data.table(moderador=md, gasto=cl,
             coef_interacao=if(length(it)) s[it[1],1] else NA_real_,
             ep=if(length(it)) s[it[1],2] else NA_real_,
             p =if(length(it)) s[it[1],4] else NA_real_,
             lrt_p=lrtp, dAIC=AIC(m1)-AIC(m0), n=nrow(d), nota="")
}

# ------------------------------- EXECUCAO -----------------------------------
mod_res <- list()
for (tg in names(MODELOS)){
  M<-MODELOS[[tg]]; if (!M$spec$ehver) next
  if (M$spec$porte=="METROPOLE"){ cat("  [",tg,"] METROPOLE (1 municipio): moderadores constantes, pulado.\n"); next }
  df <- merge(copy(M$df_est), MOD_TAB, by="cod_mun", all.x=TRUE)
  base_terms <- M$termos
  cat(sprintf("\n[moderadores] %s (n=%d)\n", tg, nrow(df)))
  for (md in MODERADORES){
    rows <- rbindlist(lapply(CATS, function(cl) testar_interacao(base_terms, df, md, cl)), fill=TRUE)
    rows <- cbind(tag=tg, ano=M$spec$ano, porte=M$spec$porte, rows)
    rows[, sig := estrelas(p)]
    mod_res[[paste(tg,md)]] <- rows
  }
}
mod_all <- rbindlist(mod_res, fill=TRUE)
fwrite(mod_all, file.path(DIR_SAIDA,"moderadores_resumo.csv"))
# Uma tabela por porte/ano (comparacao dos 3 gastos no mesmo porte).
for (tg in unique(mod_all$tag))
  fwrite(mod_all[tag==tg], file.path(DIR_SAIDA, paste0("moderadores_",tg,".csv")))
cat("\n[05] moderadores por porte concluidos:", nrow(mod_all), "testes (moderador x gasto).\n")
