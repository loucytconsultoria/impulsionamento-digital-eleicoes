# Evolução do modelo: da monografia à versão reproduzível

Este documento registra cada mudança entre a especificação da monografia e a especificação do pipeline reproduzível, com a justificativa técnica e a melhoria esperada. Só traz o caminho do original para o final; alternativas testadas e descartadas aparecem na última seção.

## 1. O modelo original (monografia)

Paraná; deputado federal e estadual (2018, 2022) e vereador (2020, 2024).

- **Votos:** binomial negativa (NB), com o gasto entrando como `log1p(gasto)` por categoria (impulsionamento, publicidade tradicional, operacional).
- **Sucesso eleitoral:** logit comum.
- **Controles:** reeleição, gênero, escolaridade, cor e ideologia do partido (esquerda, direita; centro como base). Erros-padrão sem agrupamento.
- **Vereador:** estratificado por porte do município (quatro modelos).
- **Saturação:** custo marginal por voto variando o gasto de R$ 1 em R$ 1, com três limiares (R$ 1 por voto, custo médio geral por voto, custo médio dos eleitos).

Os fundamentos eram sólidos: binomial negativa para contagem superdispersa, `log1p` para retornos decrescentes e para tratar o zero, e, sobretudo, a separação inédita do gasto em impulsionamento, publicidade tradicional e operacional, que é a contribuição central da pesquisa (a literatura anterior tratava o gasto como agregado).

## 2. As mudanças, uma a uma

| # | Mudança | Motivo técnico | Melhoria esperada |
|---|---|---|---|
| 1 | **Aquisição e reprodutibilidade:** dados lidos do bruto do TSE, colunas resolvidas por padrão de texto, versões de pacotes travadas com `renv` | Os nomes de coluna do TSE mudam entre anos | O estudo deixa de depender de arquivos locais e escala para qualquer UF e ano |
| 2 | **Deflação em base única por escopo,** por tabela IPCA versionada (out/2022 para deputado, out/2024 para vereador) | Comparar reais de anos diferentes sem corrigir a inflação compara poderes de compra diferentes; para elasticidade (log-log) é neutro, mas para pontos de saturação em reais é decisivo | Pontos de saturação comparáveis entre ciclos, sem depender de API externa |
| 3 | **Classificação de despesas:** três classes de consumo mais uma classe residual explícita (`#NULO`, "Diversas"); transferências entre campanhas removidas | Jogar o residual em "operacional" infla essa categoria; transferência não é consumo da campanha e geraria dupla contagem | Estimativas menos contaminadas, com análise de sensibilidade ao destino do residual |
| 4 | **Capital político:** da dummy de reeleição para reeleição (marca do TSE) **mais** o `log1p` da votação anterior, por conjunto de cargos e calendário eleitoral | Capital político é o maior confundidor (candidato forte atrai dinheiro e voto); a reeleição sozinha capta só uma fração | Menor viés de variável omitida no coeficiente do gasto |
| 5 | **Eleitorado** (vereador): `log(apto)` como covariável livre, em vez de *offset* | O coeficiente estimado fica entre 0,18 e 0,35 e rejeita 1: o voto não escala proporcionalmente ao eleitorado | Ajuste do tamanho do município sem impor escala 1 |
| 6 | **Margem extensiva e intensiva** (modelo de barreira): indicador de uso mais log do gasto entre usuários, para cada categoria, como modelo único de votos | `log1p` resume numa só inclinação duas decisões distintas (adotar e dosar) | Leitura mais fina e base correta para a saturação |
| 7 | **Efeito combinado** em um gasto de referência único por cenário | Com o mesmo valor aplicado às três categorias, os fatores ficam comparáveis no mesmo dinheiro | Comparação direta entre categorias |
| 8 | **Sucesso eleitoral:** logit comum → logit de **Firth**, com força de lista (*leave-one-out*) e sem posição na lista nem votos próprios | Eleito é evento raro (separação e viés de amostra pequena); em lista aberta, posição e votos próprios tornam o modelo tautológico | O modelo mede o efeito do gasto sobre eleger-se sem virar a regra de apuração |
| 9 | **Saturação sobre a margem intensiva** (entre usuários), por fórmula fechada, com **máscara** quando a dose não é distinta de zero | Para dimensionar orçamento, a população relevante é quem gasta; a busca em malha superestimava o ponto em até um passo | Ponto de saturação exato e sem resultado espúrio |
| 10 | **Vereador só por porte** e moderadores municipais (densidade, internet; IDHM e Gini exploratórios) | O contexto é lido no gradiente entre portes | Teste do achado central |
| 11 | **Diagnósticos por modelo, auditoria independente e teste de determinismo** | O leitor precisa julgar cada modelo pelos seus pressupostos | Transparência e detecção de problemas (ver documentos 04 e 05) |

