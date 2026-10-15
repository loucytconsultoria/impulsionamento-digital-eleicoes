# =============================================================================
# modelo_impulsionamento.R
# Efeito do gasto com impulsionamento digital no desempenho eleitoral.
# Motor econometrico parametrizado por (UF, ano, cargo).
#
# DESENHO (pos-separacao tratamento/estimacao):
#   O TRATAMENTO (01_tratamento.R) le o bruto do TSE, classifica, deflaciona por
#   tabela IPCA versionada e TRAVA contra valores impossiveis, gravando o painel
#   tratado em dados_tratados/painel_*.csv. ESTE motor apenas LE esse painel e
#   estima; nao processa bruto. Se o painel nao existir, ele PARA pedindo o
#   tratamento. Assim a estimacao e' deterministica sobre CSV auditaveis.
#
# PIPELINE, para cada (UF, ano, cargo):
#   1. Le o painel tratado e deriva so' o que e' do modelo (log do gasto; no
#      vereador, porte e eleitorado via merge municipal IBGE).
#   2. VOTOS: Binomial Negativa (glmmTMB/NB2), log1p(gasto) por categoria
#      (ELASTICIDADE), controles + ideologia + capital politico. SE classico e
#      HC3 robusto. Vereador: offset de eleitorado; cluster por municipio.
#   3. SUCESSO: logistica de Firth, forca de chapa leave-one-out.
#   4. Proporcao de votos: logit fracionario. Margens 3B/3C. Oster (3 categorias).
#   5. SATURACAO: custo marginal por voto e ponto de saturacao por 3 limiares
#      (R$1, custo medio geral, custo dos eleitos = MEDIA dos custos individuais);
#      FORMAS COM TETO (Michaelis-Menten, exp. assintotica, spline-NB, GAM-NB) com
#      Vmax e gasto a 90%/95% do Vmax; e um SEGUNDO conjunto em POPULACAO COMUM
#      (so' usuarios de impulsionamento) para comparacao justa entre categorias.
#   6. Vereador: estratificado por PORTE; moderadores de desenvolvimento em
#      interacao com o impulsionamento, com controle de falsas descobertas (BH).
#   7. Grava tabelas, diagnosticos e graficos por recorte.
#
# Roda em R puro. Semente fixa. Sem dependencia de IA.
# Executar a partir da raiz do repositorio (dados_tratados/ e dicionarios/ sao
# relativos a ela); o painel vem de 01_tratamento.R (nesta pasta).
# =============================================================================

# ------------------------------ 0. PACOTES -----------------------------------
.pkgs <- c(
  "data.table","dplyr","stringi","purrr","tidyr",       # dados/IO
  "sidrar",                                             # municipios (IBGE) p/ vereador
  "MASS","glmmTMB","splines","mgcv","minpack.lm",       # contagem, spline/GAM, nls robusto
  "sandwich","lmtest",                                  # erros robustos
  "logistf",                                            # Firth
  "performance","DHARMa",                               # diagnostico
  "pROC","yardstick","robomit","scales"
)
.inst <- function(p) if (!requireNamespace(p, quietly=TRUE)) {
  if (p=="minpack.lm") return(invisible())  # opcional: se ausente, usa-se nls() base
  install.packages(p, repos="https://cloud.r-project.org")
}
invisible(lapply(.pkgs, .inst))
invisible(lapply(setdiff(.pkgs, if (requireNamespace("minpack.lm", quietly=TRUE)) character(0) else "minpack.lm"),
                 library, character.only=TRUE))
select <- dplyr::select
.tem_minpack <- requireNamespace("minpack.lm", quietly=TRUE)

# ------------------------------ 1. CONFIG ------------------------------------
CONFIG <- list(
  dir_tratado = "dados_tratados/",
  dir_saida   = "saidas/por_uf_ano_cargo/",
  dir_plots   = "saidas/plots/",
  dir_dict    = "dicionarios/",
  step_sat    = 10,            # malha da curva de saturacao (R$); use 1 p/ precisao
  seed        = 42
)
set.seed(CONFIG$seed)
for (d in CONFIG[c("dir_saida","dir_plots","dir_dict")])
  dir.create(d, recursive=TRUE, showWarnings=FALSE)

# ----------------------- 2. DADOS MUNICIPAIS (vereador) ----------------------
# Populacao e densidade (IBGE/sidrar) + moderadores do dicionario versionado
# (IDHM, Gini, penetracao de internet) + crosswalk IBGE->TSE (abjData), para o
# merge com o painel (cujo cod_mun e' o codigo TSE).
obter_municipios <- function(uf) {
  out <- tryCatch({
    pop <- sidrar::get_sidra(6579, variable=9324, geo="City")
    setDT(pop); pop[, .(cod_ibge=as.character(`Município (Código)`), populacao=Valor)]
  }, error=function(e){ warning("IBGE populacao indisponivel: ", e$message)
    data.table(cod_ibge=character(), populacao=numeric()) })
  dens <- tryCatch({
    dd <- sidrar::get_sidra(4714, variable=614, geo="City")
    setDT(dd); dd[, .(cod_ibge=as.character(`Município (Código)`), densidade=Valor)]
  }, error=function(e){ warning("IBGE densidade indisponivel: ", e$message); NULL })
  if (!is.null(dens)) out <- merge(out, dens, by="cod_ibge", all.x=TRUE)
  extra <- file.path(CONFIG$dir_dict,"dados_municipios_extra.csv")
  if (file.exists(extra)) {
    ex <- fread(extra, colClasses=list(character="cod_mun")); setnames(ex,"cod_mun","cod_ibge")
    out <- merge(out, ex, by="cod_ibge", all.x=TRUE)
  } else warning("dicionario de moderadores ausente: ", extra)
  if (requireNamespace("abjData", quietly=TRUE)) {
    e <- new.env(); utils::data("muni", package="abjData", envir=e)
    xw <- as.data.table(e$muni)[, .(cod_ibge=as.character(muni_id), cod_mun=as.character(tse_id))]
    out <- merge(out, xw, by="cod_ibge", all.x=TRUE)
    out <- out[!is.na(cod_mun)]
    out[, cod_ibge := NULL]
  } else stop("abjData ausente: sem crosswalk TSE-IBGE; merge municipal do vereador falharia.")
  unique(out, by="cod_mun")
}

