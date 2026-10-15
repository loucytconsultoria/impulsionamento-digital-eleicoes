# =============================================================================
# 03_saturacao.R  -  Saturacao e curvas comparativas das TRES categorias de gasto
# -----------------------------------------------------------------------------
# Tudo deriva do modelo de votos (hurdle) de 02. Limiar de custo por voto pela
# MEDIA dos custos individuais (gasto_total/votos), eleitos e geral (sem
# mediana). Para CADA categoria (impulsionamento, tradicional, operacional):
# curva de votos previstos e de custo marginal por voto da margem intensiva,
# num perfil de referencia (demais variaveis na media da amostra; usuario da
# categoria; vereador com apto = mediana do porte).
# Derivacao (documentada no relatorio): entre usuarios,
#   votos(g) = exp(eta_ref + beta*log g) = K * g^beta, K = exp(eta_ref);
#   custo marginal por voto = d(gasto)/d(votos) = g^(1-beta) / (K*beta);
#   ponto de saturacao ANALITICO g* = (K*beta*L)^(1/(1-beta)), L = limiar.
# (Auditoria item 5: a formula fechada substitui o argmin no grid, que
# superestimava g* em ate um passo; o grid segue so para tracar as curvas.)
# (Auditoria item 3: g* e' mascarado quando a dose intensiva da categoria nao
# e' distinta de zero a 5%, porque g* colapsa quando beta tende a 0.)
# Figuras COMPARATIVAS: as tres categorias no mesmo grafico. Deputado por
# recorte; vereador por porte.
# =============================================================================

# Custo por voto individual (gasto_total/votos): MEDIA, eleitos e geral.
custo_voto <- function(df, grupo=c("eleitos","geral")){
  grupo<-match.arg(grupo)
  d <- if (grupo=="eleitos") df[eleito==1 & total_votos>0] else df[total_votos>0]
  r <- d$gasto_total/d$total_votos; r <- r[is.finite(r) & r>0]
  if (!length(r)) return(NA_real_)
  mean(r)
}

# Curva da margem intensiva de UMA categoria: votos previstos e custo marginal
# por voto, num perfil de referencia (demais variaveis na media; usuario da
# categoria; vereador com apto = mediana do porte). K = votos previstos em g=1.
curva_cat <- function(M, cat){
  m<-M$modelo; df<-M$df_est; vars<-M$termos
  b <- glmmTMB::fixef(m)$cond
  tu <- paste0("usou_",cat); tl <- paste0("lg_",cat)
  if (!(tl %in% names(b))) return(NULL)     # dose caiu do modelo: sem curva
  beta <- as.numeric(b[tl])
  users <- df[[cat]][df[[cat]]>0]
  if (length(users) < 30) return(NULL)
  gmax <- as.numeric(stats::quantile(users, 0.99)); if (!is.finite(gmax) || gmax<=1) gmax <- max(users)
  grid <- seq(1, gmax, length.out=500)
  ref <- as.data.frame(lapply(vars, function(v) mean(df[[v]], na.rm=TRUE))); names(ref)<-vars
  nd <- ref[rep(1L,length(grid)),,drop=FALSE]
  nd[[tu]] <- 1; nd[[tl]] <- log(grid)
  apto_ref <- NA_real_
  if (M$spec$ehver && "l_apto" %in% vars){ apto_ref<-stats::median(df$apto,na.rm=TRUE); nd$l_apto<-log(apto_ref) }
  votos <- as.numeric(predict(m, newdata=nd, type="response"))
  K <- votos[1]                             # grid[1]=1 => votos(1) = K
  cm <- grid^(1-beta)/(K*beta)              # custo marginal analitico
  p_beta <- M$coef[termo==tl, p]; if (!length(p_beta)) p_beta <- NA_real_
  list(categoria=cat,
       curva=data.table(categoria=cat, gasto=grid, votos_previstos=votos, custo_marginal=cm),
       beta=beta, p_beta=p_beta, K=K, apto_ref=apto_ref, n_usuarios=length(users), gmax=gmax)
}

# Ponto de saturacao analitico: menor gasto em que o custo marginal por voto
# atinge o limiar L. NA (com motivo) quando beta nao e' positivo ou nao e'
# distinto de zero a 5%.
ponto_sat <- function(cv, L){
  if (is.null(cv) || is.na(L)) return(NA_real_)
  if (!is.finite(cv$beta) || cv$beta<=0 || cv$beta>=1) return(NA_real_)
  if (is.finite(cv$p_beta) && cv$p_beta>=0.05) return(NA_real_)
  (cv$K * cv$beta * L)^(1/(1-cv$beta))
}
motivo_mascara <- function(cv){
  if (is.null(cv)) return("sem curva")
  if (!is.finite(cv$beta) || cv$beta<=0) return("dose intensiva nao positiva")
  if (is.finite(cv$p_beta) && cv$p_beta>=0.05) return("dose intensiva nao distinta de zero a 5%")
  ""
}

