# =====================================================================
# 09_explicacoes.R -- quantifica o efeito PRATICO de cada uma das quatro
# reprovacoes, para que a explicacao nao fique hipotetica.
#  (A) erro "television": reestima o vereador 2024 com o mapa corrigido
#  (B) separacao: compara TODOS os coeficientes, MV contra Firth
#  (C) independencia: efeito de desenho e correlacao intraclasse
#  (D) eventos por variavel: instabilidade por bootstrap do logit
# =====================================================================
# (pressupoe 00_setup.R carregado)

FITS  <- readRDS(file.path(DIR_TRAT, "fits_tcc.rds"))
BASES <- readRDS(file.path(DIR_TRAT, "bases_tcc.rds"))
ok <- function(x) !is.null(x) && !inherits(x, "try-error")
CONTROLES <- c("reeleicao", "masculino", "superior_completo", "corbranca", "esquerda", "direita")

# =====================================================================
# (A) EFEITO DO ERRO DE GRAFIA NO MAPA DE DESPESAS DE 2024
# =====================================================================
msg("(A) reestimando vereador 2024 com o mapa de despesas corrigido")

mapa24 <- utils::read.csv(file.path(DIR_DIC, "mapa_despesas_2024.csv"), encoding = "UTF-8")
names(mapa24) <- c("DS_ORIGEM_DESPESA", "CATEGORIA")

# correcao 1: so a grafia de "televisao"
mapa_c1 <- mapa24
mapa_c1$DS_ORIGEM_DESPESA[grepl("television", mapa_c1$DS_ORIGEM_DESPESA)] <-
  "Produção de programas de rádio, televisão ou vídeo"

# correcao 2: grafia + rubricas que faltavam no mapa (todas operacionais)
mapa_c2 <- rbind(mapa_c1, data.frame(
  DS_ORIGEM_DESPESA = c("Despesa com geradores de energia", "Encargos sociais",
                        "Reembolsos de gastos realizados por eleitores", "#NULO#"),
  CATEGORIA = "OPERACIONAL"))
mapa_c2 <- mapa_c2[!duplicated(mapa_c2$DS_ORIGEM_DESPESA), ]

FATOR_20_24 <- 1.30501440
desp24 <- ler_tse(extrair_pr("prestacao_de_contas_eleitorais_candidatos_2024.zip",
                             "despesas_contratadas_candidatos_2024_PR.csv"))
desp24$VR_DESPESA_CONTRATADA <- as.numeric(str_replace_all(as.character(desp24$VR_DESPESA_CONTRATADA), ",", "."))

agrega <- function(mapa) {
  desp24 %>% left_join(mapa, by = "DS_ORIGEM_DESPESA") %>%
    group_by(SQ_CANDIDATO) %>%
    summarise(gi = sum(VR_DESPESA_CONTRATADA[CATEGORIA == "IMPULSIONAMENTO"], na.rm = TRUE),
              gt = sum(VR_DESPESA_CONTRATADA[CATEGORIA == "PUBLICIDADE_TRADICIONAL"], na.rm = TRUE),
              go = sum(VR_DESPESA_CONTRATADA[CATEGORIA == "OPERACIONAL"], na.rm = TRUE),
              .groups = "drop")
}

base24 <- BASES$VEREADOR_2024
versao <- function(mapa, tag) {
  a <- agrega(mapa)
  d <- base24 %>% dplyr::select(-any_of(c("gasto_impulsionamento", "gasto_publicidade_tradicional",
                                          "gasto_operacional", "gasto_total",
                                          "gasto_impulsionamento_deflacionado", "gasto_tradicional_deflacionado",
                                          "gasto_operacional_deflacionado", "gasto_total_deflacionado"))) %>%
    left_join(a, by = "SQ_CANDIDATO") %>%
    mutate(across(c(gi, gt, go), ~ifelse(is.na(.), 0, .)),
           gasto_impulsionamento_deflacionado = gi / FATOR_20_24,
           gasto_tradicional_deflacionado     = gt / FATOR_20_24,
           gasto_operacional_deflacionado     = go / FATOR_20_24)
  d$.tag <- tag
  d
}

vs <- list(original = versao(mapa24, "original"),
           grafia   = versao(mapa_c1, "grafia corrigida"),
           completo = versao(mapa_c2, "grafia + rubricas faltantes"))

# quanto muda o volume de gasto tradicional
res_gasto <- purrr::map_dfr(names(vs), function(k) {
  d <- vs[[k]]
  tibble(versao = k,
         total_tradicional = sum(d$gasto_tradicional_deflacionado),
         total_operacional = sum(d$gasto_operacional_deflacionado),
         total_impulsionamento = sum(d$gasto_impulsionamento_deflacionado),
         n_com_tradicional = sum(d$gasto_tradicional_deflacionado > 0))
})
gravar(res_gasto, "40A_volume_gasto_por_versao_mapa.csv")
print(as.data.frame(res_gasto))

vg24 <- c("gasto_impulsionamento_deflacionado", "gasto_tradicional_deflacionado",
          "gasto_operacional_deflacionado")
f24 <- as.formula(paste("total_votos ~", paste0("log1p(", vg24, ")", collapse = " + "),
                        "+", paste(CONTROLES, collapse = " + ")))

