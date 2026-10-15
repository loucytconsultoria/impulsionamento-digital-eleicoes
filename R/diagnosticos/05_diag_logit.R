# =====================================================================
# 05_diag_logit.R -- bateria de diagnosticos dos modelos LOGIT
# (probabilidade de eleicao) do TCC.
# Blocos: discriminacao (AUC/ROC), calibracao (Hosmer-Lemeshow, Brier,
# intercepto e inclinacao de calibracao, Spiegelhalter), separacao e
# Firth, multicolinearidade, significancia conjunta (LRT), pseudo-R2,
# classificacao, forma funcional (linktest / Box-Tidwell), influencia e
# validacao (10-fold + otimismo por bootstrap).
# =====================================================================
# (pressupoe 00_setup.R carregado e FITS disponivel)

if (!exists("FITS")) FITS <- readRDS(file.path(DIR_TRAT, "fits_tcc.rds"))

ok <- function(x) !is.null(x) && !inherits(x, "try-error")
pv <- function(x) if (is.null(x) || length(x) == 0 || !is.finite(x)) NA_real_ else as.numeric(x)
B_BOOT  <- 200
K_FOLDS <- 10

# ---- 1. discriminacao, calibracao, classificacao ---------------------
diag_logit_geral <- function(f) {
  m <- f$m_logit; d <- f$dados
  if (!ok(m)) return(NULL)
  y <- d$eleito; p <- as.numeric(fitted(m)); n <- length(y)

  roc_obj <- try(pROC::roc(y, p, quiet = TRUE), silent = TRUE)
  auc <- if (ok(roc_obj)) as.numeric(pROC::auc(roc_obj)) else NA
  ic  <- if (ok(roc_obj)) try(as.numeric(pROC::ci.auc(roc_obj, method = "delong")), silent = TRUE) else NA

  # Hosmer-Lemeshow com varios numeros de grupos
  hl <- function(g) {
    h <- try(ResourceSelection::hoslem.test(y, p, g = g), silent = TRUE)
    if (!ok(h)) return(c(NA, NA, NA))
    c(unname(h$statistic), unname(h$parameter), pv(h$p.value))
  }
  hl10 <- hl(10); hl5 <- hl(5); hl15 <- hl(15)

  # calibracao: logit(p) como unico regressor
  lp <- qlogis(pmin(pmax(p, 1e-12), 1 - 1e-12))
  cal <- try(glm(y ~ lp, family = binomial()), silent = TRUE)
  cal_int <- if (ok(cal)) coef(cal)[1] else NA
  cal_slp <- if (ok(cal)) coef(cal)[2] else NA
  # intercepto de calibracao "na media" (slope fixo em 1)
  cal0 <- try(glm(y ~ offset(lp), family = binomial()), silent = TRUE)
  cal_int0 <- if (ok(cal0)) coef(cal0)[1] else NA

  brier <- mean((y - p)^2)
  brier_nulo <- mean((y - mean(y))^2)
  # Spiegelhalter z: padroniza o Brier sob H0 de calibracao perfeita
  num <- sum((y - p) * (1 - 2 * p))
  den <- sqrt(sum((1 - 2 * p)^2 * p * (1 - p)))
  sp_z <- if (den > 0) num / den else NA
  sp_p <- if (is.finite(sp_z)) 2 * pnorm(abs(sp_z), lower.tail = FALSE) else NA

  # pseudo-R2
  ll1 <- as.numeric(logLik(m)); ll0 <- as.numeric(logLik(update(m, . ~ 1)))
  r2mc  <- 1 - ll1 / ll0
  r2nag <- (1 - exp(2 * (ll0 - ll1) / n)) / (1 - exp(2 * ll0 / n))
  r2tjur <- mean(p[y == 1]) - mean(p[y == 0])

  # classificacao no ponto de Youden
  thr <- if (ok(roc_obj)) as.numeric(pROC::coords(roc_obj, "best", best.method = "youden",
                                                  ret = "threshold", transpose = TRUE))[1] else 0.5
  pred <- as.integer(p >= thr)
  vp <- sum(pred == 1 & y == 1); vn <- sum(pred == 0 & y == 0)
  fp <- sum(pred == 1 & y == 0); fn <- sum(pred == 0 & y == 1)

  # LRT completo vs restrito (significancia conjunta dos gastos) -- como no TCC
  lr <- if (ok(f$m_logit_restr)) try(lmtest::lrtest(m, f$m_logit_restr), silent = TRUE) else NULL
  lr_chi <- if (ok(lr)) abs(lr$Chisq[2]) else NA
  lr_df  <- if (ok(lr)) abs(lr$Df[2]) else NA
  lr_p   <- if (ok(lr)) pv(lr$`Pr(>Chisq)`[2]) else NA

  tibble(recorte = f$rc$id, rotulo = f$rc$rotulo, n = n,
         eventos = sum(y), taxa_evento = mean(y), epv = sum(y) / length(coef(m)),
         AUC = auc, AUC_ic_inf = if (length(ic) == 3) ic[1] else NA,
         AUC_ic_sup = if (length(ic) == 3) ic[3] else NA,
         HL10_stat = hl10[1], HL10_df = hl10[2], HL10_p = hl10[3],
         HL5_p = hl5[3], HL15_p = hl15[3],
         calib_intercepto = unname(cal_int), calib_inclinacao = unname(cal_slp),
         calib_intercepto_slope1 = unname(cal_int0),
         Brier = brier, Brier_nulo = brier_nulo, Brier_skill = 1 - brier / brier_nulo,
         Spiegelhalter_z = sp_z, Spiegelhalter_p = sp_p,
         R2_McFadden = r2mc, R2_Nagelkerke = r2nag, R2_Tjur = r2tjur,
         limiar_youden = thr, VP = vp, VN = vn, FP = fp, FN = fn,
         sensibilidade = vp / (vp + fn), especificidade = vn / (vn + fp),
         acuracia = (vp + vn) / n, acuracia_balanceada = (vp / (vp + fn) + vn / (vn + fp)) / 2,
         LRT_gastos_chi2 = lr_chi, LRT_gastos_df = lr_df, LRT_gastos_p = lr_p)
}

