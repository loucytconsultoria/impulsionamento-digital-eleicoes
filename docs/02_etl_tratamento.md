# ETL: do microdado bruto do TSE ao painel tratado

O tratamento é uma etapa separada da estimação. Ele lê os microdados públicos do TSE, monta **uma linha por candidato**, classifica e soma a despesa de forma auditável, deflaciona e **trava a saída contra valores impossíveis** antes de gravar. A estimação só lê os CSVs tratados; com a mesma entrada, produz o mesmo resultado.

Implementações no repositório:

- `R/pipeline/01_tratamento.R`: o ETL usado nos resultados (seis recortes: deputado federal e estadual em 2018 e 2022; vereador em 2020 e 2024), com capital político e eleitorado municipal.
- `R/01_tratamento.R`: versão genérica, parametrizada por `(UF, ano, cargo)`, que alimenta o motor `R/modelo_impulsionamento.R`.

## Por que a etapa existe

Uma versão anterior do pipeline produziu custos por voto de 4 a 10 vezes o valor real e um gasto de R$ 38,7 milhões para um único deputado, valor impossível diante do teto legal de aproximadamente R$ 3,18 milhões. O dado bruto não continha esse número: o erro nasceu dentro do pipeline, e o motor não tinha nenhuma trava que o barrasse. O ETL atual resolve isso com três princípios: filtrar o cargo na origem, montar o gasto sem multiplicar linhas e comparar a saída com o teto legal antes de salvar.

## Entradas (todas públicas)

| Insumo | Fonte | Uso |
|---|---|---|
| Candidatos | TSE, `consulta_cand` | cargo, situação de turno, atributos, chave de identidade |
| Reeleição | TSE, `consulta_cand_complementar` | `ST_REELEICAO` por `SQ_CANDIDATO` |
| Despesas | TSE, prestação de contas (`despesas_contratadas_candidatos`) | valor contratado e rubrica oficial |
| Votação | TSE, `votacao_candidato_munzona` | votos nominais, 1º turno |
| Eleitorado apto | TSE, `detalhe_votacao_munzona` | `QT_APTOS` por município (vereador) |
| IPCA | IBGE/SIDRA, tabela 1737, variável 2266 | deflação (tabela versionada em `dicionarios/ipca_indice.csv`) |
| Municípios | IBGE, Atlas do Desenvolvimento Humano | densidade, IDHM, Gini, internet (`dicionarios/`) |

## Os 13 passos

Cada passo grava no log a contagem de linhas que entraram e saíram.

1. **Carregar candidatos e filtrar o cargo na origem.** Mantém só o cargo em análise. É o filtro que impede o vazamento de gastos de governador e senador: toda linha de despesa carrega o cargo do candidato, então fixar o conjunto de `SQ_CANDIDATO` aqui garante que nenhum gasto de outro cargo entre depois.
2. **Garantir uma linha por candidato.** Confere a unicidade de `SQ_CANDIDATO`. Candidato duplicado viraria multiplicação de linhas (*fan-out*) no *join* e multiplicaria o gasto; se houver duplicata, o processo para.
3. **Carregar despesas e restringir aos candidatos do cargo** por junção interna pelo `SQ_CANDIDATO` (cinto e suspensório em relação ao passo 1).
4. **Converter o valor monetário com parser robusto.** O TSE usa o formato brasileiro (`1.234,56`). Há uma guarda: se a coluna já vier numérica, o ponto não é removido (senão `1234.56` viraria `123456`, erro de 100 vezes). O log registra o maior valor unitário.
5. **Classificar cada lançamento pela rubrica oficial** (`DS_ORIGEM_DESPESA`) em cinco classes, nesta ordem: transferência, impulsionamento, tradicional, operacional e não classificado. Regras por palavra-chave sobre o texto sem acento:
   - *impulsionamento*: "IMPULSIONAMENTO";
   - *tradicional*: impresso, militância, mobilização de rua, adesivo, rádio, televisão, vídeo, jornal, revista, carro de som, comício, jingle, vinheta, slogan, correspondência;
   - *transferência*: doação financeira a outro candidato ou partido;
   - *operacional*: pessoal, combustível, veículo, contábil, advocatício, encargo, taxa, bancário, alimentação, locação, pesquisa, comboio, criação de página ou site, internet, hospedagem, comitê, expediente, transporte, deslocamento, água, energia, telefone;
   - *não classificado*: `#NULO`, "Diversas a especificar" e qualquer resto.

   Um CSV de auditoria (`despesas_classificadas_<recorte>.csv`) lista rubrica, classe, soma e número de lançamentos, de modo que a classificação, que é a contribuição central da pesquisa, é inteiramente inspecionável.
6. **Remover transferências entre campanhas.** Transferência não é consumo da campanha do candidato e geraria dupla contagem. Se a soma removida for próxima de zero, a regra provavelmente não está pegando a rubrica correta.
7. **Somar a despesa por candidato e por classe** e pivotar para o formato largo, com zero na ausência. **Não se deduplica por `SQ_DESPESA`**: verificado no dado, o mesmo identificador agrupa itens legítimos distintos de um mesmo documento.
8. **Deflacionar para a base do escopo** pelo IPCA, usando a tabela de índices versionada (não uma chamada de API em tempo de execução, para o tratamento ser reprodutível offline). Base de preços: out/2022 para deputado e out/2024 para vereador. A base só reescala níveis em reais; não muda elasticidades.

   | Ano da despesa | Base | Fator |
   |---|---|---:|
   | 2018 | out/2022 (deputado) | 1,2555 |
   | 2022 | out/2022 (deputado) | 1,0000 |
   | 2020 | out/2024 (vereador) | 1,2939 |
   | 2024 | out/2024 (vereador) | 1,0000 |

