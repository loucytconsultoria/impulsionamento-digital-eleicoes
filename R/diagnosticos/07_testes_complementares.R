# =====================================================================
# 07_testes_complementares.R
# (a) independencia das observacoes: teste LR de intercepto aleatorio
#     por municipio nos modelos de vereador (as observacoes do TCC sao
#     candidatos agrupados em municipios);
# (b) teste formal do gradiente por porte (a hipotese central do TCC):
#     interacao porte x log1p(impulsionamento) em modelo agrupado;
# (c) heterocedasticidade dos residuos de Pearson (Breusch-Pagan);
# (d) estatisticas de teste (nao so p) da forma funcional;
# (e) estatisticas descritivas por recorte.
# =====================================================================
# (pressupoe 00_setup.R carregado)

if (!exists("FITS"))  FITS  <- readRDS(file.path(DIR_TRAT, "fits_tcc.rds"))
if (!exists("BASES")) BASES <- readRDS(file.path(DIR_TRAT, "bases_tcc.rds"))
ok <- function(x) !is.null(x) && !inherits(x, "try-error")

CONTROLES <- c("reeleicao", "masculino", "superior_completo", "corbranca", "esquerda", "direita")

# ---- (a) intercepto aleatorio por municipio ---------------------------
msg("(a) teste de agrupamento por municipio")
T_icc <- purrr::map_dfr(names(FITS), function(id) {
  f <- FITS[[id]]
  if (is.na(f$rc$porte) || !("CIDADE" %in% names(f$dados))) return(NULL)
  if (length(unique(f$dados$CIDADE)) < 5) return(NULL)   # metropole = 1 municipio
  fm <- update(f$f_votos, . ~ . + (1 | CIDADE))
  environment(fm) <- environment()
  mre <- try(glmmTMB(fm, data = f$dados, family = nbinom2(link = "log")), silent = TRUE)
  if (!ok(mre) || !ok(f$m_nb_tmb)) return(NULL)
  LR <- as.numeric(2 * (logLik(mre) - logLik(f$m_nb_tmb)))
  vc <- as.numeric(glmmTMB::VarCorr(mre)$cond$CIDADE[1, 1])
  nome <- paste0("log1p(", f$vg[["impulsionamento"]], ")")
  s_re <- summary(mre)$coefficients$cond
  s_fe <- summary(f$m_nb_tmb)$coefficients$cond
  tibble(recorte = id, rotulo = f$rc$rotulo, n_municipios = length(unique(f$dados$CIDADE)),
         LR_intercepto_aleatorio = LR,
         p_LR = pchisq(max(LR, 0), df = 1, lower.tail = FALSE) / 2,   # teste de fronteira
         var_municipio = vc, dp_municipio = sqrt(vc),
         AIC_sem_efeito = AIC(f$m_nb_tmb), AIC_com_efeito = AIC(mre),
         beta_impuls_pooled = s_fe[nome, 1], ep_pooled = s_fe[nome, 2],
         beta_impuls_com_efeito = s_re[nome, 1], ep_com_efeito = s_re[nome, 2])
})
gravar(T_icc, "30_agrupamento_municipio.csv")
print(as.data.frame(T_icc))

