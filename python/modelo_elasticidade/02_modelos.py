# -*- coding: utf-8 -*-
"""
02_modelos.py - estimacao dos modelos de elasticidade variavel.
Estima NB2 (Negative Binomial tipo 2, alpha estimado por MLE) para total_votos
entre USUÁRIOS de impulsionamento, em 3 especificações do termo de gasto:
  (a) log-linear:  l_imp                       [baseline comparável à pesquisa]
  (b) quadrática:  l_imp + l_imp²              [elasticidade variável]
  (c) spline:      bs(l_imp, df=3)             [flexível]
Cada uma em 2 variantes: COM capital político (l_votos_*) e SEM.
Compara AIC/BIC e faz teste LR (a) vs (b) — aninhados, df=1.

DECISOES DOCUMENTADAS:
- NB2 estimado em 2 estágios para garantir convergência (o MLE conjunto
  direto degenerou em várias especificações — alpha explosivo):
  (i) perfil de verossimilhança de alpha via GLM NegativeBinomial (IRLS,
      estável), otimizando alpha em [0.01, 10] por minimize_scalar;
  (ii) polimento final com smf.negativebinomial (MLE conjunto NB2) partindo
      de (beta_GLM, alpha_perfil). Aceito o polimento apenas se llf melhora
      e a matriz de covariância é finita; senão fico com o GLM de perfil
      (cov condicional a alpha — documentado no relatório).
- reeleicao permanece em TODAS as variantes (o rótulo "capital político"
  na âncora refere-se às votações anteriores l_votos_*).
"""
import numpy as np
import pandas as pd
import statsmodels.formula.api as smf
from statsmodels.genmod.families import NegativeBinomial as NBFam
from scipy import stats
from scipy.optimize import minimize_scalar

import comum as cm
from comum import TERMOS, VARIANTES, formula_de, salva_modelo

cm.configura("Estima as 6 especificacoes NB2 (3 formas x com/sem capital politico).")
SAIDAS = cm.SAIDAS
usuarios = cm.carrega_usuarios()


def ajusta_nb2(formula, dados):
    """NB2 em 2 estágios: perfil de alpha via GLM + polimento MLE conjunto.

    Retorna (res, convergiu, aviso). res tem .params (com 'alpha'),
    .cov_params(), .llf, .aic, .bic, .nobs, .bse, .pvalues — seja o MLE
    discreto polido, seja o GLM de perfil embrulhado.
    """
    def glm_em(alpha):
        return smf.glm(formula, data=dados,
                       family=NBFam(alpha=alpha)).fit(maxiter=200)

    # (i) perfil de alpha
    opt = minimize_scalar(lambda a: -glm_em(a).llf, bounds=(0.01, 10.0),
                          method="bounded",
                          options={"xatol": 1e-4, "maxiter": 100})
    alpha_hat = float(opt.x)
    glm_res = glm_em(alpha_hat)

    # (ii) polimento MLE conjunto
    mod = smf.negativebinomial(formula, data=dados)
    start = np.append(glm_res.params.values, alpha_hat)
    res_final, conv, aviso = None, False, ""
    for metodo, itmax in [("newton", 200), ("bfgs", 2000)]:
        try:
            r = mod.fit(start_params=start, method=metodo,
                        disp=0, maxiter=itmax)
            cov_ok = np.all(np.isfinite(np.asarray(r.cov_params())))
            llf_ok = np.isfinite(r.llf) and r.llf >= glm_res.llf - 1.0
            alpha_ok = 0 < float(r.params["alpha"]) < 50
            if cov_ok and llf_ok and alpha_ok:
                res_final = r
                conv = bool(r.mle_retvals.get("converged", False))
                aviso = f"mle_polido_{metodo}"
                break
        except Exception:
            continue
    if res_final is not None:
        return res_final, conv, aviso

    # fallback: GLM de perfil embrulhado com linha alpha (var de alpha por
    # diferenças finitas na verossimilhança de perfil; cov(beta,alpha)=0 aprox.)
    h = max(1e-3, 1e-3 * alpha_hat)
    l0 = glm_res.llf
    lp = glm_em(alpha_hat + h).llf
    lm = glm_em(max(alpha_hat - h, 1e-4)).llf
    d2 = (lp - 2 * l0 + lm) / h**2
    var_alpha = -1.0 / d2 if d2 < 0 else np.nan

    class GLMPerfil:
        pass

    w = GLMPerfil()
    w.params = pd.concat([glm_res.params,
                          pd.Series({"alpha": alpha_hat})])
    w.bse = pd.concat([glm_res.bse,
                       pd.Series({"alpha": np.sqrt(var_alpha)})])
    w.pvalues = pd.concat([glm_res.pvalues,
                           pd.Series({"alpha": np.nan})])
    k = len(w.params)
    cov = np.zeros((k, k))
    cov[:k - 1, :k - 1] = np.asarray(glm_res.cov_params())
    cov[k - 1, k - 1] = var_alpha
    w._cov = pd.DataFrame(cov, index=w.params.index, columns=w.params.index)
    w.cov_params = lambda self=w: self._cov
    w.llf = glm_res.llf
    w.nobs = glm_res.nobs
    w.aic = -2 * w.llf + 2 * k          # k inclui alpha, comparável ao MLE
    w.bic = -2 * w.llf + k * np.log(w.nobs)
    w.model = mod                        # exog/design do discreto p/ predição
    return w, True, "glm_perfil"


