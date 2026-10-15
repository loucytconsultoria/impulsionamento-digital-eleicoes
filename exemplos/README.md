# Exemplos com dados sintéticos

Nenhum dado real é usado nesta pasta.

- `gerar_paineis_sinteticos.py` gera, com semente fixa (2026), dois painéis fictícios (deputado federal, 2018 e 2022) no mesmo esquema dos painéis tratados pelo pipeline em R. Os candidatos são identificados como "CANDIDATO SINTETICO", e o processo gerador (binomial negativa com elasticidade quadrática do gasto e um fator latente de "força" do candidato) está descrito no cabeçalho do script.
- `paineis_sinteticos/` contém a saída do gerador (450 e 632 candidatos; 181 e 358 usuários de impulsionamento; 30 eleitos por ano).
- `saida_demo/` traz as tabelas que o módulo `python/modelo_elasticidade` produz sobre esses painéis.

```bash
python exemplos/gerar_paineis_sinteticos.py
cd python/modelo_elasticidade
python 01_prep.py --painel-dir ../../exemplos/paineis_sinteticos --saida ../../execucao/elasticidade
for s in 02_modelos 03_curva_elasticidade 04_banda_envelope 05_checagens_suporte; do
  python $s.py --saida ../../execucao/elasticidade
done
```

Os números da demonstração **não dizem nada sobre eleições reais**. Servem para testar o código e ver o formato das saídas. Como o processo gerador é conhecido, vale uma ressalva de leitura: o teste de sanidade (custo médio contra o custo total por voto do eleito típico) é calculado com os eleitos sintéticos, e a curvatura estimada é menos nítida que a dos dados reais (LR da quadrática contra a log-linear de 3,0, p = 0,08, contra 27,4 nos dados reais).
