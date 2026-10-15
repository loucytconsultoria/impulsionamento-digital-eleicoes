# Modelo de elasticidade variável: transformar um orçamento de mídia numa faixa de resultado esperado

O diagnóstico dos modelos da monografia ([04](04_diagnosticos_dos_modelos_do_tcc.md)) mostrou que a elasticidade constante imposta pelo `log1p` é rejeitada nos 12 recortes. Este módulo, em Python, responde à pergunta que o planejamento de orçamento realmente faz: **dado um valor a investir em impulsionamento, qual a faixa de votos esperada, com que incerteza, e quão confiável é essa conta?**

Código: `python/modelo_elasticidade/`. Resultados (deputado federal, Paraná, 2018 e 2022): `resultados/tabelas/modelo_elasticidade/`.

## 1. Dados e amostra

| Item | Valor |
|---|---|
| Fonte | painéis tratados de deputado federal PR 2018 (450 candidatos) e 2022 (632), do pipeline em R |
| Deflação | já embutida nos painéis (base out/2022; fator 1,2555 em 2018). O script confere: razão `gasto_total / gasto_total_nominal` mediana de 1,2555 em 2018 e 1,0000 em 2022, e **para** se não for assim. Nenhuma deflação adicional é aplicada |
| Filtro | `deferido == 1` (nenhum removido: os painéis já vêm só com deferidos) |
| **Amostra do modelo** | **usuários de impulsionamento (gasto > 0): n = 515** (173 em 2018 e 342 em 2022); 7 deles com zero votos, mantidos (a NB2 acomoda contagem zero) |
| Capital político | 5 colunas `l_votos_*` (mesmo cargo, deputado estadual, prefeito na última e na penúltima, vereador), já em log |

Percentis do gasto de impulsionamento entre usuários (R$ de out/2022):

| Amostra | n | p10 | p25 | p50 | p75 | p90 | p95 | p99 | máx |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 2018 | 173 | 502 | 1.256 | 3.773 | 12.555 | 37.176 | 57.682 | 134.494 | 138.110 |
| 2022 | 342 | 700 | 2.275 | 9.000 | 27.659 | 79.280 | 131.131 | 337.973 | 708.000 |
| conjunto | 515 | 610 | 1.883 | 6.780 | 22.750 | 62.706 | 101.470 | 309.524 | 708.000 |

Os scripts descartam as colunas de identificação (nome, `sq`) antes de gravar qualquer base intermediária.

## 2. Especificações

Binomial negativa tipo 2 (NB2, α estimado) para `total_votos`, sempre com controles (`log1p` do gasto tradicional e do operacional, reeleição, sexo, instrução superior, cor, ideologia do partido e ano). A variante **com capital político** adiciona as cinco colunas `l_votos_*`. Três formas para o termo de impulsionamento:

- **(a)** log-linear: `l_imp` (elasticidade constante, comparável à pesquisa original);
- **(b)** quadrática: `l_imp + l_imp²` (elasticidade variável);
- **(c)** *spline*: `bs(l_imp, df=3)`.

**Estimação em dois estágios.** O MLE conjunto direto do `statsmodels` (`smf.negativebinomial`) degenerou em 4 das 6 especificações (α explosivo, verossimilhança absurda). A solução, em `02_modelos.py`: (i) perfil de verossimilhança de α via GLM binomial negativo (IRLS, estável), com α otimizado em [0,01; 10]; (ii) polimento final com o MLE conjunto NB2 partindo de (β do GLM, α do perfil). As 6 especificações convergiram no MLE conjunto polido, com matriz de covariância completa; nenhuma ficou no *fallback* para o GLM.

## 3. Seleção de modelo

| Modelo | k | log-verossimilhança | AIC | BIC | α |
|---|---:|---:|---:|---:|---:|
| (a) log-linear, com capital | 17 | −5.035,81 | 10.105,62 | 10.177,77 | 1,067 |
| **(b) quadrática, com capital** | **18** | **−5.022,13** | **10.080,26** | **10.156,65** | **1,023** |
| (c) *spline*, com capital | 19 | −5.022,07 | 10.082,14 | 10.162,78 | 1,023 |
| (a) log-linear, sem capital | 12 | −5.051,54 | 10.127,07 | 10.178,00 | 1,120 |
| (b) quadrática, sem capital | 13 | −5.040,24 | 10.106,48 | 10.161,65 | 1,082 |
| (c) *spline*, sem capital | 14 | −5.040,23 | 10.108,46 | 10.167,88 | 1,082 |

