# -*- coding: utf-8 -*-
"""
gerar_paineis_sinteticos.py - gera paineis SINTETICOS (dados ficticios) com o
mesmo esquema dos paineis tratados pelo pipeline em R, para demonstrar o modelo
de elasticidade variavel sem usar nenhum dado real.

Nada aqui vem do TSE: os candidatos sao identificados como "CANDIDATO SINTETICO
nnnn", os valores sao sorteados de um processo gerador conhecido (semente fixa) e
os resultados do modelo sobre eles nao dizem nada sobre eleicoes reais.

Processo gerador (resumo)
- "forca" latente do candidato ~ N(0,1) puxa gasto, capital politico e votos
  (e' a fonte de endogeneidade que o modelo real tambem enfrenta);
- adocao de impulsionamento cresce com a forca e com o ano (2022 > 2018);
- votos ~ binomial negativa tipo 2 (alpha = 1) com elasticidade do impulsionamento
  quadratica em log(gasto) (cresce com o gasto, como nos dados reais);
- os 30 mais votados de cada ano sao os "eleitos".

Uso:
    python gerar_paineis_sinteticos.py [--saida exemplos/paineis_sinteticos]
"""
import argparse
from pathlib import Path

import numpy as np
import pandas as pd

FATOR_DEFLACAO = {2018: 1.2555, 2022: 1.0000}   # precos de out/2022
N_CAND = {2018: 450, 2022: 632}
ASSENTOS = 30


def gera_ano(rng, ano):
    n = N_CAND[ano]
    forca = rng.normal(0, 1, n)
    masc = rng.binomial(1, 0.65, n)
    sup = rng.binomial(1, 0.55, n)
    branca = rng.binomial(1, 0.75, n)
    ideo = rng.choice(["esq", "dir", "centro"], size=n, p=[0.25, 0.40, 0.35])
    esquerda = (ideo == "esq").astype(int)
    direita = (ideo == "dir").astype(int)
    reel = rng.binomial(1, np.clip(0.03 + 0.05 * (forca > 1), 0, 1), n)

    # capital politico (log1p da votacao anterior; zero para quem nao disputou)
    l_mesmo = np.where(reel == 1, rng.normal(11.4, 0.6, n),
                       np.where(rng.random(n) < 0.06, rng.normal(9.0, 1.0, n), 0.0))
    l_estadual = np.where(rng.random(n) < 0.10, rng.normal(9.5, 1.0, n), 0.0)
    l_pref_ult = np.where(rng.random(n) < 0.04, rng.normal(9.5, 1.0, n), 0.0)
    l_pref_pen = np.where(rng.random(n) < 0.04, rng.normal(9.5, 1.0, n), 0.0)
    l_ver_ult = np.where(rng.random(n) < 0.08, rng.normal(7.5, 1.0, n), 0.0)

    d = 1.0 if ano == 2022 else 0.0
    # gastos em R$ de out/2022 (ja deflacionados)
    trad = np.exp(rng.normal(9.2 + 0.9 * forca, 1.5, n))
    trad[rng.random(n) < 0.15] = 0.0
    oper = np.exp(rng.normal(9.2 + 0.9 * forca, 1.5, n))
    oper[rng.random(n) < 0.10] = 0.0
    p_uso = 1 / (1 + np.exp(-(-0.6 + 0.9 * forca + 0.9 * d)))
    usa = rng.random(n) < p_uso
    imp = np.where(usa, np.exp(rng.normal(8.6 + 0.5 * forca + 0.3 * d, 1.5, n)), 0.0)
    imp = np.clip(imp, 0, 700_000)
    imp[usa & (imp < 100)] = 100.0                      # piso: lancamento minimo
    nao_class = np.where(rng.random(n) < 0.20, np.exp(rng.normal(6.0, 1.0, n)), 0.0)

    # votos: NB2 (gamma-Poisson), elasticidade quadratica do impulsionamento
    l_imp = np.log(np.where(usa, imp, 1.0))
    efeito_imp = np.where(usa, -0.42 * l_imp + 0.046 * l_imp ** 2 + 1.0, 0.0)
    eta = (3.0 - 1.0 * d + 0.10 * np.log1p(trad) + 0.10 * np.log1p(oper)
           + efeito_imp + 0.45 * reel + 0.55 * masc + 0.35 * sup + 0.15 * branca
           - 0.1 * esquerda + 0.25 * direita
           + 0.08 * l_mesmo + 0.06 * l_estadual + 0.03 * l_ver_ult
           + 0.9 * forca)
    mu = np.exp(eta)
    alpha = 1.0
    lam = rng.gamma(shape=1 / alpha, scale=mu * alpha)
    votos = rng.poisson(lam)

    ordem = np.argsort(-votos, kind="stable")
    eleito = np.zeros(n, dtype=int)
    eleito[ordem[:ASSENTOS]] = 1

    total = imp + trad + oper + nao_class
    nominal = total / FATOR_DEFLACAO[ano]
    idx = np.arange(1, n + 1)
    return pd.DataFrame({
        "sq": [f"SINT{ano}{i:04d}" for i in idx],
        "nome": [f"CANDIDATO SINTETICO {ano}-{i:04d}" for i in idx],
        "uf": "PR", "ano": ano, "cargo": "DEPUTADO FEDERAL",
        "partido": "PARTIDO_SINTETICO", "lista": "LISTA_SINTETICA", "cod_mun": "PR",
        "total_votos": votos, "eleito": eleito, "deferido": 1,
        "impulsionamento": imp.round(2), "tradicional": trad.round(2),
        "operacional": oper.round(2), "nao_classificado": nao_class.round(2),
        "gasto_total": total.round(2), "gasto_total_nominal": nominal.round(2),
        "reeleicao": reel,
        "l_votos_mesmo_cargo_ultima": l_mesmo.round(4),
        "l_votos_dep_estadual_ultima": l_estadual.round(4),
        "l_votos_prefeito_ultima": l_pref_ult.round(4),
        "l_votos_prefeito_penultima": l_pref_pen.round(4),
        "l_votos_vereador_ultima": l_ver_ult.round(4),
        "masculino": masc, "superior_completo": sup, "corbranca": branca,
        "esquerda": esquerda, "direita": direita,
    })


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--saida", default=str(Path(__file__).parent / "paineis_sinteticos"))
    ap.add_argument("--semente", type=int, default=2026)
    args = ap.parse_args()
    saida = Path(args.saida)
    saida.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(args.semente)
    for ano in (2018, 2022):
        df = gera_ano(rng, ano)
        arq = saida / f"painel_PR_{ano}_DEPUTADO_FEDERAL.csv"
        df.to_csv(arq, index=False)
        print(f"{arq.name}: {len(df)} candidatos, {int((df.impulsionamento > 0).sum())} usuarios "
              f"de impulsionamento, {int(df.eleito.sum())} eleitos")


if __name__ == "__main__":
    main()