9. **Carregar a votação e somar votos por candidato** (`QT_VOTOS_NOMINAIS`, 1º turno). O arquivo vem por município e zona; a soma reconstrói o total nominal.
10. **Montar o capital político** a partir dos ciclos anteriores (ver a seção abaixo).
11. **Montar o painel do candidato**: atributos, votos, gasto por classe e capital político. Gasto ou voto ausente vira zero (zero legítimo, não dado faltante). `gasto_total` é a soma das quatro classes deflacionadas; `gasto_total_nominal` é mantido para auditoria.
12. **Travas de validação** (paradas duras antes de salvar; qualquer falha interrompe e não grava o CSV).
13. **Salvar** o painel, a auditoria de rubricas e o log por recorte.

### Travas do passo 12

| Trava | Efeito |
|---|---|
| `max(gasto_total_nominal)` por candidato acima de 2× o teto legal do cargo e ano | **para** (pega o impossível, com margem para quem estourou o teto legalmente) |
| número de linhas diferente do número de `SQ_CANDIDATO` únicos (*fan-out*) | **para** |
| gasto ou voto negativo | **para** |
| fator de deflação fora de [0,5; 2,5] | **para** (sinal de base ou índice errado) |
| fonte bruta ausente | **para** (nunca se preenche capital político com zero por falta de fonte) |
| candidatos acima do teto legal, mas abaixo de 2× | avisa e lista |
| número de eleitos diferente das cadeiras esperadas (PR: 30 federais, 54 estaduais) | avisa |

Tetos legais nominais usados na trava:

| Cargo | 2018 | 2022 |
|---|---:|---:|
| Deputado federal | R$ 2.500.000 | R$ 3.176.400 |
| Deputado estadual | R$ 1.000.000 | R$ 1.270.560 |

Para vereador o limite é municipal e não há número único; usa-se um teto de sanidade generoso (R$ 1,0 milhão em 2020; R$ 1,2 milhão em 2024), só para barrar o impossível.

**Conferência contra o gabarito do TSE.** Os maiores gastos nominais por candidato obtidos pelo ETL coincidem com o gabarito: deputado federal 2018, R$ 2.429.475; deputado federal 2022, R$ 3.159.985 (632 candidatos, 30 eleitos); deputado estadual 2018, R$ 999.987; deputado estadual 2022, R$ 1.294.963 (54 eleitos); vereador 2020, R$ 485.397; vereador 2024, R$ 673.034. Nenhuma trava dura disparou.

## Capital político

O capital político é o principal confundidor (candidato forte atrai mais dinheiro e mais voto). Para cada modelo, entra como:

- **reeleição**: indicador de `ST_REELEICAO == "S"` do mesmo cargo (cobre o titular e o suplente que assumiu);
- **`log1p` da votação nominal anterior**, por conjunto de cargos, contínua e igual a 0 onde o candidato não concorreu.

| Modelo | Entradas de votação anterior |
|---|---|
| Deputado estadual | mesmo cargo na última eleição geral; prefeito na última e na penúltima municipal; vereador na última municipal |
| Deputado federal | os quatro acima e ainda deputado estadual na última geral |
| Vereador | vereador na última municipal; deputado (federal ou estadual) na última geral |

A chave de identidade entre ciclos é o CPF quando íntegro na coorte e o nome normalizado mais a data de nascimento quando o CPF degenera. No arquivo de candidatos de 2024 o CPF vem mascarado (um único valor para todos), então o vereador 2024 é casado por nome e nascimento, com a mesma chave aplicada aos ciclos anteriores. Casamentos observados: 9.603 vereadores de 2024 com votação de vereador em 2020; 63 deputados federais de 2022 com votação de deputado federal em 2018.

O painel de saída traz as colunas de identificação do TSE; **os painéis com nome de candidato não fazem parte deste repositório** (o modelo de elasticidade em Python descarta as colunas de identificação ao ler o painel).

## Painel tratado

Uma linha por candidato, com: identificadores (`sq`, `nome`, `partido`, `lista`, `cod_mun`), desfechos (`total_votos`, `eleito`, `deferido`), gasto por classe em reais da base do escopo (`impulsionamento`, `tradicional`, `operacional`, `nao_classificado`, `gasto_total`, `gasto_total_nominal`), capital político (`reeleicao`, `l_votos_*`) e controles (`masculino`, `superior_completo`, `corbranca`, `esquerda`, `direita`). A ideologia é a do partido (esquerda, direita; centro como base), usada como controle no lugar do partido, que não é uma boa unidade entre estados e municípios.

## Auditoria do ETL

O painel foi conferido contra o dado bruto do TSE: os agregados por classe de despesa têm razão painel/bruto de 1,000000, e oito candidatos recomputados individualmente a partir do bruto coincidem em gasto e votos com diferença zero. Detalhes em [05_auditoria_e_reprodutibilidade.md](05_auditoria_e_reprodutibilidade.md).
