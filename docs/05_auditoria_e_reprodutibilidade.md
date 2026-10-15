# Auditoria, checagem adversarial e reprodutibilidade

## Como o código foi produzido

A reconstrução reprodutível da pesquisa (ETL, estimação e relatórios) foi feita **com assistência de IA (Claude Code)**, a partir de uma especificação escrita pelo autor: quais modelos estimar, quais decisões econométricas travar e quais travas de validação exigir. O princípio de trabalho foi o de que **quem produz não verifica**: cada etapa de produção tem uma etapa de verificação separada, descrita abaixo. Os resultados, portanto, não repousam na confiança no código gerado, e sim em controles que podem ser reexecutados.

| Camada | O que verifica | Quem executa |
|---|---|---|
| 1. Travas do ETL | Teto legal, multiplicação de linhas, valores negativos, fator de deflação, fonte ausente (o processo **para** em vez de gravar um número impossível) | O próprio pipeline, a cada execução |
| 2. Conferência do painel contra o bruto | O painel reproduz o bruto do TSE ao centavo | Verificação independente |
| 3. Auditoria adversarial dos resultados | Tenta refutar os resultados contra o dado bruto e contra a consistência interna | Um agente separado, em contexto isolado |
| 4. Teste de determinismo | Duas execuções do zero geram arquivos idênticos | Comparação de md5 |
| 5. Reprodução dos modelos originais | As bases e os modelos da monografia são reconstruídos e conferidos contra os valores impressos no código original | Bateria de diagnósticos ([04](04_diagnosticos_dos_modelos_do_tcc.md)) |
| 6. Auditoria adversarial do modelo de elasticidade | Refaz os cálculos-chave do zero, com código próprio | Um auditor independente ([06](06_modelo_de_elasticidade_variavel.md), seção 8) |

## 1. Conferência do painel contra o bruto

Os agregados por classe de despesa do painel têm razão de 1,000000 contra o dado bruto do TSE, nos dois anos de deputado federal, e oito candidatos escolhidos foram recomputados diretamente do bruto, com diferença zero em gasto e em votos. As travas de teto, os benchmarks do TSE e a checagem de fonte ausente passaram em todos os seis recortes (ver [02_etl_tratamento.md](02_etl_tratamento.md)).

## 2. Auditoria adversarial dos resultados

A verificação foi feita por um **agente separado, em contexto isolado**, com a tarefa explícita de **refutar** os resultados (*red-team*), testando cada item contra o dado bruto do TSE e contra a consistência interna. **Veredito: nenhum erro de dado ou de cálculo nos cinco itens investigados.** Três recomendações de método foram incorporadas ao pipeline.

| # | Achado que parecia erro | Verificação | Causa | Veredito / correção |
|---|---|---|---|---|
| 1 | Custo por voto alto em 2022 no deputado federal (a mediana individual salta de 10,21 para 46,31; a média dos eleitos, de 16,40 para 22,39) | Agregados conferidos contra o bruto (razão 1,000000); custo por voto de oito candidatos recomputado do bruto, com diferença zero | **Real, não artefato:** o gasto real total subiu 71% (115% em termos nominais, coerente com o aumento do fundo de financiamento de R$ 1,7 bi para R$ 4,9 bi) e os votos só 10%; há 40% mais candidatos, cada um gastando cerca de 3 vezes mais e recebendo cerca de 40% menos votos na mediana. A deflação até infla 2018, o que joga *contra* o salto | Não é erro; documentado |
| 2 | Coeficiente de reeleição **negativo** no deputado federal de 2018 (−0,606; p = 0,079), e +0,769 em 2022 | Correlação entre a dummy de reeleição e a votação anterior do mesmo cargo de 0,816 (2018) e 0,711 (2022); 100% dos incumbentes têm votação anterior positiva, contra cerca de 6% dos demais | Colinearidade: a votação anterior absorve a força do incumbente e a dummy fica com o resíduo; o repartimento se inverte de um ano para o outro | Não é erro. **Correção:** o pipeline passa a reportar o **efeito conjunto de incumbência** (fator 2,14 em 2018, p = 0,0014; 3,54 em 2022), e a dummy nunca é lida isoladamente |
| 3 | Curvas de custo marginal quase retas em portes do vereador | Nos 12 CSVs, os votos previstos seguem exatamente `K · g^β` | Matemática do modelo: com β pequeno (0,065 no pequeno de 2020; 0,008 no médio de 2020), `1 − β ≈ 1` e a curva é quase uma reta. De passagem, esses dois β **não são distintos de zero** (p = 0,379 e 0,847) | Não é erro. **Correção:** a saturação passa a ser **mascarada** (NA, com o motivo) quando a dose intensiva não é significativa a 5% |
| 4 | Coeficiente de `l_votos_deputado_ultima` **negativo** no vereador pequeno de 2020 (−0,0827; p = 0,0056) | Só 21 de 16.490 candidatos (0,13%) têm histórico de deputado; sem o 1% maior dos positivos: −0,0822; sem os cinco maiores: −0,0987; versão com indicador: −0,568 | Associação real e robusta a extremos: controlada a base local, quem veio de candidatura fraca a deputado rende menos como vereador em município pequeno | Não é erro, mas o suporte empírico é mínimo (21 casos); reportado como achado secundário e com essa qualificação |
| 5 | A saturação do deputado federal **cai** de 2018 (~22,7 mil) para 2022 (~18,3 mil) mesmo com β maior (0,195 para 0,231) e limiar maior (16,40 para 22,39) | Fórmula fechada derivada e conferida; o `K` recomputado dos coeficientes bate exatamente com o das curvas (993,10 e 352,82) | O **nível** `K` domina (decomposição de Shapley do log de g*: K × 0,268; β × 1,95; limiar × 1,49; líquido × 0,778). A queda de `K` (× 0,355) vem do intercepto (6,148 para 5,066): o candidato de referência de 2022 parte de um nível de votos cerca de 2,8 vezes menor, porque há mais candidatos dividindo praticamente os mesmos votos. Contraintuitivo, mas correto | Não é erro de dado nem de lógica. Havia só um **viés de discretização** (a busca em malha de 500 pontos superestimava o ponto em até um passo: +1,4% em 2018 e +5,2% em 2022). **Correção:** ponto de saturação por **fórmula fechada** `g* = (K·β·L)^(1/(1−β))`. Ressalva registrada: o perfil de referência é recentrado a cada ano, então o contraste 2018 × 2022 mistura coeficientes e composição |

