# =====================================================================
# 10_suporte_impulsionamento.R
# Diagnostico que faltava: SUPORTE da variavel de interesse.
# O gasto com impulsionamento e zero para a maioria esmagadora dos
# candidatos nos recortes menores. Como log1p(0) = 0, o coeficiente do
# TCC mistura duas coisas: a margem EXTENSIVA (usar ou nao usar) e a
# margem INTENSIVA (quanto gastar, entre quem usa). Este script separa
# as duas e verifica se o gradiente por porte sobrevive a separacao.
# =====================================================================
# (pressupoe 00_setup.R carregado)

FITS  <- readRDS(file.path(DIR_TRAT, "fits_tcc.rds"))
BASES <- readRDS(file.path(DIR_TRAT, "bases_tcc.rds"))
ok <- function(x) !is.null(x) && !inherits(x, "try-error")
CONTROLES <- c("reeleicao", "masculino", "superior_completo", "corbranca", "esquerda", "direita")

# ---- 1. adocao e concentracao do suporte -----------------------------
msg("(1) suporte da variavel de interesse")
T_sup <- purrr::map_dfr(names(FITS), function(id) {
  f <- FITS[[id]]; d <- f$dados
  x <- d[[f$vg[["impulsionamento"]]]]
  usa <- x > 0
  tibble(recorte = id, rotulo = f$rc$rotulo, n = nrow(d),
         n_usuarios = sum(usa), taxa_adocao = mean(usa),
         gasto_medio_entre_usuarios = if (any(usa)) mean(x[usa]) else NA,
         mediana_entre_usuarios = if (any(usa)) median(x[usa]) else NA,
         p90_entre_usuarios = if (any(usa)) quantile(x[usa], .9) else NA,
         maximo = max(x),
         # concentracao: quanto do gasto total esta nos 10 maiores
         share_top10 = if (any(usa)) sum(sort(x, decreasing = TRUE)[1:min(10, sum(usa))]) / sum(x) else NA)
})
gravar(T_sup, "50_suporte_impulsionamento.csv")
print(as.data.frame(T_sup))

# ---- 2. decomposicao extensiva / intensiva ---------------------------
# y ~ usou + log1p(gasto) + controles  (com log1p(gasto)=0 quando usou=0)
# 'usou'  = salto ao passar de nao usuario a usuario minimo
# 'log1p' = efeito de gastar mais, ENTRE quem ja usa
msg("(2) decomposicao das margens")
T_dec <- purrr::map_dfr(names(FITS), function(id) {
  f <- FITS[[id]]; d <- f$dados
  vi <- f$vg[["impulsionamento"]]
  d$usou_impuls <- as.integer(d[[vi]] > 0)
  if (sum(d$usou_impuls) < 30) return(NULL)
  fdec <- as.formula(paste("total_votos ~ usou_impuls +",
                           paste0("log1p(", unname(f$vg), ")", collapse = " + "),
                           "+", paste(CONTROLES, collapse = " + ")))
  environment(fdec) <- environment()
  m <- try(glmmTMB(fdec, data = d, family = nbinom2(link = "log")), silent = TRUE)
  if (!ok(m)) return(NULL)
  s <- summary(m)$coefficients$cond
  nm <- paste0("log1p(", vi, ")")
  s0 <- summary(f$m_nb_tmb)$coefficients$cond
  tibble(recorte = id, rotulo = f$rc$rotulo, n = nrow(d),
         taxa_adocao = mean(d$usou_impuls),
         coef_TCC = s0[nm, 1], ep_TCC = s0[nm, 2],
         coef_extensivo = s["usou_impuls", 1], ep_extensivo = s["usou_impuls", 2],
         p_extensivo = s["usou_impuls", 4],
         coef_intensivo = s[nm, 1], ep_intensivo = s[nm, 2], p_intensivo = s[nm, 4],
         efeito_extensivo_pct = 100 * (exp(s["usou_impuls", 1]) - 1),
         AIC_TCC = AIC(f$m_nb_tmb), AIC_decomposto = AIC(m),
         dAIC = AIC(m) - AIC(f$m_nb_tmb))
})
gravar(T_dec, "51_margem_extensiva_intensiva.csv")
print(as.data.frame(T_dec))

