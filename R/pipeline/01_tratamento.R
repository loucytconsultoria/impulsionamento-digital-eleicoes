# =============================================================================
# 01_tratamento.R  -  ETL: do BRUTO do TSE aos paineis tratados (1 por recorte)
# -----------------------------------------------------------------------------
# Le o BRUTO do TSE (DIR_BRUTO), classifica e soma a despesa de forma auditavel,
# deflaciona por tabela IPCA versionada, monta o capital politico (reeleicao do
# complementar + votacao do candidato em eleicoes anteriores por conjunto de
# cargos do modelo) e o eleitorado apto municipal, e TRAVA contra valores
# impossiveis e contra falha de fonte antes de salvar.
#
# Saidas: dados_tratados/painel_<TAG>.csv, despesas_classificadas_<TAG>.csv,
#         log_tratamento_<TAG>.md ; logs/tratamento.log, logs/proveniencia.csv,
#         logs/auditoria_tratamento.log.
# =============================================================================

# ------------------------------ 0. CONFIG ------------------------------------
UF <- "PR"
RECORTES <- list(
  list(ano = 2018, cargo = "DEPUTADO FEDERAL"),
  list(ano = 2022, cargo = "DEPUTADO FEDERAL"),
  list(ano = 2018, cargo = "DEPUTADO ESTADUAL"),
  list(ano = 2022, cargo = "DEPUTADO ESTADUAL"),
  list(ano = 2020, cargo = "VEREADOR"),
  list(ano = 2024, cargo = "VEREADOR")
)
FATOR_MIN <- 0.5; FATOR_MAX <- 2.5
PROV <- new.env(); PROV$rows <- list()              # acumulador de proveniencia
LOGG <- new.env(); LOGG$lines <- character(0)       # log global do tratamento
glog <- function(...) LOGG$lines <- c(LOGG$lines, paste0(...))

# Base de precos por escopo: deputado out/2022 ; vereador out/2024.
base_preco <- function(cargo) if (grepl("VEREADOR", toupper(cargo))) "202410" else "202210"

# Teto legal nominal do TSE (trava dura = 2x). Vereador: sem teto unico nacional;
# usa-se teto-sanidade generoso so para barrar valor impossivel (milhoes).
TETO_LEGAL <- function(cargo, ano) {
  k <- toupper(cargo)
  if (grepl("DEPUTADO FEDERAL", k))  return(c(`2018`=2500000, `2022`=3176400)[[as.character(ano)]])
  if (grepl("DEPUTADO ESTADUAL", k)) return(c(`2018`=1000000, `2022`=1270560)[[as.character(ano)]])
  if (grepl("VEREADOR", k))          return(c(`2020`=1000000, `2024`=1200000)[[as.character(ano)]])
  NA_real_
}

# --------------------------- 1. HELPERS BASICOS ------------------------------
normalizar_nome <- function(x)
  trimws(gsub("\\s+", " ", gsub("[^A-Z ]", " ",
    toupper(stringi::stri_trans_general(x, "Latin-ASCII")))))

# Conversor monetario com guarda: so trata texto BR ("1.234,56") quando ha
# virgula; se ja vier numerico, nao remove ponto (evita o erro 100x).
num_brl <- function(x) {
  if (is.numeric(x)) return(as.numeric(x))
  x <- trimws(as.character(x)); br <- grepl(",", x)
  x[br] <- gsub(",", ".", gsub(".", "", x[br], fixed = TRUE), fixed = TRUE)
  suppressWarnings(as.numeric(x))
}

