# examples/policy_analysis.jl
#
# DME 短期政策分析系モデル比較デモ
# IS-LM / AD-AS / New Keynesian の代表的な使い方と使い分けを示す。
#
# 実行方法:
#   julia --project=. examples/policy_analysis.jl
#
# プロットを保存する場合は savefig 行のコメントを外す。

using DME

# ─────────────────────────────────────────────────────────────────
# モデルの使い分け
# ─────────────────────────────────────────────────────────────────
#
# IS-LM モデル
#   問い: 「財政政策・金融政策は産出 Y と利子率 r にどう影響するか？」
#   仮定: 物価水準 P は固定（短期の静学モデル）。
#   変数: Y（産出）, r（利子率）, C（消費）, I（投資）
#   適用: 需要管理政策の定量効果・クラウディングアウトの有無を把握したい場合。
#
# AD-AS モデル
#   問い: 「財政・金融ショックは産出と物価の両方にどう影響するか？」
#   仮定: 物価 P は内生変数（SRAS 曲線で決定）。
#   変数: Y（産出）, P（物価）, r（利子率）, C（消費）, I（投資）
#   適用: 需要ショック vs 供給ショックの区別、スタグフレーション分析。
#
# New Keynesian モデル
#   問い: 「合理的期待・Taylor rule のもとで、ショックはインフレと産出ギャップを
#           どう動かすか？ 中央銀行の反応係数が結果を変えるか？」
#   仮定: 前向き合理的期待、IS 曲線・NKPC・Taylor rule の 3 方程式体系。
#   変数: x（産出ギャップ）, π（インフレ率偏差）, i（名目利子率偏差）
#   適用: インフレ動学・金融政策ルールの設計・トレードオフの定量評価。
#
# 同じ「金融政策」「需要ショック」でもモデルが変わると何が変わるか
#   IS-LM   : M 増加 → r 低下 → I 増加 → Y 増加（P は固定）
#   AD-AS   : M 増加 → AD 右シフト → Y 増加 + P 上昇（クラウディングアウト緩和）
#   NK      : 中央銀行が名目利子率を下げる → 産出ギャップ拡大 + インフレ上昇
#              （Taylor principle: φ_π > 1 が安定条件）
#
# ─────────────────────────────────────────────────────────────────


# ─────────────────────────────────────────────────────────────────
# 1. IS-LM モデル
# ─────────────────────────────────────────────────────────────────
#
# パラメータ設定
#   c0=100: 自律消費, c1=0.8: MPC, I0=200: 自律投資, b=50: 投資の利子率感応度
#   G=100, T=100: 基準財政, l1=0.2: 貨幣需要の所得感応度, l2=100: 利子率感応度
#   M=1000: マネーサプライ, P=1.0: 物価水準（固定）

islm_base = ISLMModel(100.0, 0.8, 200.0, 50.0, 100.0, 100.0, 0.2, 100.0, 1000.0, 1.0)

eq_base = steady_state(islm_base)
println("=== IS-LM: ベースライン均衡 ===")
println("  Y* = $(round(eq_base.Y, digits=2))")
println("  r* = $(round(eq_base.r, digits=4))")
println("  C* = $(round(eq_base.C, digits=2))")
println("  I* = $(round(eq_base.I, digits=2))")

# ── 1a. 財政政策ショック: 政府支出 G = 100 → 150（+50）
# 乗数効果: Y は増えるが、利子率 r も上昇してクラウディングアウトが発生する。

islm_fiscal = ISLMModel(100.0, 0.8, 200.0, 50.0, 150.0, 100.0, 0.2, 100.0, 1000.0, 1.0)
sr_islm_fiscal = DME.islm_policy_shock(
    islm_base, islm_fiscal;
    scenario_names = ("baseline", "fiscal_expansion"),
)

println("\n=== IS-LM: 財政拡張（ΔG = +50）===")
ΔY_fiscal = sr_islm_fiscal["Y"][2] - sr_islm_fiscal["Y"][1]
Δr_fiscal = sr_islm_fiscal["r"][2] - sr_islm_fiscal["r"][1]
println("  ΔY = $(round(ΔY_fiscal, digits=2))  (クラウディングアウト後)")
println("  Δr = $(round(Δr_fiscal, digits=4))  (利子率上昇)")
println("  乗数 = $(round(ΔY_fiscal / 50.0, digits=3))  (純粋乗数 = 1/(1-c1) = 5.0 から低下)")

# ── 1b. 金融政策ショック: マネーサプライ M = 1000 → 1200（+200）
# LM 曲線が下方シフト → r 低下 → Y 増加。P が固定なので実質効果が直接現れる。

