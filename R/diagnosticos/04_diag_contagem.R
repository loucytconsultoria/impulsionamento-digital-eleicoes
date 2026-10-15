# =====================================================================
# 04_diag_contagem.R -- bateria de diagnosticos dos modelos de CONTAGEM
# (binomial negativa de votos) do TCC.
# Blocos: dispersao/sobredispersao, excesso de zeros, ajuste global,
# residuos simulados (DHARMa), multicolinearidade (VIF/numero de
# condicao), forma funcional (linktest/RESET/quadraticos), influencia,
# erros-padrao robustos e de cluster, validacao cruzada.
# =====================================================================
# (pressupoe 00_setup.R carregado e FITS disponivel)

if (!exists("FITS")) FITS <- readRDS(file.path(DIR_TRAT, "fits_tcc.rds"))

NSIM_DHARMA <- 250
K_FOLDS     <- 5

ok <- function(x) !is.null(x) && !inherits(x, "try-error")
pv <- function(x) if (is.null(x) || length(x) == 0 || !is.finite(x)) NA_real_ else as.numeric(x)

# ---- 1. dispersao / sobredispersao -----------------------------------
diag_dispersao <- function(f) {
  id <- f$rc$id; d <- f$dados
  res <- list()

  # razao de dispersao de Pearson
  if (ok(f$m_pois)) {
    rp <- residuals(f$m_pois, type = "pearson")
    res$pearson_pois <- sum(rp^2) / df.residual(f$m_pois)
  }
  if (ok(f$m_nb_glm)) {
    rp <- residuals(f$m_nb_glm, type = "pearson")
    res$pearson_nb <- sum(rp^2) / df.residual(f$m_nb_glm)
  }

  # Cameron & Trivedi (1990) sobre o Poisson: H0 equidispersao
  ct1 <- try(AER::dispersiontest(f$m_pois, trafo = 1), silent = TRUE)  # var = mu + a*mu   (NB1)
  ct2 <- try(AER::dispersiontest(f$m_pois, trafo = 2), silent = TRUE)  # var = mu + a*mu^2 (NB2)
  res$ct_nb1_alpha <- if (ok(ct1)) unname(ct1$estimate) else NA
  res$ct_nb1_z     <- if (ok(ct1)) unname(ct1$statistic) else NA
  res$ct_nb1_p     <- if (ok(ct1)) pv(ct1$p.value) else NA
  res$ct_nb2_alpha <- if (ok(ct2)) unname(ct2$estimate) else NA
  res$ct_nb2_z     <- if (ok(ct2)) unname(ct2$statistic) else NA
  res$ct_nb2_p     <- if (ok(ct2)) pv(ct2$p.value) else NA

  # LR Poisson vs NB2 (teste de fronteira: p/2)
  if (ok(f$m_pois) && ok(f$m_nb_glm)) {
    LR <- as.numeric(2 * (logLik(f$m_nb_glm) - logLik(f$m_pois)))
    res$LR_pois_vs_nb   <- LR
    res$LR_pois_vs_nb_p <- pchisq(LR, df = 1, lower.tail = FALSE) / 2
  }

  # theta e alpha = 1/theta
  if (ok(f$m_nb_glm)) {
    res$theta <- f$m_nb_glm$theta
    res$theta_se <- f$m_nb_glm$SE.theta
    res$alpha <- 1 / f$m_nb_glm$theta
    res$theta_ic_inf <- f$m_nb_glm$theta - 1.96 * f$m_nb_glm$SE.theta
    res$theta_ic_sup <- f$m_nb_glm$theta + 1.96 * f$m_nb_glm$SE.theta
  }

  # sobredispersao residual do proprio NB (performance)
  od <- try(performance::check_overdispersion(f$m_nb_tmb), silent = TRUE)
  res$nb_disp_ratio <- if (ok(od)) as.numeric(od$dispersion_ratio) else NA
  res$nb_disp_p     <- if (ok(od)) pv(od$p_value) else NA

  # DHARMa: dispersao simulada (bidirecional) no NB
  sm <- try(DHARMa::simulateResiduals(f$m_nb_tmb, n = NSIM_DHARMA, seed = 20260809), silent = TRUE)
  if (ok(sm)) {
    td <- try(DHARMa::testDispersion(sm, plot = FALSE), silent = TRUE)
    res$dharma_disp_stat <- if (ok(td)) unname(td$statistic) else NA
    res$dharma_disp_p    <- if (ok(td)) pv(td$p.value) else NA
    tu <- try(DHARMa::testUniformity(sm, plot = FALSE), silent = TRUE)
    res$dharma_ks_stat <- if (ok(tu)) unname(tu$statistic) else NA
    res$dharma_ks_p    <- if (ok(tu)) pv(tu$p.value) else NA
    to <- try(DHARMa::testOutliers(sm, type = "bootstrap", nBoot = 100, plot = FALSE), silent = TRUE)
    res$dharma_out_freq <- if (ok(to)) unname(to$statistic) else NA
    res$dharma_out_p    <- if (ok(to)) pv(to$p.value) else NA
    tz <- try(DHARMa::testZeroInflation(sm, plot = FALSE), silent = TRUE)
    res$dharma_zi_ratio <- if (ok(tz)) unname(tz$statistic) else NA
    res$dharma_zi_p     <- if (ok(tz)) pv(tz$p.value) else NA
    tq <- try(DHARMa::testQuantiles(sm, plot = FALSE), silent = TRUE)
    res$dharma_quant_p  <- if (ok(tq)) pv(tq$p.value) else NA
    f$dharma <- sm
  }
  c(list(recorte = id, rotulo = f$rc$rotulo, n = nrow(d)), res)
}

