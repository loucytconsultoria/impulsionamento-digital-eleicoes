# =====================================================================
# 02_dados.R -- reconstrucao FIEL das bases do TCC
# Reproduz passo a passo o ETL dos tres codigos originais do TCC (deputado
# federal, deputado estadual e vereador).
# Fonte: microdados do TSE (zips em DIR_DAD), identicos aos CSVs usados
# no TCC. Nenhuma alteracao de especificacao e' introduzida aqui.
# =====================================================================
# (pressupoe 00_setup.R ja carregado)

# ---- deflatores usados no TCC (mantidos exatamente) ------------------
FATOR_18_22 <- 1.2611       # gastos de 2022 -> precos de 2018
FATOR_20_24 <- 1.30501440   # gastos de 2024 -> precos de 2020

ZIPS <- list(
  cand = c("2018" = "consulta_cand_2018.zip", "2020" = "consulta_cand_2020.zip",
           "2022" = "consulta_cand_2022.zip", "2024" = "consulta_cand_2024.zip"),
  comp = c("2018" = "consulta_cand_complementar_2018.zip", "2020" = "consulta_cand_complementar_2020.zip",
           "2022" = "consulta_cand_complementar_2022.zip", "2024" = "consulta_cand_complementar_2024.zip"),
  desp = c("2018" = "prestacao_de_contas_eleitorais_candidatos_2018.zip", "2020" = "prestacao_de_contas_eleitorais_candidatos_2020.zip",
           "2022" = "prestacao_de_contas_eleitorais_candidatos_2022.zip", "2024" = "prestacao_de_contas_eleitorais_candidatos_2024.zip"),
  voto = c("2018" = "votacao_candidato_munzona_2018.zip", "2020" = "votacao_candidato_munzona_2020.zip",
           "2022" = "votacao_candidato_munzona_2022.zip", "2024" = "votacao_candidato_munzona_2024.zip")
)

le_bruto <- function(tipo, ano) {
  arq <- switch(tipo,
    cand = sprintf("consulta_cand_%s_PR.csv", ano),
    comp = sprintf("consulta_cand_complementar_%s_PR.csv", ano),
    desp = sprintf("despesas_contratadas_candidatos_%s_PR.csv", ano),
    voto = sprintf("votacao_candidato_munzona_%s_PR.csv", ano))
  ler_tse(extrair_pr(ZIPS[[tipo]][[ano]], arq))
}

# ---- mapa de ideologia partidaria (identico ao do TCC) ---------------
mapa_ideologia_completo <- tibble::tribble(
  ~SG_PARTIDO, ~f_ideologia,
  "PSD","CENTRO", "PP","DIREITA", "PL","DIREITA", "MDB","CENTRO",
  "UNIÃO","DIREITA", "REPUBLICANOS","DIREITA", "PT","ESQUERDA",
  "PODE","CENTRO", "PSB","ESQUERDA", "PDT","ESQUERDA", "PSDB","CENTRO",
  "PRD","DIREITA", "SOLIDARIEDADE","CENTRO", "NOVO","DIREITA",
  "AVANTE","CENTRO", "CIDADANIA","CENTRO", "PMB","CENTRO",
  "AGIR","CENTRO", "PRTB","DIREITA", "PV","ESQUERDA", "DC","CENTRO",
  "REDE","ESQUERDA", "MOBILIZA","CENTRO", "PSOL","ESQUERDA",
  "PC do B","ESQUERDA",
  "PROS","CENTRO", "DEM","DIREITA", "PTB","CENTRO", "PTC","CENTRO",
  "PSL","DIREITA", "PSC","DIREITA", "PATRIOTA","DIREITA", "PMN","CENTRO",
  "PCO","ESQUERDA", "PSTU","ESQUERDA",
  "PRB","DIREITA", "PPS","ESQUERDA", "PRP","DIREITA", "PHS","CENTRO",
  "PPL","ESQUERDA", "PR","DIREITA", "PCB","ESQUERDA"
) %>% distinct(SG_PARTIDO, .keep_all = TRUE)

