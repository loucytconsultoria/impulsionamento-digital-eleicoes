# =============================================================================
# 02_modelos_votos.R  -  Modelo de votos (UNICO): hurdle de gasto em NB2
# -----------------------------------------------------------------------------
# Para cada recorte (deputado) e cada porte (vereador): Binomial Negativa (NB2)
# de total_votos com, por categoria de gasto, a margem extensiva (usou) e a dose
# intensiva (log do gasto entre usuarios); mais o capital politico (reeleicao +
# log1p dos votos anteriores por conjunto de cargos) e os controles. No vereador,
# log(apto) entra como covariavel livre. Termos constantes na coorte caem e ficam
# logados. Reporta coeficientes, VIF por termo e efeito combinado por categoria.
# Guarda os modelos ajustados em MODELOS para 03-06. E' o UNICO modelo de votos.
# =============================================================================

CATS <- c("impulsionamento","tradicional","operacional")
CONTROLES <- c("masculino","superior_completo","corbranca","esquerda","direita")
PORTE_BRK <- c(-Inf,15000,75000,750000,Inf)
PORTE_LAB <- c("PEQUENO","MEDIO","GRANDE","METROPOLE")
estrelas <- function(p) ifelse(is.na(p),"",ifelse(p<.001,"***",ifelse(p<.01,"**",ifelse(p<.05,"*",ifelse(p<.1,".","")))))

# Recortes do modelo (deputado por recorte; vereador por porte).
MODSPEC <- list(
  list(tag="PR_2018_DEPUTADO_FEDERAL",  ano=2018, cargo="DEPUTADO FEDERAL",  ehver=FALSE, porte=NA),
  list(tag="PR_2022_DEPUTADO_FEDERAL",  ano=2022, cargo="DEPUTADO FEDERAL",  ehver=FALSE, porte=NA),
  list(tag="PR_2018_DEPUTADO_ESTADUAL", ano=2018, cargo="DEPUTADO ESTADUAL", ehver=FALSE, porte=NA),
  list(tag="PR_2022_DEPUTADO_ESTADUAL", ano=2022, cargo="DEPUTADO ESTADUAL", ehver=FALSE, porte=NA)
)
for (ano in c(2020,2024)) for (pt in PORTE_LAB)
  MODSPEC[[length(MODSPEC)+1]] <- list(tag=sprintf("PR_%d_VEREADOR_%s",ano,pt),
    ano=ano, cargo="VEREADOR", ehver=TRUE, porte=pt)

# --------------------------- preparo da base --------------------------------
# Le o painel tratado e deriva as colunas do modelo (margens de gasto, log(apto),
# porte). NAO processa bruto. Subconjunto por porte no vereador.
preparar_modelo <- function(ano, cargo){
  tagp <- sprintf("PR_%d_%s", ano, gsub(" ","_",toupper(cargo)))
  f <- file.path(DIR_TRATADO, paste0("painel_",tagp,".csv"))
  if (!file.exists(f)) stop("Painel ausente: ", f, " (rode 01_tratamento.R).")
  df <- fread(f, colClasses=list(character=c("sq","cod_mun","partido","lista","nome")))
  for (cl in CATS){ set(df, j=paste0("usou_",cl), value=as.integer(df[[cl]]>0))
                    set(df, j=paste0("lg_",cl),   value=ifelse(df[[cl]]>0, log(df[[cl]]), 0)) }
  if (grepl("VEREADOR",toupper(cargo))){
    set(df, j="l_apto", value=log(df$apto))
    set(df, j="porte",  value=cut(df$apto, PORTE_BRK, labels=PORTE_LAB))
  }
  df[]
}

# Termos candidatos do modelo (na ordem de leitura).
termos_modelo <- function(df, ehver){
  hur <- as.vector(rbind(paste0("usou_",CATS), paste0("lg_",CATS)))
  cap <- c("reeleicao", grep("^l_votos_", names(df), value=TRUE))
  ctl <- intersect(CONTROLES, names(df))
  c(hur, cap, ctl, if (ehver) "l_apto")
}
# Remove termos constantes na coorte (caem do modelo) e loga.
filtrar_constantes <- function(df, termos){
  manter <- termos[vapply(termos, function(t) length(unique(df[[t]][is.finite(df[[t]])]))>1, logical(1))]
  list(manter=manter, caidos=setdiff(termos, manter))
}

fit_nb <- function(f, data) glmmTMB::glmmTMB(f, data=data, family=glmmTMB::nbinom2)
coef_tab <- function(m){ s<-summary(m)$coefficients$cond
  data.table(termo=rownames(s), estimativa=s[,1], ep=s[,2], z=s[,3], p=s[,4], sig=estrelas(s[,4])) }