# ---- 2. zeros e ajuste global ----------------------------------------
diag_zeros_ajuste <- function(f) {
  d <- f$dados; y <- d$total_votos; n <- length(y)
  zeros_obs <- sum(y == 0)

  esp_pois <- NA; esp_nb <- NA
  if (ok(f$m_pois)) esp_pois <- sum(dpois(0, fitted(f$m_pois)))
  if (ok(f$m_nb_glm)) esp_nb <- sum(dnbinom(0, size = f$m_nb_glm$theta, mu = fitted(f$m_nb_glm)))

  aics <- c(
    Poisson = if (ok(f$m_pois)) AIC(f$m_pois) else NA,
    NB2     = if (ok(f$m_nb_glm)) AIC(f$m_nb_glm) else NA,
    NB1     = if (ok(f$m_nb1)) AIC(f$m_nb1) else NA,
    ZINB    = if (ok(f$m_zinb)) AIC(f$m_zinb) else NA,
    Hurdle  = if (ok(f$m_hurdle)) AIC(f$m_hurdle) else NA)
  bics <- c(
    Poisson = if (ok(f$m_pois)) BIC(f$m_pois) else NA,
    NB2     = if (ok(f$m_nb_glm)) BIC(f$m_nb_glm) else NA,
    NB1     = if (ok(f$m_nb1)) BIC(f$m_nb1) else NA,
    ZINB    = if (ok(f$m_zinb)) BIC(f$m_zinb) else NA,
    Hurdle  = if (ok(f$m_hurdle)) BIC(f$m_hurdle) else NA)

  # pseudo-R2 e erro de previsao do NB
  r2mc <- NA; r2nag <- NA
  if (ok(f$m_nb_glm)) {
    ll1 <- as.numeric(logLik(f$m_nb_glm))
    m0 <- try(MASS::glm.nb(total_votos ~ 1, data = d), silent = TRUE)
    if (ok(m0)) {
      ll0 <- as.numeric(logLik(m0))
      r2mc  <- 1 - ll1 / ll0
      r2nag <- (1 - exp(2 * (ll0 - ll1) / nrow(d))) / (1 - exp(2 * ll0 / nrow(d)))
    }
  }
  fit <- if (ok(f$m_nb_glm)) fitted(f$m_nb_glm) else rep(NA, n)
  tibble(recorte = f$rc$id, rotulo = f$rc$rotulo, n = n,
         zeros_obs = zeros_obs, prop_zeros = zeros_obs / n,
         zeros_esp_poisson = esp_pois, zeros_esp_nb = esp_nb,
         razao_zeros_nb = zeros_obs / esp_nb,
         AIC_Poisson = aics[["Poisson"]], AIC_NB2 = aics[["NB2"]], AIC_NB1 = aics[["NB1"]],
         AIC_ZINB = aics[["ZINB"]], AIC_Hurdle = aics[["Hurdle"]],
         BIC_Poisson = bics[["Poisson"]], BIC_NB2 = bics[["NB2"]], BIC_NB1 = bics[["NB1"]],
         BIC_ZINB = bics[["ZINB"]], BIC_Hurdle = bics[["Hurdle"]],
         melhor_AIC = names(aics)[which.min(aics)],
         melhor_BIC = names(bics)[which.min(bics)],
         R2_McFadden = r2mc, R2_Nagelkerke = r2nag,
         cor_obs_ajust = suppressWarnings(cor(y, fit)),
         RMSE = sqrt(mean((y - fit)^2)), MAE = mean(abs(y - fit)))
}

