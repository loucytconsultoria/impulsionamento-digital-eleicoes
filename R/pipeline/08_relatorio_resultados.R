# =============================================================================
# 08_relatorio_resultados.R  -  Gera RELATORIO_RESULTADOS.md (deterministico)
# -----------------------------------------------------------------------------
# Monta o relatorio de resultados a partir das SAIDAS em saidas/ (nao refaz
# nenhuma conta): por recorte/porte, os coeficientes completos, a leitura de
# cada variavel pelo template unico, o efeito combinado das tres categorias no
# gasto de referencia unico, o efeito conjunto de incumbencia, a comparacao com
# a especificacao da monografia, as curvas comparativas e a saturacao das tres
# categorias. Texto sem travessoes, numeros em formato pt-BR, moeda da base do
# escopo.
# =============================================================================

fmtn <- function(x, d=2) ifelse(is.na(x), "n/d",
  formatC(x, format="f", digits=d, big.mark=".", decimal.mark=","))
fmtr <- function(x) ifelse(is.na(x), "n/d", paste0("R$ ", fmtn(x, 0)))
fmtp <- function(p) ifelse(is.na(p), "n/d", format(signif(p,3), scientific=TRUE, decimal.mark=","))
pctb <- function(b) fmtn(100*(exp(b)-1), 1)          # 100*(exp(b)-1)%

sigtxt <- function(p){
  if (is.na(p)) return("sem inferencia")
  if (p < 0.001) "distinto de zero a 0,1% (***)"
  else if (p < 0.01) "distinto de zero a 1% (**)"
  else if (p < 0.05) "distinto de zero a 5% (*)"
  else if (p < 0.1)  "distinto de zero apenas a 10% (.)"
  else "nao distinto de zero"
}

ROT_CAT <- c(impulsionamento="impulsionamento", tradicional="publicidade tradicional",
             operacional="gasto operacional")
ROT_LV <- c(
  l_votos_mesmo_cargo_ultima  = "votacao do candidato para o mesmo cargo na eleicao anterior",
  l_votos_dep_estadual_ultima = "votacao anterior para deputado estadual",
  l_votos_prefeito_ultima     = "votacao para prefeito na ultima municipal",
  l_votos_prefeito_penultima  = "votacao para prefeito na penultima municipal",
  l_votos_vereador_ultima     = "votacao para vereador na ultima municipal",
  l_votos_deputado_ultima     = "votacao para deputado (federal ou estadual) na ultima geral")
ROT_CTL <- c(masculino="candidatos homens contra mulheres",
             superior_completo="superior completo contra sem superior completo",
             corbranca="autodeclarados brancos contra nao brancos",
             esquerda="partidos de esquerda contra o centro",
             direita="partidos de direita contra o centro")

leitura_termo <- function(termo, est, p){
  s <- sigtxt(p)
  if (termo=="(Intercept)") return(NULL)
  if (grepl("^usou_", termo)){
    cl <- sub("^usou_","",termo)
    return(paste0("- `",termo,"` (margem extensiva de ",ROT_CAT[cl],"): ",fmtn(est,3),
      " pontos log ao passar de nao usar para usar a categoria; ",s,
      ". Costuma ser negativo porque e' o intercepto de quem usa com dose proxima de zero; leia junto da dose e do efeito combinado."))
  }
  if (grepl("^lg_", termo)){
    cl <- sub("^lg_","",termo)
    return(paste0("- `",termo,"` (dose intensiva de ",ROT_CAT[cl],", elasticidade entre usuarios): +1% de gasto associa-se a +",
      fmtn(est,3),"% de votos; ",s,". E' a inclinacao da curva de dose."))
  }
  if (termo=="reeleicao")
    return(paste0("- `reeleicao`: ser incumbente associa-se a ",pctb(est),
      "% nos votos esperados contra nao incumbente; ",s,
      ". Ler junto de `l_votos_mesmo_cargo_ultima`: o efeito conjunto de incumbencia esta logo abaixo."))
  if (grepl("^l_votos_", termo)){
    d <- ROT_LV[termo]; if (is.na(d)) d <- termo
    return(paste0("- `",termo,"` (elasticidade do capital politico: ",d,
      "): +1% de votos naquela eleicao associa-se a +",fmtn(est,3),"% de votos agora; ",s,"."))
  }
  if (termo %in% names(ROT_CTL))
    return(paste0("- `",termo,"`: ",pctb(est),"% de votos (",ROT_CTL[termo],"); ",s,"."))
  if (termo=="l_apto")
    return(paste0("- `l_apto` (elasticidade do voto ao eleitorado apto do municipio): ",
      fmtn(est,3),"; entre 0 e 1 significa que o voto cresce menos que proporcional ao tamanho do municipio; ",s,"."))
  paste0("- `",termo,"`: ",fmtn(est,3),"; ",s,".")
}