# -------------------------- 3. PREPARO DA BASE -------------------------------
# LE o painel tratado e deriva so' as colunas do modelo. NAO processa bruto.
preparar_base <- function(uf, ano, cargo) {
  tag <- sprintf("%s_%s_%s", uf, ano, gsub(" ","_",toupper(cargo)))
  f <- file.path(CONFIG$dir_tratado, paste0("painel_", tag, ".csv"))
  if (!file.exists(f))
    stop("Painel tratado nao encontrado:\n  ", f,
         "\n  Rode antes: source('01_tratamento.R'); tratar('", uf, "', ", ano, ", '", toupper(cargo), "')")
  df <- data.table::fread(f, colClasses=list(character=c("sq","cod_mun","partido","lista","nome")))

  # log1p(gasto) por categoria (uma parte). A saturacao varia o gasto bruto
  # reescrevendo a coluna da categoria; lp_ e' recalculado quando necessario.
  for (cl in c("impulsionamento","tradicional","operacional"))
    df[[paste0("lp_",cl)]] <- log1p(df[[cl]])
  if (!"gasto_total" %in% names(df))
    df[, gasto_total := impulsionamento + tradicional + operacional + nao_classificado]

  if (grepl("VEREADOR", toupper(cargo))) {
    mun <- obter_municipios(uf)
    n0 <- nrow(df)
    df <- merge(df, mun, by="cod_mun", all.x=TRUE)
    sem_pop <- sum(is.na(df$populacao))
    if (sem_pop > 0) message(sprintf("  [vereador] %d/%d candidatos sem populacao (municipio sem match IBGE); offset NA -> excluidos do modelo de votos.", sem_pop, n0))
    df[, eleitorado := pmax(populacao, 1)]
    df[, porte := cut(populacao, c(-Inf,2e4,1e5,1e6,Inf),
                      labels=c("PEQUENO","MEDIO","GRANDE","METROPOLE"))]
  }
  df[]
}

# ---------------------------- 4. FORMULAS -----------------------------------
# Gasto: log1p por categoria (uma parte). O coeficiente, com link log, e' a
# ELASTICIDADE do voto ao gasto da categoria (d log E[votos] / d log(1+gasto)),
# comparavel entre categorias e com a literatura. Controles: individuais +
# ideologia (centro = base) + capital politico (proxies, vindos do painel).
termos_gasto <- c("lp_impulsionamento","lp_tradicional","lp_operacional")
# Vereador NAO inclui venceu_prefeito: e' raro um prefeito eleito "rebaixar-se" a
# vereador, entao a variavel seria quase toda zero e so' adicionaria ruido.
proxies_de <- function(cargo) if (grepl("DEPUTADO",toupper(cargo)))
  c("incumbente","disputou_perdeu_geral","venceu_prefeito","venceu_vereador") else
  c("disputou_deputado","incumbente_vereador","disputou_perdeu_vereador")
controles <- c("masculino","superior_completo","corbranca","esquerda","direita")

montar_formula <- function(cargo,y,moderador=NULL,offset=FALSE){
  rhs <- c(termos_gasto, proxies_de(cargo), controles)
  if (!is.null(moderador)) rhs <- c(rhs, moderador, paste0("lp_impulsionamento:",moderador))
  f <- paste(y,"~",paste(rhs,collapse=" + "))
  if (offset) f <- paste(f,"+ offset(log(eleitorado))")
  as.formula(f)
}

estrelas <- function(p) ifelse(is.na(p),"",ifelse(p<.001,"***",ifelse(p<.01,"**",ifelse(p<.05,"*",ifelse(p<.1,".","")))))
tab_coef <- function(termos,est,se,p) data.table(termo=termos, estimativa=est, ep=se, z=est/se, p=p, sig=estrelas(p))
coef_glmnb <- function(m){ s<-summary(m)$coefficients; tab_coef(rownames(s),s[,1],s[,2],s[,4]) }
coef_vcov  <- function(m,V){ b<-coef(m); nm<-intersect(names(b),rownames(V))
  se<-sqrt(diag(V[nm,nm,drop=FALSE])); tab_coef(nm,b[nm],se,2*pnorm(-abs(b[nm]/se))) }
coef_firth <- function(m){ se<-sqrt(diag(vcov(m))); tab_coef(names(coef(m)),coef(m),se,m$prob) }

# --- NB2 robusto via glmmTMB ------------------------------------------------
# Decisao travada (DIAGNOSTICO 2026-06-28): o glm.nb (MASS) estoura por cauda
# longa de votos; glmmTMB ajusta o MESMO NB2 com otimizador estavel e reproduz o
# glm.nb onde os dois convergem. A causa do estouro era o gasto inflado, agora
# barrado no TRATAMENTO. Theta = sigma(m). HC3 calculado a mao (validado ==
# sandwich::vcovHC(glm,"HC3")), porque glmmTMB nao tem vcovHC/hatvalues.
fit_nb    <- function(f, data) glmmTMB::glmmTMB(f, data, family=glmmTMB::nbinom2)
theta_nb  <- function(m) as.numeric(glmmTMB::sigma(m))
coef_tmb  <- function(m){ s<-summary(m)$coefficients$cond; tab_coef(rownames(s),s[,1],s[,2],s[,4]) }
.tmb_parts <- function(m){
  X<-glmmTMB::getME(m,"X"); y<-as.numeric(stats::model.response(stats::model.frame(m)))
  mu<-as.numeric(stats::predict(m,type="response")); list(X=X,y=y,mu=mu,theta=theta_nb(m)) }
vcovHC3_nb <- function(m){            # HC3 (link log, NB2), bread (X'WX)^-1 sem dispersao
  p<-.tmb_parts(m); V<-p$mu+p$mu^2/p$theta; W<-as.vector(p$mu^2/V)
  s<-as.vector((p$y-p$mu)*p$mu/V); B<-solve(t(p$X)%*%(p$X*W))
  h<-W*rowSums((p$X%*%B)*p$X); meat<-t(p$X)%*%(p$X*(s^2/(1-h)^2))
  Vc<-B%*%meat%*%B; dimnames(Vc)<-list(colnames(p$X),colnames(p$X)); Vc }