Razão de verossimilhança **(a) contra (b): LR = 27,36, 1 gl, p < 0,001** (sem capital político: 22,59). O *spline* não melhora sobre a quadrática (Δ log-verossimilhança de 0,06 por um parâmetro a mais) e apenas confirma a forma. A **elasticidade constante é rejeitada**; a quadrática com capital político é a especificação vencedora (melhor AIC e BIC).

Coeficientes da vencedora (completos em `02_coeficientes.csv`):

| Parâmetro | Coeficiente | EP | p |
|---|---:|---:|---:|
| `l_imp` | −0,4219 | 0,1644 | 0,010 |
| `l_imp²` | 0,0463 | 0,0096 | < 0,001 |
| `l_trad` | 0,1011 | 0,0199 | < 0,001 |
| `l_oper` | 0,1034 | 0,0184 | < 0,001 |
| reeleição | 0,4739 | 0,2782 | 0,089 |
| masculino | 0,5823 | 0,1041 | < 0,001 |
| superior completo | 0,3829 | 0,1089 | < 0,001 |
| ano 2022 | −1,0409 | 0,1027 | < 0,001 |
| α (dispersão NB2) | 1,0231 | 0,0570 | < 0,001 |

## 4. Elasticidade local b(g)

A elasticidade de votos ao gasto passa a depender do nível de gasto: `b(g) = β₁ + 2·β₂·log(g)`, com intervalo de 95% por *delta method* (variância `V₁₁ + 4L·V₁₂ + 4L²·V₂₂`, com `L = log g`). Na vencedora:

| Ponto | g (R$ de out/2022) | b(g) | IC 95% | Usuários com gasto ≥ g |
|---|---:|---:|---|---:|
| p10 | 610 | 0,172 | [0,077; 0,266] | 463 |
| p25 | 1.883 | 0,276 | [0,212; 0,340] | 390 |
| p50 | 6.780 | 0,395 | [0,339; 0,450] | 258 |
| p75 | 22.750 | 0,507 | [0,427; 0,586] | 129 |
| p90 | 62.706 | 0,600 | [0,490; 0,711] | 52 |
| p99 | 309.524 | 0,748 | [0,583; 0,913] | 6 |
| orçamento de 100 mil | 100.000 | 0,644 | [0,518; 0,769] | 29 |
| orçamento de 250 mil | 250.000 | 0,728 | [0,571; 0,886] | 9 |

A elasticidade é **crescente no nível de gasto** (β₂ > 0): retorno percentual baixo nos gastos pequenos (cerca de 0,17 no p10), de 0,40 na mediana e de 0,73 no p99. A *spline* reproduz a mesma forma, o que valida a quadrática como resumo.

**Referência de comparação.** No ponto R$ 7.136,63 (a mediana de 2022 de R$ 9.000 expressa em preços de 2018, com o deflator 1,2611 do código original da monografia), `b(g)` é de 0,399 [0,343; 0,455] na vencedora e fica entre 0,359 e 0,404 nas seis especificações, contra uma faixa de referência de 0,23 a 0,40 obtida em estimativas anteriores de coeficiente único (`03_validacao_referencia.csv`). A vencedora cai dentro da faixa raspando no teto (0,399); a quadrática sem capital político (0,404) fica logo fora. Com e sem capital político o resultado muda pouco (0,399 contra 0,404), o que indica que a colinearidade com o capital político *não* é o que sustenta a elasticidade nesta base.

## 5. Faixa de votos por orçamento

Para um **perfil de referência** (sem reeleição, sem capital político prévio, homem, superior completo, não branco, partido de centro, ano 2022, gasto tradicional e operacional nas medianas dos usuários: R$ 29.857 e R$ 28.145), converte-se cada orçamento em votos esperados por **bootstrap paramétrico** (2.000 réplicas, semente 2026): (β, α) é sorteado de uma normal multivariada com a covariância do MLE. A "faixa da média" mede a incerteza sobre E[votos]; a "faixa preditiva" soma o ruído NB2 individual (α ≈ 1,02, ou seja, enorme dispersão entre candidatos iguais no observável).