# ---- 3. multicolinearidade -------------------------------------------
diag_vif <- function(f, modelo, tipo) {
  cc <- try(performance::check_collinearity(modelo), silent = TRUE)
  if (!ok(cc)) return(NULL)
  cc <- as.data.frame(cc)
  tibble(recorte = f$rc$id, rotulo = f$rc$rotulo, modelo = tipo,
         termo = cc$Term, VIF = cc$VIF, VIF_ic_inf = cc$VIF_CI_low,
         VIF_ic_sup = cc$VIF_CI_high, tolerancia = cc$Tolerance)
}

diag_condicao <- function(f) {
  X <- model.matrix(f$f_votos, f$dados)
  Xs <- scale(X[, colnames(X) != "(Intercept)", drop = FALSE])
  sv <- svd(Xs)$d
  R <- cor(X[, colnames(X) != "(Intercept)", drop = FALSE])
  diag(R) <- NA
  tibble(recorte = f$rc$id, rotulo = f$rc$rotulo,
         numero_condicao = max(sv) / min(sv),
         cor_max_abs = max(abs(R), na.rm = TRUE),
         par_cor_max = paste(which(abs(R) == max(abs(R), na.rm = TRUE), arr.ind = TRUE)[1, ] |>
                             (\(ix) paste(rownames(R)[ix[1]], "x", colnames(R)[ix[2]]))()))
}

# ---- 4. forma funcional ----------------------------------------------
# Todos os ajustes auxiliares usam a NB com theta FIXO no valor estimado
# pelo modelo original, de modo que a diferenca de log-verossimilhanca
# seja um teste LR valido sobre a parte sistematica.
diag_forma <- function(f) {
  d <- f$dados
  th <- f$theta_hat
  if (is.na(th)) return(NULL)
  fam <- MASS::negative.binomial(theta = th)
  fv <- f$f_votos
  environment(fv) <- environment()          # etastart precisa ser visivel aqui
  eta0 <- if (ok(f$m_nb_glm)) predict(f$m_nb_glm, type = "link") else NULL
  m0 <- try(glm(fv, data = d, family = fam, etastart = eta0), silent = TRUE)
  if (!ok(m0)) m0 <- try(glm(fv, data = d, family = fam), silent = TRUE)
  if (!ok(m0)) return(NULL)
  eta <- predict(m0, type = "link")

  # linktest de Pregibon
  dl <- data.frame(y = d$total_votos, eta = eta, eta2 = eta^2)
  ml <- try(glm(y ~ eta + eta2, data = dl, family = fam), silent = TRUE)
  p_link <- if (ok(ml)) coef(summary(ml))["eta2", 4] else NA

  d2 <- d; d2$.eta2 <- eta^2; d2$.eta3 <- eta^3
  for (v in unname(f$vg)) d2[[paste0(".q_", v)]] <- log1p(d2[[v]])^2

  f2 <- update(fv, . ~ . + .eta2 + .eta3)
  f3 <- update(fv, paste("~ . +", paste0(".q_", unname(f$vg), collapse = " + ")))
  environment(f2) <- environment(f3) <- environment()

  mr <- try(glm(f2, data = d2, family = fam, etastart = eta), silent = TRUE)
  mq <- try(glm(f3, data = d2, family = fam, etastart = eta), silent = TRUE)

  lr_p <- function(ma, mb) {
    if (!ok(mb)) return(NA_real_)
    LR <- as.numeric(2 * (logLik(mb) - logLik(ma)))
    gl <- length(coef(mb)) - length(coef(ma))
    pchisq(max(LR, 0), df = gl, lower.tail = FALSE)
  }
  tibble(recorte = f$rc$id, rotulo = f$rc$rotulo,
         linktest_p_eta2 = p_link, reset_p = lr_p(m0, mr), quadraticos_p = lr_p(m0, mq))
}

