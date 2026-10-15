# =====================================================================
# 01_populacao.R -- dicionario de populacao dos municipios do PR
# O codigo original do TCC lia "populacaomunicipiospr.csv", que nao esta
# mais na pasta. Reconstruimos a partir da fonte primaria (IBGE/SIDRA),
# com fallback para o Censo 2010 (abjData::pnud_muni).
# =====================================================================
# (pressupoe 00_setup.R ja carregado)

DEST <- file.path(DIR_DIC, "populacao_municipios_PR.csv")

if (file.exists(DEST)) {
  msg("dicionario de populacao ja existe: ", DEST)
} else {
  pop <- NULL

  # --- Fonte 1: SIDRA tabela 4714 (Censo 2022, populacao residente) ----
  try({
    suppressPackageStartupMessages(library(sidrar))
    msg("baixando SIDRA 4714 (Censo 2022) para o PR...")
    br <- sidrar::get_sidra(x = 4714, variable = 93,
                            geo = "City", geo.filter = list("State" = 41))
    br <- as.data.frame(br)
    nm_val <- intersect(c("Valor", "valor"), names(br))[1]
    cols_mun <- grep("^Munic", names(br), value = TRUE)
    nm_cod <- grep("digo", cols_mun, value = TRUE)[1]           # "Municipio (Codigo)"
    nm_mun <- setdiff(cols_mun, nm_cod)[1]                       # "Municipio"
    pop <- data.frame(
      cod_mun   = as.character(br[[nm_cod]]),
      MUNICIPIO = as.character(br[[nm_mun]]),
      POPULACAO = as.numeric(br[[nm_val]]),
      fonte     = "IBGE Censo 2022 (SIDRA 4714, var 93)"
    )
    pop <- pop[!is.na(pop$POPULACAO), ]
    msg("SIDRA OK: ", nrow(pop), " municipios")
  }, silent = FALSE)

  # --- Fonte 2 (fallback): abjData::pnud_muni, Censo 2010 --------------
  if (is.null(pop) || nrow(pop) < 300) {
    msg("fallback: abjData::pnud_muni (Censo 2010)")
    suppressPackageStartupMessages(library(abjData))
    pm <- abjData::pnud_muni
    pm <- pm[pm$uf_sigla == "PR" & pm$ano == 2010, ]
    pop <- data.frame(
      cod_mun   = as.character(pm[[intersect(c("cod_mun6", "cod_mun"), names(pm))[1]]]),
      MUNICIPIO = as.character(pm$muni_nm),
      POPULACAO = as.numeric(pm$pop),
      fonte     = "IBGE Censo 2010 (abjData::pnud_muni)"
    )
  }

  nome_limpo <- sub("\\s*\\(PR\\)\\s*$", "", pop$MUNICIPIO)
  nome_limpo <- sub("\\s*-\\s*PR\\s*$", "", nome_limpo)      # SIDRA traz "Abatia - PR"
  pop$CIDADE <- limpar_nomes_robusta(nome_limpo)
  pop <- pop[!duplicated(pop$CIDADE), c("cod_mun", "MUNICIPIO", "CIDADE", "POPULACAO", "fonte")]
  utils::write.csv(pop, DEST, row.names = FALSE, fileEncoding = "UTF-8")
  msg("gravado: ", DEST, " (", nrow(pop), " municipios)")
}

pop_pr <- utils::read.csv(DEST, encoding = "UTF-8")
msg("populacao PR | n=", nrow(pop_pr),
    " | >1M: ", sum(pop_pr$POPULACAO > 1e6),
    " | 100k-1M: ", sum(pop_pr$POPULACAO > 1e5 & pop_pr$POPULACAO <= 1e6),
    " | 20k-100k: ", sum(pop_pr$POPULACAO > 2e4 & pop_pr$POPULACAO <= 1e5),
    " | <=20k: ", sum(pop_pr$POPULACAO <= 2e4))