| Orçamento | E[votos], P10 | **P50** | P90 | Preditiva P10 | Preditiva P50 | Preditiva P90 | Custo médio (R$/voto) | Custo marginal no topo (R$/voto) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| R$ 50 mil | 7.452 | **9.134** | 11.254 | 922 | 6.394 | 21.609 | 5,47 | 9,45 |
| R$ 100 mil | 11.171 | **13.943** | 17.545 | 1.504 | 9.800 | 33.814 | 7,17 | 11,14 |
| R$ 150 mil | 14.368 | **18.195** | 23.419 | 1.644 | 12.680 | 45.584 | 8,24 | 12,10 |
| R$ 200 mil | 17.229 | **22.229** | 29.101 | 2.222 | 14.827 | 53.565 | 9,00 | 12,71 |
| R$ 250 mil | 20.007 | **26.130** | 34.619 | 2.709 | 18.056 | 58.487 | 9,57 | 13,13 |

O custo médio é o orçamento dividido pelo P50 da média; o custo marginal no topo é `g / (μ · b(g))`, pois `dV/dg = V · b(g) / g` na escala da média. A variante sem capital político dá faixas cerca de 30% maiores (mesmo CSV).

## 6. Teste de sanidade: reprovado em todos os orçamentos

A régua de sanidade é o custo **total** por voto do eleito típico de deputado federal em 2022, reproduzido exatamente pela base: **R$ 22,39 por voto** (média simples de `gasto_total / votos` entre os 30 eleitos gastadores, todas as rubricas; `05_eleitos_2022.csv`). A curva estimada promete voto de impulsionamento a R$ 5,47 a R$ 9,57 (custo médio) e R$ 9,45 a R$ 13,13 (custo marginal no topo): bem abaixo do pacote completo do eleito típico, em **todos** os orçamentos. Conclusão: **a curva está otimista demais para uso literal.** Não é erro de conta; é o que o modelo é:

1. **Endogeneidade e seleção.** O gasto de impulsionamento é escolhido por quem já tem viabilidade (recursos, rede, reconhecimento prévio), e o modelo seccional atribui essa viabilidade ao gasto. Os observáveis de capital político movem pouco o coeficiente (0,399 para 0,404), e pela lógica de Oster o viés seria pequeno se os não observáveis se comportassem como os observáveis; mas o conjunto de observáveis é fraco (não mede rede, mídia própria nem reconhecimento), e o próprio teste de sanidade indica um viés positivo grande remanescente. A faixa deve ser tratada como **limite superior**.
2. **Suporte conjunto irreal do perfil de referência** (`05_suporte_conjunto.csv`). Entre os 17 usuários que gastaram de R$ 100 mil a R$ 200 mil em impulsionamento, a mediana foi de **R$ 555 mil em publicidade tradicional e R$ 704 mil em gasto operacional**, e 70,6% foram eleitos (na faixa de R$ 200 mil ou mais, 12 usuários, as medianas são de R$ 453 mil e R$ 438 mil). O perfil de referência, com tradicional e operacional em cerca de R$ 29 mil e impulsionamento de R$ 250 mil, **não existe na amostra**: a previsão é extrapolação fora do suporte conjunto, mesmo dentro do suporte marginal.
3. **Suporte fino no topo.** Só 9 usuários gastaram R$ 250 mil ou mais, 12 gastaram R$ 200 mil ou mais e 17 gastaram R$ 150 mil ou mais. Os orçamentos até 250 mil ficam abaixo do p99 (R$ 309,5 mil), mas a cauda que identifica a curvatura ali tem meia dúzia de candidatos, quase todos já grandes.

**Como usar a conta.** A faixa do modelo (P10 da média como teto de expectativa) mostra o *potencial* do canal se a conversão for tão boa quanto a média histórica dos usuários, que inclui estruturas muito maiores. O cenário realista é ancorado no custo do eleito típico: votos ≈ orçamento ÷ R$ 22,39 (por exemplo, R$ 100 mil → cerca de 4.470 votos; R$ 250 mil → cerca de 11.165). Qualquer promessa pontual de votos por orçamento é estatisticamente indefensável (P10 ≈ 1.500 e P90 ≈ 34.000 votos preditivos em R$ 100 mil).