vcovCL_nb <- function(m, cluster){    # cluster-robusto CR0 (vereador, por municipio)
  p<-.tmb_parts(m); V<-p$mu+p$mu^2/p$theta; s<-as.vector((p$y-p$mu)*p$mu/V)
  ef<-p$X*s; B<-solve(t(p$X)%*%(p$X*as.vector(p$mu^2/V))); cl<-as.character(cluster)
  meat<-matrix(0,ncol(p$X),ncol(p$X)); for(gp in unique(cl)){ sg<-colSums(ef[cl==gp,,drop=FALSE]); meat<-meat+tcrossprod(sg) }
  Vc<-B%*%meat%*%B; dimnames(Vc)<-list(colnames(p$X),colnames(p$X)); Vc }
coef_tmb_vcov <- function(m, Vr){
  b<-glmmTMB::fixef(m)$cond; nm<-intersect(names(b),rownames(Vr))
  se<-sqrt(diag(Vr[nm,nm,drop=FALSE])); tab_coef(nm,b[nm],se,2*pnorm(-abs(b[nm]/se))) }
pseudo_r2_nb <- function(m){          # 1 - deviance/null.deviance
  tryCatch({ y<-as.numeric(stats::model.response(stats::model.frame(m)))
    mu<-as.numeric(stats::predict(m,type="response")); th<-theta_nb(m)
    dr<-MASS::negative.binomial(theta=th)$dev.resids; wt<-rep(1,length(y))
    1 - sum(dr(y,mu,wt))/sum(dr(y,rep(mean(y),length(y)),wt)) }, error=function(e) NA_real_) }

# -------------------------- 5. MODELO DE VOTOS ------------------------------
modelo_votos <- function(df,cargo){
  off <- grepl("VEREADOR",toupper(cargo))
  f <- montar_formula(cargo,"total_votos",offset=off)
  m <- fit_nb(f, df)
  vcv_hc <- tryCatch(vcovHC3_nb(m),error=function(e) NULL)
  vcv_cl <- if (off) tryCatch(vcovCL_nb(m, df$cod_mun),error=function(e) NULL) else NULL
  list(modelo=m, tipo="NB", formula=f,
       coef=coef_tmb(m),
       coef_hc3=if(!is.null(vcv_hc)) coef_tmb_vcov(m,vcv_hc) else NULL,
       coef_cluster_mun=if(!is.null(vcv_cl)) coef_tmb_vcov(m,vcv_cl) else NULL)
}

# ELASTICIDADE intensiva ENTRE USUARIOS de cada categoria: votos ~ log(gasto) +
# controles no subconjunto de quem gastou na categoria. Sem colinearidade, o
# coeficiente de log(gasto) e' a elasticidade condicional ao uso.
elasticidade_usuarios <- function(df, cargo){
  off <- grepl("VEREADOR",toupper(cargo))
  vazio <- function(cl,n) data.table(categoria=cl, n_usuarios=n, elasticidade=NA_real_, ep=NA_real_, p=NA_real_, sig="")
  rbindlist(lapply(c("impulsionamento","tradicional","operacional"), function(cl){
    d <- df[get(cl) > 0]; if (nrow(d) < 30) return(vazio(cl, nrow(d)))
    outros <- paste0("lp_", setdiff(c("impulsionamento","tradicional","operacional"), cl))
    rhs <- c(sprintf("log(%s)",cl), outros, proxies_de(cargo), controles)
    f <- paste("total_votos ~", paste(rhs, collapse=" + "))
    if (off) f <- paste(f, "+ offset(log(eleitorado))")
    m <- tryCatch(fit_nb(as.formula(f), d), error=function(e) NULL)
    if (is.null(m)) return(vazio(cl, nrow(d)))
    s <- summary(m)$coefficients$cond; tm <- sprintf("log(%s)",cl)
    if (!tm %in% rownames(s)) return(vazio(cl, nrow(d)))
    data.table(categoria=cl, n_usuarios=nrow(d), elasticidade=s[tm,1], ep=s[tm,2], p=s[tm,4], sig=estrelas(s[tm,4]))
  }))
}

# M3B - hurdle na amostra cheia (extensiva + intensiva, nao viesado, mais impreciso).
modelo_margem_3b <- function(df, cargo){
  d <- data.table::copy(df)
  cats <- c("impulsionamento","tradicional","operacional")
  for (cl in cats){ d[[paste0("usou_",cl)]] <- as.integer(d[[cl]]>0)
                    d[[paste0("lg_",cl)]]   <- ifelse(d[[cl]]>0, log(d[[cl]]), 0) }
  termos <- unlist(lapply(cats, function(cl) c(paste0("usou_",cl), sprintf("usou_%s:lg_%s",cl,cl))))
  rhs <- c(termos, proxies_de(cargo), controles)
  f <- paste("total_votos ~", paste(rhs, collapse=" + "))
  if (grepl("VEREADOR",toupper(cargo))) f <- paste(f, "+ offset(log(eleitorado))")
  m <- tryCatch(fit_nb(as.formula(f), d), error=function(e) NULL)
  if (is.null(m)) return(NULL)
  list(modelo=m, formula=as.formula(f), coef=coef_tmb(m))
}

# ------------------------- 6. MODELO DE SUCESSO ----------------------------
modelo_sucesso <- function(df,cargo){
  d <- df[apto==1]
  d[, votos_lista_loo := sum(total_votos) - total_votos, by=.(lista,cod_mun)]
  rhs <- c(termos_gasto, proxies_de(cargo), controles, "log1p(votos_lista_loo)")
  # porte so' entra quando ha' mais de um nivel (no estrato por porte e' constante).
  if (grepl("VEREADOR",toupper(cargo)) && "porte" %in% names(d) && length(unique(na.omit(d$porte)))>1) rhs <- c(rhs,"porte")
  f <- as.formula(paste("eleito ~", paste(rhs,collapse=" + ")))
  # Firth (penalizacao para evento raro/separacao). pl=FALSE: inferencia de Wald
  # sobre o ajuste de Firth -- os estimadores de ponto sao identicos; desliga os
  # intervalos de perfil de verossimilhanca (caros e instaveis em amostra grande,
  # como o vereador com ~31 mil candidatos).
  m <- logistf::logistf(f, data=d, pl=FALSE, control=logistf::logistf.control(maxit=1000))
  p <- predict(m,type="response")
  list(modelo=m, formula=f, dados=d, prob=p, coef=coef_firth(m),
       auc=as.numeric(pROC::auc(pROC::roc(d$eleito,p,quiet=TRUE))),
       pr_auc=tryCatch(yardstick::pr_auc_vec(factor(d$eleito,levels=c(1,0)),p),error=function(e) NA_real_),
       brier=mean((p-d$eleito)^2))
}