# Resolucao de colunas (absorve mudanca de nome do TSE entre anos).
PADROES <- list(
  cpf=c("^NR_CPF_CANDIDATO$","CPF_CAND","^CPF$"), nome=c("^NM_CANDIDATO$"),
  nascimento=c("^DT_NASCIMENTO$"), sq=c("^SQ_CANDIDATO$"),
  cargo=c("^DS_CARGO$","^CARGO$"), sit=c("^DS_SIT_TOT_TURNO$","DS_SITUACAO"),
  genero=c("^DS_GENERO$","DESCRICAO_SEXO"), instrucao=c("^DS_GRAU_INSTRUCAO$"),
  cor=c("^DS_COR_RACA$"), partido=c("^SG_PARTIDO$"),
  ue=c("^SG_UE$"), turno=c("^NR_TURNO$"),
  votos=c("^QT_VOTOS_NOMINAIS$","QTDE_VOTOS"),
  coligacao=c("^NM_COLIGACAO$","DS_COMPOSICAO_COLIGACAO","^NM_LEGENDA$"),
  federacao=c("^NM_FEDERACAO$","^SG_FEDERACAO$"),
  desp_valor=c("^VR_DESPESA_CONTRATADA$","VR_DESPESA","VALOR_DESPESA"),
  desp_orig=c("^DS_ORIGEM_DESPESA$","DESCRICAO_DESPESA"),
  desp_sq=c("^SQ_CANDIDATO$"),
  apto=c("^QT_APTOS$"), cd_mun=c("^CD_MUNICIPIO$")
)
col <- function(df, campo) { for (p in PADROES[[campo]]) { h<-grep(p,names(df),value=TRUE,ignore.case=TRUE); if (length(h)) return(h[1]) }
  stop("Coluna nao resolvida: '", campo, "'. Cabecalho: ", paste(head(names(df),30),collapse=", ")) }
col_opt <- function(df,campo){ for (p in PADROES[[campo]]){ h<-grep(p,names(df),value=TRUE,ignore.case=TRUE); if(length(h)) return(h[1]) }; NULL }
G <- function(df, campo) df[[col(df, campo)]]
`%||%` <- function(a,b) if (is.null(a)) b else a

reg_prov <- function(path, ano, tipo) {                # proveniencia de cada bruto lido
  path <- normalizePath(path, winslash="/", mustWork=FALSE)
  if (!is.null(PROV$rows[[path]])) return(invisible())
  PROV$rows[[path]] <- data.table(
    arquivo=basename(path), caminho=path,
    tamanho_bytes=file.info(path)$size,
    md5=unname(tools::md5sum(path)), ano=ano, tipo=tipo)
  invisible()
}

# --------------------------- 2. LEITORES DO BRUTO ----------------------------
# Cada leitor PARA com mensagem clara se a fonte faltar (trava D: fonte ausente).
fonte <- function(nome) {
  f <- file.path(DIR_BRUTO, nome)
  if (!file.exists(f)) stop("PARADA DURA [fonte ausente]: ", f,
    "\n  Adquira do BRUTO do TSE antes de rodar; nunca preencher proxy com zero por falta de fonte.")
  f
}
ler_candidato <- function(ano){ f<-fonte(sprintf("candidato_%d_%s.rds",ano,UF)); reg_prov(f,ano,"candidato")
  d<-as.data.table(readRDS(f)); d }
ler_voto <- function(ano){ f<-fonte(sprintf("voto_%d_%s.rds",ano,UF)); reg_prov(f,ano,"voto")
  d<-as.data.table(readRDS(f)); d }
ler_despesa <- function(ano){ f<-fonte(sprintf("despesa_%d_%s.rds",ano,UF)); reg_prov(f,ano,"despesa")
  d<-as.data.table(readRDS(f)); d }
ler_complementar <- function(ano){            # ST_REELEICAO por SQ_CANDIDATO (dedup)
  z<-fonte(sprintf("consulta_cand_complementar_%d.zip",ano)); reg_prov(z,ano,"complementar")
  alvo<-grep(sprintf("complementar_%d_%s\\.csv$",ano,UF), utils::unzip(z,list=TRUE)$Name, value=TRUE)
  if(!length(alvo)) stop("PARADA DURA: CSV do complementar nao encontrado no zip ", basename(z))
  con<-utils::unzip(z,files=alvo[1],exdir=tempdir())
  d<-fread(con,sep=";",encoding="Latin-1",showProgress=FALSE)
  d[, .(sq=as.character(SQ_CANDIDATO), reeleicao=as.integer(ST_REELEICAO=="S"))][!duplicated(sq)]
}
ler_eleitorado <- function(ano){              # apto municipal: vereador, turno 1, soma QT_APTOS
  z<-fonte(sprintf("detalhe_votacao_munzona_%d.zip",ano)); reg_prov(z,ano,"detalhe_munzona")
  alvo<-grep(sprintf("munzona_%d_%s\\.csv$",ano,UF), utils::unzip(z,list=TRUE)$Name, value=TRUE)
  if(!length(alvo)) stop("PARADA DURA: CSV de detalhe_munzona nao encontrado no zip ", basename(z))
  con<-utils::unzip(z,files=alvo[1],exdir=tempdir())
  d<-fread(con,sep=";",encoding="Latin-1",showProgress=FALSE)
  keep <- grepl("VEREADOR",toupper(G(d,"cargo"))) & G(d,"turno")==1
  dt <- data.table(cod_mun=as.character(G(d,"cd_mun"))[keep], apto=as.numeric(G(d,"apto"))[keep])
  dt[, .(apto=sum(apto,na.rm=TRUE)), by=cod_mun]
}

