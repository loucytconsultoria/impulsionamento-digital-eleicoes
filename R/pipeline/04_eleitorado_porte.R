# =============================================================================
# 04_eleitorado_porte.R  -  Eleitorado apto, porte e coeficiente de log(apto)
# -----------------------------------------------------------------------------
# Documenta as faixas de porte por eleitorado apto (15k/75k/750k) e reporta o
# coeficiente LIVRE de log(apto) estimado em cada porte do vereador (decisao 5).
# Onde o eleitorado nao varia (METROPOLE, um municipio), o termo cai e fica
# registrado.
# =============================================================================

# Faixas de porte (limites em eleitorado apto).
faixas <- data.table(
  porte=PORTE_LAB,
  limite_inferior=c(0,15000,75000,750000),
  limite_superior=c(15000,75000,750000,Inf))
fwrite(faixas, file.path(DIR_SAIDA,"porte_faixas.csv"))

# Resumo do eleitorado/porte por ano (a partir dos paineis do vereador).
res_porte <- list(); coef_apto <- list()
for (tg in names(MODELOS)){
  M<-MODELOS[[tg]]; if (!M$spec$ehver) next
  d <- M$df_full
  res_porte[[tg]] <- data.table(ano=M$spec$ano, porte=M$spec$porte,
    n_candidatos=nrow(d), n_municipios=uniqueN(d$cod_mun),
    apto_min=min(d$apto,na.rm=TRUE), apto_mediana=stats::median(d$apto,na.rm=TRUE),
    apto_max=max(d$apto,na.rm=TRUE))
  # coeficiente de log(apto): estimado quando varia; cai (constante) na METROPOLE.
  ct <- M$coef[termo=="l_apto"]
  if (nrow(ct)==1)
    coef_apto[[tg]] <- data.table(ano=M$spec$ano, porte=M$spec$porte,
      coef_log_apto=ct$estimativa, ep=ct$ep, z=ct$z, p=ct$p, sig=ct$sig,
      rejeita_1 = abs((ct$estimativa-1)/ct$ep) > 1.96, situacao="estimado")
  else
    coef_apto[[tg]] <- data.table(ano=M$spec$ano, porte=M$spec$porte,
      coef_log_apto=NA_real_, ep=NA_real_, z=NA_real_, p=NA_real_, sig="",
      rejeita_1=NA, situacao="constante (caiu do modelo)")
}
rp <- rbindlist(res_porte, fill=TRUE)[order(ano, factor(porte, levels=PORTE_LAB))]
ca <- rbindlist(coef_apto, fill=TRUE)[order(ano, factor(porte, levels=PORTE_LAB))]
fwrite(rp, file.path(DIR_SAIDA,"eleitorado_porte.csv"))
fwrite(ca, file.path(DIR_SAIDA,"coef_logapto_porte.csv"))
cat("\n[04] eleitorado/porte e coef de log(apto) por porte:\n"); print(ca)