titulo_tag <- function(cargo, ano, porte){
  nome <- c("DEPUTADO FEDERAL"="Deputado Federal","DEPUTADO ESTADUAL"="Deputado Estadual",
            "VEREADOR"="Vereador")[toupper(cargo)]
  if (is.na(nome)) nome <- cargo
  t <- paste0("PR ", ano, ", ", nome)
  if (nzchar(porte)) t <- paste0(t, ", porte ", porte)
  t
}

# ------------------------------ INSUMOS --------------------------------------
metas <- fread(file.path(DIR_SAIDA,"modelos_votos_resumo.csv"))
satur <- fread(file.path(DIR_SAIDA,"saturacao_resumo.csv"))
incum <- fread(file.path(DIR_SAIDA,"efeito_incumbencia.csv"))
L <- character(0); w <- function(...) L <<- c(L, paste0(...))

# ------------------------------ CABECALHO ------------------------------------
w("# Relatorio de resultados: gastos de campanha e votos (PR)")
w("")
w("Resultados do modelo unico de votos, por recorte")
w("(deputado federal e estadual, 2018 e 2022) e por porte (vereador, 2020 e 2024).")
w("Estudo COMPARATIVO entre as tres categorias de gasto: impulsionamento digital,")
w("publicidade tradicional e gasto operacional. Valores monetarios na moeda da base")
w("do escopo: deputado em R$ de out/2022; vereador em R$ de out/2024.")
w("Fontes numericas: `tabelas/pipeline/`; metodo completo em")
w("`docs/01_metodologia.md`; auditoria dos resultados em")
w("`docs/05_auditoria_e_reprodutibilidade.md`.")
w("")
w("## Como ler os coeficientes (template unico)")
w("")
w("- O modelo de votos e' Binomial Negativa (NB2) com ligacao log: um coeficiente b")
w("  le-se como 100*(exp(b)-1)% de variacao nos votos esperados por +1 unidade da")
w("  variavel, mantido o resto constante.")
w("- `usou_<categoria>` (margem extensiva): efeito de ADOTAR a categoria, em pontos")
w("  log; sozinho costuma ser negativo porque e' o intercepto de quem usa com dose")
w("  proxima de zero, e so faz sentido lido junto da dose.")
w("- `lg_<categoria>` (dose intensiva): elasticidade entre usuarios; +1% de gasto")
w("  associa-se a +b% de votos. E' a inclinacao da curva de dose.")
w("- EFEITO COMBINADO da categoria: exp(b_usou + b_lg * log(gasto de referencia));")
w("  fator de votos de um usuario tipico contra um nao usuario, no MESMO gasto de")
w("  referencia para as tres categorias, o que torna os fatores comparaveis no")
w("  mesmo dinheiro. Ex.: fator 2,3 significa 2,3 vezes os votos, ou +130%.")
w("- GASTO DE REFERENCIA UNICO do cenario: mediana do gasto positivo por categoria,")
w("  agrupando as tres categorias entre quem gastou; um valor por recorte e porte,")
w("  aplicado igual as tres categorias, na moeda da base do escopo.")
w("- `reeleicao` (dummy): 100*(exp(b)-1)% por ser incumbente; ler junto de")
w("  `l_votos_mesmo_cargo_ultima`. O EFEITO CONJUNTO DE INCUMBENCIA e' o fator")
w("  exp(b_reeleicao + b_lvotos * votacao tipica de um incumbente, em log1p),")
w("  contra um desafiante sem historico; e' a leitura correta porque a dummy e a")
w("  votacao anterior sao colineares (todo incumbente tem votacao anterior).")
w("- `l_votos_<cargo>_<quando>`: elasticidade do capital politico daquele cargo;")
w("  +1% de voto anterior associa-se a +b% de votos agora.")
w("- Controles (masculino, superior_completo, corbranca, esquerda, direita):")
w("  100*(exp(b)-1)% da categoria contra a base (mulher; sem superior; nao branco;")
w("  centro).")
w("- `l_apto` (vereador): elasticidade do voto ao eleitorado; entre 0 e 1, o voto")
w("  cresce menos que proporcional ao tamanho do municipio.")
w("- Significancia: *** 0,1%; ** 1%; * 5%; . 10%.")
w("")
w("## Curvas comparativas e saturacao: como foram calculadas")
w("")
w("Entre usuarios de uma categoria, os votos previstos vem da margem intensiva do")
w("modelo: votos(g) = exp(eta_ref + b_lg * log g) = K * g^b_lg, com K = exp(eta_ref)")
w("o nivel do perfil de referencia (usuario da categoria, demais variaveis na media")
w("da amostra do recorte; no vereador, eleitorado apto na mediana do porte). O")
w("custo marginal por voto e' a derivada inversa d(gasto)/d(votos previstos), que")
w("na forma fechada e' g^(1-b_lg)/(K*b_lg). O ponto de saturacao pratica e' o gasto")
w("g* em que o custo marginal atinge o limiar L: g* = (K*b_lg*L)^(1/(1-b_lg)).")
w("O limiar e' a MEDIA dos custos individuais (gasto total dividido por votos),")
w("entre os eleitos e no conjunto geral do recorte. A saturacao nao e' reportada")
w("quando a dose intensiva da categoria nao e' distinta de zero a 5% (g* colapsa")
w("quando b_lg tende a zero). As tres categorias aparecem no mesmo grafico, cada")
w("uma na sua faixa observada de gasto (ate o quantil 99% do gasto dos usuarios);")
w("a leitura e' comparativa.")
w("")
w("Nota de leitura para contrastes entre anos: o ponto de saturacao depende do")
w("nivel K do perfil de referencia do proprio ano. No federal, K cai de 2018 para")
w("2022 (mais candidatos dividindo praticamente os mesmos votos), e por isso a")
w("saturacao de 2022 e' menor mesmo com dose e limiar maiores; a decomposicao")
w("completa esta em `docs/05_auditoria_e_reprodutibilidade.md` (item 5).")
w("")