# mapa de ideologia usado NO CODIGO DE VEREADOR 2024 (so partidos de 2024)
mapa_ideologia2024 <- mapa_ideologia_completo %>%
  filter(SG_PARTIDO %in% c("PSD","PP","PL","MDB","UNIÃO","REPUBLICANOS","PT","PODE","PSB",
                           "PDT","PSDB","PRD","SOLIDARIEDADE","NOVO","AVANTE","CIDADANIA",
                           "PMB","AGIR","PRTB","PV","DC","REDE","MOBILIZA","PSOL","PC do B"))

le_mapa_despesas <- function(ano) {
  m <- utils::read.csv(file.path(DIR_DIC, sprintf("mapa_despesas_%s.csv", ano)),
                       encoding = "UTF-8", check.names = FALSE)
  names(m) <- c("DS_ORIGEM_DESPESA", "CATEGORIA")
  m
}

# ---- agregacao de despesas por candidato (formula do TCC) ------------
agrega_despesas <- function(desp, mapa, cargo_desp = NULL) {
  d <- desp %>%
    mutate(VR_DESPESA_CONTRATADA = as.numeric(str_replace_all(as.character(VR_DESPESA_CONTRATADA), ",", ".")))
  if (!is.null(cargo_desp)) d <- d %>% filter(DS_CARGO == cargo_desp)
  d %>%
    left_join(mapa, by = "DS_ORIGEM_DESPESA") %>%
    group_by(SQ_CANDIDATO) %>%
    summarise(
      gasto_impulsionamento         = sum(VR_DESPESA_CONTRATADA[CATEGORIA == "IMPULSIONAMENTO"], na.rm = TRUE),
      gasto_publicidade_tradicional = sum(VR_DESPESA_CONTRATADA[CATEGORIA == "PUBLICIDADE_TRADICIONAL"], na.rm = TRUE),
      gasto_operacional             = sum(VR_DESPESA_CONTRATADA[CATEGORIA == "OPERACIONAL"], na.rm = TRUE),
      .groups = "drop") %>%
    mutate(gasto_total = gasto_impulsionamento + gasto_publicidade_tradicional + gasto_operacional)
}

# =====================================================================
# BLOCO A -- DEPUTADOS (federal e estadual), 2018 e 2022
# =====================================================================
monta_deputado <- function(ano, cargo_cand, cargo_desp) {
  cand <- le_bruto("cand", ano)
  comp <- le_bruto("comp", ano)
  desp <- le_bruto("desp", ano)
  voto <- le_bruto("voto", ano)
  mapa <- le_mapa_despesas(ano)

  despesas_agg <- agrega_despesas(desp, mapa, cargo_desp)
  votos_agg <- voto %>% filter(DS_CARGO == cargo_desp) %>%
    group_by(SQ_CANDIDATO) %>%
    summarise(total_votos = sum(QT_VOTOS_NOMINAIS, na.rm = TRUE), .groups = "drop")

  base <- cand %>%
    filter(DS_CARGO == cargo_cand) %>%
    dplyr::select(SQ_CANDIDATO, SG_PARTIDO, DS_GENERO, DS_GRAU_INSTRUCAO, DS_COR_RACA, DS_SIT_TOT_TURNO) %>%
    left_join(comp %>% dplyr::select(SQ_CANDIDATO, ST_REELEICAO), by = "SQ_CANDIDATO",
              relationship = "many-to-many") %>%
    distinct(SQ_CANDIDATO, .keep_all = TRUE) %>%
    left_join(despesas_agg, by = "SQ_CANDIDATO") %>%
    left_join(votos_agg, by = "SQ_CANDIDATO") %>%
    left_join(mapa_ideologia_completo, by = "SG_PARTIDO") %>%
    mutate(
      eleito            = ifelse(DS_SIT_TOT_TURNO %in% c("ELEITO POR MÉDIA", "ELEITO POR QP", "ELEITO"), 1, 0),
      reeleicao         = ifelse(ST_REELEICAO == "S", 1, 0),
      across(starts_with("gasto_"), ~ifelse(is.na(.), 0, .)),
      total_votos       = ifelse(is.na(total_votos) | total_votos < 0, 0, total_votos),
      masculino         = ifelse(DS_GENERO == "MASCULINO", 1, 0),
      corbranca         = ifelse(DS_COR_RACA == "BRANCA", 1, 0),
      superior_completo = ifelse(DS_GRAU_INSTRUCAO == "SUPERIOR COMPLETO", 1, 0),
      esquerda          = ifelse(f_ideologia == "ESQUERDA", 1, 0),
      centro            = ifelse(f_ideologia == "CENTRO", 1, 0),
      direita           = ifelse(f_ideologia == "DIREITA", 1, 0)
    ) %>%
    mutate(across(c(total_votos, eleito, reeleicao, masculino, corbranca,
                    superior_completo, esquerda, centro, direita), ~ifelse(is.na(.), 0, .)))

  if (ano == "2022") {
    base <- base %>%
      mutate(gasto_impulsionamento_deflacionado = gasto_impulsionamento / FATOR_18_22,
             gasto_tradicional_deflacionado     = gasto_publicidade_tradicional / FATOR_18_22,
             gasto_operacional_deflacionado     = gasto_operacional / FATOR_18_22,
             gasto_total_deflacionado           = gasto_total / FATOR_18_22) %>%
      mutate(across(ends_with("_deflacionado"), ~ifelse(is.na(.) | !is.finite(.) | . < 0, 0, .)))
  }
  base
}

