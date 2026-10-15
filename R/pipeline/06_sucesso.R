# =============================================================================
# 06_sucesso.R  -  Probabilidade de eleicao (logit de Firth)
# -----------------------------------------------------------------------------
# Logit de Firth (penalizado, robusto a separacao e a evento raro) de eleito,
# com os mesmos blocos do modelo de votos (margens de gasto + capital + controles
# + log(apto) no vereador) e a forca de lista (votos dos demais da legenda no
# mesmo recorte, leave-one-out). Deputado por recorte; vereador por porte.
# pl=FALSE: inferencia de Wald sobre o ajuste de Firth (perfis caros e instaveis
# em amostra grande); os estimadores de ponto sao os mesmos.
# =============================================================================

coef_firth <- function(m){ se<-sqrt(diag(vcov(m)))
  data.table(termo=names(coef(m)), estimativa=as.numeric(coef(m)), ep=as.numeric(se),
             z=as.numeric(coef(m)/se), p=as.numeric(m$prob), sig=estrelas(as.numeric(m$prob))) }

ajustar_sucesso <- function(M){
  spec<-M$spec; d <- copy(M$df_full)[deferido==1]
  if (nrow(d)<30 || sum(d$eleito)<3) { cat("  [",spec$tag,"] amostra/eventos insuficientes; pulado.\n"); return(NULL) }
  d[, votos_lista_loo := sum(total_votos) - total_votos, by=.(lista, cod_mun)]
  set(d, j="l_lista", value=log1p(d$votos_lista_loo))
  hur <- as.vector(rbind(paste0("usou_",CATS), paste0("lg_",CATS)))
  cap <- c("reeleicao", grep("^l_votos_", names(d), value=TRUE))
  ctl <- intersect(CONTROLES, names(d))
  termos <- c(hur, cap, ctl, if (spec$ehver) "l_apto", "l_lista")
  fc <- filtrar_constantes(d, termos)
  f  <- as.formula(paste("eleito ~", paste(fc$manter, collapse=" + ")))
  cat(sprintf("\n[sucesso] %s | n=%d eleitos=%d | caidos: %s\n", spec$tag, nrow(d), sum(d$eleito),
              if(length(fc$caidos)) paste(fc$caidos,collapse=", ") else "(nenhum)"))
  m <- tryCatch(logistf::logistf(f, data=d, pl=FALSE, control=logistf::logistf.control(maxit=1000)),
                error=function(e){ message("  [erro Firth] ",e$message); NULL })
  if (is.null(m)) return(NULL)
  p <- tryCatch(as.numeric(predict(m, type="response")), error=function(e) as.numeric(m$predict))
  auc <- tryCatch(as.numeric(pROC::auc(pROC::roc(d$eleito, p, quiet=TRUE))), error=function(e) NA_real_)
  ct <- cbind(tag=spec$tag, cargo=spec$cargo, ano=spec$ano,
              porte=ifelse(is.na(spec$porte),"",spec$porte), coef_firth(m))
  fwrite(ct, file.path(DIR_SAIDA, paste0("coef_sucesso_",spec$tag,".csv")))
  data.table(tag=spec$tag, cargo=spec$cargo, ano=spec$ano,
             porte=ifelse(is.na(spec$porte),"",spec$porte),
             n=nrow(d), eleitos=sum(d$eleito), auc=auc,
             max_abs_coef=max(abs(coef(m)),na.rm=TRUE))
}

# ------------------------------- EXECUCAO -----------------------------------
diag <- rbindlist(lapply(MODELOS, ajustar_sucesso), fill=TRUE)
fwrite(diag, file.path(DIR_SAIDA, "sucesso_resumo.csv"))
cat("\n[06] modelos de sucesso (Firth) concluidos.\n"); print(diag[, .(tag,n,eleitos,auc=round(auc,3))])
