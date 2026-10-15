# Diagnóstico dos 12 modelos da monografia

Os modelos originais da monografia foram reconstruídos a partir dos microdados brutos do TSE, reestimados nos **12 recortes** (deputado federal e estadual em 2018 e 2022; vereador em 2020 e 2024, separado por porte de município) e submetidos a uma bateria de testes de especificação: 16 blocos de diagnóstico, com mais de 40 estatísticas, aplicados a cada modelo de contagem e a cada logit. O objetivo não foi "refutar", e sim saber **o que se pode afirmar com a precisão que os dados permitem**.

Código: `R/diagnosticos/` (executado por `Rscript R/diagnosticos/run_all.R`). Tabelas: `resultados/tabelas/diagnosticos/`. Figuras: `resultados/figuras/diag_*.png` e `resumo_*.png`.

## 1. A reprodução é exata onde pôde ser verificada

- Os tamanhos de amostra coincidem com os da monografia: 450, 632, 767 e 902 candidatos nos deputados; 16.719, 8.206, 5.113 e 735 vereadores em 2024. (Os tamanhos do vereador em 2020 não estavam registrados e não têm referência.)
- Para deputado federal 2018, os dez coeficientes da binomial negativa, o parâmetro de dispersão (0,534), o VIF máximo (3,83), a AUC do logit (0,9739), a estatística de Hosmer-Lemeshow (2,1884) e a razão de verossimilhança conjunta dos gastos (66,616) coincidem com os valores impressos no código original. Para 2022, a AUC (0,9935), a estatística de Hosmer-Lemeshow (0,1416) e a razão de verossimilhança (92,034) também coincidem.
- O único item que não reproduz é o vetor de gasto de 2022: o TSE republicou a prestação de contas desse ano depois da defesa. A diferença agregada é de cerca de R$ 0,3 milhão em um total de R$ 160 milhões, e desloca a elasticidade do impulsionamento de 0,1569 para 0,1619, sem alterar sinal, significância ou conclusão.

## 2. Quadro de vereditos

| Item avaliado | Veredito | Evidência |
|---|---|---|
| Escolha de família sobredispersa | Aprovado | Razão de dispersão de Pearson sob Poisson de 83 a 1,4 milhão; Poisson rejeitado em 12 de 12 (LR, p < 0,001) |
| Multicolinearidade | Aprovado | VIF máximo 3,83 (VIF do impulsionamento nunca passa de 1,89); número de condição máximo 3,52 |
| Significância conjunta dos gastos (logit) | Aprovado | LR de 34,6 a 530,4 (3 gl), p < 0,001 em 12 de 12 |
| Discriminação do logit | Aprovado | AUC de 0,754 a 0,994; na validação por 10 partições, de 0,752 a 0,989 |
| Robustez do coeficiente do impulsionamento | Aprovado | Estável entre NB2, ZINB e *hurdle* (diferenças na terceira casa decimal); significativo sob HC3 e sob erro agrupado |
| Gradiente por porte em 2024 | Aprovado | Sobrevive ao teste de interação, à separação das margens (p = 0,0001) e ao efeito municipal |
| Excesso de zeros | Ressalva | ZINB ou *hurdle* vencem o AIC em 9 de 12 recortes; até 5,8 vezes mais zeros que o previsto |
| **Forma funcional (elasticidade constante)** | **Ressalva** | **Termos quadráticos dos três gastos rejeitam em 12 de 12 (LR de 42 a 237, 3 gl, p < 10⁻⁸)**; Box-Tidwell rejeita em 9 de 12 logits |
| Função de variância | Ressalva | Breusch-Pagan rejeita em 6 de 12 (todos de vereador); dispersão residual simulada abaixo de 1 em todos |
| Calibração do logit | Ressalva | Hosmer-Lemeshow (10 grupos) rejeita em 4 de 12; o z de Spiegelhalter não rejeita em nenhum |
| Gradiente por porte em 2020 | Ressalva | Passa no teste ingênuo por pouco (p = 0,027) e desaparece ao separar as margens (p = 0,499) |
| Observações influentes | Ressalva | Distância de Cook acima de 1 em três recortes de deputado (4,79; 1,71; 1,68); a elasticidade se move até 52% ao excluir o 1% mais influente |
| **Suporte da variável de interesse** | **Reprovado** | Impulsionamento é zero para 46% a 99% dos candidatos; o coeficiente único confunde adoção com intensidade |
| **Independência das observações** | **Reprovado** | LR do intercepto municipal de 94,8 a 819,8; a elasticidade cai de 6% a 43% |
| **Eventos por variável no logit** | **Reprovado** | 3,0 no deputado federal, 3,8 nas metrópoles e 5,4 no estadual, contra o mínimo usual de 10 |
| Classificação de despesas em 2024 | Reprovado | Erro de grafia no mapa de rubricas descartou R$ 30,6 milhões; efeito nas estimativas de até 2,1% |
| Endogeneidade do gasto | Limite de desenho | Sem estratégia de identificação; gasto e votos são simultâneos |

