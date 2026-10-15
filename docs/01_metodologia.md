# Metodologia

Pipeline completo, do dado bruto do TSE ao resultado, para deputado (federal e estadual) e vereador no Paraná. Este documento descreve o desenho, a especificação econométrica e os principais resultados no nível de detalhe necessário para auditar e reproduzir. O tratamento dos dados está em [02_etl_tratamento.md](02_etl_tratamento.md); a transcrição dos coeficientes, recorte a recorte, em [`resultados/RELATORIO_RESULTADOS.md`](../resultados/RELATORIO_RESULTADOS.md).

- **Escopo:** Paraná. Deputado federal e estadual (2018, 2022); vereador (2020, 2024).
- **Arquitetura:** o tratamento (`R/pipeline/01_tratamento.R`) lê o bruto, valida e grava os painéis; a estimação e os relatórios (`R/pipeline/02` a `08`) leem esses painéis. O pipeline inteiro roda com `Rscript R/pipeline/run_all.R`.

## 1. Pergunta e desenho

Estima-se o efeito do gasto declarado com **impulsionamento digital** sobre (i) o volume de votos nominais e (ii) a probabilidade de eleição, em comparação com o gasto em publicidade tradicional e com o gasto operacional. A unidade é o candidato; o corte é transversal por eleição. A interpretação é de **associação condicional**: o capital político do candidato (reeleição e votação em pleitos anteriores) entra como controle, mas não há desenho de identificação causal.

## 2. Tratamento (resumo)

Por recorte (UF, ano, cargo): filtro de cargo na origem; uma linha por candidato; classificação da rubrica oficial da despesa em impulsionamento, tradicional, operacional, transferência (removida) e residual (`#NULO`, "diversas"; fora dos regressores); soma por candidato e classe, sem deduplicar `SQ_DESPESA`; deflação por IPCA até a base do escopo; travas de teto legal, fan-out, sinal e fator de deflação. O detalhe está no documento de ETL.

**Sensibilidade à classificação.** Ao reajustar o modelo de votos *adicionando* o residual como regressor (margem extensiva e dose), o efeito combinado de cada categoria se desloca no máximo 0,086 na escala log (deputado estadual 2022, tradicional), com mediana de deslocamento em torno de 0,02 (`resultados/tabelas/pipeline/sensibilidade_classificacao.csv`). Manter o residual fora dos regressores quase não altera as três categorias de interesse.

## 3. Eleitorado e porte

O eleitorado apto municipal (`QT_APTOS`, vereador, 1º turno, somado por município) entra no modelo do vereador como covariável livre `log(apto)`, com coeficiente estimado entre 0,18 e 0,35, sempre rejeitando 1: o voto não escala proporcionalmente ao eleitorado, e `log(apto)` ajusta o tamanho do município sem impor a escala 1. O vereador é modelado por **porte**, em faixas de eleitorado apto:

| Porte | Faixa |
|---|---|
| PEQUENO | até 15 mil |
| MÉDIO | 15 a 75 mil |
| GRANDE | 75 a 750 mil |
| METRÓPOLE | acima de 750 mil (Curitiba, um único município) |

Na metrópole o eleitorado não varia, então `log(apto)` cai do modelo.

## 4. Modelo de votos

Há um **único modelo de votos**: binomial negativa tipo 2 (NB2, `glmmTMB`) para `total_votos`. Cada categoria de gasto entra em duas partes (modelo de barreira, *hurdle*):

- a **margem extensiva** (`usou_<categoria>`: indicador de gasto positivo), que mede a decisão de adotar a ferramenta;
- a **dose intensiva** (`lg_<categoria>`: log do gasto entre quem gastou), que mede a elasticidade entre usuários.

Somam-se o capital político, os controles individuais (sexo, instrução superior, cor, ideologia do partido) e, no vereador, `log(apto)`. Deputado: um modelo por recorte, sem estratos. Vereador: um modelo por porte. Termos constantes na coorte caem do modelo e ficam registrados.

Para cada modelo são reportados os coeficientes completos, o VIF por termo e o **efeito combinado** por categoria. O VIF é baixo entre categorias e controles e só é alto entre as duas margens da mesma categoria, o que é esperado; por isso a leitura é feita pelo efeito combinado, não por coeficiente isolado.

**Efeito combinado** = fator multiplicativo de votos de um usuário contra um não usuário, avaliado em um **gasto de referência único** por cenário: a mediana do gasto positivo, agrupando as três categorias entre quem gastou, aplicada igual às três (na moeda da base do escopo). No mesmo dinheiro, os fatores das três categorias ficam comparáveis.

**Efeito conjunto de incumbência.** A reeleição e a votação anterior do mesmo cargo são colineares (todo incumbente tem votação anterior positiva); por isso a leitura correta é o fator `exp(b_reeleicao + b_lvotos · l_típico)`, com `l_típico` a mediana da votação anterior entre os incumbentes, contra um desafiante sem histórico, com erro-padrão por *delta method*.

**Comparação com a especificação da monografia.** A especificação original (NB2 com `log1p` do gasto único por categoria, sem barreira, e capital político só pela dummy de reeleição) é reajustada nos *mesmos* painéis e na mesma amostra de cada recorte, para a comparação ser de especificação e não de dado. O AIC do modelo atual é menor em **12 dos 12** recortes (`resultados/tabelas/pipeline/comparacao_monografia_resumo.csv`).

## 5. Saturação e curvas comparativas

Tudo deriva do modelo de votos, e a leitura é **comparativa entre as três categorias**. Para cada categoria, a curva vem da margem intensiva, num perfil de referência (usuário da categoria, demais variáveis na média do recorte). Entre usuários,