# =====================================================================
# BLOCO B -- VEREADORES, 2020 e 2024, por porte de municipio
# =====================================================================
pop_pr_clean <- utils::read.csv(file.path(DIR_DIC, "populacao_municipios_PR.csv"), encoding = "UTF-8") %>%
  dplyr::select(CIDADE, POPULACAO) %>% distinct(CIDADE, .keep_all = TRUE)

classifica_porte <- function(pop) {
  as.factor(case_when(
    pop <= 20000                   ~ "PEQUENO",
    pop >  20000 & pop <= 100000   ~ "MEDIO",
    pop >  100000 & pop <= 1000000 ~ "GRANDE",
    pop >  1000000                 ~ "METROPOLE",
    TRUE                           ~ "NAO_CLASSIFICADO"))
}

monta_vereador <- function(ano) {
  cand <- le_bruto("cand", ano)
  comp <- le_bruto("comp", ano)
  desp <- le_bruto("desp", ano)
  voto <- le_bruto("voto", ano)
  mapa <- le_mapa_despesas(ano)

  despesas_agg <- agrega_despesas(desp, mapa, NULL)   # o TCC nao filtrou cargo aqui
  votos_agg <- voto %>%
    { if (ano == "2020") filter(., DS_CARGO == "Vereador") else . } %>%
    group_by(SQ_CANDIDATO) %>%
    summarise(total_votos = sum(QT_VOTOS_NOMINAIS, na.rm = TRUE), .groups = "drop")

  cols_comp <- c("SQ_CANDIDATO", "ST_REELEICAO")
  if (ano == "2024") cols_comp <- c(cols_comp, "ST_CANDIDATO_INSERIDO_URNA")

  base <- cand %>%
    dplyr::select(NM_UE, DS_CARGO, SQ_CANDIDATO, SG_PARTIDO, DS_GENERO,
                  DS_GRAU_INSTRUCAO, DS_COR_RACA, DS_SIT_TOT_TURNO) %>%
    left_join(comp %>% dplyr::select(all_of(cols_comp)), by = "SQ_CANDIDATO",
              relationship = "many-to-many") %>%
    mutate(CIDADE = limpar_nomes_robusta(NM_UE)) %>%
    filter(DS_CARGO == "VEREADOR")

  if (ano == "2024") base <- base %>% filter(ST_CANDIDATO_INSERIDO_URNA == "SIM")

  mapa_ideo <- if (ano == "2024") mapa_ideologia2024 else mapa_ideologia_completo

  base <- base %>%
    distinct(SQ_CANDIDATO, .keep_all = TRUE) %>%
    left_join(despesas_agg, by = "SQ_CANDIDATO") %>%
    left_join(votos_agg, by = "SQ_CANDIDATO") %>%
    left_join(pop_pr_clean, by = "CIDADE") %>%
    left_join(mapa_ideo, by = "SG_PARTIDO") %>%
    filter(!is.na(POPULACAO)) %>%
    mutate(
      eleito            = ifelse(DS_SIT_TOT_TURNO %in% c("ELEITO POR MÉDIA", "ELEITO POR QP", "ELEITO"), 1, 0),
      reeleicao         = ifelse(ST_REELEICAO == "S", 1, 0),
      across(starts_with("gasto_"), ~ifelse(is.na(.), 0, .)),
      total_votos       = ifelse(is.na(total_votos), 0, total_votos),
      masculino         = ifelse(DS_GENERO == "MASCULINO", 1, 0),
      corbranca         = ifelse(DS_COR_RACA == "BRANCA", 1, 0),
      superior_completo = ifelse(DS_GRAU_INSTRUCAO == "SUPERIOR COMPLETO", 1, 0),
      esquerda          = ifelse(f_ideologia == "ESQUERDA", 1, 0),
      centro            = ifelse(f_ideologia == "CENTRO", 1, 0),
      direita           = ifelse(f_ideologia == "DIREITA", 1, 0),
      f_porte_municipio = classifica_porte(POPULACAO)
    ) %>%
    mutate(across(c(esquerda, centro, direita), ~ifelse(is.na(.), 0, .)))

  if (ano == "2024") {
    base <- base %>%
      mutate(gasto_impulsionamento_deflacionado = gasto_impulsionamento / FATOR_20_24,
             gasto_tradicional_deflacionado     = gasto_publicidade_tradicional / FATOR_20_24,
             gasto_operacional_deflacionado     = gasto_operacional / FATOR_20_24,
             gasto_total_deflacionado           = gasto_total / FATOR_20_24)
  }
  base
}