islm_monetary = ISLMModel(100.0, 0.8, 200.0, 50.0, 100.0, 100.0, 0.2, 100.0, 1200.0, 1.0)
sr_islm_monetary = DME.islm_policy_shock(
    islm_base, islm_monetary;
    scenario_names = ("baseline", "monetary_expansion"),
)

println("\n=== IS-LM: 金融緩和（ΔM = +200）===")
ΔY_mon = sr_islm_monetary["Y"][2] - sr_islm_monetary["Y"][1]
Δr_mon = sr_islm_monetary["r"][2] - sr_islm_monetary["r"][1]
println("  ΔY = $(round(ΔY_mon, digits=2))")
println("  Δr = $(round(Δr_mon, digits=4))  (利子率低下)")

# IS-LM 財政 vs 金融の産出変化を比較
p_islm_cmp = plot_comparison(
    [sr_islm_fiscal, sr_islm_monetary];
    var = "Y",
    labels = ["財政拡張 (ΔG=+50)", "金融緩和 (ΔM=+200)"],
    title = "IS-LM: 財政政策 vs 金融政策（産出 Y）",
    xlabel = "シナリオ",
    ylabel = "産出 Y",
)
# savefig(p_islm_cmp, "islm_policy_comparison.png")

# 財政政策の全変数を可視化
p_islm_fiscal = plot_result(
    sr_islm_fiscal;
    vars = ["Y", "r", "C", "I"],
    title = "IS-LM: 財政拡張（ΔG = +50）",
    xlabel = "シナリオ (1=baseline, 2=fiscal)",
)
# savefig(p_islm_fiscal, "islm_fiscal.png")


# ─────────────────────────────────────────────────────────────────
# 2. AD-AS モデル
# ─────────────────────────────────────────────────────────────────
#
# IS-LM と同じ需要側パラメータに加えて、供給側を追加:
#   Y_n=1500: 潜在産出, v=500: SRAS 傾き（価格感応度）, P_e=1.0: 期待物価

adas_base = ADASModel(100.0, 0.8, 200.0, 50.0, 100.0, 100.0, 0.2, 100.0, 300.0,
                      1500.0, 500.0, 1.0)

eq_adas = steady_state(adas_base)
println("\n=== AD-AS: ベースライン均衡 ===")
println("  Y* = $(round(eq_adas.Y, digits=2))")
println("  P* = $(round(eq_adas.P, digits=4))")
println("  r* = $(round(eq_adas.r, digits=4))")

# ── 2a. 需要ショック: 政府支出 G = 100 → 150（+50）
# IS-LM と同じ財政拡張だが、AD-AS では P が内生的に上昇する。
# P 上昇 → 実質貨幣供給 M/P 減少 → r 上昇 → 投資減少（追加クラウディングアウト）
# 結果: IS-LM より Y の増加幅が小さく、かつ P が上昇する。

adas_demand = ADASModel(100.0, 0.8, 200.0, 50.0, 150.0, 100.0, 0.2, 100.0, 300.0,
                        1500.0, 500.0, 1.0)
sr_adas_demand = DME.adas_shock_compare(
    adas_base, adas_demand;
    scenario_names = ("baseline", "demand_shock"),
)

println("\n=== AD-AS: 需要ショック（ΔG = +50）===")
ΔY_ad = sr_adas_demand["Y"][2] - sr_adas_demand["Y"][1]
ΔP_ad = sr_adas_demand["P"][2] - sr_adas_demand["P"][1]
println("  ΔY = $(round(ΔY_ad, digits=2))  ← IS-LM より小さい（P 上昇で需要が一部相殺）")
println("  ΔP = $(round(ΔP_ad, digits=4))  ← 物価が上昇")

# ── 2b. 供給ショック: 潜在産出 Y_n = 1500 → 1200（−300）
# SRAS 曲線の左シフト → Y 減少 + P 上昇（スタグフレーション型）
# 需要ショックとは異なり、Y と P が逆方向に動く点がポイント。

adas_supply = ADASModel(100.0, 0.8, 200.0, 50.0, 100.0, 100.0, 0.2, 100.0, 300.0,
                        1200.0, 500.0, 1.0)
sr_adas_supply = DME.adas_shock_compare(
    adas_base, adas_supply;
    scenario_names = ("baseline", "supply_shock"),
)

println("\n=== AD-AS: 供給ショック（ΔY_n = −300）===")
ΔY_as = sr_adas_supply["Y"][2] - sr_adas_supply["Y"][1]
ΔP_as = sr_adas_supply["P"][2] - sr_adas_supply["P"][1]
println("  ΔY = $(round(ΔY_as, digits=2))  ← 産出減少（スタグフレーション型）")
println("  ΔP = $(round(ΔP_as, digits=4))  ← 物価上昇（需要ショックと同方向）")
println("  ※ Y と P の動きが「需要ショック」とは逆 → 識別の手がかり")