# --------------------------- SECAO POR RECORTE -------------------------------
for (i in seq_len(nrow(metas))){
  tg <- metas$tag[i]
  ct <- fread(file.path(DIR_SAIDA, paste0("coef_votos_",tg,".csv")))
  ef <- fread(file.path(DIR_SAIDA, paste0("efeito_combinado_",tg,".csv")))
  cm <- fread(file.path(DIR_SAIDA, paste0("comparacao_monografia_",tg,".csv")))
  st <- satur[tag==tg]
  ic <- incum[tag==tg]
  gref <- ef$g_ref[1]

  w("---"); w("")
  w("## ", titulo_tag(metas$cargo[i], metas$ano[i], metas$porte[i]))
  w("")
  w("Amostra do modelo de votos: n = ", metas$n[i], " (de ", metas$n_full[i],
    " candidatos; ", metas$eleitos[i], " eleitos). AIC = ", fmtn(metas$aic[i],1),
    "; theta (dispersao NB2) = ", fmtn(metas$theta[i],3),
    ". Gasto de referencia unico do cenario: ", fmtr(gref), ".")
  w("")
  w("### Coeficientes completos")
  w("")
  w("| termo | estimativa | EP | p | sig |")
  w("|---|---:|---:|---:|---|")
  for (j in seq_len(nrow(ct)))
    w("| ", ct$termo[j], " | ", fmtn(ct$estimativa[j],4), " | ", fmtn(ct$ep[j],4),
      " | ", fmtp(ct$p[j]), " | ", ct$sig[j], " |")
  w("")
  w("### Leitura de cada variavel")
  w("")
  for (j in seq_len(nrow(ct))){
    li <- leitura_termo(ct$termo[j], ct$estimativa[j], ct$p[j])
    if (!is.null(li)) w(li)
  }
  if (nrow(ic)==1)
    w("- EFEITO CONJUNTO DE INCUMBENCIA: um incumbente tipico (votacao anterior de ",
      fmtn(ic$votos_anteriores_tipicos,0), " votos, mediana entre os ", ic$n_incumbentes,
      " incumbentes da amostra) tem fator ", fmtn(ic$fator,2), " de votos (",
      pctb(ic$efeito_log), "%) contra um desafiante sem historico; p = ", fmtp(ic$p),
      " (", ic$sig, "). E' a leitura correta de reeleicao + votacao anterior juntas.")
  w("")
  w("### Efeito combinado das tres categorias (mesmo gasto de referencia, ", fmtr(gref), ")")
  w("")
  w("| categoria | fator de votos | variacao | p | sig |")
  w("|---|---:|---:|---:|---|")
  eo <- ef[order(-efeito_mult)]
  for (j in seq_len(nrow(eo)))
    w("| ", eo$categoria[j], " | ", fmtn(eo$efeito_mult[j],2), " | ",
      ifelse(is.na(eo$efeito_mult[j]),"n/d",paste0(pctb(eo$efeito_log[j]),"%")), " | ",
      fmtp(eo$p[j]), " | ", eo$sig[j], " |")
  w("")
  ok <- eo[is.finite(efeito_mult)]
  if (nrow(ok)>=2)
    w("No mesmo dinheiro (", fmtr(gref), "), a ordem dos fatores de votos e': ",
      paste(paste0(ok$categoria, " (", fmtn(ok$efeito_mult,2), ")"), collapse=", "),
      ". O fator compara um usuario tipico da categoria, naquele gasto, com um nao usuario.")
  w("")
  w("### Comparacao com a especificacao da monografia")
  w("")
  w("Mesma amostra e mesma familia NB2; muda a especificacao: a monografia usava")
  w("log1p do gasto unico por categoria e so a dummy de reeleicao como capital.")
  w("")
  w("| medida | monografia | sig | atual | sig |")
  w("|---|---:|---|---:|---|")
  for (j in seq_len(nrow(cm)))
    w("| ", cm$medida[j], " | ", fmtn(cm$monografia[j],4), " | ", cm$sig_monografia[j],
      " | ", fmtn(cm$atual[j],4), " | ", cm$sig_atual[j], " |")
  w("")
  lgi <- ct[termo=="lg_impulsionamento", estimativa]
  lpi <- cm[grepl("^elasticidade_impulsionamento", medida), monografia]
  rem <- cm[medida=="reeleicao", monografia]; rea <- cm[medida=="reeleicao", atual]
  aim <- cm[medida=="AIC", monografia];       aia <- cm[medida=="AIC", atual]
  w("Leitura: a dose intensiva do impulsionamento entre usuarios (",
    fmtn(lgi,3), ") e' maior que a elasticidade log1p unica da monografia (",
    fmtn(lpi,3), ") porque o log1p unico dilui a dose entre os nao usuarios. ",
    "A incumbencia, que na monografia era so a dummy de reeleicao (", fmtn(rem,3),
    "), agora se reparte entre a dummy (", fmtn(rea,3),
    ") e a votacao anterior do mesmo cargo, entao os dois termos atuais leem-se ",
    "juntos (efeito conjunto acima). AIC: atual ", fmtn(aia,1), " contra ",
    fmtn(aim,1), " da monografia (",
    ifelse(aia<aim, "o modelo atual ajusta melhor", "a especificacao da monografia ajusta melhor"), ").")
  w("")
  w("### Curvas comparativas e saturacao das tres categorias")
  w("")
  w("![Custo marginal por voto](figuras/custo_marginal_categorias_", tg, ".png)")
  w("")
  w("![Votos previstos](figuras/votos_previstos_categorias_", tg, ".png)")
  w("")
  w("Limiar de custo por voto (media dos custos individuais): eleitos ",
    fmtr(st$custo_eleitos_media[1]), "; geral ", fmtr(st$custo_geral_media[1]), ".")
  w("")
  w("| categoria | dose intensiva (b_lg) | n usuarios | saturacao (limiar eleitos) | saturacao (limiar geral) | faixa observada ate |")
  w("|---|---:|---:|---:|---:|---:|")
  for (j in seq_len(nrow(st))){
    se <- if (nzchar(st$mascara[j])) paste0("n/d (", st$mascara[j], ")")
          else paste0(fmtr(st$sat_eleitos[j]),
                      ifelse(st$sat_eleitos_na_faixa[j], "", " (alem da faixa observada)"))
    sg <- if (nzchar(st$mascara[j])) "n/d"
          else paste0(fmtr(st$sat_geral[j]),
                      ifelse(st$sat_geral_na_faixa[j], "", " (alem da faixa observada)"))
    w("| ", st$categoria[j], " | ", fmtn(st$beta_intensiva[j],3), " | ", st$n_usuarios[j],
      " | ", se, " | ", sg, " | ", fmtr(st$gasto_q99[j]), " |")
  }
  w("")
  w("O ponto de saturacao e' o gasto na categoria a partir do qual cada voto")
  w("adicional custa mais do que o limiar (formula fechada na secao de metodo).")
  w("'Alem da faixa observada' significa que o cruzamento fica acima do quantil")
  w("99% do gasto observado dos usuarios, ou seja, e' extrapolacao.")
  w("")
}

# ------------------------------ RODAPE ----------------------------------------
w("---"); w("")
w("## Reproducao")
w("")
w("Execucao completa: `Rscript R/pipeline/run_all.R` (scripts 00 a 08), a partir da raiz do")
w("repositorio. Determinismo verificado por md5 dos paineis tratados, das tabelas e das")
w("figuras em duas execucoes (ver `docs/05_auditoria_e_reprodutibilidade.md`); o")
w("inventario com md5 por arquivo e gravado em `MANIFEST.md`.")

writeLines(L, file.path(ROOT, "RELATORIO_RESULTADOS.md"))
cat("\n[08] RELATORIO_RESULTADOS.md gerado (", length(L), " linhas).\n")
