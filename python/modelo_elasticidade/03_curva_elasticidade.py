# -*- coding: utf-8 -*-
"""
03_curva_elasticidade.py - extrai a curva de elasticidade local b(g) = d log E[votos] / d log(gasto_imp)
das especificações estimadas em 02, com IC 95% por delta method.

- (a) log-linear: b(g) = beta_l_imp (constante).
- (b) quadrática: b(g) = beta1 + 2*beta2*log(g); var por delta method exata.
- (c) spline: b(g) = soma_j beta_j * B_j'(log g), com B_j' por diferença
  finita central (h=1e-5) na base patsy reconstruída da mesma amostra;
  var = grad' Cov grad (delta method).

Pontos avaliados: percentis 10/25/50/75/90/95/99 do gasto entre usuários
(pool, R$ base out/2022), o ponto de referencia R$ 7.136,63 (mediana 2022
em precos de 2018), a mediana 2022 desta base e os envelopes
R$ 50k/100k/150k/200k/250k. Também documenta o suporte amostral (quantos
usuários gastaram >= g).
"""
import numpy as np
import pandas as pd
from scipy import stats

import comum as cm
from comum import (TERMOS, VARIANTES, carrega_modelo, design_info, matriz_para,
                   REF_PONTO_GASTO, REF_FAIXA)

cm.configura("Curva de elasticidade local b(g) com IC 95% (delta method).")
SAIDAS = cm.SAIDAS
usuarios = cm.carrega_usuarios()
Z = stats.norm.ppf(0.975)

# --- Pontos de avaliação ---
qs = [0.10, 0.25, 0.50, 0.75, 0.90, 0.95, 0.99]
pontos = [("p" + str(int(q * 100)),
           float(usuarios["impulsionamento"].quantile(q))) for q in qs]
pontos += [("ref_mediana2022_precos2018", REF_PONTO_GASTO),
           ("mediana2022_base", float(
               usuarios.loc[usuarios["ano"] == 2022,
                            "impulsionamento"].median()))]
pontos += [(f"envelope_{int(e/1000)}k", float(e))
           for e in [50_000, 100_000, 150_000, 200_000, 250_000]]

linhas = []
for var_nome in VARIANTES:
    for spec_nome in TERMOS:
        chave = f"{spec_nome}__{var_nome}"
        params, cov = carrega_modelo(chave)
        # dropa alpha (não entra na média condicional)
        beta = params.drop("alpha")
        V = cov.drop("alpha", axis=0).drop("alpha", axis=1)

        if spec_nome == "c_spline":
            dinfo = design_info(spec_nome, var_nome, usuarios)
            cols = list(dinfo.column_names)
            assert cols == list(beta.index), "ordem de colunas divergente"

        for rotulo, g in pontos:
            L = np.log(g)
            suporte = int((usuarios["impulsionamento"] >= g).sum())
            if spec_nome == "a_loglinear":
                b = float(beta["l_imp"])
                se = float(np.sqrt(V.loc["l_imp", "l_imp"]))
            elif spec_nome == "b_quadratica":
                b1 = float(beta["l_imp"])
                b2 = float(beta["I(l_imp ** 2)"])
                b = b1 + 2.0 * b2 * L
                v = (V.loc["l_imp", "l_imp"]
                     + 4.0 * L * V.loc["l_imp", "I(l_imp ** 2)"]
                     + 4.0 * L**2 * V.loc["I(l_imp ** 2)", "I(l_imp ** 2)"])
                se = float(np.sqrt(v))
            else:  # spline: derivada numérica da preditora linear em l_imp
                h = 1e-5
                base = usuarios.iloc[[0]].copy()  # controles irrelevantes p/ grad
                mais = base.assign(l_imp=L + h)
                menos = base.assign(l_imp=L - h)
                Xp = matriz_para(mais, dinfo).values[0]
                Xm = matriz_para(menos, dinfo).values[0]
                grad = (Xp - Xm) / (2 * h)  # só termos em l_imp variam
                b = float(grad @ beta.values)
                se = float(np.sqrt(grad @ V.values @ grad))
            linhas.append({
                "modelo": chave, "ponto": rotulo, "gasto_g_R$2022": round(g, 2),
                "log_g": round(L, 4), "b_g": round(b, 4),
                "ep": round(se, 4),
                "ic95_inf": round(b - Z * se, 4),
                "ic95_sup": round(b + Z * se, 4),
                "n_usuarios_gasto>=g": suporte,
            })

curva = pd.DataFrame(linhas)
curva.to_csv(SAIDAS / "03_curva_elasticidade.csv",
             index=False, encoding="utf-8-sig")

# --- Validacao contra a faixa de referencia ---
val = curva[(curva["ponto"] == "ref_mediana2022_precos2018")]
val = val[["modelo", "b_g", "ic95_inf", "ic95_sup"]].copy()
val["faixa_referencia"] = f"{REF_FAIXA[0]:.2f} a {REF_FAIXA[1]:.2f}"
val["dentro_da_faixa"] = (val["b_g"] >= REF_FAIXA[0]) & (val["b_g"] <= REF_FAIXA[1])
val.to_csv(SAIDAS / "03_validacao_referencia.csv",
           index=False, encoding="utf-8-sig")

print("=== b(g) no ponto de referencia (mediana 2022 em precos de 2018, R$ 7.136,63) ===")
print(val.to_string(index=False))
print("\n=== Curva completa — especificação quadrática com capital político ===")
print(curva[curva["modelo"] == "b_quadratica__com_cap"].to_string(index=False))
print("\n=== Curva — quadrática sem capital político ===")
print(curva[curva["modelo"] == "b_quadratica__sem_cap"].to_string(index=False))
print("\n=== Curva — spline com capital político (checagem de forma) ===")
print(curva[curva["modelo"] == "c_spline__com_cap"].to_string(index=False))
