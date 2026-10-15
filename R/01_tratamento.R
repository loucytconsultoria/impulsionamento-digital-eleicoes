# =============================================================================
# 01_tratamento.R  -  ETL: do bruto do TSE aos paineis tratados
# -----------------------------------------------------------------------------
# Implementa a especificacao de docs/02_etl_tratamento.md (passos 1 a 13).
# Executar a partir da raiz do repositorio (os caminhos dados/, dados_tratados/ e
# dicionarios/ sao relativos a ela).
# Parametrizado por (UF, ano, cargo). Le o cache bruto do TSE em dados/ (baixa se
# faltar), monta UMA linha por candidato, classifica e soma a despesa de forma
# auditavel, deflaciona por tabela IPCA versionada (offline) e TRAVA a saida
# contra valores impossiveis antes de salvar.
#
# Saidas em dados_tratados/:
#   painel_<UF>_<ANO>_<CARGO>.csv              -> uma linha por candidato (o motor le)
#   despesas_classificadas_<UF>_<ANO>_<CARGO>.csv -> auditoria da classificacao
#   log_tratamento_<UF>_<ANO>_<CARGO>.md       -> contagens por passo e travas
#
# AUTOSSUFICIENTE e SEM IA. Roda em R puro. As travas PARAM a execucao (stop) em
# vez de gravar um numero impossivel: e' uma decisao de desenho (ver passo 12).
# =============================================================================

# ------------------------------ 0. PACOTES -----------------------------------
suppressMessages({
  library(data.table); library(dplyr); library(stringi); library(tidyr)
})
# electionsBR so' e' carregado se precisar baixar (o cache cobre o PR).

# ------------------------------ 1. CONFIG ------------------------------------
CFG <- list(
  dir_cache    = "dados/",
  dir_tratado  = "dados_tratados/",
  dir_dict     = "dicionarios/",
  ipca_csv     = "dicionarios/ipca_indice.csv",
  fator_min    = 0.5,   # trava do fator de deflacao (passo 8)
  fator_max    = 2.5
)
for (d in c(CFG$dir_cache, CFG$dir_tratado, CFG$dir_dict))
  dir.create(d, recursive = TRUE, showWarnings = FALSE)

# Base de precos por ESCOPO (decisao de desenho, ETL passo 8):
#   deputado -> out/2022 ; vereador -> out/2024. A eleicao mais recente do escopo.
base_preco <- function(cargo) if (grepl("VEREADOR", toupper(cargo))) "202410" else "202210"

# Teto legal nominal do TSE, para a trava de 2x (passo 12).
#   Deputado: tabela oficial do TSE. Vereador: limite e' MUNICIPAL e nao ha' numero
#   unico; usa-se um teto-sanidade generoso (ver nota no log), cujo papel e' barrar
#   inflacao impossivel (milhoes/dezenas de milhoes), nao a conformidade legal exata.
TETO_LEGAL <- function(cargo, ano) {
  k <- toupper(cargo)
  if (grepl("DEPUTADO FEDERAL", k))  return(c(`2018`=2500000, `2022`=3176400)[[as.character(ano)]])
  if (grepl("DEPUTADO ESTADUAL", k)) return(c(`2018`=1000000, `2022`=1270560)[[as.character(ano)]])
  if (grepl("VEREADOR", k))          return(c(`2020`=1000000, `2024`=1200000)[[as.character(ano)]])
  NA_real_
}

# ------------------------- 2. HELPERS BASICOS --------------------------------
normalizar_nome <- function(x)
  trimws(gsub("\\s+", " ", gsub("[^A-Z ]", " ",
    toupper(stringi::stri_trans_general(x, "Latin-ASCII")))))
normalizar_partido <- function(x) toupper(stringi::stri_trans_general(trimws(x), "Latin-ASCII"))

# num_brl com GUARDA (passo 4): se a coluna ja' vem numerica (CDN entrega assim),
# NAO remove ponto. So' trata texto BR ("1.234,56") quando ha' virgula. Sem a
# guarda, "1234.56" numerico viraria 123456 (erro de 100x).
num_brl <- function(x) {
  if (is.numeric(x)) return(as.numeric(x))
  x <- trimws(as.character(x))
  br <- grepl(",", x)
  x[br] <- gsub(",", ".", gsub(".", "", x[br], fixed = TRUE), fixed = TRUE)
  suppressWarnings(as.numeric(x))
}