# --------------------------- 3. DEFLACAO (TABELA) ----------------------------
.ipca <- NULL
ipca_indice <- function(){ if (is.null(.ipca)){ f<-file.path(DIR_DICT,"ipca_indice.csv")
  if(!file.exists(f)) stop("PARADA DURA: tabela IPCA versionada ausente: ",f)
  t<-fread(f,colClasses=list(character="periodo")); .ipca<<-setNames(as.numeric(t$indice),t$periodo) }; .ipca }
fator_deflacao <- function(ano_despesa, base_periodo){
  idx<-ipca_indice(); p<-sprintf("%d10",as.integer(ano_despesa))
  if(is.na(idx[p])) stop("PARADA DURA: IPCA sem indice para ",p)
  if(is.na(idx[base_periodo])) stop("PARADA DURA: IPCA sem indice para base ",base_periodo)
  f<-as.numeric(idx[base_periodo]/idx[p])
  if(!is.finite(f)||f<FATOR_MIN||f>FATOR_MAX)
    stop(sprintf("PARADA DURA: fator de deflacao %.4f fora de [%.1f,%.1f] (ano %s, base %s).",
                 f,FATOR_MIN,FATOR_MAX,ano_despesa,base_periodo))
  f
}

# ----------------------- 4. CLASSIFICACAO DE DESPESAS ------------------------
REGRAS_DESPESA <- list(
  impulsionamento="IMPULSIONAMENTO",
  tradicional=paste("IMPRESS|MILITANCIA|MOBILIZA|ADESIVO|RADIO|TELEVIS|VIDEO",
                    "JORNAL|REVISTA|CARROS? DE SOM|COMICIO|JINGLE|VINHETA|SLOGAN|CORRESPOND",sep="|"),
  transferencia="DOAC[AO][^;]*FINANCEIR|DOAC[AO][^;]*(CANDIDAT|PARTID)",
  operacional=paste("PESSOAL|COMBUST|VEICULO|CONTAB|ADVOCAT|ENCARGO|TAXA|BANCARI",
                    "ALIMENTA|LOCACAO|PESQUISA|COMBOIO|PAGINA|INTERNET|HOSPEDAGEM",
                    "COMITE|EXPEDIENTE|TRANSPORTE|DESLOCAMENTO|AGUA|ENERGIA|TELEFONE",sep="|")
)
classificar_rubrica <- function(rubrica){
  r<-toupper(stringi::stri_trans_general(rubrica,"Latin-ASCII"))
  cl<-rep("nao_classificado",length(r))
  for(nome in c("transferencia","impulsionamento","tradicional","operacional"))
    cl[cl=="nao_classificado" & grepl(REGRAS_DESPESA[[nome]],r)]<-nome
  cl
}