# =====================================================================
# EXECUCAO
# =====================================================================
msg("montando bases...")
BASES <- list(
  DEPFED_2018 = monta_deputado("2018", "DEPUTADO FEDERAL",  "Deputado Federal"),
  DEPFED_2022 = monta_deputado("2022", "DEPUTADO FEDERAL",  "Deputado Federal"),
  DEPEST_2018 = monta_deputado("2018", "DEPUTADO ESTADUAL", "Deputado Estadual"),
  DEPEST_2022 = monta_deputado("2022", "DEPUTADO ESTADUAL", "Deputado Estadual"),
  VEREADOR_2020 = monta_vereador("2020"),
  VEREADOR_2024 = monta_vereador("2024")
)

saveRDS(BASES, file.path(DIR_TRAT, "bases_tcc.rds"))

# ---- auditoria de reproducao vs. numeros impressos no TCC ------------
alvos <- tibble::tribble(
  ~base, ~grupo, ~n_TCC,
  "DEPFED_2018", "TOTAL", 450, "DEPFED_2022", "TOTAL", 632,
  "DEPEST_2018", "TOTAL", 767, "DEPEST_2022", "TOTAL", 902,
  "VEREADOR_2024", "PEQUENO", 16719, "VEREADOR_2024", "MEDIO", 8206,
  "VEREADOR_2024", "GRANDE", 5113, "VEREADOR_2024", "METROPOLE", 735
)

aud <- purrr::map_dfr(names(BASES), function(b) {
  d <- BASES[[b]]
  if (grepl("VEREADOR", b)) {
    tibble(base = b, grupo = as.character(d$f_porte_municipio)) %>% count(base, grupo, name = "n_agora")
  } else {
    tibble(base = b, grupo = "TOTAL", n_agora = nrow(d))
  }
}) %>% left_join(alvos, by = c("base", "grupo")) %>%
  mutate(dif = n_agora - n_TCC)

print(as.data.frame(aud))
gravar(aud, "01_auditoria_reproducao_amostras.csv")

# ---- rubricas de despesa nao classificadas pelo mapa do TCC ----------
nao_class <- purrr::map_dfr(c("2018", "2020", "2022", "2024"), function(ano) {
  desp <- le_bruto("desp", ano) %>%
    mutate(VR_DESPESA_CONTRATADA = as.numeric(str_replace_all(as.character(VR_DESPESA_CONTRATADA), ",", ".")))
  mapa <- le_mapa_despesas(ano)
  desp %>% left_join(mapa, by = "DS_ORIGEM_DESPESA") %>%
    filter(is.na(CATEGORIA)) %>%
    group_by(ano = ano, DS_ORIGEM_DESPESA) %>%
    summarise(n_lancamentos = n(), valor_total = sum(VR_DESPESA_CONTRATADA, na.rm = TRUE), .groups = "drop")
})
print(as.data.frame(nao_class))
gravar(nao_class, "02_rubricas_nao_classificadas.csv")

msg("bases prontas: ", paste(names(BASES), collapse = ", "))