## 7. Limitações

- **Endogeneidade:** sem instrumento nem painel dentro do candidato; o contraste com e sem capital político é o único teste de sensibilidade a não observáveis viável. Uma análise formal de Oster exigiria o R² de um modelo linear de referência e fica como extensão. Direção do viés: para cima.
- **Extrapolação:** orçamentos acima de cerca de R$ 338 mil (p99 de 2022) seriam extrapolação pura e não estão cobertos.
- **Validade entre ciclos:** custos de mídia digital, regras do TSE para impulsionamento, saturação do canal e a concorrência do ciclo podem deslocar a curva; o coeficiente do ano de 2022 (−1,04 em log) mostra que o *nível* muda muito entre ciclos mesmo com controles.
- **Dispersão individual:** α ≈ 1,02, portanto só faz sentido falar em faixa.
- **Qualidade criativa:** o modelo usa a média dos usuários como referência de conversão e não identifica heterogeneidade de qualidade criativa ou de segmentação.
- **Observações repetidas:** 34 candidatos (por nome) aparecem em 2018 e em 2022 (68 das 515 observações); os erros-padrão tratam tudo como independente e podem estar levemente estreitos. Erro-padrão agrupado por candidato seria o acabamento correto.
- **Forma quadrática:** o vértice fica em g ≈ R$ 95; abaixo disso `b(g)` é negativo (7 usuários), artefato da forma que não afeta nenhuma decisão de orçamento.

## 8. Verificação independente

O modelo foi refeito do zero por um auditor independente (sem reutilizar os scripts), a partir dos painéis brutos, com matriz de desenho construída à mão (ordem de colunas diferente, de propósito), MLE direto com partida em Poisson, *bootstrap* com semente própria (777, 4.000 réplicas) e curva do *spline* reestimada em grade fina. Resultado: **confirmado**, sem nenhum número refutado.

| Item | Resultado |
|---|---|
| Amostra e deflação | n = 515 (173 + 342) reproduzido; deflação exata (razão 1,255548 em todas as 359 linhas gastadoras de 2018 e 1,000000 em 2022; as rubricas também estão deflacionadas) |
| Especificação vencedora | log-verossimilhança, AIC e BIC idênticos; pior divergência entre os 18 parâmetros de **0,037%**; LR (a) contra (b) = 27,361 (p = 1,7·10⁻⁷) |
| Curva b(g) | idêntica nos pontos avaliados (por exemplo, 0,3993 no ponto de referência e 0,7482 no p99) |
| Faixa por orçamento | divergência máxima de **0,91%** no P50 (R$ 100 mil: 14.020 contra 13.943); fórmulas de custo conferidas |
| Régua de R$ 22,39 | recalculada dos painéis brutos; para comparação, a razão agregada soma/soma é R$ 18,35 e a mediana individual R$ 20,68 (a média de razões usada é a mais conservadora das três) |
| *Spline* contra quadrática | *spline* monotônico crescente em grade de 200 pontos, sem trocas de sinal da derivada; no p99 é ainda mais otimista (0,795 contra 0,747) |

Ressalvas do auditor, nenhuma invalida os resultados: erro-padrão não agrupado por candidato (acima), elasticidade negativa abaixo de R$ 95 (acima) e validação da referência que passa raspando (0,399 numa faixa que termina em 0,40).

## 9. Como rodar

```bash
cd python/modelo_elasticidade
pip install -r ../requirements.txt

# demonstração com painéis SINTÉTICOS (nenhum dado real)
python ../../exemplos/gerar_paineis_sinteticos.py
python 01_prep.py --painel-dir ../../exemplos/paineis_sinteticos --saida ../../execucao/elasticidade
for s in 02_modelos 03_curva_elasticidade 04_banda_envelope 05_checagens_suporte; do
  python $s.py --saida ../../execucao/elasticidade
done

# com os painéis reais gerados pelo pipeline em R
python 01_prep.py --painel-dir <execucao>/dados_tratados --saida <pasta de saída>
```

Cada script aceita `--saida` (padrão `./saidas_elasticidade`, ou a variável de ambiente `ELASTICIDADE_SAIDA`). Com os painéis reais, o código reproduz exatamente as tabelas de `resultados/tabelas/modelo_elasticidade/` (diferença numérica zero).