## 3. Achados principais

### 3.1 A forma funcional é rejeitada nos 12 recortes

A especificação `log1p` impõe elasticidade constante. O teste conjunto de termos quadráticos nos três logaritmos de gasto rejeita em todos os 12 modelos de contagem (estatísticas LR entre 42 e 237 para 3 graus de liberdade). A leitura correta não é que o modelo esteja errado, e sim que **a elasticidade não é constante ao longo da faixa de gasto**, o que é especialmente relevante para o cálculo de saturação e de custo marginal por voto. Essa é a motivação do modelo de elasticidade variável em [06_modelo_de_elasticidade_variavel.md](06_modelo_de_elasticidade_variavel.md).

### 3.2 O coeficiente do impulsionamento mistura adoção e intensidade

Em quase todos os recortes, o gasto com impulsionamento é zero para a maioria dos candidatos. Como `log1p(0) = 0`, o regressor é, nesses casos, quase um indicador de adoção estimado sobre uma fração pequena da amostra: no vereador de 2020 em município pequeno, o coeficiente é estimado com 179 usuários entre 17.253 candidatos (taxa de adoção de 1,04%). Ao separar as duas margens, elas têm sinais opostos: em deputado federal 2022, o coeficiente único de 0,162 se decompõe em **−2,41 na adoção e +0,398 na intensidade**, com ganho de AIC de 55 pontos. A decomposição melhora o AIC em 9 dos 12 recortes (em 7 deles, por mais de 2 pontos). O sinal negativo da margem extensiva não deve ser lido como "usar impulsionamento reduz votos": é o preço que a função `log1p` paga por atravessar uma massa de pontos em zero com uma única curva.

### 3.3 Candidatos do mesmo município não são observações independentes

O teste de razão de verossimilhança de um intercepto aleatório por município rejeita a independência nos seis recortes de vereador testáveis (as metrópoles têm um único município). Ao acomodar o agrupamento, a elasticidade do impulsionamento **cai 43% no vereador 2020 pequeno** (0,053 para 0,030), 25% no 2020 médio e 22% no 2024 pequeno; nos portes grandes, que agregam só 21 municípios, a queda é de 6% a 10%. Parte do que o modelo original atribui ao impulsionamento é diferença entre municípios, não entre candidatos.

Quanto à inferência: o efeito de desenho aproximado vai de 5,8 a 14,3 (correlação intraclasse de 0,035 a 0,113), o que implicaria erros-padrão subestimados por um fator de 2,4 a 3,8 para quantidades de nível municipal; para um regressor que varia dentro do município, como o gasto do candidato, esse é um limite superior. O erro-padrão agrupado estimado de fato fica entre 0,76 e 1,56 vez o erro de máxima verossimilhança (maior no vereador 2024 grande, 0,0079 contra 0,0051). A significância do impulsionamento sobrevive a todas as correções nos 12 recortes, mas **corrigir o erro-padrão não corrige o viés do ponto estimado** causado pela heterogeneidade municipal não modelada.

### 3.4 O logit de deputado federal é instável por escassez de eventos