# Proporcao de votos (logit fracionario). Sem offset (a proporcao ja' normaliza).
modelo_share <- function(df, cargo){
  d <- data.table::copy(df)
  if (grepl("VEREADOR",toupper(cargo))) d[, vote_share := total_votos/sum(total_votos,na.rm=TRUE), by=cod_mun]
  else                                  d[, vote_share := total_votos/sum(total_votos,na.rm=TRUE)]
  d[!is.finite(vote_share), vote_share := 0]
  rhs <- c(termos_gasto, proxies_de(cargo), controles)
  f <- as.formula(paste("vote_share ~", paste(rhs, collapse=" + ")))
  m <- stats::glm(f, data=d, family=quasibinomial("logit"))
  vcv <- tryCatch(sandwich::vcovHC(m,type="HC3"), error=function(e) NULL)
  list(modelo=m, formula=f, coef=if(!is.null(vcv)) coef_vcov(m,vcv) else coef_glmnb(m))
}

# --------------------------- 7. DIAGNOSTICOS -------------------------------
diag_votos <- function(mv){
  m<-mv$modelo
  dh<-tryCatch({ s<-DHARMa::simulateResiduals(m,n=250)
    list(dispersao=DHARMa::testDispersion(s,plot=FALSE)$p.value,
         zeros=DHARMa::testZeroInflation(s,plot=FALSE)$p.value,
         uniforme=DHARMa::testUniformity(s,plot=FALSE)$p.value, sim=s)},error=function(e) NULL)
  list(aic=AIC(m), theta=theta_nb(m), pseudo_r2=pseudo_r2_nb(m),
       vif=tryCatch(performance::check_collinearity(m),error=function(e) NULL),
       dharma=dh)
}
diag_sucesso <- function(ms){
  list(auc=ms$auc, pr_auc=ms$pr_auc, brier=ms$brier,
       max_abs_coef=max(abs(coef(ms$modelo)),na.rm=TRUE),  # bandeira de separacao
       n=nrow(ms$dados), eleitos=sum(ms$dados$eleito))
}

# Oster (3 categorias), companheira linear, descritivo.
oster_sensibilidade <- function(df,cargo,x="lp_impulsionamento"){
  con  <- paste(c(setdiff(termos_gasto,x), proxies_de(cargo), controles), collapse=" + ")
  d <- as.data.frame(df); d$ltv <- log1p(d$total_votos)
  r2 <- tryCatch(summary(stats::lm(as.formula(paste("ltv ~",x,"+",con)), d))$r.squared, error=function(e) NA_real_)
  r2max <- if (is.na(r2)) 1 else min(1, 1.3*r2)
  val <- function(t,n) if (is.null(t)) NA_real_ else as.numeric(t$Value[t$Name==n])[1]
  ob <- tryCatch(robomit::o_beta(y="ltv", x=x, con=con, delta=1, R2max=r2max, type="lm", data=d), error=function(e) NULL)
  od <- tryCatch(robomit::o_delta(y="ltv", x=x, con=con, beta=0, R2max=r2max, type="lm", data=d), error=function(e) NULL)
  data.table(categoria=sub("lp_","",x), delta=val(od,"delta*"), beta_estrela=val(ob,"beta*"),
             beta_controlado=val(ob,"Controlled Coefficient"), beta_naive=val(ob,"Uncontrolled Coefficient"),
             r2=r2, r2max=r2max)
}
oster_todas <- function(df,cargo)
  rbindlist(lapply(termos_gasto, function(x) oster_sensibilidade(df,cargo,x)))

# ======================= 8. CURVAS DE SATURACAO =============================
# Limiares de custo por voto. Tres metodos para a ancora dos ELEITOS, decisao
# definida no desenho: o limiar usado e' a MEDIA dos custos por voto individuais dos
# eleitos (gasto_total/total_votos, eleitos com voto>0); reporta-se tambem a
# MEDIANA e a razao agregada (robustez). O limiar 'medio geral' segue agregado.
custo_voto <- function(df, grupo=c("geral","eleitos"), metodo=c("agregado","media","mediana")){
  grupo <- match.arg(grupo); metodo <- match.arg(metodo)
  d <- if (grupo=="eleitos") df[eleito==1 & total_votos>0] else df[total_votos>0]
  if (!nrow(d)) return(NA_real_)
  if (metodo=="agregado"){ s<-sum(d$total_votos,na.rm=TRUE); if (s<=0) return(NA_real_); return(sum(d$gasto_total,na.rm=TRUE)/s) }
  r <- d$gasto_total/d$total_votos; r <- r[is.finite(r)]
  if (!length(r)) return(NA_real_)
  if (metodo=="media") mean(r) else median(r)
}
perfil_ref <- function(df, vars){
  r <- df[1]; for (v in vars) if (v %in% names(df)) r[[v]] <- mean(df[[v]],na.rm=TRUE); r
}
# Modelo intensivo ENTRE USUARIOS da categoria (subamostra gasto>0): base da curva.
modelo_intensivo <- function(df, cargo, classe){
  d <- df[get(classe) > 0]
  outros <- paste0("lp_", setdiff(c("impulsionamento","tradicional","operacional"), classe))
  off <- if (grepl("VEREADOR",toupper(cargo))) "+ offset(log(eleitorado))" else ""
  f <- as.formula(paste("total_votos ~",
        paste(c(sprintf("log(%s)",classe), outros, proxies_de(cargo), controles), collapse=" + "), off))
  list(modelo=tryCatch(fit_nb(f,d), error=function(e) NULL), dados=d)
}
# Curva log-log fechada (votos = C*gasto^beta, demais vars na media): C,beta por
# 2 predicoes; malha analitica. A log-log NAO tem teto (cresce sem limite), por
# isso so' tem saturacao por LIMIAR de custo marginal (nao assintota).
curva_categoria <- function(mi, classe, gmax=50000, step=10){
  if (is.null(mi$modelo)) return(data.table(gasto=numeric(), votos=numeric()))
  vars <- setdiff(all.vars(stats::formula(mi$modelo)), "total_votos")
  ref  <- perfil_ref(mi$dados, vars)
  probe <- c(1000, 100000); nd <- ref[rep(1L,2)]; nd[[classe]] <- probe
  V <- as.numeric(predict(mi$modelo, newdata=nd, type="response"))
  beta <- log(V[2]/V[1])/log(probe[2]/probe[1]); C <- V[1]/probe[1]^beta
  grid <- seq(max(step,1), gmax, by=step)
  data.table(gasto=grid, votos=C*grid^beta)
}
ponto_inflexao <- function(curva, limite){
  if (is.na(limite) || !nrow(curva)) return(NA_real_)
  cm <- c(NA, diff(curva$gasto)/diff(curva$votos))
  i <- which(is.finite(cm) & cm>0 & cm>limite)[1]
  if (is.na(i)) NA_real_ else curva$gasto[i]
}
.gmax_saturacao <- function(mi, classe, ref, limiares, base=50000, teto=5e6){
  if (is.null(mi$modelo)) return(base)
  probe <- c(1000, 100000); nd <- ref[rep(1L,2)]; nd[[classe]] <- probe
  V <- tryCatch(as.numeric(predict(mi$modelo, newdata=nd, type="response")), error=function(e) NULL)
  if (is.null(V) || any(!is.finite(V)) || V[1]<=0) return(base)
  beta <- log(V[2]/V[1])/log(probe[2]/probe[1]); C <- V[1]/probe[1]^beta
  if (!is.finite(beta) || beta<=0 || beta>=1) return(teto)
  alvo <- suppressWarnings(max(limiares[is.finite(limiares)], na.rm=TRUE))
  if (!is.finite(alvo)) return(base)
  gstar <- (alvo*C*beta)^(1/(1-beta))
  min(teto, max(base, 1.2*gstar))
}