# ---- 5. influencia ---------------------------------------------------
diag_influencia <- function(f) {
  m <- if (ok(f$m_nb_glm)) f$m_nb_glm else f$m_nb_fix
  if (!ok(m)) return(NULL)
  n <- nrow(f$dados); p <- length(coef(m))
  h  <- hatvalues(m); cd <- cooks.distance(m)
  lim_h <- 2 * p / n; lim_cd <- 4 / n
  nome_imp <- paste0("log1p(", f$vg[["impulsionamento"]], ")")

  # reestimacao sem o 1% mais influente (Cook)
  corte <- quantile(cd, 0.99, na.rm = TRUE)
  keep <- cd <= corte
  b0 <- coef(m)[nome_imp]
  m2 <- try(glm(f$f_votos, data = f$dados[keep, , drop = FALSE],
                family = MASS::negative.binomial(theta = f$theta_hat)), silent = TRUE)
  b1 <- if (ok(m2)) coef(m2)[nome_imp] else NA

  # dfbeta do coeficiente de impulsionamento
  dfb <- try(dfbeta(m), silent = TRUE)
  dfb_imp <- if (ok(dfb) && nome_imp %in% colnames(dfb)) dfb[, nome_imp] else rep(NA, n)

  tibble(recorte = f$rc$id, rotulo = f$rc$rotulo, n = n,
         leverage_max = max(h), n_leverage_alto = sum(h > lim_h), lim_leverage = lim_h,
         cook_max = max(cd, na.rm = TRUE), n_cook_alto = sum(cd > lim_cd, na.rm = TRUE), lim_cook = lim_cd,
         beta_impuls = unname(b0), beta_impuls_sem_1pct = unname(b1),
         variacao_pct = 100 * (unname(b1) - unname(b0)) / abs(unname(b0)),
         dfbeta_impuls_max_abs = max(abs(dfb_imp), na.rm = TRUE))
}

# ---- 6. erros-padrao robustos e de cluster ---------------------------
# usa o objeto negbin (MASS::glm.nb), para o qual o pacote sandwich trata
# a dispersao corretamente como conhecida (=1) na escala NB
diag_robusto <- function(f) {
  m <- if (ok(f$m_nb_glm)) f$m_nb_glm else f$m_nb_fix
  if (!ok(m)) return(NULL)
  b <- coef(m)
  ep_mle <- sqrt(diag(vcov(m)))
  ep_hc0 <- sqrt(diag(sandwich::vcovHC(m, type = "HC0")))
  ep_hc3 <- sqrt(diag(sandwich::vcovHC(m, type = "HC3")))
  ep_cl <- rep(NA_real_, length(b))
  if (!is.na(f$rc$porte) && "CIDADE" %in% names(f$dados)) {
    vc <- try(sandwich::vcovCL(m, cluster = f$dados$CIDADE), silent = TRUE)
    if (ok(vc)) ep_cl <- sqrt(diag(vc))
  }
  tibble(recorte = f$rc$id, rotulo = f$rc$rotulo, termo = names(b), estimativa = unname(b),
         ep_mle = unname(ep_mle), ep_HC0 = unname(ep_hc0), ep_HC3 = unname(ep_hc3),
         ep_cluster_mun = unname(ep_cl),
         p_mle = 2 * pnorm(abs(b / ep_mle), lower.tail = FALSE),
         p_HC3 = 2 * pnorm(abs(b / ep_hc3), lower.tail = FALSE),
         p_cluster = 2 * pnorm(abs(b / ep_cl), lower.tail = FALSE))
}

# ---- 7. validacao cruzada (k-fold) -----------------------------------
diag_cv <- function(f) {
  d <- f$dados; th <- f$theta_hat
  if (is.na(th)) return(NULL)
  set.seed(20260809)
  fold <- sample(rep_len(1:K_FOLDS, nrow(d)))
  pred <- rep(NA_real_, nrow(d))
  for (k in 1:K_FOLDS) {
    mk <- try(glm(f$f_votos, data = d[fold != k, , drop = FALSE],
                  family = MASS::negative.binomial(theta = th)), silent = TRUE)
    if (ok(mk)) pred[fold == k] <- predict(mk, newdata = d[fold == k, , drop = FALSE], type = "response")
  }
  y <- d$total_votos
  ll_oos <- sum(dnbinom(y, size = th, mu = pmax(pred, 1e-8), log = TRUE), na.rm = TRUE)
  tibble(recorte = f$rc$id, rotulo = f$rc$rotulo, k = K_FOLDS,
         RMSE_cv = sqrt(mean((y - pred)^2, na.rm = TRUE)),
         MAE_cv = mean(abs(y - pred), na.rm = TRUE),
         logLik_oos = ll_oos,
         cor_cv = suppressWarnings(cor(y, pred, use = "complete.obs")))
}