A triagem automática de separação (probabilidade ajustada abaixo de 10⁻⁶ ou acima de 1 − 10⁻⁶, ou erro-padrão acima de 10) acusou quatro recortes: deputado federal 2018 e 2022, deputado estadual 2022 e vereador 2020 metrópole. A inspeção direta dos ajustes afastou o diagnóstico de separação: todos convergem em 9 a 12 iterações, as probabilidades de eleitos e não eleitos se sobrepõem amplamente e a AUC não desaba fora da amostra. O problema real é o **viés de amostra pequena**: apenas 30 eleitos para 10 parâmetros (3,0 eventos por variável). Em 500 reamostras *bootstrap*, o coeficiente do impulsionamento no logit de 2022 varia de −0,28 a +13,06 (3,2% das reamostras produzem estimativas absurdas, com módulo acima de 5), e a correção de Firth o corta de 0,375 para 0,182 (−51,6%). Nos demais recortes, a correção move o coeficiente entre 8% e 10%. A conclusão prática: os logits de deputado federal servem para avaliar o efeito conjunto dos gastos e o poder discriminante, **não para interpretar coeficientes individuais**.

### 3.5 Um erro de rubrica foi encontrado, e seu efeito é pequeno

O mapa de categorias de despesa de 2024 do código original grafava "Produção de programas de rádio, **television** ou vídeo", com "television" no lugar de "televisão". A rubrica correta existe nos microdados com 4.089 lançamentos e R$ 30,6 milhões (todos os cargos do arquivo do Paraná), que **foram descartados silenciosamente** em vez de entrar em publicidade tradicional. A parcela dos vereadores que entram nos modelos é de R$ 3,03 milhões, concentrada em 152 candidatos com gasto tradicional indevidamente zerado. Reestimando com o mapa corrigido, o coeficiente do impulsionamento se move no máximo 2,1% (de 0,0729 para 0,0713, no porte médio), e o AIC melhora em 30 pontos no porte pequeno. É um erro objetivo, que deve ser corrigido, e é quase inócuo para as conclusões.

| Mapa | Porte | Impulsionamento | Tradicional | Operacional |
|---|---|---:|---:|---:|
| original | pequeno | 0,0698 | 0,0739 | 0,0180 |
| original | médio | 0,0729 | 0,0854 | 0,0442 |
| original | grande | 0,0720 | 0,1110 | 0,0471 |
| original | metrópole | 0,1366 | 0,0965 | 0,0308 |
| corrigido (grafia e rubricas faltantes) | pequeno | 0,0691 | 0,0749 | 0,0169 |
| corrigido | médio | 0,0713 | 0,0857 | 0,0438 |
| corrigido | grande | 0,0719 | 0,1099 | 0,0473 |
| corrigido | metrópole | 0,1368 | 0,0936 | 0,0316 |

## 4. O achado central, testado formalmente

A monografia conclui que a elasticidade do impulsionamento **cresce com o porte do município**. Na monografia, essa conclusão vem da comparação visual entre quatro modelos estimados separadamente. O teste correto estima um modelo único com interação entre porte e gasto.

| Ciclo | LR da interação (3 gl) | p | Elasticidades implícitas (pequeno, médio, grande, metrópole) |
|---|---:|---:|---|
| 2020 | 9,16 | 0,027 | 0,052; 0,066; 0,085; 0,096 |
| 2024 | 36,98 | < 0,001 | 0,063; 0,080; 0,086; 0,130 |

Mas a taxa de adoção cresce com o porte exatamente na mesma direção (de 1,0% no pequeno a 29,0% na metrópole em 2020; de 1,8% a 47,1% em 2024), então há risco de o gradiente ser reflexo da diferença de adoção. Deixando as duas margens variarem livremente por porte:

| Ciclo | LR conjunto (6 gl) | p | p só extensiva | p só intensiva |
|---|---:|---:|---:|---:|
| 2020 | 5,36 | 0,499 | 0,507 | 0,391 |
| 2024 | 28,81 | 0,0001 | 0,275 | 0,039 |