# 需要 vs 供給ショックの物価比較
p_adas_P = plot_comparison(
    [sr_adas_demand, sr_adas_supply];
    var = "P",
    labels = ["需要ショック (ΔG=+50)", "供給ショック (ΔY_n=−300)"],
    title = "AD-AS: 物価水準の比較（需要 vs 供給ショック）",
    xlabel = "シナリオ",
    ylabel = "物価水準 P",
)
# savefig(p_adas_P, "adas_price_comparison.png")

# 産出 vs 物価で AD-AS 均衡を可視化
p_adas_demand = plot_result(
    sr_adas_demand;
    vars = ["Y", "P"],
    title = "AD-AS: 需要ショック（ΔG = +50）",
    xlabel = "シナリオ (1=baseline, 2=demand)",
)
# savefig(p_adas_demand, "adas_demand_shock.png")


# ─────────────────────────────────────────────────────────────────
# 3. New Keynesian モデル
# ─────────────────────────────────────────────────────────────────
#
# 3 方程式 NK モデル（線形化, 定常状態からの乖離）
#   σ=1.0: 異時点間代替弾力性, r_n=0.02: 自然利子率
#   β=0.99: 割引因子, κ=0.1: NKPC 傾き
#   φ_π=1.5: インフレ反応（Taylor principle: φ_π > 1）, φ_x=0.5: 産出ギャップ反応
#   π_star=0.02: インフレ目標, ρ_x=0.8: 需要持続性, ρ_c=0.5: コストプッシュ持続性
#   ρ_m=0.5: 金融政策ショック持続性

nk = NewKeynesianModel(1.0, 0.02, 0.99, 0.1, 1.5, 0.5, 0.02, 0.8, 0.5, 0.5)

ss_nk = steady_state(nk)
println("\n=== New Keynesian: 定常状態 ===")
println("  x*  = $(ss_nk.x)   （産出ギャップ = 0）")
println("  π*  = $(ss_nk.π)   （インフレ目標）")
println("  i*  = $(round(ss_nk.i, digits=4))  （自然利子率 + インフレ目標）")

# ── 3a. 需要ショック IRF（IS 曲線への正のショック, ε₀ = 1%）
# 産出ギャップ x と π が同方向に上昇（IS-LM の ΔY と類似）。
# 中央銀行は i を引き上げ（Taylor rule）、持続性 ρ_x に応じて収束する。

irf_demand = impulse_response(nk, 1.0; shock = :demand, T = 20)
sr_nk_demand = to_simulation_result(nk, irf_demand, "demand_shock")

println("\n=== NK: 需要ショック IRF（初期応答）===")
println("  x[1]  = $(round(irf_demand.x[1], digits=4))   （産出ギャップ, 定常状態からの乖離）")
println("  π[1]  = $(round(irf_demand.π[1], digits=4))   （インフレ率乖離）")
println("  i[1]  = $(round(irf_demand.i[1], digits=4))   （名目利子率乖離）")

# ── 3b. コストプッシュショック IRF（NKPC への正のショック, ε₀ = 1%）
# x と π が逆方向に動く（スタグフレーション的トレードオフ）。
# 物価安定か景気安定かの政策トレードオフが生じる。

irf_cost = impulse_response(nk, 1.0; shock = :cost_push, T = 20)
sr_nk_cost = to_simulation_result(nk, irf_cost, "cost_push_shock")

println("\n=== NK: コストプッシュショック IRF（初期応答）===")
println("  x[1]  = $(round(irf_cost.x[1], digits=4))   ← 産出ギャップ減少（AD-AS 供給ショックと対応）")
println("  π[1]  = $(round(irf_cost.π[1], digits=4))   ← インフレ上昇（同上）")
println("  i[1]  = $(round(irf_cost.i[1], digits=4))   ← CBは引き締めで反応")

# ── 3c. 金融政策ショック IRF（予期せぬ利上げ, ε₀ = 1%）
# 名目利子率が突然上昇 → 実質金利上昇 → x 減少 + π 低下。
# IS-LM の「M 減少による r 上昇」の前向き期待版。

irf_monetary = impulse_response(nk, 1.0; shock = :monetary, T = 20)
sr_nk_monetary = to_simulation_result(nk, irf_monetary, "monetary_shock")

println("\n=== NK: 金融政策ショック IRF（予期せぬ利上げ）===")
println("  x[1]  = $(round(irf_monetary.x[1], digits=4))   ← 産出ギャップ減少")
println("  π[1]  = $(round(irf_monetary.π[1], digits=4))   ← インフレ低下")
println("  i[1]  = $(round(irf_monetary.i[1], digits=4))   ← 名目利子率上昇（ショック直撃）")