# --------------------- 5. CAPITAL POLITICO (decisao 2) -----------------------
# Conjuntos de voto por modelo + calendario. Cada entrada e' a votacao nominal
# (1o turno, deduplicada por candidato) que o candidato teve naquela eleicao/cargo;
# entra como log1p, 0 onde nao concorreu. So reeleicao e' dummy.
CAPITAL_CAL <- list(
  "DEPUTADO FEDERAL"=list(
    "2018"=list(l_votos_mesmo_cargo_ultima=list(ano=2014,cargo="DEPUTADO FEDERAL"),
                l_votos_dep_estadual_ultima=list(ano=2014,cargo="DEPUTADO ESTADUAL"),
                l_votos_prefeito_ultima=list(ano=2016,cargo="PREFEITO"),
                l_votos_prefeito_penultima=list(ano=2012,cargo="PREFEITO"),
                l_votos_vereador_ultima=list(ano=2016,cargo="VEREADOR")),
    "2022"=list(l_votos_mesmo_cargo_ultima=list(ano=2018,cargo="DEPUTADO FEDERAL"),
                l_votos_dep_estadual_ultima=list(ano=2018,cargo="DEPUTADO ESTADUAL"),
                l_votos_prefeito_ultima=list(ano=2020,cargo="PREFEITO"),
                l_votos_prefeito_penultima=list(ano=2016,cargo="PREFEITO"),
                l_votos_vereador_ultima=list(ano=2020,cargo="VEREADOR"))),
  "DEPUTADO ESTADUAL"=list(
    "2018"=list(l_votos_mesmo_cargo_ultima=list(ano=2014,cargo="DEPUTADO ESTADUAL"),
                l_votos_prefeito_ultima=list(ano=2016,cargo="PREFEITO"),
                l_votos_prefeito_penultima=list(ano=2012,cargo="PREFEITO"),
                l_votos_vereador_ultima=list(ano=2016,cargo="VEREADOR")),
    "2022"=list(l_votos_mesmo_cargo_ultima=list(ano=2018,cargo="DEPUTADO ESTADUAL"),
                l_votos_prefeito_ultima=list(ano=2020,cargo="PREFEITO"),
                l_votos_prefeito_penultima=list(ano=2016,cargo="PREFEITO"),
                l_votos_vereador_ultima=list(ano=2020,cargo="VEREADOR"))),
  "VEREADOR"=list(
    "2020"=list(l_votos_mesmo_cargo_ultima=list(ano=2016,cargo="VEREADOR"),
                l_votos_deputado_ultima=list(ano=2018,cargo="DEPUTADO")),
    "2024"=list(l_votos_mesmo_cargo_ultima=list(ano=2020,cargo="VEREADOR"),
                l_votos_deputado_ultima=list(ano=2022,cargo="DEPUTADO")))
)
cpf_integro <- function(cpfvec){ v<-as.character(cpfvec); length(v)>0 && uniqueN(v)/length(v) >= 0.5 }
chave_de <- function(df, tipo) if (tipo=="cpf") as.character(G(df,"cpf")) else
  trimws(paste(normalizar_nome(G(df,"nome")), as.character(G(df,"nascimento"))))
cargo_match <- function(x, spec) if (spec=="DEPUTADO") grepl("^DEPUTADO (FEDERAL|ESTADUAL)$",x) else x==spec

# votacao nominal (1o turno, dedup por candidato) por chave de identidade.
votos_por_chave <- function(ano, cargo_spec, tipo){
  cand<-ler_candidato(ano); vot<-ler_voto(ano)
  keep <- G(vot,"turno")==1 & cargo_match(toupper(G(vot,"cargo")), cargo_spec)
  dv <- data.table(sq=as.character(G(vot,"sq"))[keep], votos=as.numeric(G(vot,"votos"))[keep])
  vv <- dv[, .(votos=sum(votos,na.rm=TRUE)), by=sq]
  ck<-data.table(sq=as.character(G(cand,"sq")), chave=chave_de(cand,tipo))
  m<-merge(vv, ck, by="sq")
  m[, .(votos=sum(votos,na.rm=TRUE)), by=chave]      # dedup por candidato (chave)
}
# Capital politico do recorte: reeleicao (mesmo cargo) + l_votos_* por conjunto.
montar_capital <- function(ano, cargo, sq_cargo){
  atual<-ler_candidato(ano)
  atual<-atual[as.character(G(atual,"sq")) %in% sq_cargo]
  tipo <- if (cpf_integro(G(atual,"cpf"))) "cpf" else "nome_nasc"
  sq<-as.character(G(atual,"sq")); chave<-chave_de(atual,tipo)
  cal<-CAPITAL_CAL[[toupper(cargo)]][[as.character(ano)]]
  if (is.null(cal)) stop("PARADA DURA: calendario de capital ausente para ",cargo," ",ano)
  out<-data.table(sq=sq); detalhe<-list()
  for (vn in names(cal)){
    e<-cal[[vn]]; tab<-votos_por_chave(e$ano, e$cargo, tipo)
    vv<-log1p(tab$votos[match(chave, tab$chave)]); vv[is.na(vv)]<-0
    out[[vn]]<-vv
    detalhe[[vn]]<-list(ano=e$ano, cargo=e$cargo, n_nonzero=sum(vv>0))
  }
  re<-ler_complementar(ano)
  rv<-re$reeleicao[match(sq, re$sq)]; rv[is.na(rv)]<-0L
  out[["reeleicao"]]<-as.integer(rv)
  setattr(out,"tipo_chave",tipo); setattr(out,"detalhe",detalhe); out[]
}

