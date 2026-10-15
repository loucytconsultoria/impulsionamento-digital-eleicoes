# =====================================================================
# 06_figuras.R -- figuras de diagnostico (PNG) para o relatorio
# Para cada recorte: painel do modelo de contagem (QQ de residuos
# simulados, residuos x ajustado, rootograma, distancia de Cook) e
# painel do logit (ROC, calibracao/residuos binados, influencia).
# Mais quatro figuras-resumo.
# =====================================================================
# (pressupoe 00_setup.R carregado e FITS disponivel)

if (!exists("FITS")) FITS <- readRDS(file.path(DIR_TRAT, "fits_tcc.rds"))
ok <- function(x) !is.null(x) && !inherits(x, "try-error")

W <- 2000; H <- 1500; RES <- 170
abre <- function(nome, w = W, h = H) grDevices::png(file.path(DIR_FIG, nome), width = w, height = h, res = RES)

# ---------------------------------------------------------------------
# 1. Painel de diagnostico do modelo de contagem
# ---------------------------------------------------------------------
painel_contagem <- function(f) {
  id <- f$rc$id
  if (!ok(f$m_nb_glm)) return(invisible(NULL))
  m <- f$m_nb_glm; d <- f$dados; y <- d$total_votos
  mu <- fitted(m); th <- m$theta

  sm <- try(DHARMa::simulateResiduals(f$m_nb_tmb, n = 250, seed = 20260809), silent = TRUE)

  abre(paste0("diag_contagem_", id, ".png"))
  op <- par(mfrow = c(2, 2), mar = c(4.2, 4.2, 3.0, 1.2), cex.main = 0.95, cex.lab = 0.9, cex.axis = 0.85)

  # (a) QQ dos residuos quantilicos simulados
  if (ok(sm)) {
    r <- sm$scaledResiduals
    u <- (rank(r, ties.method = "average") - 0.5) / length(r)
    plot(sort(u), sort(r), pch = 16, cex = 0.35, col = "#33639999",
         xlab = "uniforme esperado", ylab = "residuo quantilico (DHARMa)",
         main = "(a) QQ dos residuos simulados")
    abline(0, 1, col = "#cc3311", lwd = 2)
  } else plot.new()

  # (b) residuos quantilicos x preditor linear
  if (ok(sm)) {
    eta <- predict(m, type = "link")
    plot(eta, sm$scaledResiduals, pch = 16, cex = 0.35, col = "#33639999",
         xlab = "preditor linear", ylab = "residuo quantilico",
         main = "(b) Residuos x preditor linear")
    abline(h = c(0.25, 0.5, 0.75), col = c("grey60", "#cc3311", "grey60"), lty = c(2, 1, 2))
    if (length(eta) > 50) {
      lo <- try(stats::lowess(eta, sm$scaledResiduals, f = 0.4), silent = TRUE)
      if (ok(lo)) lines(lo, col = "#ee7733", lwd = 2)
    }
  } else plot.new()

  # (c) rootograma pendurado
  kmax <- 30; ks <- 0:kmax
  obs <- sapply(ks, function(k) sum(y == k))
  esp <- sapply(ks, function(k) sum(dnbinom(k, size = th, mu = mu)))
  plot(ks, sqrt(esp), type = "n", ylim = range(c(0, sqrt(esp), sqrt(esp) - sqrt(obs))),
       xlab = "votos (contagem)", ylab = "raiz da frequencia",
       main = "(c) Rootograma pendurado (NB)")
  rect(ks - 0.4, sqrt(esp) - sqrt(obs), ks + 0.4, sqrt(esp), col = "#c7dcec", border = "grey50")
  lines(ks, sqrt(esp), col = "#cc3311", lwd = 2)
  abline(h = 0, col = "grey30")

  # (d) distancia de Cook
  cd <- cooks.distance(m)
  plot(cd, type = "h", col = "#336699", xlab = "observacao", ylab = "distancia de Cook",
       main = "(d) Influencia (Cook)")
  abline(h = 4 / nrow(d), col = "#cc3311", lty = 2)

  par(op)
  mtext_titulo <- paste0(f$rc$rotulo, " - modelo binomial negativa de votos")
  grDevices::dev.off()
  invisible(mtext_titulo)
}

