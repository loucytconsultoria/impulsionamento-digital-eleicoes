# -*- coding: utf-8 -*-
"""
04_banda_envelope.py - converte um ORCAMENTO de gasto de impulsionamento em uma
FAIXA DE RESULTADO ESPERADO (votos), com intervalos, para um perfil de referencia.

Usa a especificacao vencedora (quadratica, com capital politico; AIC/BIC e LR em
02) e, por robustez, a variante sem capital politico.

PERFIL DE REFERENCIA (parametrizavel nas constantes abaixo):
  sem reeleicao, sem capital politico previo (l_votos_* = 0), masculino=1,
  superior_completo=1, corbranca=0, esquerda=0, direita=0, ano=2022,
  tradicional e operacional nas MEDIANAS dos usuarios (01_medianas_controles.csv).

INCERTEZA: bootstrap parametrico com 2.000 replicas (semente 2026):
  (beta, alpha) ~ MVN(estimativas, cov MLE); faixa da MEDIA E[votos] = exp(x'b)
  (P10/P50/P90) e faixa PREDITIVA individual (soma o ruido NB2: y ~ NB(mu, alpha)).

CUSTOS: custo medio = orcamento / votos (P50 da media); custo marginal no topo do
orcamento = g / (mu * b(g)), pois dV/dg = V*b(g)/g na escala da media.

TESTE DE SANIDADE: compara o custo medio com o custo total por voto do ELEITO
tipico de 2022 (media simples de gasto_total/votos entre os eleitos gastadores,
todas as rubricas; calculado a partir da propria base). Orcamento cujo custo medio de
impulsionamento fica ABAIXO disso promete voto de impulsionamento mais barato que o
pacote completo do eleito: otimista demais; sinalizado.
"""
import numpy as np
import pandas as pd

import comum as cm
from comum import carrega_modelo, design_info, matriz_para

cm.configura("Faixa de votos esperada por orcamento de impulsionamento.")
SAIDAS = cm.SAIDAS

SEED = 2026
N_BOOT = 2000
ENVELOPES = [50_000, 100_000, 150_000, 200_000, 250_000]   # R$ de out/2022

usuarios = cm.carrega_usuarios()
completa = cm.carrega_completa()
CUSTO_ELEITO_2022, _n = cm.custo_total_voto_eleitos(completa, 2022)
med = pd.read_csv(SAIDAS / "01_medianas_controles.csv").iloc[0]

rng = np.random.default_rng(SEED)

linhas = []
for var_nome in ["com_cap", "sem_cap"]:
    chave = f"b_quadratica__{var_nome}"
    params, cov = carrega_modelo(chave)
    dinfo = design_info("b_quadratica", var_nome, usuarios)
    beta_names = list(dinfo.column_names)
    idx = beta_names + ["alpha"]
    mu_hat_params = params[idx]
    V = cov.loc[idx, idx].values

    # sorteio conjunto (beta, alpha); alpha truncado a >0
    draws = rng.multivariate_normal(mu_hat_params.values, V, size=N_BOOT)
    draws[:, -1] = np.clip(draws[:, -1], 1e-4, None)

    b1 = float(params["l_imp"])
    b2 = float(params["I(l_imp ** 2)"])

    for E in ENVELOPES:
        novo = pd.DataFrame([{
            "l_imp": np.log(E),
            "l_trad": np.log1p(med["tradicional_mediana_usuarios"]),
            "l_oper": np.log1p(med["operacional_mediana_usuarios"]),
            "reeleicao": 0, "masculino": 1, "superior_completo": 1,
            "corbranca": 0, "esquerda": 0, "direita": 0, "ano": 2022,
            "l_votos_mesmo_cargo_ultima": 0.0,
            "l_votos_dep_estadual_ultima": 0.0,
            "l_votos_prefeito_ultima": 0.0,
            "l_votos_prefeito_penultima": 0.0,
            "l_votos_vereador_ultima": 0.0,
        }])
        x = matriz_para(novo, dinfo).values[0]

        mu_ponto = float(np.exp(x @ params[beta_names].values))
        mus = np.exp(draws[:, :-1] @ x)            # banda da média
        alphas = draws[:, -1]
        # banda preditiva individual: y ~ NB2(mu, alpha)
        n_nb = 1.0 / alphas
        p_nb = n_nb / (n_nb + mus)
        y_pred = rng.negative_binomial(n_nb, p_nb)

        b_g = b1 + 2.0 * b2 * np.log(E)
        p10m, p50m, p90m = np.percentile(mus, [10, 50, 90])
        p10y, p50y, p90y = np.percentile(y_pred, [10, 50, 90])
        custo_medio = E / p50m
        custo_marginal = E / (p50m * b_g)
        linhas.append({
            "modelo": chave, "envelope_R$2022": E,
            "votos_ponto": round(mu_ponto, 0),
            "votos_media_P10": round(p10m, 0),
            "votos_media_P50": round(p50m, 0),
            "votos_media_P90": round(p90m, 0),
            "votos_pred_P10": round(float(p10y), 0),
            "votos_pred_P50": round(float(p50y), 0),
            "votos_pred_P90": round(float(p90y), 0),
            "b_g_topo": round(b_g, 4),
            "custo_medio_R$/voto_P50": round(custo_medio, 2),
            "custo_marginal_topo_R$/voto": round(custo_marginal, 2),
            "n_usuarios_gasto>=E": int(
                (usuarios["impulsionamento"] >= E).sum()),
            "sanidade_vs_eleito_tipico": ("OTIMISTA DEMAIS (abaixo do eleito tipico)"
                                  if custo_medio < CUSTO_ELEITO_2022
                                  else "ok (acima/igual ao eleito tipico)"),
        })

banda = pd.DataFrame(linhas)
banda.to_csv(SAIDAS / "04_banda_envelopes.csv",
             index=False, encoding="utf-8-sig")

print(f"Bootstrap parametrico: {N_BOOT} replicas, semente {SEED}")
print(f"Custo total/voto do eleito tipico 2022: R$ {CUSTO_ELEITO_2022:.2f}")
print(f"Perfil de referencia: trad mediana R$ {med['tradicional_mediana_usuarios']:,.0f}; "
      f"oper mediana R$ {med['operacional_mediana_usuarios']:,.0f}")
for m in banda["modelo"].unique():
    print(f"\n=== {m} ===")
    print(banda[banda["modelo"] == m].drop(columns="modelo")
          .to_string(index=False))