# Resolucao de colunas (absorve mudanca de nome do TSE entre anos).
PADROES <- list(
  cpf        = c("^NR_CPF_CANDIDATO$","CPF_CAND","^CPF$"),
  nome       = c("^NM_CANDIDATO$","NOME_CANDIDATO","^NM_URNA"),
  nascimento = c("DT_NASCIMENTO","DATA_NASCIMENTO"),
  sq_cand    = c("^SQ_CANDIDATO$","SEQUENCIAL_CANDIDATO"),
  cargo      = c("^DS_CARGO$","^CARGO$","DESCRICAO_CARGO"),
  sit_turno  = c("DS_SIT_TOT_TURNO","SITUACAO.*TURNO","DS_SITUACAO_CAND"),
  genero     = c("DS_GENERO","DESCRICAO_SEXO","^DS_SEXO"),
  instrucao  = c("DS_GRAU_INSTRUCAO","GRAU_INSTRUCAO"),
  cor        = c("DS_COR_RACA","COR_RACA"),
  partido    = c("^SG_PARTIDO$","SIGLA_PARTIDO"),
  cod_mun    = c("^CD_MUNICIPIO$","CODIGO_MUNICIPIO","^SG_UE$"),
  uf         = c("^SG_UF$","^SIGLA_UF$"),
  desp_valor = c("VR_DESPESA","VALOR_DESPESA","VR_PAGAMENTO"),
  desp_orig  = c("DS_ORIGEM_DESPESA","DESCRICAO_DESPESA","DS_DESPESA"),
  desp_cargo = c("^DS_CARGO$","DESCRICAO_CARGO"),
  desp_sq    = c("^SQ_CANDIDATO$","SEQUENCIAL_CANDIDATO"),
  votos      = c("QT_VOTOS_NOMINAIS","QTDE_VOTOS","^QT_VOTOS"),
  coligacao  = c("NM_COLIGACAO","DS_COMPOSICAO_COLIGACAO","SG_COLIGACAO","NM_LEGENDA"),
  federacao  = c("NM_FEDERACAO","SG_FEDERACAO","NR_FEDERACAO")
)
col <- function(df, campo) {
  for (p in PADROES[[campo]]) { h <- grep(p, names(df), value=TRUE, ignore.case=TRUE); if (length(h)) return(h[1]) }
  stop("Coluna nao resolvida para '", campo, "'. Cabecalho: ", paste(head(names(df),40), collapse=", "))
}
col_opt <- function(df, campo){ for (p in PADROES[[campo]]){ h<-grep(p,names(df),value=TRUE,ignore.case=TRUE); if(length(h)) return(h[1]) }; NULL }
G <- function(df, campo) df[[col(df, campo)]]
`%||%` <- function(a,b) if (is.null(a)) b else a

# --------------------- 3. AQUISICAO DE DADOS DO TSE --------------------------
TIPO_TSE <- list(candidato="candidate", voto="vote_mun_zone")
URL_PRESTACAO <- function(ano)
  sprintf(paste0("https://cdn.tse.jus.br/estatistica/sead/odsele/",
                 "prestacao_contas/prestacao_de_contas_eleitorais_candidatos_%s.zip"), ano)

obter_despesa_tse <- function(ano, uf) {
  cache <- file.path(CFG$dir_cache, sprintf("despesa_%s_%s.rds", ano, uf))
  if (file.exists(cache)) return(readRDS(cache))
  zipf <- file.path(CFG$dir_cache, sprintf("prestacao_de_contas_eleitorais_candidatos_%s.zip", ano))
  if (!file.exists(zipf)) {
    message(sprintf("  baixando TSE despesas (prestacao de contas) %s ...", ano))
    old <- options(timeout = max(3600, getOption("timeout"))); on.exit(options(old), add = TRUE)
    part <- paste0(zipf, ".part")
    utils::download.file(URL_PRESTACAO(ano), part, mode="wb", method="libcurl", quiet=FALSE)
    file.rename(part, zipf)
  }
  alvo  <- sprintf("despesas_contratadas_candidatos_%s_%s.csv", ano, uf)
  nomes <- utils::unzip(zipf, list=TRUE)$Name
  hit   <- grep(alvo, nomes, value=TRUE, fixed=TRUE)
  if (!length(hit)) stop("arquivo de despesa nao encontrado no zip do TSE: ", alvo)
  con <- utils::unzip(zipf, files=hit[1], exdir=tempdir())
  d   <- data.table::fread(con, sep=";", encoding="Latin-1", showProgress=FALSE, integer64="double")
  data.table::setDT(d); saveRDS(d, cache); d
}
obter_tse <- function(tipo, ano, uf=NULL) {
  if (tipo == "despesa") return(obter_despesa_tse(ano, uf %||% "BR"))
  cache <- file.path(CFG$dir_cache, sprintf("%s_%s_%s.rds", tipo, ano, ifelse(is.null(uf),"BR",uf)))
  if (file.exists(cache)) return(readRDS(cache))
  message(sprintf("  baixando TSE: %s %s %s", tipo, ano, uf %||% "BR"))
  if (!requireNamespace("electionsBR", quietly=TRUE)) stop("electionsBR ausente e cache nao encontrado para ", tipo, " ", ano, " ", uf)
  d <- electionsBR::elections_tse(year=ano, type=TIPO_TSE[[tipo]], uf=uf %||% "all")
  data.table::setDT(d); saveRDS(d, cache); d
}