# VIF por termo (manual; car ausente). VIF_j = diag(solve(cor(X)))_j sobre a
# matriz de desenho sem intercepto. Alto so' entre as duas margens da mesma
# categoria (usou x lg), nao entre categorias/controles.
vif_termos <- function(f, df){
  X <- tryCatch(model.matrix(delete.response(terms(f)), data=df), error=function(e) NULL)
  if (is.null(X)) return(NULL)
  X <- X[, colnames(X)!="(Intercept)", drop=FALSE]
  keep <- apply(X, 2, function(c) length(unique(c))>1); X <- X[, keep, drop=FALSE]
  R <- tryCatch(cor(X), error=function(e) NULL); if (is.null(R)) return(NULL)
  vi <- tryCatch(diag(solve(R)), error=function(e) rep(NA_real_, ncol(X)))
  data.table(termo=colnames(X), vif=as.numeric(vi))
}

# Gasto de referencia UNICO do cenario (recorte/porte): mediana do gasto positivo
# por categoria, agrupando as tres categorias entre quem gastou; um valor,
# aplicado igual as tres, na moeda da base do escopo.
gasto_ref_unico <- function(df_est)
  stats::median(unlist(lapply(CATS, function(cl){ g<-df_est[[cl]]; g[g>0] }), use.names=FALSE))

# Efeito combinado por categoria NO GASTO DE REFERENCIA UNICO: fator
# multiplicativo de votos = exp(b_usou + b_lg*log(g_ref_unico)). EP por
# delta-method sobre (usou, lg). Os fatores das tres categorias ficam
# comparaveis no mesmo dinheiro.
efeito_combinado <- function(m, df_est){
  b <- glmmTMB::fixef(m)$cond; V <- vcov(m)$cond
  gref <- gasto_ref_unico(df_est); lref <- log(gref)
  rbindlist(lapply(CATS, function(cl){
    tu<-paste0("usou_",cl); tl<-paste0("lg_",cl)
    if (!(tu %in% names(b))) return(data.table(categoria=cl, g_ref=gref, b_usou=NA_real_,
        b_lg=NA_real_, efeito_log=NA_real_, ep=NA_real_, z=NA_real_, p=NA_real_, sig="", efeito_mult=NA_real_))
    has_lg <- tl %in% names(b)
    cc <- if (has_lg) c(1, lref) else 1
    nm <- if (has_lg) c(tu, tl) else tu
    est <- sum(b[nm]*cc); va <- as.numeric(t(cc) %*% V[nm,nm,drop=FALSE] %*% cc)
    se <- sqrt(va); z <- est/se; p <- 2*pnorm(-abs(z))
    data.table(categoria=cl, g_ref=gref, b_usou=unname(b[tu]),
               b_lg=if(has_lg) unname(b[tl]) else NA_real_,
               efeito_log=est, ep=se, z=z, p=p, sig=estrelas(p), efeito_mult=exp(est))
  }))
}

# Efeito conjunto de incumbencia (auditoria, item 2): a dummy de reeleicao e a
# votacao anterior do mesmo cargo sao colineares (todo incumbente tem votacao
# anterior positiva), entao a leitura correta e o efeito conjunto
# exp(b_reeleicao + b_lvotos * l_tipico), com l_tipico = mediana de
# l_votos_mesmo_cargo_ultima entre os incumbentes da amostra, contra um
# desafiante sem historico. EP por delta-method.
efeito_incumbencia <- function(m, df_est){
  b <- glmmTMB::fixef(m)$cond; V <- vcov(m)$cond
  nm <- c("reeleicao","l_votos_mesmo_cargo_ultima")
  if (!all(nm %in% names(b))) return(NULL)
  li <- df_est$l_votos_mesmo_cargo_ultima[df_est$reeleicao==1]; li <- li[is.finite(li) & li>0]
  if (!length(li)) return(NULL)
  ltip <- stats::median(li); cc <- c(1, ltip)
  est <- sum(b[nm]*cc); va <- as.numeric(t(cc) %*% V[nm,nm,drop=FALSE] %*% cc)
  se <- sqrt(va); z <- est/se; p <- 2*pnorm(-abs(z))
  data.table(b_reeleicao=unname(b["reeleicao"]), b_lvotos=unname(b["l_votos_mesmo_cargo_ultima"]),
             l_votos_tipico=ltip, votos_anteriores_tipicos=expm1(ltip), n_incumbentes=length(li),
             efeito_log=est, ep=se, z=z, p=p, sig=estrelas(p), fator=exp(est))
}

