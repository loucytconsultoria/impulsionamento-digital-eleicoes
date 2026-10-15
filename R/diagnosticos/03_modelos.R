# =====================================================================
# 03_modelos.R -- reestimacao dos modelos ORIGINAIS do TCC
# + modelos auxiliares usados apenas como referencia de teste
#   (Poisson, ZINB, hurdle, Firth), sem alterar a especificacao original.
# =====================================================================
# (pressupoe 00_setup.R e 02_dados.R ja carregados; BASES no ambiente)

if (!exists("BASES")) BASES <- readRDS(file.path(DIR_TRAT, "bases_tcc.rds"))

CONTROLES <- c("reeleicao", "masculino", "superior_completo", "corbranca", "esquerda", "direita")

vars_gasto_de <- function(ano) {
  if (ano %in% c("2018", "2020")) {
    c(impulsionamento = "gasto_impulsionamento",
      tradicional     = "gasto_publicidade_tradicional",
      operacional     = "gasto_operacional")
  } else {
    c(impulsionamento = "gasto_impulsionamento_deflacionado",
      tradicional     = "gasto_tradicional_deflacionado",
      operacional     = "gasto_operacional_deflacionado")
  }
}

form_de <- function(y, vg) {
  as.formula(paste0(y, " ~ ", paste0("log1p(", vg, ")", collapse = " + "),
                    " + ", paste(CONTROLES, collapse = " + ")))
}
form_restr <- function(y) as.formula(paste0(y, " ~ ", paste(CONTROLES, collapse = " + ")))

# ---- registro dos 12 recortes do TCC ---------------------------------
RECORTES <- list()
for (cargo in c("DEPFED", "DEPEST")) for (ano in c("2018", "2022")) {
  id <- paste0(cargo, "_", ano)
  RECORTES[[id]] <- list(id = id, base = id, ano = ano, cargo = cargo, porte = NA_character_,
                         rotulo = paste0(ifelse(cargo == "DEPFED", "Deputado federal", "Deputado estadual"), " ", ano),
                         estimador_tcc = "glmmTMB nbinom2")
}
for (ano in c("2020", "2024")) for (porte in c("PEQUENO", "MEDIO", "GRANDE", "METROPOLE")) {
  id <- paste0("VER_", ano, "_", porte)
  RECORTES[[id]] <- list(id = id, base = paste0("VEREADOR_", ano), ano = ano, cargo = "VEREADOR", porte = porte,
                         rotulo = paste0("Vereador ", ano, " - ", porte),
                         estimador_tcc = "MASS::glm.nb")
}

dados_do <- function(rc) {
  d <- BASES[[rc$base]]
  if (!is.na(rc$porte)) d <- d[as.character(d$f_porte_municipio) == rc$porte, , drop = FALSE]
  vg <- vars_gasto_de(rc$ano)
  cols <- c("total_votos", "eleito", unname(vg), CONTROLES)
  if (!is.na(rc$porte)) cols <- c(cols, "CIDADE")
  d <- d[, intersect(cols, names(d)), drop = FALSE]
  d <- d[stats::complete.cases(d[, setdiff(names(d), "CIDADE")]), , drop = FALSE]
  d
}

