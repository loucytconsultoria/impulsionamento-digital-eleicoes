# -*- coding: utf-8 -*-
"""
comum.py - constantes e funcoes compartilhadas pelos scripts 01 a 05.

As formulas ficam num so lugar para que os scripts de curva e de faixa de
resultado reconstruam EXATAMENTE o mesmo desenho de matriz (inclusive os nos do
spline, memorizados pelo patsy a partir da mesma base de usuarios).

Caminhos: nenhum e' fixo no codigo. Cada script aceita --saida (pasta onde le e
grava os arquivos intermediarios; padrao ./saidas_elasticidade, ou a variavel de
ambiente ELASTICIDADE_SAIDA) e o 01_prep.py aceita --painel-dir (pasta com os
paineis tratados pelo pipeline em R, ou com os paineis sinteticos de exemplos/).
"""
import argparse
import os
from pathlib import Path

import numpy as np
import pandas as pd
import patsy

SAIDAS = Path(os.environ.get("ELASTICIDADE_SAIDA", "saidas_elasticidade"))

CAP = ["l_votos_mesmo_cargo_ultima", "l_votos_dep_estadual_ultima",
       "l_votos_prefeito_ultima", "l_votos_prefeito_penultima",
       "l_votos_vereador_ultima"]

CONTROLES_BASE = ("l_trad + l_oper + reeleicao + masculino + superior_completo"
                  " + corbranca + esquerda + direita + C(ano)")
CONTROLES_CAP = CONTROLES_BASE + " + " + " + ".join(CAP)

TERMOS = {
    "a_loglinear": "l_imp",
    "b_quadratica": "l_imp + I(l_imp**2)",
    "c_spline": "bs(l_imp, df=3)",
}
VARIANTES = {"com_cap": CONTROLES_CAP, "sem_cap": CONTROLES_BASE}

# Faixa de elasticidade de referencia (modelos log-linear de coeficiente unico,
# estimativas anteriores) e ponto de gasto em que ela e' comparada: mediana do
# gasto de impulsionamento de 2022 entre usuarios, em precos de 2018 (R$ 9.000 de
# out/2022 divididos pelo deflator 1,2611 do codigo original da monografia).
REF_PONTO_GASTO = 7136.63
REF_FAIXA = (0.23, 0.40)


def configura(descricao, painel=False):
    """Le a linha de comando, fixa a pasta de saida e a cria. Devolve os args."""
    global SAIDAS
    ap = argparse.ArgumentParser(description=descricao)
    ap.add_argument("--saida", default=str(SAIDAS),
                    help="pasta de arquivos intermediarios e resultados "
                         "(padrao: %(default)s)")
    if painel:
        ap.add_argument("--painel-dir", required=True,
                        help="pasta com painel_PR_2018_DEPUTADO_FEDERAL.csv e "
                             "painel_PR_2022_DEPUTADO_FEDERAL.csv")
    args = ap.parse_args()
    SAIDAS = Path(args.saida)
    SAIDAS.mkdir(parents=True, exist_ok=True)
    return args


def formula_de(spec_nome, var_nome):
    return f"total_votos ~ {TERMOS[spec_nome]} + {VARIANTES[var_nome]}"


def rhs_de(spec_nome, var_nome):
    return f"{TERMOS[spec_nome]} + {VARIANTES[var_nome]}"


def carrega_usuarios():
    return pd.read_csv(SAIDAS / "01_base_usuarios.csv")


def carrega_completa():
    return pd.read_csv(SAIDAS / "01_base_completa_deferidos.csv")


def custo_total_voto_eleitos(completa, ano=2022):
    """Custo total por voto do eleito tipico: media simples de gasto_total /
    total_votos entre os eleitos do ano com gasto positivo (todas as rubricas).
    E' a regua de sanidade da faixa de resultado."""
    e = completa[(completa["ano"] == ano) & (completa["eleito"] == 1)
                 & (completa["gasto_total"] > 0)]
    return float((e["gasto_total"] / e["total_votos"]).mean()), len(e)


def design_info(spec_nome, var_nome, usuarios):
    """Reconstroi o design patsy memorizado na base de usuarios."""
    dm = patsy.dmatrix(rhs_de(spec_nome, var_nome), data=usuarios,
                       return_type="dataframe")
    return dm.design_info


def matriz_para(novos_dados, dinfo):
    """Matriz de desenho para novos pontos, com os mesmos nos/codigos."""
    (m,) = patsy.build_design_matrices([dinfo], novos_dados,
                                       return_type="dataframe")
    return m


def salva_modelo(chave, params, cov):
    params.rename("coef").to_csv(
        SAIDAS / f"02_params_{chave}.csv",
        encoding="utf-8-sig", index_label="parametro")
    pd.DataFrame(np.asarray(cov), index=params.index,
                 columns=params.index).to_csv(
        SAIDAS / f"02_cov_{chave}.csv", encoding="utf-8-sig")


def carrega_modelo(chave):
    params = pd.read_csv(SAIDAS / f"02_params_{chave}.csv",
                         index_col=0)["coef"]
    cov = pd.read_csv(SAIDAS / f"02_cov_{chave}.csv", index_col=0)
    return params, cov