# --------------------------- 4. DEFLACAO (TABELA) ----------------------------
.ipca <- NULL
ipca_indice <- function() {
  if (is.null(.ipca)) {
    if (!file.exists(CFG$ipca_csv)) stop("Tabela IPCA versionada ausente: ", CFG$ipca_csv)
    t <- data.table::fread(CFG$ipca_csv, colClasses=list(character="periodo"))
    .ipca <<- setNames(as.numeric(t$indice), t$periodo)
  }
  .ipca
}
# Fator do ano da despesa (out) ate o ano-base (out). Trava em [fator_min, fator_max].
fator_deflacao <- function(ano_despesa, base_periodo) {
  idx <- ipca_indice()
  p_d <- sprintf("%d10", as.integer(ano_despesa))
  if (is.na(idx[p_d]))        stop("IPCA sem indice para ", p_d, " na tabela versionada.")
  if (is.na(idx[base_periodo])) stop("IPCA sem indice para base ", base_periodo, " na tabela versionada.")
  f <- as.numeric(idx[base_periodo] / idx[p_d])
  if (!is.finite(f) || f < CFG$fator_min || f > CFG$fator_max)
    stop(sprintf("PARADA DURA: fator de deflacao %.4f fora de [%.1f, %.1f] (ano %s, base %s).",
                 f, CFG$fator_min, CFG$fator_max, ano_despesa, base_periodo))
  f
}

# ----------------------- 5. CLASSIFICACAO DE DESPESAS ------------------------
REGRAS_DESPESA <- list(
  impulsionamento = "IMPULSIONAMENTO",
  tradicional     = paste("IMPRESS|MILITANCIA|MOBILIZA|ADESIVO|RADIO|TELEVIS|VIDEO",
                          "JORNAL|REVISTA|CARROS? DE SOM|COMICIO|JINGLE|VINHETA|SLOGAN|CORRESPOND", sep="|"),
  transferencia   = "DOAC[AO][^;]*FINANCEIR|DOAC[AO][^;]*(CANDIDAT|PARTID)",
  operacional     = paste("PESSOAL|COMBUST|VEICULO|CONTAB|ADVOCAT|ENCARGO|TAXA|BANCARI",
                          "ALIMENTA|LOCACAO|PESQUISA|COMBOIO|PAGINA|INTERNET|HOSPEDAGEM",
                          "COMITE|EXPEDIENTE|TRANSPORTE|DESLOCAMENTO|AGUA|ENERGIA|TELEFONE", sep="|")
)
classificar_rubrica <- function(rubrica) {
  r <- toupper(stringi::stri_trans_general(rubrica, "Latin-ASCII"))
  cl <- rep("nao_classificado", length(r))
  for (nome in c("transferencia","impulsionamento","tradicional","operacional"))
    cl[cl=="nao_classificado" & grepl(REGRAS_DESPESA[[nome]], r)] <- nome
  cl
}