# ---- 2. separacao e Firth --------------------------------------------
diag_separacao <- function(f) {
  m <- f$m_logit; d <- f$dados
  if (!ok(m)) return(NULL)
  p <- fitted(m)
  s <- summary(m)$coefficients
  nome <- paste0("log1p(", f$vg[["impulsionamento"]], ")")

  b_mle <- if (nome %in% rownames(s)) s[nome, 1] else NA
  e_mle <- if (nome %in% rownames(s)) s[nome, 2] else NA
  b_f <- NA; e_f <- NA; p_f <- NA
  if (ok(f$m_logit_firth)) {
    fi <- f$m_logit_firth
    j <- match(nome, names(coef(fi)))
    if (!is.na(j)) { b_f <- coef(fi)[j]; e_f <- sqrt(diag(vcov(fi)))[j]; p_f <- fi$prob[j] }
  }
  tibble(recorte = f$rc$id, rotulo = f$rc$rotulo,
         n_prob_extrema = sum(p < 1e-6 | p > 1 - 1e-6),
         max_abs_coef = max(abs(s[, 1])), max_ep = max(s[, 2]),
         indicio_separacao = (sum(p < 1e-6 | p > 1 - 1e-6) > 0) | (max(abs(s[, 2])) > 10),
         beta_impuls_MLE = b_mle, ep_impuls_MLE = e_mle,
         p_impuls_MLE = if (nome %in% rownames(s)) s[nome, 4] else NA,
         beta_impuls_Firth = unname(b_f), ep_impuls_Firth = unname(e_f),
         p_impuls_Firth = unname(p_f))
}