# --- FORMAS COM TETO (assintota horizontal) ---------------------------------
# A log-log nao satura; estas formas tem Vmax (teto de votos). Reporta-se Vmax e
# o gasto em que a curva atinge 90% e 95% do Vmax (saturacao pratica).
#   - Michaelis-Menten:   votos = Vmax*gasto/(K+gasto)         -> g90=9K, g95=19K
#   - Exp. assintotica:   votos = Vmax*(1-exp(-k*gasto))       -> via grade
#   - Spline-NB e GAM-NB: mean structure flexivel com covariaveis na media; Vmax =
#     maximo previsto na faixa observada; g90/g95 = menor gasto que atinge a fracao.
# nls ajustado na NUVEM (gasto_i, votos_i) dos usuarios (marginal/descritivo);
# spline/GAM ajustam com covariaveis (others na media), consistente com a log-log.
.nls_fit <- function(form, start, data){
  if (.tem_minpack) tryCatch(minpack.lm::nlsLM(form, start=start, data=data, control=minpack.lm::nls.lm.control(maxiter=200)), error=function(e) NULL)
  else tryCatch(nls(form, start=start, data=data, control=nls.control(maxiter=200, warnOnly=TRUE)), error=function(e) NULL)
}
.g_fracao <- function(predf, Vmax, gcap){
  gg <- seq(1, gcap, length.out=4000); pv <- suppressWarnings(predf(gg))
  i90<-which(pv>=0.90*Vmax)[1]; i95<-which(pv>=0.95*Vmax)[1]
  c(g90=if(is.na(i90)) NA_real_ else gg[i90], g95=if(is.na(i95)) NA_real_ else gg[i95])
}
formas_teto <- function(mi, classe, cargo){
  d <- mi$dados; x <- d[[classe]]; y <- as.numeric(d$total_votos)
  ok <- is.finite(x) & is.finite(y) & x>0; x<-x[ok]; y<-y[ok]
  formas <- c("michaelis_menten","exp_assintotica","spline_nb","gam_nb")
  vazio <- function(nt) data.table(classe=classe, forma=formas, Vmax=NA_real_, g90=NA_real_, g95=NA_real_,
                                   gasto_obs_max=NA_real_, max_votos_obs=NA_real_, teto_na_faixa=FALSE, convergiu=FALSE, nota=nt)
  if (length(x) < 30) return(vazio("n<30"))
  gobs <- max(x); ymax <- max(y); gcap <- 20*gobs; dd <- data.frame(x=x, y=y)
  res <- list()
  # Michaelis-Menten: votos = Vmax*gasto/(K+gasto); g90=9K, g95=19K
  mm <- suppressWarnings(.nls_fit(y ~ Vm*x/(K+x), c(Vm=ymax*1.1, K=stats::median(x)), dd))
  res$mm <- if (!is.null(mm)) { cf<-coef(mm); data.table(classe=classe, forma="michaelis_menten",
      Vmax=unname(cf["Vm"]), g90=9*unname(cf["K"]), g95=19*unname(cf["K"]), convergiu=TRUE, nota="") } else
      data.table(classe=classe, forma="michaelis_menten", Vmax=NA_real_, g90=NA_real_, g95=NA_real_, convergiu=FALSE, nota="nls nao convergiu")
  # Exp. assintotica: votos = Vmax*(1-exp(-k*gasto))
  ae <- suppressWarnings(.nls_fit(y ~ Vmax*(1-exp(-k*x)), c(Vmax=ymax*1.1, k=1/stats::median(x)), dd))
  res$ae <- if (!is.null(ae)) { cf<-coef(ae); Vmx<-unname(cf["Vmax"]); k<-unname(cf["k"])
      g<-.g_fracao(function(g) Vmx*(1-exp(-k*g)), Vmx, gcap)
      data.table(classe=classe, forma="exp_assintotica", Vmax=Vmx, g90=g["g90"], g95=g["g95"], convergiu=TRUE, nota="") } else
      data.table(classe=classe, forma="exp_assintotica", Vmax=NA_real_, g90=NA_real_, g95=NA_real_, convergiu=FALSE, nota="nls nao convergiu")
  # Spline-NB e GAM-NB com covariaveis na media (consistente com a log-log)
  outros <- paste0("lp_", setdiff(c("impulsionamento","tradicional","operacional"), classe))
  off <- grepl("VEREADOR",toupper(cargo))
  vars_cov <- c(outros, proxies_de(cargo), controles)
  ref <- perfil_ref(d, c(vars_cov, if(off) "eleitorado"))
  grid <- seq(min(x), gobs, length.out=300)
  curva_pred <- function(modelo){
    nd <- ref[rep(1L,length(grid))]; nd[[classe]] <- grid
    pv <- tryCatch(as.numeric(predict(modelo, newdata=as.data.frame(nd), type="response")), error=function(e) rep(NA_real_,length(grid)))
    Vmx <- suppressWarnings(max(pv, na.rm=TRUE))
    if (!is.finite(Vmx)) return(list(Vmax=NA_real_, g90=NA_real_, g95=NA_real_))
    i90<-which(pv>=0.90*Vmx)[1]; i95<-which(pv>=0.95*Vmx)[1]
    list(Vmax=Vmx, g90=if(is.na(i90)) NA_real_ else grid[i90], g95=if(is.na(i95)) NA_real_ else grid[i95])
  }
  rhs_off <- if (off) "+ offset(log(eleitorado))" else ""
  fs <- as.formula(paste("total_votos ~ splines::ns(log(",classe,"),3) +", paste(vars_cov,collapse=" + "), rhs_off))
  ms <- tryCatch(suppressWarnings(fit_nb(fs, d)), error=function(e) NULL)
  res$sp <- if (!is.null(ms)) { p<-curva_pred(ms); data.table(classe=classe, forma="spline_nb", Vmax=p$Vmax, g90=p$g90, g95=p$g95, convergiu=TRUE, nota="Vmax=max na faixa") } else
      data.table(classe=classe, forma="spline_nb", Vmax=NA_real_, g90=NA_real_, g95=NA_real_, convergiu=FALSE, nota="nao convergiu")
  fg <- as.formula(paste("total_votos ~ s(log(",classe,")) +", paste(vars_cov,collapse=" + "), rhs_off))
  mg <- tryCatch(suppressWarnings(mgcv::gam(fg, family=mgcv::nb(), data=as.data.frame(d), method="REML")), error=function(e) NULL)
  res$gam <- if (!is.null(mg)) { p<-curva_pred(mg); data.table(classe=classe, forma="gam_nb", Vmax=p$Vmax, g90=p$g90, g95=p$g95, convergiu=TRUE, nota="Vmax=max na faixa") } else
      data.table(classe=classe, forma="gam_nb", Vmax=NA_real_, g90=NA_real_, g95=NA_real_, convergiu=FALSE, nota="nao convergiu")
  tab <- rbindlist(res, fill=TRUE)
  # Avaliacao honesta: ha teto IDENTIFICAVEL na faixa de gasto observada?
  # Para MM/exp: teto plausivel se Vmax <= 5x o maior voto observado E g95 <= maior gasto observado.
  # Para spline/GAM: Vmax=max-na-faixa por construcao; "teto na faixa" se 95% e' atingido antes do topo.
  tab[, gasto_obs_max := gobs][, max_votos_obs := ymax]
  tab[forma %in% c("michaelis_menten","exp_assintotica"),
      teto_na_faixa := is.finite(Vmax) & Vmax <= 5*ymax & is.finite(g95) & g95 <= gobs]
  tab[forma %in% c("spline_nb","gam_nb"),
      teto_na_faixa := is.finite(g95) & g95 < 0.95*gobs]
  tab[convergiu==TRUE & forma %in% c("michaelis_menten","exp_assintotica") & (!is.finite(Vmax) | Vmax > 5*ymax),
      nota := "teto >> dados: sem saturacao na faixa (coerente com log-log)"]
  tab[convergiu==TRUE & forma %in% c("spline_nb","gam_nb") & teto_na_faixa==FALSE,
      nota := "curva ainda subindo no topo: sem plateau claro na faixa"]
  setcolorder(tab, c("classe","forma","Vmax","g90","g95","gasto_obs_max","max_votos_obs","teto_na_faixa","convergiu","nota"))
  tab[]
}