# ---- 3. o gradiente por porte sobrevive a separacao das margens? -----
msg("(3) gradiente por porte com margens separadas")
T_grad2 <- purrr::map_dfr(c("2020", "2024"), function(ano) {
  d <- BASES[[paste0("VEREADOR_", ano)]]
  d <- d[as.character(d$f_porte_municipio) %in% c("PEQUENO", "MEDIO", "GRANDE", "METROPOLE"), ]
  d$porte <- factor(as.character(d$f_porte_municipio),
                    levels = c("PEQUENO", "MEDIO", "GRANDE", "METROPOLE"))
  vg <- if (ano == "2020")
    c("gasto_impulsionamento", "gasto_publicidade_tradicional", "gasto_operacional") else
    c("gasto_impulsionamento_deflacionado", "gasto_tradicional_deflacionado", "gasto_operacional_deflacionado")
  d <- d[stats::complete.cases(d[, c("total_votos", vg, CONTROLES)]), ]
  d$usou_impuls <- as.integer(d[[vg[1]]] > 0)

  rhs <- paste0("log1p(", vg[-1], ")", collapse = " + ")
  ctl <- paste(CONTROLES, collapse = " + ")
  # restrito: margens iguais entre portes
  f0 <- as.formula(paste("total_votos ~ usou_impuls + log1p(", vg[1], ") +", rhs, "+", ctl, "+ porte"))
  # livre: as DUAS margens variam por porte
  f1 <- as.formula(paste("total_votos ~ porte * usou_impuls + porte * log1p(", vg[1], ") +",
                         rhs, "+", ctl))
  # so a margem extensiva varia
  f2 <- as.formula(paste("total_votos ~ porte * usou_impuls + log1p(", vg[1], ") +", rhs, "+", ctl))
  # so a margem intensiva varia
  f3 <- as.formula(paste("total_votos ~ usou_impuls + porte * log1p(", vg[1], ") +", rhs, "+", ctl))
  environment(f0) <- environment(f1) <- environment(f2) <- environment(f3) <- environment()

  ms <- lapply(list(f0, f1, f2, f3), function(ff)
    try(glmmTMB(ff, data = d, family = nbinom2(link = "log")), silent = TRUE))
  if (!all(sapply(ms, ok))) return(NULL)
  lr <- function(a, b) {
    L <- as.numeric(2 * (logLik(b) - logLik(a)))
    gl <- length(glmmTMB::fixef(b)$cond) - length(glmmTMB::fixef(a)$cond)
    c(L, gl, pchisq(max(L, 0), df = gl, lower.tail = FALSE))
  }
  a1 <- lr(ms[[1]], ms[[2]]); a2 <- lr(ms[[1]], ms[[3]]); a3 <- lr(ms[[1]], ms[[4]])
  b <- glmmTMB::fixef(ms[[2]])$cond
  base_e <- "usou_impuls"; base_i <- paste0("log1p(", vg[1], ")")
  pega <- function(base, p) {
    if (p == "PEQUENO") return(b[[base]])
    cand <- c(paste0("porte", p, ":", base), paste0(base, ":porte", p))
    nm <- cand[cand %in% names(b)][1]
    if (is.na(nm)) NA else b[[base]] + b[[nm]]
  }
  tibble(ano = ano, n = nrow(d), taxa_adocao = mean(d$usou_impuls),
         LR_ambas_margens = a1[1], gl_ambas = a1[2], p_ambas = a1[3],
         LR_so_extensiva = a2[1], gl_ext = a2[2], p_extensiva = a2[3],
         LR_so_intensiva = a3[1], gl_int = a3[2], p_intensiva = a3[3],
         ext_PEQUENO = pega(base_e, "PEQUENO"), ext_MEDIO = pega(base_e, "MEDIO"),
         ext_GRANDE = pega(base_e, "GRANDE"), ext_METROPOLE = pega(base_e, "METROPOLE"),
         int_PEQUENO = pega(base_i, "PEQUENO"), int_MEDIO = pega(base_i, "MEDIO"),
         int_GRANDE = pega(base_i, "GRANDE"), int_METROPOLE = pega(base_i, "METROPOLE"))
})
gravar(T_grad2, "52_gradiente_margens_separadas.csv")
print(as.data.frame(T_grad2))

# ---- 4. adocao por porte (para mostrar a confusao com o gradiente) ---
msg("(4) adocao por porte")
T_ado <- purrr::map_dfr(c("2020", "2024"), function(ano) {
  d <- BASES[[paste0("VEREADOR_", ano)]]
  vi <- if (ano == "2020") "gasto_impulsionamento" else "gasto_impulsionamento_deflacionado"
  d %>% filter(as.character(f_porte_municipio) != "NAO_CLASSIFICADO") %>%
    group_by(ano = ano, porte = as.character(f_porte_municipio)) %>%
    summarise(n = n(), n_usuarios = sum(.data[[vi]] > 0),
              taxa_adocao = mean(.data[[vi]] > 0),
              gasto_medio_usuarios = mean(.data[[vi]][.data[[vi]] > 0]),
              .groups = "drop")
})
gravar(T_ado, "53_adocao_por_porte.csv")
print(as.data.frame(T_ado))

msg("suporte concluido")