# ---- 8b. sensibilidade da elasticidade do impulsionamento ------------
# Como o coeficiente de interesse se move entre especificacoes de contagem.
diag_sensibilidade <- function(f) {
  nome <- paste0("log1p(", f$vg[["impulsionamento"]], ")")
  pega <- function(m, tipo) {
    if (!ok(m)) return(NULL)
    b <- switch(tipo,
      glm    = { s <- summary(m)$coefficients; if (!nome %in% rownames(s)) return(NULL); s[nome, 1:2] },
      tmb    = { s <- summary(m)$coefficients$cond; if (!nome %in% rownames(s)) return(NULL); s[nome, 1:2] },
      pscl   = { s <- summary(m)$coefficients$count
                 rn <- rownames(s); if (!nome %in% rn) return(NULL); s[nome, 1:2] })
    c(b[1], b[2])
  }
  linhas <- list(
    NB2_glmnb   = pega(f$m_nb_glm, "glm"),
    NB2_glmmTMB = pega(f$m_nb_tmb, "tmb"),
    NB1_glmmTMB = pega(f$m_nb1, "tmb"),
    Poisson     = pega(f$m_pois, "glm"),
    ZINB        = pega(f$m_zinb, "pscl"),
    Hurdle      = pega(f$m_hurdle, "pscl"))
  linhas <- Filter(Negate(is.null), linhas)
  if (!length(linhas)) return(NULL)
  tibble(recorte = f$rc$id, rotulo = f$rc$rotulo,
         especificacao = names(linhas),
         coef_impulsionamento = sapply(linhas, `[`, 1),
         ep = sapply(linhas, `[`, 2)) %>%
    mutate(z = coef_impulsionamento / ep,
           p = 2 * pnorm(abs(z), lower.tail = FALSE),
           semielasticidade_pct = 100 * (exp(coef_impulsionamento) - 1))
}

# ---- 8. rootograma (dados) -------------------------------------------
dados_rootograma <- function(f, kmax = 30) {
  if (!ok(f$m_nb_glm)) return(NULL)
  y <- f$dados$total_votos; mu <- fitted(f$m_nb_glm); th <- f$m_nb_glm$theta
  ks <- 0:kmax
  obs <- sapply(ks, function(k) sum(y == k))
  esp <- sapply(ks, function(k) sum(dnbinom(k, size = th, mu = mu)))
  tibble(recorte = f$rc$id, rotulo = f$rc$rotulo, contagem = ks,
         observado = obs, esperado_nb = esp)
}

# =====================================================================
# EXECUCAO
# =====================================================================
msg("=== diagnosticos dos modelos de contagem ===")
T_disp <- list(); T_zero <- list(); T_vif <- list(); T_cond <- list()
T_forma <- list(); T_infl <- list(); T_rob <- list(); T_cv <- list(); T_root <- list()
T_sens <- list()

for (id in names(FITS)) {
  f <- FITS[[id]]
  msg("  ", id)
  T_disp[[id]]  <- try(as.data.frame(diag_dispersao(f)), silent = TRUE)
  T_zero[[id]]  <- try(diag_zeros_ajuste(f), silent = TRUE)
  T_vif[[id]]   <- try(diag_vif(f, f$m_nb_tmb, "NB (votos)"), silent = TRUE)
  T_cond[[id]]  <- try(diag_condicao(f), silent = TRUE)
  T_forma[[id]] <- try(diag_forma(f), silent = TRUE)
  T_infl[[id]]  <- try(diag_influencia(f), silent = TRUE)
  T_rob[[id]]   <- try(diag_robusto(f), silent = TRUE)
  T_cv[[id]]    <- try(diag_cv(f), silent = TRUE)
  T_root[[id]]  <- try(dados_rootograma(f), silent = TRUE)
  T_sens[[id]]  <- try(diag_sensibilidade(f), silent = TRUE)
}

junta <- function(L) dplyr::bind_rows(Filter(function(x) !inherits(x, "try-error") && !is.null(x), L))

gravar(junta(T_disp),  "10_dispersao_sobredispersao.csv")
gravar(junta(T_zero),  "11_zeros_e_ajuste_global.csv")
gravar(junta(T_vif),   "12_vif_modelos_contagem.csv")
gravar(junta(T_cond),  "13_numero_condicao.csv")
gravar(junta(T_forma), "14_forma_funcional.csv")
gravar(junta(T_infl),  "15_influencia.csv")
gravar(junta(T_rob),   "16_erros_padrao_robustos.csv")
gravar(junta(T_cv),    "17_validacao_cruzada.csv")
gravar(junta(T_root),  "18_rootograma_dados.csv")
gravar(junta(T_sens),  "19_sensibilidade_elasticidade.csv")

msg("diagnosticos de contagem concluidos")