# --------------------- 6. PROXIES DE CAPITAL POLITICO ------------------------
CALENDARIO <- list(
  "2018"=list(geral_ant=2014, munic_ant=2016),
  "2020"=list(geral_ant=2018, munic_ant=2016),
  "2022"=list(geral_ant=2018, munic_ant=2020),
  "2024"=list(geral_ant=2022, munic_ant=2020),
  "2026"=list(geral_ant=2022, munic_ant=2024)
)
taxa_homonimos <- function(uf, ano_hist) {
  cand <- obter_tse("candidato", ano_hist, uf)
  nm <- normalizar_nome(G(cand,"nome")); nasc <- G(cand,"nascimento")
  t <- data.table(nm, nasc)[, .(p=uniqueN(nasc)), by=nm]
  mean(t$p>1 | is.na(t$p))
}
# Chave de identidade entre ciclos. CPF quando integro; senao nome normalizado +
# data de nascimento (com a trava de homonimos). O TSE MASCAROU o CPF em 2024
# (NR_CPF_CANDIDATO = valor unico "-4" para todos), entao coortes com CPF
# degenerado caem para nome+nascimento. A escolha e' pela coorte ATUAL (a que esta'
# sendo casada), e a MESMA chave e' usada nos ciclos anteriores, para casarem.
cpf_integro <- function(cpfvec){ v<-as.character(cpfvec); length(v)>0 && uniqueN(v)/length(v) >= 0.5 }
chave_de <- function(df, tipo){
  if (tipo=="cpf") as.character(G(df,"cpf"))
  else trimws(paste(normalizar_nome(G(df,"nome")), as.character(G(df,"nascimento"))))
}
resultado_por_chave <- function(uf, ano, tipo) {
  cand <- obter_tse("candidato", ano, uf)
  data.table(chave=chave_de(cand,tipo), cargo=toupper(G(cand,"cargo")),
             venceu=as.integer(grepl("ELEITO", toupper(G(cand,"sit_turno")))))
}
# "incumbente" = VENCEU a ultima eleicao para o cargo (esta' no mandato). Usa
# sempre o ciclo imediatamente anterior (geral_ant / munic_ant). Devolve, no
# atributo "chave_tipo", se casou por cpf ou nome+nascimento (para o log/trava).
montar_proxies <- function(uf, ano, cargo) {
  cal <- CALENDARIO[[as.character(ano)]]
  atual <- obter_tse("candidato", ano, uf)
  tipo <- if (cpf_integro(G(atual,"cpf"))) "cpf" else "nome_nasc"
  if (tipo != "cpf")
    message(sprintf("  [proxies %s %s] CPF degenerado (distintos=%d de %d); casando por nome+nascimento.",
                    uf, ano, uniqueN(as.character(G(atual,"cpf"))), nrow(atual)))
  base <- data.table(sq=G(atual,"sq_cand"), chave=chave_de(atual,tipo))
  rg <- resultado_por_chave(uf, cal$geral_ant, tipo); rm_ <- resultado_por_chave(uf, cal$munic_ant, tipo)
  venceu  <- function(res,alvo) res[grepl(alvo,cargo) & venceu==1, unique(chave)]
  disputou<- function(res,alvo) res[grepl(alvo,cargo), unique(chave)]
  if (grepl("DEPUTADO", toupper(cargo))) {
    inc<-venceu(rg,toupper(cargo)); disp<-disputou(rg,toupper(cargo))
    base[, `:=`(
      incumbente            = +(chave %in% inc),
      disputou_perdeu_geral = +(chave %in% setdiff(disp,inc)),
      venceu_prefeito       = +(chave %in% venceu(rm_,"PREFEITO")),
      venceu_vereador       = +(chave %in% venceu(rm_,"VEREADOR")))]
  } else {
    inc_v<-venceu(rm_,"VEREADOR"); disp_v<-disputou(rm_,"VEREADOR")
    base[, `:=`(
      disputou_deputado        = +(chave %in% disputou(rg,"DEPUTADO")),
      incumbente_vereador      = +(chave %in% inc_v),
      venceu_prefeito          = +(chave %in% venceu(rm_,"PREFEITO")),
      disputou_perdeu_vereador = +(chave %in% setdiff(disp_v,inc_v)))]
  }
  base[, chave:=NULL]
  setattr(base, "chave_tipo", tipo)
  base[]
}