res_coef <- purrr::map_dfr(names(vs), function(k) {
  d0 <- vs[[k]]
  purrr::map_dfr(c("PEQUENO", "MEDIO", "GRANDE", "METROPOLE"), function(p) {
    d <- d0[as.character(d0$f_porte_municipio) == p, ]
    d <- d[stats::complete.cases(d[, c("total_votos", vg24, CONTROLES)]), ]
    m <- try(glmmTMB(f24, data = d, family = nbinom2(link = "log")), silent = TRUE)
    if (!ok(m)) return(NULL)
    s <- summary(m)$coefficients$cond
    tibble(versao = k, porte = p, n = nrow(d),
           impuls = s[paste0("log1p(", vg24[1], ")"), 1],
           ep_impuls = s[paste0("log1p(", vg24[1], ")"), 2],
           trad = s[paste0("log1p(", vg24[2], ")"), 1],
           ep_trad = s[paste0("log1p(", vg24[2], ")"), 2],
           oper = s[paste0("log1p(", vg24[3], ")"), 1],
           ep_oper = s[paste0("log1p(", vg24[3], ")"), 2],
           AIC = AIC(m))
  })
})
gravar(res_coef, "40B_coeficientes_mapa_corrigido.csv")
print(as.data.frame(res_coef))

# =====================================================================
# (B) SEPARACAO: TODOS OS COEFICIENTES, MAXIMA VEROSSIMILHANCA x FIRTH
# =====================================================================
msg("(B) separacao: MV contra Firth")
SEPARADOS <- c("DEPFED_2018", "DEPFED_2022", "DEPEST_2022", "VER_2020_METROPOLE")
res_sep <- purrr::map_dfr(SEPARADOS, function(id) {
  f <- FITS[[id]]
  s <- summary(f$m_logit)$coefficients
  fi <- f$m_logit_firth
  tibble(recorte = id, termo = rownames(s),
         coef_MV = s[, 1], ep_MV = s[, 2], p_MV = s[, 4],
         coef_Firth = coef(fi)[match(rownames(s), names(coef(fi)))],
         ep_Firth = sqrt(diag(vcov(fi)))[match(rownames(s), names(coef(fi)))],
         p_Firth = fi$prob[match(rownames(s), names(coef(fi)))]) %>%
    mutate(razao_ep = ep_MV / ep_Firth,
           variacao_coef_pct = 100 * (coef_Firth - coef_MV) / abs(coef_MV))
})
gravar(res_sep, "41_separacao_MV_vs_Firth.csv")
print(as.data.frame(res_sep %>% dplyr::select(recorte, termo, coef_MV, ep_MV, coef_Firth, ep_Firth, razao_ep)))

# =====================================================================
# (C) INDEPENDENCIA: efeito de desenho e correlacao intraclasse
# =====================================================================
msg("(C) efeito de desenho")
icc <- utils::read.csv(file.path(DIR_OUT, "30_agrupamento_municipio.csv"), encoding = "UTF-8")
res_icc <- purrr::map_dfr(seq_len(nrow(icc)), function(i) {
  id <- icc$recorte[i]
  f <- FITS[[id]]
  th <- f$theta_hat
  tam <- table(f$dados$CIDADE)
  m_bar <- mean(tam)
  # variancia na escala do preditor linear: municipal + a induzida pela NB
  var_nb <- log1p(1 / th)
  rho <- icc$var_municipio[i] / (icc$var_municipio[i] + var_nb)
  tibble(recorte = id, n = nrow(f$dados), n_municipios = icc$n_municipios[i],
         candidatos_por_municipio = m_bar, mediana_por_municipio = median(tam),
         var_municipio = icc$var_municipio[i], var_nb_implicada = var_nb,
         rho_intraclasse = rho,
         efeito_desenho = 1 + (m_bar - 1) * rho,
         n_efetivo = nrow(f$dados) / (1 + (m_bar - 1) * rho),
         ep_subestimado_fator = sqrt(1 + (m_bar - 1) * rho))
})
gravar(res_icc, "42_efeito_desenho.csv")
print(as.data.frame(res_icc))

# =====================================================================
# (D) EVENTOS POR VARIAVEL: instabilidade do logit por bootstrap
# =====================================================================
msg("(D) instabilidade do logit por bootstrap")
set.seed(20260809)
B <- 500
res_epv <- purrr::map_dfr(c("DEPFED_2018", "DEPFED_2022", "DEPEST_2018",
                            "VER_2024_MEDIO", "VER_2024_PEQUENO"), function(id) {
  f <- FITS[[id]]
  d <- f$dados
  fl <- f$f_logit; environment(fl) <- environment()
  nome <- paste0("log1p(", f$vg[["impulsionamento"]], ")")
  b0 <- coef(f$m_logit)[nome]
  bs <- rep(NA_real_, B)
  for (b in seq_len(B)) {
    ib <- sample.int(nrow(d), nrow(d), replace = TRUE)
    db <- d[ib, , drop = FALSE]
    if (length(unique(db$eleito)) < 2) next
    mb <- try(suppressWarnings(glm(fl, data = db, family = binomial())), silent = TRUE)
    if (ok(mb)) bs[b] <- coef(mb)[nome]
  }
  bs <- bs[is.finite(bs)]
  g <- utils::read.csv(file.path(DIR_OUT, "20_logit_discriminacao_calibracao.csv"), encoding = "UTF-8")
  epv <- g$epv[g$recorte == id][1]
  tibble(recorte = id, eventos_por_variavel = epv, coef_amostra = unname(b0),
         B_validos = length(bs), mediana_boot = median(bs),
         q025 = quantile(bs, .025), q975 = quantile(bs, .975),
         amplitude_IC = quantile(bs, .975) - quantile(bs, .025),
         dp_boot = sd(bs),
         prop_absurdos = mean(abs(bs) > 5),
         viés_mediano = median(bs) - unname(b0))
})
gravar(res_epv, "43_instabilidade_logit_bootstrap.csv")
print(as.data.frame(res_epv))

msg("explicacoes quantificadas")