## 3. O que mudou nos números (mesma amostra, mesma família)

O pipeline reajusta a especificação da monografia nos mesmos painéis para que a comparação seja de especificação e não de dado. O AIC do modelo atual é **menor em todos os 12 recortes**. Exemplo, deputado federal 2018 (`resultados/RELATORIO_RESULTADOS.md`):

| Medida | Monografia | Atual |
|---|---:|---:|
| Elasticidade do impulsionamento | 0,098 (`log1p` único) | 0,195 (dose intensiva entre usuários) |
| Reeleição | 1,045 | −0,606 (dummy) |
| Efeito conjunto de incumbência | n/d | fator 2,14 |
| AIC | 7.745,9 | 7.630,5 |

A dose intensiva é maior que a elasticidade `log1p` única porque o `log1p` dilui a dose entre os não usuários. A reeleição muda de sinal porque a dummy e a votação anterior são colineares (correlação de 0,82 em 2018): a votação anterior absorve a força do incumbente e a dummy fica com o resíduo. A leitura correta é sempre o **efeito conjunto**, nunca a dummy isolada.

## 4. Variáveis do modelo final

- **Dependentes:** `total_votos` (contagem de votos nominais, desfecho principal) e `eleito` (complementar, mecânico pelas regras de lista).
- **Gasto** (deflacionado): `impulsionamento` (rubrica oficial "Despesa com Impulsionamento de Conteúdos", a variável de interesse); `tradicional` (alcance *offline*: impressos, militância, adesivos, rádio, TV e vídeo, jornais, carros de som, comícios, jingles, correspondência); `operacional` (estrutura e logística); `nao_classificado` (residual, só para sensibilidade).
- **Capital político:** `reeleicao` e `l_votos_*` (votação anterior por cargo, em `log1p`).
- **Controles:** `masculino`, `superior_completo`, `corbranca`, `esquerda`, `direita` (centro é a base).
- **Força de lista** (só no sucesso): `votos_lista_loo`, a soma dos votos dos demais candidatos da lista, sem os votos do próprio candidato.

## 5. Alternativas testadas e descartadas

- **Erros-padrão agrupados por partido:** com cerca de 30 partidos, o erro agrupado infla artificialmente os erros-padrão e apagou a significância do gasto numa versão intermediária. O desempenho de voto é individual; para o vereador, o agrupamento por município (centenas de grupos) é a escolha defensável.
- **Poisson:** rejeitado pelos testes de sobredispersão em 12 de 12 recortes.
- **Binomial negativa inflacionada de zeros (ZINB) como modelo principal:** mantida só como verificação de robustez (o coeficiente do impulsionamento praticamente não se move).
- **Posição na lista e votos próprios no modelo de sucesso:** tautológicos pelas regras de lista aberta.
- **Formas funcionais com teto** (Michaelis-Menten, exponencial assintótica, spline e GAM binomiais negativos) para as curvas de custo marginal: implementadas no motor `R/modelo_impulsionamento.R`, mas fora do pipeline final.

## 6. Motor de estimação alternativo

`R/modelo_impulsionamento.R` é um motor autossuficiente, parametrizado por `(UF, ano, cargo)`, que lê o painel tratado por `R/01_tratamento.R` e implementa, além do modelo de votos e do sucesso de Firth: erros-padrão robustos HC3 e agrupados por município, logit fracionário para a participação de votos, sensibilidade de Oster para as três categorias, diagnósticos de resíduos simulados (DHARMa) e controle de falsas descobertas (Benjamini-Hochberg) nas interações exploratórias. Foi o ponto de partida do pipeline final, que o simplifica para um modelo único de votos e uma única especificação de capital político.