# Ajuste de um recorte/porte e salvamento das saidas do modelo de votos.
ajustar_votos <- function(spec){
  df0 <- preparar_modelo(spec$ano, spec$cargo)
  df  <- if (spec$ehver) df0[porte==spec$porte] else df0
  df_full <- copy(df)                                  # para o sucesso (06)
  df_est  <- df[total_votos>0]                         # amostra do modelo de votos
  termos  <- termos_modelo(df_est, spec$ehver)
  fc <- filtrar_constantes(df_est, termos)
  f  <- as.formula(paste("total_votos ~", paste(fc$manter, collapse=" + ")))
  cat(sprintf("\n[votos] %s | n=%d | termos=%d | caidos: %s\n",
              spec$tag, nrow(df_est), length(fc$manter),
              if(length(fc$caidos)) paste(fc$caidos,collapse=", ") else "(nenhum)"))
  m  <- tryCatch(fit_nb(f, df_est), error=function(e){ message("  [erro fit] ",e$message); NULL })
  if (is.null(m)) { cat("  modelo nao convergiu; recorte ignorado.\n"); return(NULL) }
  ct  <- coef_tab(m); vt <- vif_termos(f, df_est); ef <- efeito_combinado(m, df_est)
  inc <- efeito_incumbencia(m, df_est)
  meta <- data.table(tag=spec$tag, cargo=spec$cargo, ano=spec$ano,
                     porte=ifelse(is.na(spec$porte),"",spec$porte),
                     n=nrow(df_est), n_full=nrow(df_full), eleitos=sum(df_full$eleito),
                     theta=as.numeric(glmmTMB::sigma(m)), aic=AIC(m),
                     termos_caidos=ifelse(length(fc$caidos),paste(fc$caidos,collapse=";"),""))
  pref <- function(d) cbind(tag=spec$tag, cargo=spec$cargo, ano=spec$ano,
                            porte=ifelse(is.na(spec$porte),"",spec$porte), d)
  fwrite(pref(ct), file.path(DIR_SAIDA, paste0("coef_votos_",spec$tag,".csv")))
  if(!is.null(vt)) fwrite(pref(vt), file.path(DIR_SAIDA, paste0("vif_",spec$tag,".csv")))
  fwrite(pref(ef), file.path(DIR_SAIDA, paste0("efeito_combinado_",spec$tag,".csv")))
  MODELOS[[spec$tag]] <<- list(spec=spec, modelo=m, formula=f, df_est=df_est, df_full=df_full,
                               termos=fc$manter, coef=ct, vif=vt, efeito=ef, incumb=inc, meta=meta)
  invisible(meta)
}

# ------------------------------- EXECUCAO -----------------------------------
MODELOS <- list()
metas <- rbindlist(lapply(MODSPEC, ajustar_votos), fill=TRUE)
fwrite(metas, file.path(DIR_SAIDA, "modelos_votos_resumo.csv"))
# Painel-resumo do efeito combinado do impulsionamento por recorte/porte.
ef_imp <- rbindlist(lapply(MODELOS, function(M){
  e <- M$efeito[categoria=="impulsionamento"]
  cbind(tag=M$spec$tag, cargo=M$spec$cargo, ano=M$spec$ano,
        porte=ifelse(is.na(M$spec$porte),"",M$spec$porte), e) }), fill=TRUE)
fwrite(ef_imp, file.path(DIR_SAIDA, "efeito_combinado_impulsionamento.csv"))
# Efeito conjunto de incumbencia por recorte/porte (auditoria, item 2).
inc_all <- rbindlist(lapply(MODELOS, function(M){
  if (is.null(M$incumb)) return(NULL)
  cbind(tag=M$spec$tag, cargo=M$spec$cargo, ano=M$spec$ano,
        porte=ifelse(is.na(M$spec$porte),"",M$spec$porte), M$incumb) }), fill=TRUE)
fwrite(inc_all, file.path(DIR_SAIDA, "efeito_incumbencia.csv"))

# Sensibilidade da classificacao: a classe residual (nao_classificado) e as
# transferencias ficam FORA dos regressores. Para medir o efeito dessa escolha nos
# coeficientes das tres categorias, reajusta-se o hurdle ADICIONANDO o residual
# (usou + dose) e mede-se o deslocamento do efeito combinado de cada categoria.
sensibilidade_residual <- function(M){
  df <- copy(M$df_est)
  set(df, j="usou_nao_classificado", value=as.integer(df$nao_classificado>0))
  set(df, j="lg_nao_classificado",   value=ifelse(df$nao_classificado>0, log(df$nao_classificado), 0))
  extra <- c("usou_nao_classificado","lg_nao_classificado")
  extra <- extra[vapply(extra, function(t) length(unique(df[[t]]))>1, logical(1))]
  if (!length(extra)) return(NULL)
  f2 <- as.formula(paste("total_votos ~", paste(c(M$termos, extra), collapse=" + ")))
  m2 <- tryCatch(fit_nb(f2, df), error=function(e) NULL); if (is.null(m2)) return(NULL)
  ef2 <- efeito_combinado(m2, df)
  m <- merge(M$efeito[, .(categoria, efeito_log_base=efeito_log)],
             ef2[, .(categoria, efeito_log_com_residual=efeito_log)], by="categoria")
  m[, deslocamento := efeito_log_com_residual - efeito_log_base]
  cbind(tag=M$spec$tag, cargo=M$spec$cargo, ano=M$spec$ano,
        porte=ifelse(is.na(M$spec$porte),"",M$spec$porte), m)
}
sens <- rbindlist(lapply(MODELOS, sensibilidade_residual), fill=TRUE)
fwrite(sens, file.path(DIR_SAIDA, "sensibilidade_classificacao.csv"))
cat("[02] sensibilidade da classificacao: maior |deslocamento| =",
    round(max(abs(sens$deslocamento), na.rm=TRUE), 4), "(efeito combinado, escala log).\n")
cat("\n[02] modelos de votos:", length(MODELOS), "recortes/portes ajustados.\n")