```
votos(g) = exp(η_ref + b · log g) = K · g^b          (K = exp(η_ref))
custo marginal por voto = g^(1-b) / (K · b)
ponto de saturação prática g* = (K · b · L)^(1 / (1-b))
```

em que `L` é o limiar de custo por voto: a **média** dos custos individuais (gasto total dividido pelos votos), calculada entre os eleitos e no conjunto geral. A fórmula fechada substitui uma busca em malha que superestimava o ponto em até um passo da malha; a malha é usada apenas para traçar as curvas. A saturação **não é reportada** quando a dose intensiva da categoria não é distinta de zero a 5%, porque `g*` colapsa quando `b` tende a zero (é o caso do impulsionamento de vereador pequeno e médio em 2020, com p = 0,379 e 0,847). Quando `g*` fica acima do quantil 99% do gasto observado, as colunas `sat_*_na_faixa` marcam que o cruzamento é extrapolação.

Nota para contrastes entre anos: o ponto de saturação depende do nível `K` do perfil de referência do próprio ano. No federal, `K` cai de 2018 para 2022 (mais candidatos dividindo praticamente os mesmos votos) e, por isso, a saturação de 2022 é menor mesmo com dose e limiar maiores.

## 6. Moderadores (vereador, por porte)

Para cada moderador (densidade demográfica e penetração de internet; IDHM e Gini, exploratórios) testa-se a interação com a dose de cada um dos três gastos. Reporta-se, por interação, o coeficiente, o erro-padrão, o p, o teste de razão de verossimilhança e o ΔAIC. A maioria das interações não é significativa dentro do porte e os sinais variam; das 72 interações estimadas, 21 têm p < 0,05. O contexto fica lido no gradiente entre portes, e não nas interações dentro de cada porte.

## 7. Probabilidade de eleição

Logit de **Firth** (penalizado, robusto a evento raro e a separação) de `eleito`, com os mesmos blocos do modelo de votos e a **força de lista** (votos dos demais candidatos da legenda no mesmo recorte, leave-one-out). A posição na lista e os votos próprios ficam de fora de propósito: em lista aberta, eleger-se é função mecânica dos próprios votos, e incluí-los transformaria o modelo na regra de apuração.

## 8. Resultados principais

**Efeito combinado do impulsionamento** (fator de votos de um usuário contra um não usuário, no gasto de referência de cada cenário):

| Recorte | 2018 / 2020 | 2022 / 2024 |
|---|---:|---:|
| Deputado federal | 2,09 | 2,66 |
| Deputado estadual | 1,78 | 2,30 |
| Vereador, porte pequeno | 1,22 | 1,43 |
| Vereador, porte médio | 1,33 | 1,50 |
| Vereador, porte grande | 1,67 | 1,64 |
| Vereador, metrópole | 1,94 | 2,55 |

Em 2022 o impulsionamento passa a ter o maior fator das três categorias no deputado federal (impulsionamento 2,66; tradicional 1,98; operacional 1,52); em 2018 o tradicional era o maior (2,95 contra 2,09). No vereador, o efeito do impulsionamento **cresce com o porte do município** nos dois ciclos, e na metrópole de 2024 ultrapassa o tradicional (2,55 contra 2,37). Ressalva importante, de [04_diagnosticos](04_diagnosticos_dos_modelos_do_tcc.md): esse gradiente é bem estabelecido em 2024 e frágil em 2020.

**Elasticidade do eleitorado (vereador),** `log(apto)`:

| Porte | 2020 | 2024 |
|---|---:|---:|
| Pequeno | 0,24 | 0,27 |
| Médio | 0,31 | 0,35 |
| Grande | 0,24 | 0,18 |

**Custo por voto** (média dos custos individuais, R$ da base do escopo):

| Recorte | Eleitos | Geral |
|---|---:|---:|
| Deputado federal 2018 | 16,40 | 25,18 |
| Deputado federal 2022 | 22,39 | 77,21 |
| Deputado estadual 2018 | 9,02 | 30,34 |
| Deputado estadual 2022 | 9,85 | 52,49 |
| Vereador 2020, pequeno / médio / grande / metrópole | 9,09 / 9,32 / 14,58 / 21,06 | 45,56 / 41,95 / 46,35 / 46,04 |
| Vereador 2024, pequeno / médio / grande / metrópole | 13,07 / 12,09 / 16,07 / 26,88 | 80,01 / 65,12 / 58,29 / 64,84 |

Os pontos de saturação por categoria estão em `resultados/tabelas/pipeline/saturacao_resumo.csv`. No impulsionamento, crescem com o porte do vereador; no federal, o ponto de 2022 (R$ 17,4 mil, limiar dos eleitos) fica abaixo do de 2018 (R$ 22,4 mil) porque o nível de votos do perfil de referência caiu entre os anos.

**AUC do logit de eleição** (Firth): deputado federal 0,983 (2018) e 0,995 (2022); deputado estadual 0,967 e 0,980; vereador cresce com o porte, de 0,82 (pequeno) a 0,98 (metrópole 2020). A AUC próxima de 1 nos deputados reflete o peso da força de lista e a escassez de eventos; ver a análise de estabilidade nos diagnósticos.

## 9. Reprodutibilidade

- R 4.6.0; versões dos pacotes travadas em `R/renv.lock`.
- Semente fixa `set.seed(20260629)` no pipeline.
- Execução: `Rscript R/pipeline/run_all.R` (ver o README do repositório). O orquestrador executa os scripts 00 a 08 com `echo=TRUE`, de modo que a transcrição registra comando e saída, e grava um `MANIFEST.md` com o md5 de cada arquivo gerado.
- **Determinismo verificado:** o pipeline foi executado duas vezes, do zero, e os arquivos de `dados_tratados/` (18), `saidas/` (89) e `figuras/` (24) batem por md5 nas duas execuções, sem nenhuma diferença.
