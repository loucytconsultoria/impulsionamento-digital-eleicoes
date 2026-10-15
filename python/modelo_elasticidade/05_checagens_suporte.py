# -*- coding: utf-8 -*-
"""
05_checagens_suporte.py - checagens de suporte amostral e contexto para as
limitacoes do modelo:
1) Suporte CONJUNTO: quem gasta muito em impulsionamento também gasta muito
   nas outras rubricas? (medianas de tradicional/operacional por faixa de imp)
   — relevante porque o candidato-tipo fixa trad/oper na mediana geral.
2) Eleitos 2022: gasto de impulsionamento e custo total/voto dos eleitos
   (confere a âncora R$ 22,39/voto).
3) Suporte no topo: candidatos observados acima de cada envelope.
"""
import numpy as np
import pandas as pd

import comum as cm

cm.configura("Checagens de suporte conjunto e custo do eleito tipico.")
SAIDAS = cm.SAIDAS
usuarios = cm.carrega_usuarios()
completa = cm.carrega_completa()

# 1) suporte conjunto
faixas = [(0, 10_000), (10_000, 50_000), (50_000, 100_000),
          (100_000, 200_000), (200_000, np.inf)]
rows = []
for lo, hi in faixas:
    g = usuarios[(usuarios["impulsionamento"] >= lo)
                 & (usuarios["impulsionamento"] < hi)]
    rows.append({
        "faixa_imp": f"[{lo:,.0f}, {hi:,.0f})", "n": len(g),
        "trad_mediana": round(float(g["tradicional"].median()), 0),
        "oper_mediana": round(float(g["operacional"].median()), 0),
        "votos_mediana": round(float(g["total_votos"].median()), 0),
        "pct_eleitos": round(100 * float(g["eleito"].mean()), 1),
    })
sup = pd.DataFrame(rows)
sup.to_csv(SAIDAS / "05_suporte_conjunto.csv",
           index=False, encoding="utf-8-sig")

# 2) eleitos 2022 — custo total por voto (todas as rubricas, gastadores)
e22 = completa[(completa["ano"] == 2022) & (completa["eleito"] == 1)
               & (completa["gasto_total"] > 0)]
custo_total_voto, _ = cm.custo_total_voto_eleitos(completa, 2022)
imp_med_eleitos = e22["impulsionamento"].median()
imp_p90_eleitos = e22["impulsionamento"].quantile(0.90)
chk = pd.DataFrame([{
    "n_eleitos_2022_gastadores": len(e22),
    "custo_total_por_voto_medio_R$": round(float(custo_total_voto), 2),
    "imp_mediana_eleitos_2022_R$": round(float(imp_med_eleitos), 2),
    "imp_p90_eleitos_2022_R$": round(float(imp_p90_eleitos), 2),
    "votos_mediana_eleitos_2022": float(e22["total_votos"].median()),
}])
chk.to_csv(SAIDAS / "05_eleitos_2022.csv",
           index=False, encoding="utf-8-sig")

print("=== Suporte conjunto (usuários, pool 2018+2022, R$ 2022) ===")
print(sup.to_string(index=False))
print("\n=== Eleitos 2022 (gastadores) ===")
print(chk.to_string(index=False))