# ---- estimacao -------------------------------------------------------
ajusta_recorte <- function(rc) {
  d  <- dados_do(rc)
  vg <- vars_gasto_de(rc$ano)
  f_votos <- form_de("total_votos", vg)
  f_log   <- form_de("eleito", vg)
  f_logr  <- form_restr("eleito")
  # amarra o ambiente das formulas a este frame (para etastart/start serem achados)
  environment(f_votos) <- environment(f_log) <- environment(f_logr) <- environment()

  msg("ajustando ", rc$id, " (n=", nrow(d), ")")

  out <- list(rc = rc, dados = d, vg = vg,
              f_votos = f_votos, f_logit = f_log, f_logit_restr = f_logr)

  # --- contagem: especificacao original + auxiliares ---
  out$m_nb_tmb <- try(glmmTMB(f_votos, data = d, family = nbinom2(link = "log")), silent = TRUE)
  out$m_pois   <- try(glm(f_votos, data = d, family = poisson(link = "log")), silent = TRUE)
  out$m_nb_glm <- try(MASS::glm.nb(f_votos, data = d, control = glm.control(maxit = 200)), silent = TRUE)
  # partida a partir da solucao do glmmTMB quando o IRLS do glm.nb diverge
  b_tmb <- if (!inherits(out$m_nb_tmb, "try-error")) glmmTMB::fixef(out$m_nb_tmb)$cond else NULL
  eta_tmb <- if (!is.null(b_tmb)) as.vector(model.matrix(f_votos, d) %*% b_tmb) else NULL
  if (inherits(out$m_nb_glm, "try-error") && !is.null(b_tmb)) {
    out$m_nb_glm <- try(MASS::glm.nb(f_votos, data = d, init.theta = sigma(out$m_nb_tmb),
                                     start = b_tmb,
                                     control = glm.control(maxit = 1000, epsilon = 1e-10)), silent = TRUE)
  }
  # glm com theta FIXO no valor estimado -- usado para alavancagem/influencia
  # (mesma verossimilhanca condicional; permite hatvalues/cooks.distance)
  theta_hat <- if (!inherits(out$m_nb_glm, "try-error")) out$m_nb_glm$theta else
               if (!inherits(out$m_nb_tmb, "try-error")) sigma(out$m_nb_tmb) else NA
  out$theta_hat <- theta_hat
  out$m_nb_fix <- NULL
  if (!is.na(theta_hat)) {
    out$m_nb_fix <- try(glm(f_votos, data = d, etastart = eta_tmb,
                            family = MASS::negative.binomial(theta = theta_hat)), silent = TRUE)
    if (inherits(out$m_nb_fix, "try-error"))
      out$m_nb_fix <- try(glm(f_votos, data = d,
                              family = MASS::negative.binomial(theta = theta_hat)), silent = TRUE)
  }
  out$m_nb1    <- try(glmmTMB(f_votos, data = d, family = nbinom1(link = "log")), silent = TRUE)

  # ZINB e hurdle (dois componentes; parte zero apenas com intercepto)
  f_2p <- as.formula(paste(paste(deparse(f_votos), collapse = ""), "| 1"))
  out$m_zinb   <- try(pscl::zeroinfl(f_2p, data = d, dist = "negbin"), silent = TRUE)
  out$m_hurdle <- try(pscl::hurdle(f_2p, data = d, dist = "negbin"), silent = TRUE)

  # --- sucesso eleitoral: logit original + auxiliares ---
  out$m_logit       <- try(glm(f_log,  data = d, family = binomial(link = "logit")), silent = TRUE)
  out$m_logit_restr <- try(glm(f_logr, data = d, family = binomial(link = "logit")), silent = TRUE)
  out$m_logit_tmb   <- try(glmmTMB(f_log, data = d, family = binomial(link = "logit")), silent = TRUE)
  out$m_logit_firth <- try(logistf::logistf(f_log, data = d, pl = FALSE), silent = TRUE)
  out
}

msg("=== estimando ", length(RECORTES), " recortes ===")
FITS <- lapply(RECORTES, ajusta_recorte)
names(FITS) <- names(RECORTES)
saveRDS(FITS, file.path(DIR_TRAT, "fits_tcc.rds"))

# ---- tabela de coeficientes reproduzidos -----------------------------
tab_coef <- purrr::map_dfr(FITS, function(f) {
  m <- f$m_nb_tmb
  if (inherits(m, "try-error")) return(NULL)
  s <- summary(m)$coefficients$cond
  tibble(recorte = f$rc$id, rotulo = f$rc$rotulo, n = nrow(f$dados),
         termo = rownames(s), estimativa = s[, 1], ep = s[, 2], z = s[, 3], p = s[, 4])
})
gravar(tab_coef, "03_coeficientes_NB_glmmTMB.csv")

tab_coef_glm <- purrr::map_dfr(FITS, function(f) {
  m <- f$m_nb_glm
  if (inherits(m, "try-error")) return(NULL)
  s <- summary(m)$coefficients
  tibble(recorte = f$rc$id, rotulo = f$rc$rotulo, n = nrow(f$dados),
         theta = m$theta, theta_se = m$SE.theta,
         termo = rownames(s), estimativa = s[, 1], ep = s[, 2], z = s[, 3], p = s[, 4])
})
gravar(tab_coef_glm, "04_coeficientes_NB_glmnb.csv")

# ---- equivalencia entre os dois estimadores NB -----------------------
equiv <- purrr::map_dfr(FITS, function(f) {
  if (inherits(f$m_nb_glm, "try-error") || inherits(f$m_nb_tmb, "try-error")) return(NULL)
  a <- coef(f$m_nb_glm); b <- glmmTMB::fixef(f$m_nb_tmb)$cond
  tibble(recorte = f$rc$id, max_dif_abs_coef = max(abs(a[names(b)] - b)),
         theta_glmnb = f$m_nb_glm$theta,
         theta_tmb = sigma(f$m_nb_tmb))
})
gravar(purrr::map_dfr(FITS, ~tibble(recorte = .x$rc$id,
                                    glm_nb_ok = !inherits(.x$m_nb_glm, "try-error"),
                                    nb_fix_ok = !is.null(.x$m_nb_fix) && !inherits(.x$m_nb_fix, "try-error"),
                                    zinb_ok   = !inherits(.x$m_zinb, "try-error"),
                                    hurdle_ok = !inherits(.x$m_hurdle, "try-error"),
                                    logit_ok  = !inherits(.x$m_logit, "try-error"))),
       "06_status_ajustes.csv")
gravar(equiv, "05_equivalencia_glmnb_vs_glmmTMB.csv")
print(as.data.frame(equiv))

msg("modelos estimados e salvos")