# Saturacao completa por categoria. limiar dos eleitos = MEDIA (decisao de desenho).
saturacao <- function(df, cargo, step=CONFIG$step_sat, formas=TRUE){
  lim <- c(R1            = 1,
           medio_geral   = custo_voto(df,"geral","agregado"),
           eleitos_media = custo_voto(df,"eleitos","media"))
  lim_extra <- c(eleitos_mediana = custo_voto(df,"eleitos","mediana"),
                 eleitos_razao   = custo_voto(df,"eleitos","agregado"),
                 medio_mediana   = custo_voto(df,"geral","mediana"))
  curvas <- list(); linhas <- list(); tab_formas <- list()
  for (classe in c("impulsionamento","tradicional","operacional")){
    mi <- modelo_intensivo(df, cargo, classe)
    ref <- if (!is.null(mi$modelo)) perfil_ref(mi$dados, setdiff(all.vars(stats::formula(mi$modelo)),"total_votos")) else NULL
    gmax <- if (!is.null(ref)) .gmax_saturacao(mi, classe, ref, c(lim,lim_extra)) else 50000
    cv <- curva_categoria(mi, classe, gmax, step); curvas[[classe]] <- cv
    # elasticidade (precisao) do termo log(gasto) no modelo intensivo
    el <- NA_real_; el_se <- NA_real_
    if (!is.null(mi$modelo)){ s<-summary(mi$modelo)$coefficients$cond; tm<-sprintf("log(%s)",classe)
      if (tm %in% rownames(s)){ el<-s[tm,1]; el_se<-s[tm,2] } }
    linhas[[classe]] <- data.table(classe=classe, n_usuarios=nrow(mi$dados), gmax=gmax,
      elasticidade=el, elasticidade_ep=el_se,
      custo_medio_geral=lim["medio_geral"], custo_eleitos_media=lim["eleitos_media"],
      custo_eleitos_mediana=lim_extra["eleitos_mediana"], custo_eleitos_razao=lim_extra["eleitos_razao"],
      sat_R1=ponto_inflexao(cv,1),
      sat_medio=ponto_inflexao(cv,lim["medio_geral"]),
      sat_eleitos_media=ponto_inflexao(cv,lim["eleitos_media"]),
      sat_eleitos_mediana=ponto_inflexao(cv,lim_extra["eleitos_mediana"]))
    if (formas) tab_formas[[classe]] <- tryCatch(formas_teto(mi, classe, cargo), error=function(e) NULL)
  }
  list(tabela=rbindlist(linhas), curvas=curvas, limiares=c(lim,lim_extra),
       formas_teto=if(formas) rbindlist(tab_formas) else NULL)
}