# ---- (b) teste formal do gradiente por porte -------------------------
msg("(b) teste do gradiente por porte")
T_grad <- purrr::map_dfr(c("2020", "2024"), function(ano) {
  d <- BASES[[paste0("VEREADOR_", ano)]]
  d <- d[as.character(d$f_porte_municipio) %in% c("PEQUENO", "MEDIO", "GRANDE", "METROPOLE"), ]
  d$porte <- factor(as.character(d$f_porte_municipio),
                    levels = c("PEQUENO", "MEDIO", "GRANDE", "METROPOLE"))
  vg <- if (ano == "2020")
    c("gasto_impulsionamento", "gasto_publicidade_tradicional", "gasto_operacional") else
    c("gasto_impulsionamento_deflacionado", "gasto_tradicional_deflacionado", "gasto_operacional_deflacionado")
  d <- d[stats::complete.cases(d[, c("total_votos", vg, CONTROLES)]), ]

  rhs_g <- paste0("log1p(", vg, ")", collapse = " + ")
  # modelo restrito: efeito do impulsionamento igual entre portes
  f0 <- as.formula(paste("total_votos ~", rhs_g, "+", paste(CONTROLES, collapse = " + "), "+ porte"))
  # modelo livre: interacao porte x impulsionamento
  f1 <- as.formula(paste("total_votos ~ porte * log1p(", vg[1], ") +",
                         paste0("log1p(", vg[-1], ")", collapse = " + "), "+",
                         paste(CONTROLES, collapse = " + ")))
  # modelo com todas as interacoes de gasto (referencia)
  f2 <- as.formula(paste("total_votos ~ porte * (", rhs_g, ") +",
                         paste(CONTROLES, collapse = " + ")))
  environment(f0) <- environment(f1) <- environment(f2) <- environment()

  m0 <- try(glmmTMB(f0, data = d, family = nbinom2(link = "log")), silent = TRUE)
  m1 <- try(glmmTMB(f1, data = d, family = nbinom2(link = "log")), silent = TRUE)
  m2 <- try(glmmTMB(f2, data = d, family = nbinom2(link = "log")), silent = TRUE)
  if (!ok(m0) || !ok(m1)) return(NULL)

  LR1 <- as.numeric(2 * (logLik(m1) - logLik(m0)))
  gl1 <- length(glmmTMB::fixef(m1)$cond) - length(glmmTMB::fixef(m0)$cond)
  LR2 <- if (ok(m2)) as.numeric(2 * (logLik(m2) - logLik(m0))) else NA
  gl2 <- if (ok(m2)) length(glmmTMB::fixef(m2)$cond) - length(glmmTMB::fixef(m0)$cond) else NA

  # elasticidade implicada por porte no modelo livre
  b <- glmmTMB::fixef(m1)$cond
  base_nm <- paste0("log1p(", vg[1], ")")
  eff <- sapply(levels(d$porte), function(p) {
    if (p == "PEQUENO") b[[base_nm]] else {
      nm <- paste0("porte", p, ":", base_nm)
      nm2 <- paste0(base_nm, ":porte", p)
      inc <- if (nm %in% names(b)) b[[nm]] else if (nm2 %in% names(b)) b[[nm2]] else NA
      b[[base_nm]] + inc
    }
  })
  tibble(ano = ano, n = nrow(d),
         LR_interacao_impuls = LR1, gl_interacao = gl1,
         p_interacao_impuls = pchisq(max(LR1, 0), df = gl1, lower.tail = FALSE),
         LR_interacao_todos_gastos = LR2, gl_todos = gl2,
         p_interacao_todos = if (is.na(LR2)) NA else pchisq(max(LR2, 0), df = gl2, lower.tail = FALSE),
         elast_PEQUENO = eff[["PEQUENO"]], elast_MEDIO = eff[["MEDIO"]],
         elast_GRANDE = eff[["GRANDE"]], elast_METROPOLE = eff[["METROPOLE"]],
         AIC_restrito = AIC(m0), AIC_livre = AIC(m1))
})
gravar(T_grad, "31_teste_gradiente_porte.csv")
print(as.data.frame(T_grad))

# ---- (c) heterocedasticidade dos residuos de Pearson -----------------
msg("(c) heterocedasticidade")
T_het <- purrr::map_dfr(names(FITS), function(id) {
  f <- FITS[[id]]
  m <- if (ok(f$m_nb_glm)) f$m_nb_glm else f$m_nb_fix
  if (!ok(m)) return(NULL)
  r2 <- residuals(m, type = "pearson")^2
  eta <- predict(m, type = "link")
  aux <- try(lm(r2 ~ eta), silent = TRUE)
  if (!ok(aux)) return(NULL)
  s <- summary(aux)
  LM <- nrow(f$dados) * s$r.squared
  tibble(recorte = id, rotulo = f$rc$rotulo,
         BP_LM = LM, BP_gl = 1, BP_p = pchisq(LM, df = 1, lower.tail = FALSE),
         inclinacao = coef(aux)[2], p_inclinacao = coef(s)[2, 4])
})
gravar(T_het, "32_heterocedasticidade.csv")
print(as.data.frame(T_het))