# 3 ショックのインフレ応答を比較
p_nk_pi = plot_comparison(
    [sr_nk_demand, sr_nk_cost, sr_nk_monetary];
    var = "π",
    labels = ["需要ショック", "コストプッシュ", "金融政策（利上げ）"],
    title = "NK: ショック種別によるインフレ応答の比較",
    ylabel = "インフレ率乖離 π̃",
)
# savefig(p_nk_pi, "nk_inflation_comparison.png")

# 3 ショックの産出ギャップ応答を比較
p_nk_x = plot_comparison(
    [sr_nk_demand, sr_nk_cost, sr_nk_monetary];
    var = "x",
    labels = ["需要ショック", "コストプッシュ", "金融政策（利上げ）"],
    title = "NK: ショック種別による産出ギャップ応答の比較",
    ylabel = "産出ギャップ x̃",
)
# savefig(p_nk_x, "nk_output_comparison.png")

# ── 3d. Taylor rule 設計の影響: ハト派 vs タカ派
# コストプッシュショックへの対応を題材にする。
# ハト派（φ_π=1.2）: インフレ反応小 → x の犠牲が小さいが π は長引く
# タカ派（φ_π=2.5）: インフレ反応大 → π を素早く抑えるが x の落ち込みが大きい

nk_dove = NewKeynesianModel(1.0, 0.02, 0.99, 0.1, 1.2, 0.5, 0.02, 0.8, 0.5, 0.5)
nk_hawk = NewKeynesianModel(1.0, 0.02, 0.99, 0.1, 2.5, 0.5, 0.02, 0.8, 0.5, 0.5)

sr_taylor_cmp = DME.nk_irf_compare(
    nk_dove, nk_hawk;
    shock = :cost_push,
    shock_size = 1.0,
    T = 20,
    scenario_names = ("dovish φ_π=1.2", "hawkish φ_π=2.5"),
)

println("\n=== NK: Taylor rule 設計（コストプッシュへの応答比較）===")
println("  ハト派 π[1] = $(round(sr_taylor_cmp["π_base"][1], digits=4))" *
        "  x[1] = $(round(sr_taylor_cmp["x_base"][1], digits=4))")
println("  タカ派 π[1] = $(round(sr_taylor_cmp["π_alt"][1], digits=4))" *
        "  x[1] = $(round(sr_taylor_cmp["x_alt"][1], digits=4))")
println("  ※ タカ派はインフレを抑えるが産出ギャップの犠牲が大きい（ sacrifice ratio）")

# ハト派 vs タカ派: インフレの比較
p_taylor_pi = plot_irf(
    sr_taylor_cmp;
    vars = ["π_base", "π_alt"],
    title = "NK: ハト派 vs タカ派 — コストプッシュへのインフレ応答",
    ylabel = "インフレ率乖離 π̃",
)
# savefig(p_taylor_pi, "nk_taylor_inflation.png")

# ハト派 vs タカ派: 産出ギャップの比較
p_taylor_x = plot_irf(
    sr_taylor_cmp;
    vars = ["x_base", "x_alt"],
    title = "NK: ハト派 vs タカ派 — コストプッシュへの産出ギャップ応答",
    ylabel = "産出ギャップ x̃",
)
# savefig(p_taylor_x, "nk_taylor_output.png")

# 全変数の IRF（需要ショック）を可視化
p_nk_irf = plot_irf(
    sr_nk_demand;
    vars = ["x", "π", "i"],
    title = "NK: 需要ショック IRF（x, π, i）",
)
# savefig(p_nk_irf, "nk_demand_irf.png")


# ─────────────────────────────────────────────────────────────────
# 生成されたプロット変数の一覧
# ─────────────────────────────────────────────────────────────────
println("\n=== 生成されたプロット ===")
println("  p_islm_cmp    : IS-LM 財政 vs 金融政策（産出 Y）")
println("  p_islm_fiscal : IS-LM 財政拡張（Y, r, C, I）")
println("  p_adas_P      : AD-AS 需要 vs 供給ショック（物価 P）")
println("  p_adas_demand : AD-AS 需要ショック（Y, P）")
println("  p_nk_pi       : NK ショック種別インフレ応答比較")
println("  p_nk_x        : NK ショック種別産出ギャップ応答比較")
println("  p_taylor_pi   : NK ハト派 vs タカ派インフレ応答")
println("  p_taylor_x    : NK ハト派 vs タカ派産出ギャップ応答")
println("  p_nk_irf      : NK 需要ショック IRF（x, π, i）")
println("\nプロットを保存する場合: savefig(p_islm_cmp, \"islm_policy_comparison.png\") など")