# =============================================================================
#                      PIPELINE DE TRATAMENTO (1 recorte)
# =============================================================================
tratar <- function(uf, ano, cargo){
  tag<-sprintf("%s_%s_%s",uf,ano,gsub(" ","_",toupper(cargo)))
  base_p<-base_preco(cargo); ehver<-grepl("VEREADOR",toupper(cargo))
  L<-character(0); add<-function(...) L[[length(L)+1]]<<-paste0(...)
  hard<-function(cond,msg){ if(isTRUE(cond)){ add("\n**PARADA DURA**: ",msg)
    writeLines(L,file.path(DIR_TRATADO,paste0("log_tratamento_",tag,".md")))
    stop("PARADA DURA [",tag,"]: ",msg) } }
  add("# Log de tratamento - ",uf," ",ano," ",toupper(cargo)); add("")
  add("- Base de precos: out/",substr(base_p,1,4)," (escopo ",ifelse(ehver,"vereador","deputado"),").")
  fator<-fator_deflacao(ano,base_p)
  add("- Fator de deflacao do ano da eleicao ate a base: ",sprintf("%.4f",fator),".")
  add(""); add("| Passo | Descricao | Entrada | Saida |"); add("|---|---|---:|---:|")

  ## 1. Candidatos; filtrar cargo na origem ----------------------------------
  cand0<-ler_candidato(ano); n_in<-nrow(cand0)
  cand<-cand0[toupper(G(cand0,"cargo"))==toupper(cargo)]
  add("| 1 | Carregar candidatos e filtrar cargo (",toupper(cargo),") | ",n_in," | ",nrow(cand)," |")
  hard(nrow(cand)==0,"nenhum candidato apos filtrar o cargo.")

  ## 2. Uma linha por SQ ------------------------------------------------------
  sqv<-as.character(G(cand,"sq")); n_lin<-length(sqv); n_uni<-uniqueN(sqv)
  if (n_lin!=n_uni){ cand<-cand[!duplicated(sqv)]; sqv<-as.character(G(cand,"sq")) }
  add("| 2 | Garantir 1 linha por SQ_CANDIDATO | ",n_lin," | ",nrow(cand)," |")
  add(""); add("- Passo 2: n_linhas=",n_lin," ; n_sq_unicos=",n_uni,
              ifelse(n_lin==n_uni," (sem duplicata)",paste0(" (removidas ",n_lin-n_uni,")")))
  sq_cargo<-unique(sqv)

  ## 3. Despesas restritas aos SQ do cargo -----------------------------------
  desp0<-ler_despesa(ano); nd_in<-nrow(desp0)
  desp0[, .sq:=as.character(G(desp0,"desp_sq"))]
  desp<-desp0[.sq %in% sq_cargo]
  add("| 3 | Restringir despesas aos SQ do cargo | ",nd_in," | ",nrow(desp)," |")

  ## 4. Parser monetario ------------------------------------------------------
  vcol<-col(desp,"desp_valor"); cls<-class(desp[[vcol]])[1]
  desp[, .valor:=num_brl(get(vcol))]; max_unit<-max(desp$.valor,na.rm=TRUE)
  add("| 4 | Converter valor (col ",vcol,", classe ",cls,") | ",nrow(desp)," | ",nrow(desp)," |")
  add("- Passo 4: maior despesa unitaria = R$ ",format(round(max_unit),big.mark=".",decimal.mark=",")," ; NAs=",sum(is.na(desp$.valor)))
  hard(max_unit>1e8,paste0("despesa unitaria impossivel (R$ ",round(max_unit)," > 100 mi)."))

  ## 5. Classificar a rubrica -------------------------------------------------
  desp[, .classe:=classificar_rubrica(G(desp,"desp_orig"))]
  audit<-desp[, .(soma=sum(.valor,na.rm=TRUE),n=.N), by=.(rubrica=G(desp,"desp_orig"),classe=.classe)][order(classe,-soma)]
  resumo<-desp[, .(soma=sum(.valor,na.rm=TRUE),n=.N), by=.classe][order(-soma)]
  add("| 5 | Classificar rubrica em 5 classes | ",nrow(desp)," | ",nrow(desp)," |")
  add("- Passo 5: ",paste(sprintf("%s: R$ %s (%d)",resumo$.classe,
        format(round(resumo$soma),big.mark=".",decimal.mark=","),resumo$n),collapse=" | "))

  ## 6. Remover transferencias ------------------------------------------------
  n_tr<-sum(desp$.classe=="transferencia"); soma_tr<-sum(desp$.valor[desp$.classe=="transferencia"],na.rm=TRUE)
  desp_c<-desp[.classe!="transferencia"]
  add("| 6 | Remover transferencias | ",nrow(desp)," | ",nrow(desp_c)," |")
  add("- Passo 6: removidas ",n_tr," transferencias, soma R$ ",format(round(soma_tr),big.mark=".",decimal.mark=","))

  ## 7. Somar por (SQ, classe), pivotar (sem dedup SQ_DESPESA) ----------------
  g_long<-desp_c[, .(v=sum(.valor,na.rm=TRUE)), by=.(sq=.sq,classe=.classe)]
  g<-dcast(g_long, sq~classe, value.var="v", fill=0)
  for(cl in c("impulsionamento","tradicional","operacional","nao_classificado")) if(!cl%in%names(g)) g[[cl]]<-0
  add("| 7 | Somar por (SQ,classe) e pivotar | ",nrow(desp_c)," | ",nrow(g)," |")

  ## 8. Deflacionar -----------------------------------------------------------
  for(cl in c("impulsionamento","tradicional","operacional","nao_classificado")){
    g[[paste0(cl,"_nom")]]<-g[[cl]]; g[[cl]]<-g[[cl]]*fator }
  add("| 8 | Deflacionar (fator ",sprintf("%.4f",fator),", base out/",substr(base_p,1,4),") | ",nrow(g)," | ",nrow(g)," |")

  ## 9. Votacao do recorte ----------------------------------------------------
  voto0<-ler_voto(ano)
  voto0<-voto0[cargo_match(toupper(G(voto0,"cargo")), toupper(cargo)) & G(voto0,"turno")==1]
  vv<-data.table(sq=as.character(G(voto0,"sq")), votos=as.numeric(G(voto0,"votos")))
  v<-vv[, .(total_votos=sum(votos,na.rm=TRUE)), by=sq]
  add("| 9 | Votacao: somar votos nominais por candidato | ",nrow(voto0)," | ",nrow(v)," |")

  ## 10. Capital politico -----------------------------------------------------
  cap<-montar_capital(ano,cargo,sq_cargo); tipo_chave<-attr(cap,"tipo_chave"); det<-attr(cap,"detalhe")
  add("| 10 | Capital politico (reeleicao + votos anteriores, chave ",tipo_chave,") | ",nrow(cap)," | ",nrow(cap)," |")
  add("- Passo 10: chave de casamento = ",tipo_chave,
      ifelse(tipo_chave!="cpf"," (CPF mascarado na coorte; fallback nome+nascimento)",""))
  add("- Passo 10: reeleicao (S) = ",sum(cap$reeleicao)," de ",nrow(cap))
  for(vn in names(det)) add("- Passo 10: ",vn," <- ",det[[vn]]$cargo," ",det[[vn]]$ano," ; n_nonzero=",det[[vn]]$n_nonzero)
  # TRAVAS de fonte (D): reeleicao precisa variar; mesmo_cargo nao pode vir toda zero.
  hard(sum(cap$reeleicao)==0 || sum(cap$reeleicao)==nrow(cap),
       "reeleicao constante na coorte (toda 0 ou toda 1): fonte do complementar errada.")
  hard(sum(cap$l_votos_mesmo_cargo_ultima>0)==0,
       "l_votos_mesmo_cargo_ultima toda zero: casamento de identidade/fonte de votacao anterior falhou.")

  ## 11. Eleitorado apto (vereador) -------------------------------------------
  apto_tab<-NULL
  if (ehver){ apto_tab<-ler_eleitorado(ano)
    add("- Passo 11: eleitorado apto municipal de ",nrow(apto_tab)," municipios (vereador, turno 1).") }

  ## 12. Montar painel --------------------------------------------------------
  fcol<-col_opt(cand,"federacao"); ccol<-col_opt(cand,"coligacao")
  lista<-as.character(G(cand,"partido"))
  if(!is.null(ccol)){ x<-as.character(cand[[ccol]]); ok<-!(is.na(x)|x==""|grepl("ISOLAD|#NULO",toupper(x))); lista[ok]<-x[ok] }
  if(!is.null(fcol)){ x<-as.character(cand[[fcol]]); ok<-!(is.na(x)|x==""|grepl("#NULO",toupper(x))); lista[ok]<-x[ok] }
  MAPA_IDEOLOGIA<-c(PT="ESQUERDA",PSB="ESQUERDA",PDT="ESQUERDA",PSOL="ESQUERDA",PCDOB="ESQUERDA",
    "PC DO B"="ESQUERDA",REDE="ESQUERDA",PV="ESQUERDA",PCO="ESQUERDA",PSTU="ESQUERDA",PPS="ESQUERDA",PCB="ESQUERDA",
    PP="DIREITA",PL="DIREITA",UNIAO="DIREITA",REPUBLICANOS="DIREITA",PRD="DIREITA",NOVO="DIREITA",PRTB="DIREITA",
    DEM="DIREITA",PSL="DIREITA",PSC="DIREITA",PATRIOTA="DIREITA",PRB="DIREITA",PRP="DIREITA",PR="DIREITA")
  fam<-MAPA_IDEOLOGIA[toupper(stringi::stri_trans_general(G(cand,"partido"),"Latin-ASCII"))]
  sit<-toupper(stringi::stri_trans_general(G(cand,"sit"),"Latin-ASCII"))
  painel<-data.table(
    sq=as.character(G(cand,"sq")), nome=G(cand,"nome"), uf=uf, ano=ano, cargo=toupper(cargo),
    partido=as.character(G(cand,"partido")), lista=lista, cod_mun=as.character(G(cand,"ue")),
    eleito=as.integer(grepl("ELEITO",sit) & !grepl("NAO",sit)),
    deferido=as.integer(!grepl("INDEFERIDO|RENUN|FALECID|CASSAD",sit)),
    masculino=as.integer(grepl("MASCULINO",toupper(G(cand,"genero")))),
    superior_completo=as.integer(grepl("SUPERIOR COMPLETO",toupper(G(cand,"instrucao")))),
    corbranca=as.integer(grepl("BRANCA",toupper(G(cand,"cor")))),
    esquerda=as.integer(fam %in% "ESQUERDA"), direita=as.integer(fam %in% "DIREITA"))
  painel<-merge(painel, v,   by="sq", all.x=TRUE)
  painel<-merge(painel, g,   by="sq", all.x=TRUE)
  painel<-merge(painel, cap, by="sq", all.x=TRUE)
  if (ehver) painel<-merge(painel, apto_tab, by="cod_mun", all.x=TRUE)
  zc<-c("impulsionamento","tradicional","operacional","nao_classificado"); zc<-c(zc,paste0(zc,"_nom"))
  for(cl in zc){ if(!cl%in%names(painel)) painel[[cl]]<-0; painel[is.na(get(cl)), (cl):=0] }
  painel[is.na(total_votos), total_votos:=0]
  capcols<-setdiff(names(cap),"sq"); for(cc in capcols) painel[is.na(get(cc)), (cc):=0]
  painel[, gasto_total:=impulsionamento+tradicional+operacional+nao_classificado]
  painel[, gasto_total_nominal:=impulsionamento_nom+tradicional_nom+operacional_nom+nao_classificado_nom]
  add("| 12 | Montar painel (join votos+gasto+capital",ifelse(ehver,"+apto",""),") | ",nrow(cand)," | ",nrow(painel)," |")

  ## 13. Travas de validacao --------------------------------------------------
  teto<-TETO_LEGAL(cargo,ano); max_nom<-max(painel$gasto_total_nominal,na.rm=TRUE)
  hard(nrow(painel)!=uniqueN(painel$sq),"fan-out: n_linhas != n_sq_unicos.")
  hard(any(painel$gasto_total<0,na.rm=TRUE)||any(painel$total_votos<0,na.rm=TRUE),"gasto ou voto negativo.")
  hard(is.finite(teto) && max_nom>2*teto,
       sprintf("gasto_total_nominal R$ %s > 2x teto (R$ %s) para %s %s.",
               format(round(max_nom),big.mark=".",decimal.mark=","),format(2*teto,big.mark=".",decimal.mark=","),toupper(cargo),ano))
  acima<-painel[gasto_total_nominal>teto]
  add("| 13 | Travas de validacao | ",nrow(painel)," | ",nrow(painel)," |")
  add("- Passo 13: teto legal nominal = R$ ",format(teto,big.mark=".",decimal.mark=",")," ; trava 2x = R$ ",format(2*teto,big.mark=".",decimal.mark=","))
  add("- Passo 13: MAIOR gasto_total_nominal = R$ ",format(round(max_nom),big.mark=".",decimal.mark=","),
      " ; deflacionado = R$ ",format(round(max(painel$gasto_total,na.rm=TRUE)),big.mark=".",decimal.mark=","))
  add("- Passo 13: acima do teto legal (AVISO) = ",nrow(acima))
  if(nrow(acima)){ aci<-acima[order(-gasto_total_nominal)][1:min(.N,10)]
    for(i in 1:nrow(aci)) add("    - ",aci$nome[i]," (",aci$partido[i],"): R$ ",format(round(aci$gasto_total_nominal[i]),big.mark=".",decimal.mark=",")) }
  n_eleitos<-sum(painel$eleito,na.rm=TRUE)
  cadeiras<-unname(c("DEPUTADO FEDERAL"=30,"DEPUTADO ESTADUAL"=54)[toupper(cargo)])
  add("- Passo 13: eleitos = ",n_eleitos, ifelse(!is.na(cadeiras)&&n_eleitos!=cadeiras,paste0(" (ATENCAO: esperado ",cadeiras,")"),""))
  if (ehver){ sem_apto<-sum(is.na(painel$apto)|painel$apto<=0)
    add("- Passo 13: vereadores sem eleitorado apto (municipio sem match) = ",sem_apto) }

  ## 14. Salvar ---------------------------------------------------------------
  cols<-c("sq","nome","uf","ano","cargo","partido","lista","cod_mun","total_votos","eleito","deferido",
          "impulsionamento","tradicional","operacional","nao_classificado","gasto_total","gasto_total_nominal",
          "reeleicao", grep("^l_votos_",names(painel),value=TRUE),
          "masculino","superior_completo","corbranca","esquerda","direita",
          if(ehver) "apto")
  fwrite(painel[, ..cols], file.path(DIR_TRATADO,paste0("painel_",tag,".csv")))
  audit[, rubrica:=iconv(rubrica,from="latin1",to="UTF-8")]
  fwrite(audit, file.path(DIR_TRATADO,paste0("despesas_classificadas_",tag,".csv")))
  add(""); add("## Saidas"); add("- painel_",tag,".csv (",nrow(painel)," cand, ",length(cols)," cols)")
  add("- despesas_classificadas_",tag,".csv (",nrow(audit)," rubricas x classe)")
  writeLines(L, file.path(DIR_TRATADO,paste0("log_tratamento_",tag,".md")))

  glog("## ",tag," : ",nrow(painel)," candidatos, ",n_eleitos," eleitos, reeleicao(S)=",sum(cap$reeleicao),
       ", max nom R$ ",format(round(max_nom),big.mark=".",decimal.mark=","))
  message(sprintf("  [OK] %s : %d cand, %d eleitos, max nom R$ %s", tag,nrow(painel),n_eleitos,
                  format(round(max_nom),big.mark=".",decimal.mark=",")))
  invisible(list(tag=tag, n=nrow(painel), eleitos=n_eleitos))
}

# ------------------------------- EXECUCAO ------------------------------------
glog("# Log de tratamento"); glog("")
for (r in RECORTES) tratar(UF, r$ano, r$cargo)

# Proveniencia de cada bruto lido
prov<-rbindlist(PROV$rows); setorder(prov, tipo, ano, arquivo)
fwrite(prov, file.path(DIR_LOG,"proveniencia.csv"))
writeLines(LOGG$lines, file.path(DIR_LOG,"tratamento.log"))
cat("\n[01] tratamento concluido:", length(RECORTES), "recortes; proveniencia de", nrow(prov), "arquivos brutos.\n")