# ---------------------------------------------------------------------
# 2. Painel de diagnostico do logit
# ---------------------------------------------------------------------
painel_logit <- function(f) {
  id <- f$rc$id
  if (!ok(f$m_logit)) return(invisible(NULL))
  m <- f$m_logit; d <- f$dados; y <- d$eleito; p <- as.numeric(fitted(m))

  abre(paste0("diag_logit_", id, ".png"), w = 2400, h = 900)
  op <- par(mfrow = c(1, 3), mar = c(4.2, 4.2, 3.0, 1.2), cex.main = 1.0, cex.lab = 0.95, cex.axis = 0.9)

  # (a) curva ROC
  r <- try(pROC::roc(y, p, quiet = TRUE), silent = TRUE)
  if (ok(r)) {
    plot(1 - r$specificities, r$sensitivities, type = "l", lwd = 2.5, col = "#336699",
         xlab = "1 - especificidade", ylab = "sensibilidade",
         main = sprintf("(a) ROC  |  AUC = %.3f", as.numeric(pROC::auc(r))))
    abline(0, 1, col = "grey60", lty = 2)
  } else plot.new()

  # (b) calibracao por decis de risco
  nb <- min(10, length(unique(quantile(p, seq(0, 1, 0.1)))) - 1)
  brk <- unique(quantile(p, probs = seq(0, 1, length.out = nb + 1)))
  g <- cut(p, breaks = brk, include.lowest = TRUE)
  pm <- tapply(p, g, mean); om <- tapply(y, g, mean)
  plot(pm, om, pch = 19, col = "#336699", xlim = range(c(pm, om)), ylim = range(c(pm, om)),
       xlab = "probabilidade prevista (media do grupo)", ylab = "frequencia observada",
       main = "(b) Calibracao por grupos de risco")
  abline(0, 1, col = "#cc3311", lwd = 2)

  # (c) residuos binados
  rb <- y - p
  rm_ <- tapply(rb, g, mean); se2 <- tapply(rb, g, function(z) 2 * sd(z) / sqrt(length(z)))
  plot(pm, rm_, pch = 19, col = "#336699", ylim = range(c(rm_, se2, -se2), na.rm = TRUE),
       xlab = "probabilidade prevista", ylab = "residuo medio do grupo",
       main = "(c) Residuos binados (+- 2 EP)")
  lines(pm, se2, col = "grey50", lty = 2); lines(pm, -se2, col = "grey50", lty = 2)
  abline(h = 0, col = "#cc3311", lwd = 2)

  par(op); grDevices::dev.off()
  invisible(TRUE)
}