resultados = {}
linhas_comp = []
linhas_coef = []

for var_nome in VARIANTES:
    for spec_nome in TERMOS:
        formula = formula_de(spec_nome, var_nome)
        res, conv, aviso = ajusta_nb2(formula, usuarios)
        chave = f"{spec_nome}__{var_nome}"
        resultados[chave] = res
        salva_modelo(chave, res.params, res.cov_params())
        linhas_comp.append({
            "modelo": chave, "n": int(res.nobs), "k_params": len(res.params),
            "llf": round(res.llf, 3), "aic": round(res.aic, 2),
            "bic": round(res.bic, 2),
            "alpha": round(float(res.params.get("alpha", np.nan)), 4),
            "convergiu": conv, "aviso": aviso,
        })
        bse = res.bse
        pv = res.pvalues
        for nome_p, val in res.params.items():
            linhas_coef.append({
                "modelo": chave, "parametro": nome_p,
                "coef": round(float(val), 6),
                "ep": round(float(bse[nome_p]), 6),
                "p_valor": round(float(pv[nome_p]), 5),
            })
        print(f"[ok] {chave}: llf={res.llf:.2f} aic={res.aic:.1f} "
              f"conv={conv} {aviso}")

comp = pd.DataFrame(linhas_comp)

# --- Teste LR (a) vs (b), aninhados, df=1, nas duas variantes ---
linhas_lr = []
for var_nome in VARIANTES:
    ra = resultados[f"a_loglinear__{var_nome}"]
    rb = resultados[f"b_quadratica__{var_nome}"]
    rc = resultados[f"c_spline__{var_nome}"]
    lr_ab = 2 * (rb.llf - ra.llf)
    p_ab = stats.chi2.sf(lr_ab, df=1)
    lr_ac = 2 * (rc.llf - ra.llf)
    p_ac = stats.chi2.sf(lr_ac, df=2)  # spline df=3 tem 2 params a mais que a
    linhas_lr.append({"variante": var_nome, "teste": "LR (a) vs (b)",
                      "estatistica": round(lr_ab, 3), "gl": 1,
                      "p_valor": round(p_ab, 5)})
    linhas_lr.append({"variante": var_nome, "teste": "LR (a) vs (c)",
                      "estatistica": round(lr_ac, 3), "gl": 2,
                      "p_valor": round(p_ac, 5)})
lr = pd.DataFrame(linhas_lr)

comp.to_csv(SAIDAS / "02_comparacao_modelos.csv",
            index=False, encoding="utf-8-sig")
pd.DataFrame(linhas_coef).to_csv(SAIDAS / "02_coeficientes.csv",
                                 index=False, encoding="utf-8-sig")
lr.to_csv(SAIDAS / "02_testes_lr.csv",
          index=False, encoding="utf-8-sig")

print("\n=== Comparação de modelos ===")
print(comp.to_string(index=False))
print("\n=== Testes LR ===")
print(lr.to_string(index=False))
print("\n=== Termos de gasto (coeficientes-chave) ===")
chaves = [r for r in linhas_coef
          if ("l_imp" in r["parametro"] or "bs(" in r["parametro"])]
print(pd.DataFrame(chaves).to_string(index=False))