# ============================================================================
#                     PIPELINE DE TRATAMENTO (passos 1 a 13)
# ============================================================================
tratar <- function(uf, ano, cargo) {
  tag <- sprintf("%s_%s_%s", uf, ano, gsub(" ","_",toupper(cargo)))
  L <- character(0)                                   # acumulador do log
  add <- function(...) { L[[length(L)+1]] <<- paste0(...); invisible() }
  hard <- function(cond, msg) if (isTRUE(cond)) { add("\n**PARADA DURA**: ", msg);
    writeLines(L, file.path(CFG$dir_tratado, paste0("log_tratamento_",tag,".md")));
    stop("PARADA DURA [", tag, "]: ", msg) }
  base_p <- base_preco(cargo)
  add("# Log de tratamento - ", uf, " ", ano, " ", toupper(cargo))
  add("")
  add("- Gerado por `01_tratamento.R`. Base de precos: out/", substr(base_p,1,4),
      " (escopo ", ifelse(grepl("VEREADOR",toupper(cargo)),"vereador","deputado"), ").")
  add("- Fator de deflacao do ano da eleicao ate a base: ",
      sprintf("%.4f", fator_deflacao(ano, base_p)), ".")
  add("")
  add("| Passo | Descricao | Entrada | Saida |")
  add("|---|---|---:|---:|")

  ## Passo 1. Candidatos; filtrar o cargo na origem -----------------------------
  cand0 <- obter_tse("candidato", ano, uf)
  n_in  <- nrow(cand0)
  cand  <- cand0[grepl(toupper(cargo), toupper(G(cand0,"cargo")))]
  add("| 1 | Carregar candidatos e filtrar cargo (", toupper(cargo), ") | ", n_in, " | ", nrow(cand), " |")
  hard(nrow(cand)==0, "nenhum candidato apos filtrar o cargo (cargo errado?).")

  ## Passo 2. Uma linha por SQ_CANDIDATO (sem fan-out) --------------------------
  sqv <- as.character(G(cand,"sq_cand"))
  n_lin <- length(sqv); n_uni <- uniqueN(sqv)
  if (n_lin != n_uni) { setDT(cand); cand <- cand[!duplicated(sqv)]; sqv <- as.character(G(cand,"sq_cand")) }
  add("| 2 | Garantir 1 linha por SQ_CANDIDATO | ", n_lin, " | ", nrow(cand), " |")
  add("")
  add("- Passo 2: n_linhas=", n_lin, " ; n_sq_unicos=", n_uni,
      ifelse(n_lin==n_uni, " (sem duplicata)", paste0(" (removidas ", n_lin-n_uni, " duplicatas)")))
  sq_cargo <- unique(sqv)

  ## Passo 3. Despesas restritas aos candidatos do cargo -----------------------
  desp0 <- obter_tse("despesa", ano, uf)
  nd_in <- nrow(desp0)
  setDT(desp0)
  desp0[, .sq := as.character(G(desp0,"desp_sq"))]
  desp <- desp0[.sq %in% sq_cargo]
  add("| 3 | Restringir despesas aos SQ do cargo | ", nd_in, " | ", nrow(desp), " |")

  ## Passo 4. Parser monetario robusto -----------------------------------------
  vcol <- col(desp, "desp_valor")
  cls  <- class(desp[[vcol]])[1]
  desp[, .valor := num_brl(get(vcol))]
  max_unit <- max(desp$.valor, na.rm=TRUE)
  add("| 4 | Converter valor (coluna ", vcol, ", classe ", cls, ") | ", nrow(desp), " | ", nrow(desp), " |")
  add("- Passo 4: maior despesa unitaria = R$ ", format(round(max_unit), big.mark=".", decimal.mark=","),
      " ; NAs no parsing = ", sum(is.na(desp$.valor)))
  hard(max_unit > 1e8, paste0("despesa unitaria impossivel (R$ ", round(max_unit), " > 100 mi): parser ou formato."))

  ## Passo 5. Classificar a rubrica --------------------------------------------
  desp[, .classe := classificar_rubrica(G(desp,"desp_orig"))]
  audit <- desp[, .(soma=sum(.valor,na.rm=TRUE), n=.N),
                by=.(rubrica=G(desp,"desp_orig"), classe=.classe)][order(classe,-soma)]
  add("| 5 | Classificar rubrica em 5 classes | ", nrow(desp), " | ", nrow(desp), " |")
  resumo_cl <- desp[, .(soma=sum(.valor,na.rm=TRUE), n=.N), by=.classe][order(-soma)]
  add("- Passo 5: classes -> ",
      paste(sprintf("%s: R$ %s (%d lanc.)", resumo_cl$.classe,
                    format(round(resumo_cl$soma), big.mark=".", decimal.mark=","), resumo_cl$n), collapse=" | "))

  ## Passo 6. Remover transferencias entre campanhas ---------------------------
  n_tr  <- sum(desp$.classe=="transferencia"); soma_tr <- sum(desp$.valor[desp$.classe=="transferencia"], na.rm=TRUE)
  desp_c <- desp[.classe != "transferencia"]
  add("| 6 | Remover transferencias | ", nrow(desp), " | ", nrow(desp_c), " |")
  add("- Passo 6: removidas ", n_tr, " transferencias, soma R$ ",
      format(round(soma_tr), big.mark=".", decimal.mark=","),
      ifelse(soma_tr<=0 && n_tr==0, " (ATENCAO: nenhuma transferencia pega - conferir rubricas no CSV de auditoria)", ""))

  ## Passo 7. Somar por (SQ, classe), pivotar largo. NAO deduplicar SQ_DESPESA. -
  g_long <- desp_c[, .(valor_nom=sum(.valor, na.rm=TRUE)), by=.(sq=.sq, classe=.classe)]
  g <- dcast(g_long, sq ~ classe, value.var="valor_nom", fill=0)
  for (cl in c("impulsionamento","tradicional","operacional","nao_classificado"))
    if (!cl %in% names(g)) g[[cl]] <- 0
  add("| 7 | Somar por (SQ, classe) e pivotar (sem dedup SQ_DESPESA) | ", nrow(desp_c), " | ", nrow(g), " |")

  ## Passo 8. Deflacionar para a base do escopo --------------------------------
  fator <- fator_deflacao(ano, base_p)
  for (cl in c("impulsionamento","tradicional","operacional","nao_classificado")) {
    g[[paste0(cl,"_nom")]] <- g[[cl]]
    g[[cl]] <- g[[cl]] * fator
  }
  add("| 8 | Deflacionar (fator ", sprintf("%.4f",fator), ", base out/", substr(base_p,1,4), ") | ", nrow(g), " | ", nrow(g), " |")

  ## Passo 9. Votacao: somar votos por candidato -------------------------------
  voto0 <- obter_tse("voto", ano, uf); setDT(voto0)
  vcargo <- col_opt(voto0, "cargo")
  if (!is.null(vcargo)) voto0 <- voto0[grepl(toupper(cargo), toupper(voto0[[vcargo]]))]
  vv <- data.table(sq=as.character(G(voto0,"sq_cand")), votos=as.numeric(G(voto0,"votos")))
  v  <- vv[, .(total_votos=sum(votos, na.rm=TRUE)), by=sq]
  add("| 9 | Votacao: somar votos nominais por candidato | ", nrow(voto0), " | ", nrow(v), " |")

  ## Passo 10. Proxies de capital politico -------------------------------------
  cal <- CALENDARIO[[as.character(ano)]]
  hom_g <- taxa_homonimos(uf, cal$geral_ant); hom_m <- taxa_homonimos(uf, cal$munic_ant)
  prox <- montar_proxies(uf, ano, cargo); prox[, sq := as.character(sq)]
  chave_tipo <- attr(prox, "chave_tipo") %||% "cpf"
  add("| 10 | Montar proxies (geral ", cal$geral_ant, ", munic ", cal$munic_ant, ", chave ", chave_tipo, ") | ", nrow(prox), " | ", nrow(prox), " |")
  add("- Passo 10: chave de casamento = ", chave_tipo,
      ifelse(chave_tipo!="cpf", " (CPF degenerado/mascarado na coorte atual; fallback p/ nome+nascimento)", ""))
  add("- Passo 10: homonimos geral ", cal$geral_ant, " = ", sprintf("%.2f%%",100*hom_g),
      " ; munic ", cal$munic_ant, " = ", sprintf("%.2f%%",100*hom_m),
      ifelse(max(hom_g,hom_m)>0.05, " (ATENCAO: acima de 5%)", ""))
  # TRAVA contra degeneracao silenciosa: nenhuma proxy pode sair constante.
  prox_cols <- setdiff(names(prox), "sq")
  const_prox <- prox_cols[vapply(prox_cols, function(c) uniqueN(prox[[c]])<=1, logical(1))]
  if (length(const_prox))
    add("- Passo 10: **ATENCAO** proxies CONSTANTES (degeneradas): ", paste(const_prox, collapse=", "),
        " -- casamento de identidade provavelmente falhou; conferir a chave.")

  ## Passo 11. Montar o painel do candidato ------------------------------------
  fcol<-col_opt(cand,"federacao"); ccol<-col_opt(cand,"coligacao")
  lista <- as.character(G(cand,"partido"))
  if(!is.null(ccol)){ vv2<-as.character(cand[[ccol]]); ok<-!(is.na(vv2)|vv2==""|grepl("ISOLAD|#NULO",toupper(vv2))); lista[ok]<-vv2[ok] }
  if(!is.null(fcol)){ vv2<-as.character(cand[[fcol]]); ok<-!(is.na(vv2)|vv2==""|grepl("#NULO",toupper(vv2))); lista[ok]<-vv2[ok] }
  ideol <- toupper(stringi::stri_trans_general(G(cand,"partido"),"Latin-ASCII"))  # so' para esquerda/direita abaixo
  MAPA_IDEOLOGIA <- c(
    "PT"="ESQUERDA","PSB"="ESQUERDA","PDT"="ESQUERDA","PSOL"="ESQUERDA","PCDOB"="ESQUERDA",
    "PC DO B"="ESQUERDA","REDE"="ESQUERDA","PV"="ESQUERDA","PCO"="ESQUERDA","PSTU"="ESQUERDA",
    "PPS"="ESQUERDA","PPL"="ESQUERDA","PCB"="ESQUERDA",
    "PP"="DIREITA","PL"="DIREITA","UNIAO"="DIREITA","REPUBLICANOS"="DIREITA","PRD"="DIREITA",
    "NOVO"="DIREITA","PRTB"="DIREITA","DEM"="DIREITA","PSL"="DIREITA","PSC"="DIREITA",
    "PATRIOTA"="DIREITA","PRB"="DIREITA","PRP"="DIREITA","PR"="DIREITA")
  fam <- MAPA_IDEOLOGIA[normalizar_partido(G(cand,"partido"))]

  painel <- data.table(
    sq    = as.character(G(cand,"sq_cand")),
    nome  = G(cand,"nome"),
    uf    = uf, ano = ano, cargo = toupper(cargo),
    partido = as.character(G(cand,"partido")),
    lista = lista,
    cod_mun = as.character(G(cand,"cod_mun")),
    eleito = as.integer({s<-toupper(stringi::stri_trans_general(G(cand,"sit_turno"),"Latin-ASCII")); grepl("ELEITO",s) & !grepl("NAO",s)}),
    apto   = as.integer(!grepl("INDEFERIDO|RENUN|FALECID|CASSAD", toupper(G(cand,"sit_turno")))),
    masculino        = as.integer(grepl("MASCULINO", toupper(G(cand,"genero")))),
    superior_completo= as.integer(grepl("SUPERIOR COMPLETO", toupper(G(cand,"instrucao")))),
    corbranca        = as.integer(grepl("BRANCA", toupper(G(cand,"cor")))),
    esquerda = as.integer(fam %in% "ESQUERDA"),
    direita  = as.integer(fam %in% "DIREITA")
  )
  painel <- painel |>
    left_join(v,    by="sq") |>
    left_join(g,    by="sq") |>
    left_join(prox, by="sq")
  painel <- data.table::copy(setDT(painel))   # copy: evita aviso de "shallow copy" do := apos o join

  # Preencher ausencias com zero (sem despesa/voto declarado e' zero legitimo).
  # set() em vez de [[<- para nao disparar o aviso de "shallow copy" do data.table.
  zcols <- c("impulsionamento","tradicional","operacional","nao_classificado")
  zcols <- c(zcols, paste0(zcols, "_nom"))
  for (cl in zcols) {
    if (!cl %in% names(painel)) set(painel, j=cl, value=0)
    na_i <- which(is.na(painel[[cl]])); if (length(na_i)) set(painel, i=na_i, j=cl, value=0)
  }
  na_v <- which(is.na(painel$total_votos)); if (length(na_v)) set(painel, i=na_v, j="total_votos", value=0)
  painel[, gasto_total         := impulsionamento + tradicional + operacional + nao_classificado]
  painel[, gasto_total_nominal := impulsionamento_nom + tradicional_nom + operacional_nom + nao_classificado_nom]
  add("| 11 | Montar painel do candidato (join votos+gasto+proxies) | ", nrow(cand), " | ", nrow(painel), " |")

  ## Passo 12. Travas de validacao (paradas duras) -----------------------------
  teto <- TETO_LEGAL(cargo, ano)
  max_nom <- max(painel$gasto_total_nominal, na.rm=TRUE)
  acima_teto <- painel[gasto_total_nominal > teto]
  hard(nrow(painel) != uniqueN(painel$sq), "fan-out: n_linhas diferente de n_sq_unicos no painel.")
  hard(any(painel$gasto_total < 0, na.rm=TRUE) || any(painel$total_votos < 0, na.rm=TRUE), "gasto ou voto negativo.")
  hard(is.finite(teto) && max_nom > 2*teto,
       sprintf("gasto_total_nominal R$ %s > 2x teto legal (R$ %s) para %s %s.",
               format(round(max_nom),big.mark=".",decimal.mark=","),
               format(2*teto,big.mark=".",decimal.mark=","), toupper(cargo), ano))
  add("| 12 | Travas de validacao | ", nrow(painel), " | ", nrow(painel), " |")
  add("- Passo 12: teto legal nominal = R$ ", format(teto, big.mark=".", decimal.mark=","),
      " ; trava dura 2x = R$ ", format(2*teto, big.mark=".", decimal.mark=","))
  add("- Passo 12: MAIOR gasto_total_nominal = R$ ", format(round(max_nom), big.mark=".", decimal.mark=","),
      " ; deflacionado = R$ ", format(round(max(painel$gasto_total,na.rm=TRUE)), big.mark=".", decimal.mark=","))
  add("- Passo 12: candidatos acima do teto legal (AVISO, nao para) = ", nrow(acima_teto))
  if (nrow(acima_teto)) {
    aci <- acima_teto[order(-gasto_total_nominal)][1:min(.N,10)]
    for (i in 1:nrow(aci)) add("    - ", aci$nome[i], " (", aci$partido[i], "): R$ ",
                               format(round(aci$gasto_total_nominal[i]), big.mark=".", decimal.mark=","))
  }
  n_eleitos <- sum(painel$eleito, na.rm=TRUE)
  cadeiras <- unname(c("DEPUTADO FEDERAL"=30, "DEPUTADO ESTADUAL"=54)[toupper(cargo)])  # NA para vereador
  add("- Passo 12: eleitos = ", n_eleitos,
      ifelse(!is.na(cadeiras) && n_eleitos!=cadeiras, paste0(" (ATENCAO: esperado ", cadeiras, ")"), ""))

  ## Passo 13. Salvar -----------------------------------------------------------
  # Painel final (so' colunas do dicionario; mantem *_nom de auditoria do gasto total).
  cols_painel <- c("sq","nome","uf","ano","cargo","partido","lista","cod_mun",
                   "total_votos","eleito","apto",
                   "impulsionamento","tradicional","operacional","nao_classificado",
                   "gasto_total","gasto_total_nominal",
                   intersect(c("incumbente","disputou_perdeu_geral","venceu_prefeito","venceu_vereador",
                               "disputou_deputado","incumbente_vereador","disputou_perdeu_vereador"), names(painel)),
                   "masculino","superior_completo","corbranca","esquerda","direita")
  fwrite(painel[, ..cols_painel], file.path(CFG$dir_tratado, paste0("painel_",tag,".csv")))
  audit[, rubrica := iconv(rubrica, from="latin1", to="UTF-8")]  # texto legivel sem mojibake na auditoria
  fwrite(audit, file.path(CFG$dir_tratado, paste0("despesas_classificadas_",tag,".csv")))
  add("")
  add("## Saidas")
  add("- `dados_tratados/painel_", tag, ".csv` (", nrow(painel), " candidatos, ", length(cols_painel), " colunas)")
  add("- `dados_tratados/despesas_classificadas_", tag, ".csv` (", nrow(audit), " rubricas x classe)")
  writeLines(L, file.path(CFG$dir_tratado, paste0("log_tratamento_",tag,".md")))

  message(sprintf("  [OK] %s : %d candidatos, %d eleitos, max nom R$ %s",
                  tag, nrow(painel), n_eleitos, format(round(max_nom), big.mark=".", decimal.mark=",")))
  invisible(list(tag=tag, n=nrow(painel), eleitos=n_eleitos, max_nom=max_nom,
                 max_def=max(painel$gasto_total,na.rm=TRUE), painel=painel))
}

# ------------------------------- USO ----------------------------------------
# source("01_tratamento.R")
# tratar("PR", 2022, "DEPUTADO FEDERAL")
# tratar("PR", 2018, "DEPUTADO ESTADUAL")
# tratar("PR", 2024, "VEREADOR")
# =============================================================================