**Veredito sobre o achado central.** O gradiente de **2024 é sólido**: resiste ao teste de interação, à separação das margens e ao controle da heterogeneidade municipal (com intercepto por município, as elasticidades de pequeno, médio e grande passam a 0,054, 0,063 e 0,067, e a razão entre grande e pequeno sobe de 1,03 para 1,24). Entre os usuários de 2024, a elasticidade da margem intensiva é de 0,107 (pequeno), 0,121 (médio), 0,189 (grande) e 0,290 (metrópole). O gradiente de **2020 é frágil**: passa no teste ingênuo por pouco (ganho de AIC de apenas 3,2 pontos) e não sobrevive à separação das margens; o que parecia gradiente era, em boa medida, diferença de taxa de adoção entre portes. A formulação defensável é que o retorno do impulsionamento cresce com o porte do município no ciclo de 2024, quando a ferramenta já estava difundida, e que em 2020 a evidência é insuficiente com a especificação original.

## 5. O que muda quando se corrige, em ordem de efeito

1. **Suporte e agrupamento municipal** são os dois problemas de maior consequência: deslocam o ponto estimado e, juntos, determinam se o gradiente de 2020 existe.
2. **Instabilidade do logit de deputado federal:** grave em um único recorte (2022), onde o coeficiente cai pela metade sob Firth. Não deve ser generalizada em bloco: o vereador 2024 metrópole tem 3,8 eventos por variável e um coeficiente praticamente invariante a Firth (0,687 para 0,646).
3. **Erro de grafia de 2024:** objetivo, mas quase inócuo (deslocamento máximo de 2,1%).
4. **Forma funcional:** apresentar saturação e custo marginal com faixa de incerteza, ou adotar forma flexível (termo quadrático ou *spline*) na parte de gasto.
5. **Excesso de zeros:** reportar o ZINB como verificação de robustez ao lado do modelo principal.

**O que não precisa mudar:** a escolha de uma família sobredispersa, o conjunto de controles, a separação por porte de município e a estratégia de comparar impulsionamento com publicidade tradicional e operacional resistem a todos os testes. O poder discriminante dos logits é real e sobrevive à validação fora da amostra. As críticas são de precisão e de honestidade inferencial; uma única, o gradiente de 2020, recomenda recuo em uma afirmação substantiva.

**Endogeneidade.** Nenhum teste da bateria resolve a simultaneidade entre gasto e votos: candidatos com melhores perspectivas arrecadam e gastam mais. As elasticidades são associações condicionais, não efeitos causais, e os cálculos de custo por voto e de saturação são descritivos.

## 6. Dois cuidados de leitura

- O teste de razão de verossimilhança conjunta dos gastos (item "significância conjunta") é sobre o **bloco** das três categorias, não sobre o impulsionamento isolado. Individualmente, no logit de máxima verossimilhança o coeficiente do impulsionamento só é significativo a 5% nos quatro recortes de vereador de 2024 (em 2020, o porte médio e a metrópole ficam em p ≈ 0,05 a 0,06); nos deputados, o p fica entre 0,10 e 0,50 (entre 0,09 e 0,49 sob Firth).
- A AUC corrigida por *bootstrap* (otimismo de Harrell, 200 reamostragens) subestima a queda observada na validação por partições em 11 dos 12 recortes; ao reportar, prefira a AUC de 10 partições.

## 7. Reprodutibilidade

A bateria é determinística (semente `20260809` para simulações, validação cruzada e *bootstrap*). Ambiente: R 4.6.0 com `glmmTMB`, `MASS`, `DHARMa`, `performance`, `pROC`, `ResourceSelection`, `pscl`, `logistf`, `sandwich`, `lmtest`, `car` e `AER`. Fontes: Repositório de Dados Eleitorais do TSE (consulta_cand, consulta_cand_complementar, despesas_contratadas_candidatos e votacao_candidato_munzona, 2018, 2020, 2022 e 2024, recorte Paraná) e IBGE, Censo Demográfico 2022, tabela SIDRA 4714 (população municipal, para a classificação de porte).