# ------------------------------ 9. GRAFICOS ---------------------------------
CORES <- c(impulsionamento="#1f77b4", tradicional="#d62728", operacional="#2ca02c")
plot_saturacao <- function(sat, tag){
  cls <- names(sat$curvas)
  vals <- unlist(lapply(sat$curvas,function(c) c$votos))
  if (!length(vals)) return(invisible())
  gmax <- max(unlist(lapply(sat$curvas, function(c) if (nrow(c)) max(c$gasto) else 0)), 1, na.rm=TRUE)
  png(file.path(CONFIG$dir_plots,paste0("saturacao_votos_",tag,".png")),1000,680,res=120)
  yl <- range(vals,na.rm=TRUE)
  plot(NA,xlim=c(0,gmax),ylim=yl,xlab="Gasto (R$ da base)",ylab="Votos previstos",
       main=paste("Votos previstos vs gasto -",tag))
  for (cl in cls) lines(sat$curvas[[cl]]$gasto, sat$curvas[[cl]]$votos, col=CORES[cl], lwd=2)
  legend("bottomright",legend=cls,col=CORES[cls],lwd=2,bty="n"); dev.off()
  png(file.path(CONFIG$dir_plots,paste0("saturacao_custo_",tag,".png")),1000,680,res=120)
  cap <- max(sat$limiares["eleitos_media"]*4, sat$limiares["medio_geral"]*2, 5, na.rm=TRUE)
  plot(NA,xlim=c(0,gmax),ylim=c(0,cap),xlab="Gasto (R$ da base)",
       ylab="Custo marginal por voto (R$)",main=paste("Custo marginal por voto -",tag))
  for (cl in cls){ cv<-sat$curvas[[cl]]; cm<-c(NA,diff(cv$gasto)/diff(cv$votos))
    lines(cv$gasto, cm, col=CORES[cl], lwd=2) }
  abline(h=sat$limiares[c("R1","medio_geral","eleitos_media")], lty=2, col="grey40")
  legend("topleft",legend=cls,col=CORES[cls],lwd=2,bty="n"); dev.off()
}
plot_coef <- function(tab, tag, titulo){
  tab <- tab[termo!="(Intercept)"]; if (!nrow(tab)) return(invisible())
  png(file.path(CONFIG$dir_plots,paste0("coef_",tag,".png")),900,max(420,42*nrow(tab)),res=110)
  par(mar=c(4,13,3,1)); y<-seq_len(nrow(tab)); lo<-tab$estimativa-1.96*tab$ep; hi<-tab$estimativa+1.96*tab$ep
  plot(tab$estimativa,y,xlim=range(c(lo,hi),na.rm=TRUE),yaxt="n",ylab="",xlab="coeficiente",main=titulo,pch=19)
  segments(lo,y,hi,y); abline(v=0,lty=2,col="grey50"); axis(2,at=y,labels=tab$termo,las=1,cex.axis=.7); dev.off()
}
plot_diag_votos <- function(dv, tag){
  if (is.null(dv$dharma) || is.null(dv$dharma$sim)) return(invisible())
  png(file.path(CONFIG$dir_plots,paste0("dharma_",tag,".png")),1000,520,res=110)
  plot(dv$dharma$sim); dev.off()
}
plot_roc <- function(ms, tag){
  png(file.path(CONFIG$dir_plots,paste0("roc_",tag,".png")),700,700,res=120)
  pROC::plot.roc(ms$dados$eleito, ms$prob, print.auc=TRUE, main=paste("ROC sucesso -",tag)); dev.off()
}

# --------------------- 10. INFERENCIA EXPLORATORIA (FDR) --------------------
exploratorio_fdr <- function(df,cargo,moderadores){
  r<-purrr::map_dfr(moderadores,function(md){
    if (!md %in% names(df) || all(is.na(df[[md]]))) return(NULL)
    f<-montar_formula(cargo,"total_votos",moderador=md,offset=grepl("VEREADOR",toupper(cargo)))
    m<-tryCatch(fit_nb(f,df),error=function(e) NULL); if(is.null(m)) return(NULL)
    s<-summary(m)$coefficients$cond; tm<-paste0("lp_impulsionamento:",md)
    if(!tm%in%rownames(s)) return(NULL)
    data.frame(moderador=md, estimativa=s[tm,1], ep=s[tm,2], p=s[tm,4]) })
  if(!is.null(r) && nrow(r)) r$p_bh<-p.adjust(r$p,"BH"); r
}

# --------------------------- 11. ORQUESTRADOR -------------------------------
# Roda um recorte (UF, ano, cargo) sobre uma amostra ja' preparada `dfv`
# (votos>0). Usado tanto no pooled quanto em cada estrato de porte.
rodar_recorte <- function(dfv, df_full, cargo, tag, moderadores=NULL, step=CONFIG$step_sat, com_formas=TRUE){
  mv  <- modelo_votos(dfv,cargo)
  ms  <- tryCatch(modelo_sucesso(df_full,cargo),error=function(e){message("  sucesso: ",e$message);NULL})
  sat <- saturacao(dfv,cargo,step=step,formas=com_formas)
  sat_comum <- tryCatch({
    sub <- dfv[impulsionamento>0]
    if (nrow(sub) >= 30) saturacao(sub,cargo,step=step,formas=com_formas) else NULL
  }, error=function(e){message("  sat_comum: ",e$message);NULL})
  res <- list(
    meta=list(tag=tag, cargo=cargo, n=nrow(dfv), n_candidatos=nrow(df_full), eleitos=sum(df_full$eleito)),
    votos=mv, sucesso=ms,
    share=tryCatch(modelo_share(dfv,cargo),error=function(e){message("  share: ",e$message);NULL}),
    elasticidade_usuarios=elasticidade_usuarios(dfv,cargo),
    margem3b=tryCatch(modelo_margem_3b(dfv,cargo),error=function(e){message("  3B: ",e$message);NULL}),
    diag_votos=diag_votos(mv),
    diag_sucesso=if(!is.null(ms)) diag_sucesso(ms) else NULL,
    oster=oster_todas(dfv,cargo),
    saturacao=sat, saturacao_comum=sat_comum,
    fdr=if(!is.null(moderadores)) exploratorio_fdr(dfv,cargo,moderadores) else NULL)
  # graficos
  tryCatch(plot_saturacao(sat,tag),error=function(e) message("  plot sat: ",e$message))
  tryCatch(plot_coef(mv$coef,paste0("votos_",tag),paste("NB votos -",tag)),error=function(e) NULL)
  if(!is.null(ms)) tryCatch(plot_coef(ms$coef,paste0("sucesso_",tag),paste("Firth sucesso -",tag)),error=function(e) NULL)
  tryCatch(plot_diag_votos(res$diag_votos,tag),error=function(e) NULL)
  if(!is.null(ms)) tryCatch(plot_roc(ms,tag),error=function(e) NULL)
  res
}