Os números de saturação acima (22,7 mil e 18,3 mil) são os da auditoria, calculados pela busca em malha **antes** da correção; os valores finais pela fórmula fechada, usados nos resultados, são R$ 22,4 mil (2018) e R$ 17,4 mil (2022) para o limiar dos eleitos.

### Correções incorporadas ao pipeline

1. Ponto de saturação analítico (fórmula fechada) no lugar da busca em malha, por categoria de gasto; a malha segue apenas para traçar as curvas.
2. Máscara de significância: saturação reportada como NA (com motivo) quando a dose intensiva da categoria não é distinta de zero a 5%.
3. Efeito conjunto de incumbência por recorte, lido junto da reeleição.

## 3. Determinismo

O pipeline completo foi executado **duas vezes, do zero** (`Rscript R/pipeline/run_all.R`), com `dados_tratados/`, `saidas/` e `figuras/` apagados e regenerados inteiramente entre as execuções. **Todos os arquivos são idênticos por md5:**

| Pasta | Arquivos | Diferenças |
|---|---:|---:|
| `dados_tratados/` | 18 | 0 |
| `saidas/` | 89 | 0 |
| `figuras/` | 24 | 0 |

A semente é fixa (`set.seed(20260629)`); o `MANIFEST.md` gerado ao final do pipeline lista o md5 e o tamanho de cada arquivo. A transcrição do R (`.Rout`) difere entre execuções apenas no tempo de processamento impresso ao final, que não faz parte dos arquivos de dados e saídas.

## 4. Reprodução independente nesta versão do repositório

Ao montar este repositório, os caminhos dos scripts foram parametrizados (variáveis de ambiente, sem nenhum caminho local fixo) e a reprodução foi verificada de novo, a partir dos microdados brutos:

- **Pipeline completo** (`Rscript R/pipeline/run_all.R`, scripts 00 a 08, cerca de 20 minutos): os 18 arquivos de `dados_tratados/`, os 89 de `saidas/` e os 24 de `figuras/` saíram **idênticos por md5** aos da execução original. O relatório de resultados difere apenas nas linhas de referência a arquivos, que foram reescritas para esta estrutura.
- **Bateria de diagnósticos** (`Rscript R/diagnosticos/run_all.R`, cerca de 41 minutos, incluindo a extração dos pacotes originais do TSE): as 38 tabelas e as 28 figuras saíram **idênticas por md5** às originais.
- **Módulo em Python** reexecutado sobre os painéis reais: reproduziu com **diferença numérica zero** as tabelas de coeficientes, curvas de elasticidade e faixas de resultado de `resultados/tabelas/modelo_elasticidade/`.

## 5. Limites do que foi auditado

- A auditoria verifica **cálculo e consistência**, não identificação causal: os resultados são associações condicionais (ver o limite de endogeneidade nos documentos 04 e 06).
- Os dados de prestação de contas estão sujeitos à subdeclaração.
- A comparação entre anos é uma sucessão de cortes transversais, não uma série temporal.