# ---- 3. forma funcional (linktest e Box-Tidwell) ---------------------
diag_logit_forma <- function(f) {
  m <- f$m_logit; d <- f$dados
  if (!ok(m)) return(NULL)
  eta <- predict(m, type = "link")
  dl <- data.frame(y = d$eleito, eta = eta, eta2 = eta^2)
  ml <- try(glm(y ~ eta + eta2, data = dl, family = binomial()), silent = TRUE)
  p_link <- if (ok(ml)) coef(summary(ml))["eta2", 4] else NA

  # Box-Tidwell: adiciona z*log(z) para cada log-gasto (convencao 0*log0 = 0)
  d2 <- d
  novos <- character(0)
  for (v in unname(f$vg)) {
    z <- log1p(d2[[v]])
    nm <- paste0(".bt_", v)
    d2[[nm]] <- ifelse(z > 0, z * log(z), 0)
    novos <- c(novos, nm)
  }
  fbt <- update(f$f_logit, paste("~ . +", paste(novos, collapse = " + ")))
  environment(fbt) <- environment()
  mbt <- try(glm(fbt, data = d2, family = binomial()), silent = TRUE)
  p_bt <- if (ok(mbt)) {
    LR <- as.numeric(2 * (logLik(mbt) - logLik(m)))
    pchisq(max(LR, 0), df = length(novos), lower.tail = FALSE)
  } else NA

  tibble(recorte = f$rc$id, rotulo = f$rc$rotulo,
         linktest_p_eta2 = p_link, box_tidwell_p = p_bt)
}

# ---- 4. influencia ---------------------------------------------------
diag_logit_influencia <- function(f) {
  m <- f$m_logit
  if (!ok(m)) return(NULL)
  n <- nrow(f$dados); p <- length(coef(m))
  h <- hatvalues(m); cd <- cooks.distance(m)
  nome <- paste0("log1p(", f$vg[["impulsionamento"]], ")")
  dfb <- try(dfbeta(m), silent = TRUE)
  dfb_imp <- if (ok(dfb) && nome %in% colnames(dfb)) dfb[, nome] else rep(NA_real_, n)
  tibble(recorte = f$rc$id, rotulo = f$rc$rotulo, n = n,
         leverage_max = max(h), n_leverage_alto = sum(h > 2 * p / n),
         cook_max = max(cd, na.rm = TRUE), n_cook_alto = sum(cd > 4 / n, na.rm = TRUE),
         dfbeta_impuls_max_abs = max(abs(dfb_imp), na.rm = TRUE))
}

# ---- 5. validacao: 10-fold e otimismo por bootstrap ------------------
auc_de <- function(y, p) {
  if (length(unique(y)) < 2) return(NA_real_)
  as.numeric(pROC::auc(pROC::roc(y, p, quiet = TRUE)))
}

diag_logit_validacao <- function(f) {
  m <- f$m_logit; d <- f$dados
  if (!ok(m)) return(NULL)
  y <- d$eleito
  auc_ap <- auc_de(y, fitted(m))
  fl <- f$f_logit; environment(fl) <- environment()

  # k-fold estratificado
  set.seed(20260809)
  idx1 <- which(y == 1); idx0 <- which(y == 0)
  fold <- integer(length(y))
  fold[idx1] <- sample(rep_len(1:K_FOLDS, length(idx1)))
  fold[idx0] <- sample(rep_len(1:K_FOLDS, length(idx0)))
  pcv <- rep(NA_real_, length(y))
  for (k in 1:K_FOLDS) {
    mk <- try(glm(fl, data = d[fold != k, , drop = FALSE], family = binomial()), silent = TRUE)
    if (ok(mk)) pcv[fold == k] <- predict(mk, newdata = d[fold == k, , drop = FALSE], type = "response")
  }
  auc_cv <- auc_de(y, pcv)
  brier_cv <- mean((y - pcv)^2, na.rm = TRUE)

  # otimismo de Harrell por bootstrap
  set.seed(20260809)
  otim <- rep(NA_real_, B_BOOT)
  for (b in seq_len(B_BOOT)) {
    ib <- sample.int(nrow(d), nrow(d), replace = TRUE)
    db <- d[ib, , drop = FALSE]
    if (length(unique(db$eleito)) < 2) next
    mb <- try(suppressWarnings(glm(fl, data = db, family = binomial())), silent = TRUE)
    if (!ok(mb)) next
    a_boot <- auc_de(db$eleito, fitted(mb))
    a_orig <- try(auc_de(y, predict(mb, newdata = d, type = "response")), silent = TRUE)
    if (ok(a_orig)) otim[b] <- a_boot - a_orig
  }
  otimismo <- mean(otim, na.rm = TRUE)
  tibble(recorte = f$rc$id, rotulo = f$rc$rotulo,
         AUC_aparente = auc_ap, AUC_10fold = auc_cv, Brier_10fold = brier_cv,
         otimismo_bootstrap = otimismo, AUC_corrigida = auc_ap - otimismo,
         B = sum(!is.na(otim)))
}