CORES  <- c(impulsionamento="#1f77b4", tradicional="#d62728", operacional="#2ca02c")
ROTULO <- c(impulsionamento="Impulsionamento", tradicional="Tradicional", operacional="Operacional")

plot_custo_comp <- function(cvs, tag){
  png(file.path(DIR_FIG, paste0("custo_marginal_categorias_",tag,".png")), 1000, 680, res=120)
  on.exit(dev.off())
  dat <- lapply(cvs, function(cv) cv$curva[is.finite(custo_marginal) & custo_marginal>0])
  xr <- range(unlist(lapply(dat, function(d) range(d$gasto))))
  yr <- range(unlist(lapply(dat, function(d) range(d$custo_marginal))))
  plot(NA, xlim=xr, ylim=yr, xlab="Gasto na categoria (R$ da base)",
       ylab="Custo marginal por voto (R$)",
       main=paste("Custo marginal por voto por categoria de gasto\n",tag))
  for (cv in cvs) lines(dat[[cv$categoria]]$gasto, dat[[cv$categoria]]$custo_marginal,
                        lwd=2, col=CORES[cv$categoria])
  legend("topleft", legend=ROTULO[vapply(cvs, `[[`, "", "categoria")],
         col=CORES[vapply(cvs, `[[`, "", "categoria")], lwd=2, bty="n")
}
plot_votos_comp <- function(cvs, tag){
  png(file.path(DIR_FIG, paste0("votos_previstos_categorias_",tag,".png")), 1000, 680, res=120)
  on.exit(dev.off())
  xr <- range(unlist(lapply(cvs, function(cv) range(cv$curva$gasto))))
  yr <- range(unlist(lapply(cvs, function(cv) range(cv$curva$votos_previstos))))
  plot(NA, xlim=xr, ylim=yr, xlab="Gasto na categoria (R$ da base)", ylab="Votos previstos",
       main=paste("Votos previstos vs gasto, por categoria\n",tag))
  for (cv in cvs) lines(cv$curva$gasto, cv$curva$votos_previstos, lwd=2, col=CORES[cv$categoria])
  legend("bottomright", legend=ROTULO[vapply(cvs, `[[`, "", "categoria")],
         col=CORES[vapply(cvs, `[[`, "", "categoria")], lwd=2, bty="n")
}

# ------------------------------- EXECUCAO -----------------------------------
sat_res <- list()
for (tg in names(MODELOS)){
  M<-MODELOS[[tg]]; df<-M$df_est
  lim <- c(eleitos_media = custo_voto(df,"eleitos"),
           geral_media   = custo_voto(df,"geral"))
  cvs <- list()
  for (cat in CATS){
    cv <- tryCatch(curva_cat(M, cat), error=function(e){message("  curva ",tg," ",cat,": ",e$message); NULL})
    if (is.null(cv)) next
    cvs[[cat]] <- cv
    se <- ponto_sat(cv, lim["eleitos_media"]); sg <- ponto_sat(cv, lim["geral_media"])
    sat_res[[paste(tg,cat)]] <- data.table(
      tag=tg, cargo=M$spec$cargo, ano=M$spec$ano,
      porte=ifelse(is.na(M$spec$porte),"",M$spec$porte), categoria=cat,
      beta_intensiva=cv$beta, p_beta=cv$p_beta, n_usuarios=cv$n_usuarios, K_ref=cv$K,
      custo_eleitos_media=lim["eleitos_media"], custo_geral_media=lim["geral_media"],
      sat_eleitos=se, sat_geral=sg,
      sat_eleitos_na_faixa=is.finite(se) & se<=cv$gmax,
      sat_geral_na_faixa  =is.finite(sg) & sg<=cv$gmax,
      gasto_q99=cv$gmax, apto_ref=cv$apto_ref, mascara=motivo_mascara(cv))
  }
  if (length(cvs)){
    fwrite(cbind(tag=tg, cargo=M$spec$cargo, ano=M$spec$ano,
                 porte=ifelse(is.na(M$spec$porte),"",M$spec$porte),
                 rbindlist(lapply(cvs, `[[`, "curva"))),
           file.path(DIR_SAIDA, paste0("curva_categorias_",tg,".csv")))
    pos <- cvs[vapply(cvs, function(cv) is.finite(cv$beta) && cv$beta>0, logical(1))]
    if (length(pos)){                       # so plota categorias com dose positiva
      tryCatch(plot_custo_comp(pos,tg), error=function(e) message("  plot custo ",tg,": ",e$message))
      tryCatch(plot_votos_comp(pos,tg), error=function(e) message("  plot votos ",tg,": ",e$message))
    }
    if (length(pos) < length(cvs))
      cat("  [",tg,"] categorias sem dose positiva (fora do grafico): ",
          paste(setdiff(names(cvs), names(pos)), collapse=", "), "\n")
  }
}
fwrite(rbindlist(sat_res, fill=TRUE), file.path(DIR_SAIDA, "saturacao_resumo.csv"))
cat("\n[03] saturacao (formula fechada) e curvas comparativas das tres categorias concluidas.\n")