rodar_analise <- function(uf,ano,cargo,moderadores=NULL,step_saturacao=CONFIG$step_sat){
  message(sprintf("\n=== %s | %s | %s ===", uf,ano,cargo))
  df  <- preparar_base(uf,ano,cargo)
  ehver <- grepl("VEREADOR", toupper(cargo))
  dfv <- df[total_votos>0]
  if (ehver) dfv <- dfv[!is.na(eleitorado)]   # offset exige eleitorado
  message(sprintf("  candidatos=%d  amostra_votos(>0)=%d  eleitos=%d", nrow(df), nrow(dfv), sum(df$eleito)))

  tag_base <- sprintf("%s_%s_%s",uf,ano,gsub(" ","_",cargo))
  saidas <- list()

  if (!ehver) {
    res <- rodar_recorte(dfv, df, cargo, tag_base, moderadores=moderadores, step=step_saturacao)
    salvar_saida(res, uf, ano, cargo, tag_base)
    saidas[[tag_base]] <- res
  } else {
    # POOLED (com offset, moderadores + FDR, saturacao geral)
    res_pool <- rodar_recorte(dfv, df, cargo, paste0(tag_base,"_POOL"), moderadores=moderadores, step=step_saturacao)
    salvar_saida(res_pool, uf, ano, cargo, paste0(tag_base,"_POOL"))
    saidas[[paste0(tag_base,"_POOL")]] <- res_pool
    # POR PORTE (votos, share, sucesso, saturacao) - estratos com N suficiente
    for (pt in levels(df$porte)){
      dpt  <- df[porte==pt]; dvpt <- dpt[total_votos>0 & !is.na(eleitorado)]
      if (nrow(dvpt) < 50 || sum(dpt$eleito)<3){ message(sprintf("  porte %s: N insuficiente (votos=%d, eleitos=%d) - pulado", pt, nrow(dvpt), sum(dpt$eleito))); next }
      tagp <- sprintf("%s_PORTE_%s", tag_base, pt)
      message(sprintf("  --- porte %s: votos=%d eleitos=%d ---", pt, nrow(dvpt), sum(dpt$eleito)))
      resp <- rodar_recorte(dvpt, dpt, cargo, tagp, moderadores=NULL, step=step_saturacao, com_formas=TRUE)
      salvar_saida(resp, uf, ano, cargo, tagp)
      saidas[[tagp]] <- resp
    }
  }
  invisible(saidas)
}

salvar_saida <- function(res,uf,ano,cargo,tag){
  W<-function(x,nm) if(!is.null(x)) data.table::fwrite(cbind(uf,ano,cargo,tag,as.data.table(x)),
                       file.path(CONFIG$dir_saida,paste0(nm,"_",tag,".csv")))
  W(res$votos$coef,"coef_votos")
  W(res$votos$coef_hc3,"coef_votos_hc3")
  W(res$votos$coef_cluster_mun,"coef_votos_clustermun")
  if(!is.null(res$sucesso)) W(res$sucesso$coef,"coef_sucesso")
  if(!is.null(res$share)) W(res$share$coef,"coef_share")
  if(!is.null(res$margem3b)) W(res$margem3b$coef,"coef_m3b")
  W(res$elasticidade_usuarios,"elasticidade_usuarios")
  W(res$saturacao$tabela,"saturacao")
  if(!is.null(res$saturacao$formas_teto)) W(res$saturacao$formas_teto,"saturacao_formas_teto")
  if(!is.null(res$saturacao_comum)){ W(res$saturacao_comum$tabela,"saturacao_popcomum")
    if(!is.null(res$saturacao_comum$formas_teto)) W(res$saturacao_comum$formas_teto,"saturacao_popcomum_formas") }
  W(res$oster,"oster")
  if(!is.null(res$fdr)) W(res$fdr,"fdr")
  dv<-res$diag_votos
  W(data.table(aic=dv$aic, theta=dv$theta, pseudo_r2=dv$pseudo_r2,
               disp_p=if(!is.null(dv$dharma)) dv$dharma$dispersao else NA,
               zeros_p=if(!is.null(dv$dharma)) dv$dharma$zeros else NA,
               unif_p=if(!is.null(dv$dharma)) dv$dharma$uniforme else NA),"diag_votos")
  if(!is.null(res$diag_sucesso)) W(as.data.table(res$diag_sucesso),"diag_sucesso")
  saveRDS(res, file.path(CONFIG$dir_saida,paste0("full_",tag,".rds")))
  message("  saida: ",tag)
}

# ------------------------------- 12. USO ------------------------------------
# source("01_tratamento.R"); tratar("PR",2022,"DEPUTADO FEDERAL")  # gera o painel
# source("modelo_impulsionamento.R")
# rodar_analise("PR", 2022, "DEPUTADO FEDERAL")
# moder <- c("densidade","penetracao_internet","idhm","gini")   # so' vereador
# rodar_analise("PR", 2024, "VEREADOR", moderadores=moder)
# Precisao maxima na saturacao: rodar_analise("PR",2022,"DEPUTADO FEDERAL", step_saturacao=1)
# =============================================================================