# ---- 6. residuos binados e curva ROC (dados p/ grafico) --------------
dados_binados <- function(f, nbins = 20) {
  m <- f$m_logit
  if (!ok(m)) return(NULL)
  p <- fitted(m); r <- f$dados$eleito - p
  q <- cut(p, breaks = unique(quantile(p, probs = seq(0, 1, length.out = nbins + 1))),
           include.lowest = TRUE)
  tapply(seq_along(p), q, function(ix) {
    tibble(recorte = f$rc$id, rotulo = f$rc$rotulo, n_bin = length(ix),
           p_medio = mean(p[ix]), resid_medio = mean(r[ix]),
           obs_medio = mean(f$dados$eleito[ix]),
           se2 = 2 * sd(r[ix]) / sqrt(length(ix)))
  }) |> dplyr::bind_rows()
}

dados_roc <- function(f) {
  m <- f$m_logit
  if (!ok(m)) return(NULL)
  r <- try(pROC::roc(f$dados$eleito, as.numeric(fitted(m)), quiet = TRUE), silent = TRUE)
  if (!ok(r)) return(NULL)
  tibble(recorte = f$rc$id, rotulo = f$rc$rotulo,
         especificidade = r$specificities, sensibilidade = r$sensitivities)
}

# =====================================================================
# EXECUCAO
# =====================================================================
msg("=== diagnosticos dos modelos logit ===")
L_ger <- list(); L_sep <- list(); L_vif <- list(); L_forma <- list()
L_infl <- list(); L_val <- list(); L_bin <- list(); L_roc <- list()

for (id in names(FITS)) {
  f <- FITS[[id]]
  msg("  ", id)
  L_ger[[id]]   <- try(diag_logit_geral(f), silent = TRUE)
  L_sep[[id]]   <- try(diag_separacao(f), silent = TRUE)
  L_vif[[id]]   <- try(diag_vif(f, f$m_logit, "Logit (eleito)"), silent = TRUE)
  L_forma[[id]] <- try(diag_logit_forma(f), silent = TRUE)
  L_infl[[id]]  <- try(diag_logit_influencia(f), silent = TRUE)
  L_val[[id]]   <- try(diag_logit_validacao(f), silent = TRUE)
  L_bin[[id]]   <- try(dados_binados(f), silent = TRUE)
  L_roc[[id]]   <- try(dados_roc(f), silent = TRUE)
}

junta <- function(L) dplyr::bind_rows(Filter(function(x) !inherits(x, "try-error") && !is.null(x), L))

gravar(junta(L_ger),   "20_logit_discriminacao_calibracao.csv")
gravar(junta(L_sep),   "21_logit_separacao_firth.csv")
gravar(junta(L_vif),   "22_vif_modelos_logit.csv")
gravar(junta(L_forma), "23_logit_forma_funcional.csv")
gravar(junta(L_infl),  "24_logit_influencia.csv")
gravar(junta(L_val),   "25_logit_validacao.csv")
gravar(junta(L_bin),   "26_logit_residuos_binados.csv")
gravar(junta(L_roc),   "27_logit_curvas_roc.csv")

msg("diagnosticos logit concluidos")