# ---------------------------------------------------------------------
# 3. Figuras-resumo
# ---------------------------------------------------------------------
figuras_resumo <- function() {
  le <- function(x) utils::read.csv(file.path(DIR_OUT, x), encoding = "UTF-8")

  ordem <- c("DEPFED_2018", "DEPFED_2022", "DEPEST_2018", "DEPEST_2022",
             "VER_2020_PEQUENO", "VER_2020_MEDIO", "VER_2020_GRANDE", "VER_2020_METROPOLE",
             "VER_2024_PEQUENO", "VER_2024_MEDIO", "VER_2024_GRANDE", "VER_2024_METROPOLE")
  curto <- c("DF18", "DF22", "DE18", "DE22", "V20-P", "V20-M", "V20-G", "V20-Met",
             "V24-P", "V24-M", "V24-G", "V24-Met")

  # (i) elasticidade do impulsionamento entre especificacoes
  s <- le("19_sensibilidade_elasticidade.csv")
  esp <- c("NB2_glmnb", "NB1_glmmTMB", "Poisson", "ZINB", "Hurdle")
  M <- sapply(esp, function(e) sapply(ordem, function(r) {
    v <- s$coef_impulsionamento[s$recorte == r & s$especificacao == e]; if (length(v)) v[1] else NA }))
  abre("resumo_elasticidade_por_especificacao.png", w = 2400, h = 1300)
  par(mar = c(6.5, 4.5, 3, 8))
  cores <- c("#336699", "#ee7733", "#009988", "#cc3311", "#aa4499")
  matplot(M, type = "b", pch = 16, lty = 1, lwd = 2, col = cores, xaxt = "n",
          xlab = "", ylab = "coeficiente de log1p(gasto com impulsionamento)",
          main = "Elasticidade do impulsionamento por especificacao de contagem")
  axis(1, at = seq_along(ordem), labels = curto, las = 2, cex.axis = 0.85)
  abline(h = 0, col = "grey60", lty = 2); grid(nx = NA, ny = NULL)
  legend("topright", inset = c(-0.16, 0), legend = esp, col = cores, lwd = 2, pch = 16,
         bty = "n", xpd = TRUE, cex = 0.85)
  grDevices::dev.off()

  # (ii) sobredispersao: razao de Pearson do Poisson (log10) e theta do NB
  dsp <- le("10_dispersao_sobredispersao.csv")
  dsp <- dsp[match(ordem, dsp$recorte), ]
  abre("resumo_sobredispersao.png", w = 2400, h = 1200)
  par(mfrow = c(1, 2), mar = c(6.5, 4.8, 3, 1.5))
  barplot(log10(dsp$pearson_pois), names.arg = curto, las = 2, col = "#cc3311",
          ylab = "log10 da razao de dispersao (Poisson)",
          main = "Sobredispersao sob Poisson"); abline(h = 0, col = "grey30")
  barplot(dsp$theta, names.arg = curto, las = 2, col = "#336699",
          ylab = "theta estimado (NB2)", main = "Parametro de forma da NB")
  grDevices::dev.off()

  # (iii) AUC aparente x 10-fold x corrigida
  arq <- file.path(DIR_OUT, "25_logit_validacao.csv")
  if (file.exists(arq)) {
    v <- le("25_logit_validacao.csv"); v <- v[match(ordem, v$recorte), ]
    abre("resumo_auc.png", w = 2400, h = 1200)
    par(mar = c(6.5, 4.8, 3, 8))
    Mv <- rbind(v$AUC_aparente, v$AUC_10fold, v$AUC_corrigida)
    barplot(Mv, beside = TRUE, names.arg = curto, las = 2, ylim = c(0.5, 1.02),
            col = c("#336699", "#ee7733", "#009988"), ylab = "AUC",
            main = "Poder discriminante do logit: aparente, 10-fold e corrigida por otimismo")
    abline(h = c(0.7, 0.8, 0.9), col = "grey70", lty = 3)
    legend("topright", inset = c(-0.13, 0), legend = c("aparente", "10-fold", "corrigida"),
           fill = c("#336699", "#ee7733", "#009988"), bty = "n", xpd = TRUE, cex = 0.9)
    grDevices::dev.off()
  }

  # (iv) VIF maximo por recorte nos dois modelos
  v1 <- le("12_vif_modelos_contagem.csv")
  arq2 <- file.path(DIR_OUT, "22_vif_modelos_logit.csv")
  v2 <- if (file.exists(arq2)) le("22_vif_modelos_logit.csv") else NULL
  mx <- function(df) sapply(ordem, function(r) { z <- df$VIF[df$recorte == r]; if (length(z)) max(z) else NA })
  abre("resumo_vif.png", w = 2400, h = 1200)
  par(mar = c(6.5, 4.8, 3, 8))
  Mv <- if (is.null(v2)) rbind(mx(v1)) else rbind(mx(v1), mx(v2))
  barplot(Mv, beside = TRUE, names.arg = curto, las = 2, col = c("#336699", "#ee7733")[1:nrow(Mv)],
          ylab = "VIF maximo", main = "Multicolinearidade: maior VIF de cada modelo")
  abline(h = c(5, 10), col = c("#ee7733", "#cc3311"), lty = 2, lwd = 2)
  legend("topright", inset = c(-0.13, 0), legend = c("NB (votos)", "Logit (eleito)")[1:nrow(Mv)],
         fill = c("#336699", "#ee7733")[1:nrow(Mv)], bty = "n", xpd = TRUE, cex = 0.9)
  grDevices::dev.off()
}

# =====================================================================
msg("=== gerando figuras ===")
for (id in names(FITS)) {
  msg("  ", id)
  try(painel_contagem(FITS[[id]]), silent = TRUE)
  try(painel_logit(FITS[[id]]), silent = TRUE)
}
try(figuras_resumo(), silent = TRUE)
msg("figuras em: ", DIR_FIG, " (", length(list.files(DIR_FIG, pattern = "png$")), " arquivos)")
