# -*- coding: utf-8 -*-
"""
01_prep.py - prepara a base empilhada 2018+2022 (deputado federal, PR) para o
modelo de elasticidade variavel entre gasto de impulsionamento e votos.

Uso:
    python 01_prep.py --painel-dir <pasta com os paineis> [--saida <pasta>]

Os paineis sao os arquivos painel_PR_2018_DEPUTADO_FEDERAL.csv e
painel_PR_2022_DEPUTADO_FEDERAL.csv gerados pelo pipeline em R (R/pipeline) ou,
para uma demonstracao, os paineis sinteticos de exemplos/paineis_sinteticos.

DECISOES DOCUMENTADAS
- Deflacao: os paineis ja vem deflacionados para a base out/2022 (fator 1,2555
  aplicado em 2018). NENHUMA deflacao adicional e' aplicada. Conferencia embutida:
  gasto_total / gasto_total_nominal tem mediana ~1,2555 em 2018 e ~1,0000 em 2022.
- Amostra principal: USUARIOS de impulsionamento (impulsionamento > 0), restritos
  a deferido == 1.
- Logs: l_imp = log(impulsionamento); tradicional e operacional entram como
  log1p (ha zeros legitimos entre usuarios de impulsionamento).
- Capital politico: as colunas l_votos_* ja vem em log no painel e entram como estao.
- Privacidade: as colunas de identificacao (nome, sq) sao removidas antes de
  gravar qualquer base intermediaria.
"""
import numpy as np
import pandas as pd

import comum as cm

args = cm.configura("Prepara a base de usuarios de impulsionamento.", painel=True)
SAIDAS = cm.SAIDAS

from pathlib import Path
base = Path(args.painel_dir)
d18 = pd.read_csv(base / "painel_PR_2018_DEPUTADO_FEDERAL.csv")
d22 = pd.read_csv(base / "painel_PR_2022_DEPUTADO_FEDERAL.csv")

log = []
log.append(("linhas_brutas_2018", len(d18)))
log.append(("linhas_brutas_2022", len(d22)))

# --- Conferencia de deflacao (verificar, nao assumir) ---
m18 = d18[(d18["gasto_total_nominal"] > 0)]
razao18 = (m18["gasto_total"] / m18["gasto_total_nominal"]).median()
m22 = d22[(d22["gasto_total_nominal"] > 0)]
razao22 = (m22["gasto_total"] / m22["gasto_total_nominal"]).median()
log.append(("razao_deflacao_mediana_2018", round(float(razao18), 4)))
log.append(("razao_deflacao_mediana_2022", round(float(razao22), 4)))
assert abs(razao18 - 1.2555) < 0.001, "2018 NAO esta deflacionado como esperado!"
assert abs(razao22 - 1.0000) < 0.001, "2022 nao deveria ter deflacao!"

df = pd.concat([d18, d22], ignore_index=True)
df["ano"] = df["ano"].astype(int)
df = df.drop(columns=[c for c in ("nome", "sq") if c in df.columns])

# --- Filtros documentados ---
n0 = len(df)
df = df[df["deferido"] == 1].copy()
log.append(("removidos_indeferidos", n0 - len(df)))
log.append(("n_deferidos_total", len(df)))

usuarios = df[df["impulsionamento"] > 0].copy()
log.append(("n_usuarios_impulsionamento_total", len(usuarios)))
log.append(("n_usuarios_2018", int((usuarios["ano"] == 2018).sum())))
log.append(("n_usuarios_2022", int((usuarios["ano"] == 2022).sum())))
log.append(("usuarios_com_zero_votos", int((usuarios["total_votos"] == 0).sum())))

# --- Variaveis do modelo ---
usuarios["l_imp"] = np.log(usuarios["impulsionamento"])
usuarios["l_trad"] = np.log1p(usuarios["tradicional"])
usuarios["l_oper"] = np.log1p(usuarios["operacional"])

CAP_COLS = [c for c in usuarios.columns if c.startswith("l_votos_")]
log.append(("colunas_capital_politico", "; ".join(CAP_COLS)))
for c in CAP_COLS + ["reeleicao", "masculino", "superior_completo",
                     "corbranca", "esquerda", "direita"]:
    usuarios[c] = pd.to_numeric(usuarios[c], errors="raise").fillna(0)

# --- Descritivas do gasto de impulsionamento entre usuarios (base out/2022) ---
qs = [0.10, 0.25, 0.50, 0.75, 0.90, 0.95, 0.99]
desc_rows = []
for ano, g in [(2018, usuarios[usuarios["ano"] == 2018]),
               (2022, usuarios[usuarios["ano"] == 2022]),
               ("pool", usuarios)]:
    row = {"amostra": ano, "n": len(g)}
    for q in qs:
        row[f"p{int(q*100)}"] = round(float(g["impulsionamento"].quantile(q)), 2)
    row["max"] = round(float(g["impulsionamento"].max()), 2)
    row["media"] = round(float(g["impulsionamento"].mean()), 2)
    desc_rows.append(row)
desc = pd.DataFrame(desc_rows)
desc.to_csv(SAIDAS / "01_percentis_gasto_impulsionamento.csv",
            index=False, encoding="utf-8-sig")

# Medianas dos controles entre usuarios (para o perfil de referencia)
med = {
    "tradicional_mediana_usuarios": float(usuarios["tradicional"].median()),
    "operacional_mediana_usuarios": float(usuarios["operacional"].median()),
    "imp_mediana_usuarios_pool": float(usuarios["impulsionamento"].median()),
    "imp_mediana_usuarios_2022": float(
        usuarios.loc[usuarios["ano"] == 2022, "impulsionamento"].median()),
}
pd.DataFrame([med]).to_csv(SAIDAS / "01_medianas_controles.csv",
                           index=False, encoding="utf-8-sig")
for k, v in med.items():
    log.append((k, round(v, 2)))

usuarios.to_csv(SAIDAS / "01_base_usuarios.csv",
                index=False, encoding="utf-8-sig")
df.to_csv(SAIDAS / "01_base_completa_deferidos.csv",
          index=False, encoding="utf-8-sig")

pd.DataFrame(log, columns=["item", "valor"]).to_csv(
    SAIDAS / "01_log_prep.csv", index=False, encoding="utf-8-sig")

print(pd.DataFrame(log, columns=["item", "valor"]).to_string(index=False))
print("\nPercentis do gasto de impulsionamento (usuarios, R$ base out/2022):")
print(desc.to_string(index=False))