# ---- (d) forma funcional com estatisticas de teste -------------------
msg("(d) forma funcional detalhada")
T_ff <- purrr::map_dfr(names(FITS), function(id) {
  f <- FITS[[id]]; d <- f$dados; th <- f$theta_hat
  if (is.na(th)) return(NULL)
  fam <- MASS::negative.binomial(theta = th)
  fv <- f$f_votos; environment(fv) <- environment()
  eta0 <- if (ok(f$m_nb_glm)) predict(f$m_nb_glm, type = "link") else NULL
  m0 <- try(glm(fv, data = d, family = fam, etastart = eta0), silent = TRUE)
  if (!ok(m0)) return(NULL)
  eta <- predict(m0, type = "link")
  d2 <- d; d2$.eta2 <- eta^2; d2$.eta3 <- eta^3
  for (v in unname(f$vg)) d2[[paste0(".q_", v)]] <- log1p(d2[[v]])^2
  f2 <- update(fv, . ~ . + .eta2 + .eta3)
  f3 <- update(fv, paste("~ . +", paste0(".q_", unname(f$vg), collapse = " + ")))
  environment(f2) <- environment(f3) <- environment()
  # RESET: tenta com e sem partida informada
  mr <- try(glm(f2, data = d2, family = fam, etastart = eta), silent = TRUE)
  if (!ok(mr)) mr <- try(glm(f2, data = d2, family = fam, start = c(coef(m0), 0, 0)), silent = TRUE)
  if (!ok(mr)) mr <- try(glm(f2, data = d2, family = fam, control = glm.control(maxit = 200)), silent = TRUE)
  mq <- try(glm(f3, data = d2, family = fam, etastart = eta), silent = TRUE)
  est <- function(mb) {
    if (!ok(mb)) return(c(NA, NA, NA))
    LR <- as.numeric(2 * (logLik(mb) - logLik(m0)))
    gl <- length(coef(mb)) - length(coef(m0))
    c(LR, gl, pchisq(max(LR, 0), df = gl, lower.tail = FALSE))
  }
  a <- est(mr); b <- est(mq)
  dl <- data.frame(y = d$total_votos, eta = eta, eta2 = eta^2)
  ml <- try(glm(y ~ eta + eta2, data = dl, family = fam), silent = TRUE)
  tibble(recorte = id, rotulo = f$rc$rotulo,
         linktest_coef_eta2 = if (ok(ml)) coef(ml)["eta2"] else NA,
         linktest_p = if (ok(ml)) coef(summary(ml))["eta2", 4] else NA,
         RESET_LR = a[1], RESET_gl = a[2], RESET_p = a[3],
         quadraticos_LR = b[1], quadraticos_gl = b[2], quadraticos_p = b[3])
})
gravar(T_ff, "33_forma_funcional_detalhada.csv")
print(as.data.frame(T_ff))

# ---- (e) estatisticas descritivas ------------------------------------
msg("(e) descritivas")
T_desc <- purrr::map_dfr(names(FITS), function(id) {
  f <- FITS[[id]]; d <- f$dados
  vs <- c(total_votos = "total_votos", eleito = "eleito",
          impulsionamento = unname(f$vg[["impulsionamento"]]),
          tradicional = unname(f$vg[["tradicional"]]),
          operacional = unname(f$vg[["operacional"]]))
  purrr::map_dfr(names(vs), function(k) {
    x <- d[[vs[[k]]]]
    tibble(recorte = id, rotulo = f$rc$rotulo, variavel = k, n = length(x),
           media = mean(x), dp = sd(x), mediana = median(x),
           p25 = quantile(x, .25), p75 = quantile(x, .75), maximo = max(x),
           prop_zero = mean(x == 0))
  })
})
gravar(T_desc, "34_descritivas.csv")

msg("testes complementares concluidos")
