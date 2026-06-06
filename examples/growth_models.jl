# examples/growth_models.jl
#
# DME 長期成長系モデル比較デモ
# Ramsey / RBC / Solow の代表的な使い方と使い分けを示す。
#
# 実行方法:
#   julia --project=. examples/growth_models.jl
#
# プロットを保存する場合は savefig 行のコメントを外す。

using DME

# ─────────────────────────────────────────────────────────────────
# モデルの使い分け
# ─────────────────────────────────────────────────────────────────
#
# Ramsey モデル
#   問い: 「最適貯蓄を行う家計の世界で、定常状態と移行経路はどうなるか？」
#   特徴: 内生的な消費・貯蓄決定、完全予見、外生ショックなし。
#   適用: 定常状態の資本水準、定常状態への収束速度を分析したい場合。
#
# RBC モデル（Real Business Cycle）
#   問い: 「技術ショックはどのようにマクロ変数を動かすか？」
#   特徴: 確率的な技術水準、内生的な労働供給、線形化（Blanchard-Kahn 法）。
#   適用: 景気変動・短期ダイナミクスのインパルス応答を定量評価したい場合。
#
# Solow モデル
#   問い: 「貯蓄率・人口成長・技術進歩は長期の生活水準にどう影響するか？」
#   特徴: 外生的な貯蓄率、最適化なし、解析的な定常状態解。
#   適用: 黄金律・パラメータ比較静学・長期収束経路を直感的に把握したい場合。
#
# ─────────────────────────────────────────────────────────────────


# ─────────────────────────────────────────────────────────────────
# 1. Ramsey モデル
# ─────────────────────────────────────────────────────────────────

rams = RamseyModel(0.3, 0.99, 0.25)  # α=0.3, β=0.99, δ=0.25

# 定常状態（解析解）
ep_rams = steady_state(rams)
println("=== Ramsey: 定常状態 ===")
println("  K* = $(round(ep_rams.K, digits=4))")
println("  C* = $(round(ep_rams.C, digits=4))")

# 完全予見経路: K0 = K*/2 から定常状態への移行を数値的に解く
path_rams = transition_path(rams, ep_rams.K / 2)  # maxT=30（デフォルト）

# SimulationResult に変換して汎用的な後処理 API を使う
sr_rams = to_simulation_result(rams, path_rams, "transition_path")
println("  変数: $(sort(variable_names(sr_rams)))")
println("  期間数: $(nperiods(sr_rams))")

# 移行経路のサマリー（期末値が定常状態に収束しているか確認）
summary_rams = summarize_result(sr_rams)
println("  K: 初期=$(round(summary_rams["variables"]["K"].initial, digits=4)), " *
        "終端=$(round(summary_rams["variables"]["K"].final, digits=4)) ≈ K*")

# プロット: 資本と消費の移行経路
p_rams = plot_result(sr_rams; vars=["K", "C"], title="Ramsey モデル: 移行経路（K₀ = K*/2）",
                     xlabel="Period", ylabel="Level")
# savefig(p_rams, "ramsey_transition.png")


# ─────────────────────────────────────────────────────────────────
# 2. RBC モデル
# ─────────────────────────────────────────────────────────────────

rbc = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)  # α, β, γ, δ, μ, ρ

# 定常状態
ep_rbc = steady_state(rbc)
println("\n=== RBC: 定常状態 ===")
println("  K* = $(round(ep_rbc.K, digits=4))")
println("  Y* = $(round(ep_rbc.Y, digits=4))")
println("  C* = $(round(ep_rbc.C, digits=4))")
println("  L* = $(round(ep_rbc.L, digits=4))")

# 技術ショック（ε₀ = 1%）のインパルス応答
# 返り値は定常状態からの対数偏差（hat 変数）
irf = impulse_response(rbc, 0.01)
sr_irf = to_simulation_result(rbc, irf, "technology_shock")

# metadata にショックサイズを付与するとプロットタイトルに反映される
sr_irf = SimulationResult(
    sr_irf.model_name, sr_irf.scenario_name, sr_irf.variables,
    Dict{String,Any}("parameters" => parameters(rbc), "shock_size" => 0.01),
)

println("\n=== RBC: 技術ショック IRF サマリー ===")
summary_irf = summarize_result(sr_irf)
for var in ["ŷ", "ĉ", "k̂"]
    s = summary_irf["variables"][var]
    println("  $var: peak=$(round(s.peak_response, digits=5)) (t=$(s.argmax-1)), " *
            "符号反転=$(s.sign_reversal)")
end

# IRF プロット: ゼロライン（基準線）付き。t=0 がショック発生時点。
p_irf = plot_irf(sr_irf; vars=["ŷ", "ĉ", "k̂"],
                 title="RBC モデル: 技術ショック IRF（ε₀ = 1%）")
# savefig(p_irf, "rbc_irf.png")

# ショックサイズの比較: 1% vs 2%
sr_shock1 = to_simulation_result(rbc, impulse_response(rbc, 0.01), "shock_1pct")
sr_shock2 = to_simulation_result(rbc, impulse_response(rbc, 0.02), "shock_2pct")

p_cmp_rbc = plot_comparison(
    [sr_shock1, sr_shock2];
    var="ŷ",
    labels=["技術ショック 1%", "技術ショック 2%"],
    title="RBC: ショック規模の比較（産出 ŷ）",
    ylabel="Log deviation from SS",
)
# savefig(p_cmp_rbc, "rbc_shock_comparison.png")


# ─────────────────────────────────────────────────────────────────
# 3. Solow モデル
# ─────────────────────────────────────────────────────────────────

solow = SolowModel(0.3, 0.2, 0.1, 0.01, 0.02)  # α=0.3, s=0.2, δ=0.1, n=0.01, g=0.02

# 定常状態（解析解: 効率労働単位あたり）
ep_solow = steady_state(solow)
println("\n=== Solow: 定常状態（効率労働単位あたり）===")
println("  k* = $(round(ep_solow.k, digits=4))")
println("  y* = $(round(ep_solow.y, digits=4))")
println("  c* = $(round(ep_solow.c, digits=4))")

# 収束経路: k0 = k*/2（資本不足）から T=100 期の前向き反復
path_solow = transition_path(solow, ep_solow.k / 2; T=100)
sr_solow = to_simulation_result(solow, path_solow, "convergence_from_below")

println("  変数: $(sort(variable_names(sr_solow)))")
println("  期末 k = $(round(sr_solow["k"][end], digits=4)) ≈ k*")

# 収束経路のプロット
p_solow = plot_result(sr_solow; vars=["k", "y", "c"],
                      title="Solow モデル: 収束経路（k₀ = k*/2）",
                      xlabel="Period", ylabel="効率労働単位あたり")
# savefig(p_solow, "solow_convergence.png")

# 異なる初期値からの収束を比較（k* より低い vs 高い）
sr_below = to_simulation_result(solow,
    transition_path(solow, ep_solow.k / 2; T=100), "k₀ = k*/2 (低資本)")
sr_above = to_simulation_result(solow,
    transition_path(solow, ep_solow.k * 2.0; T=100), "k₀ = 2k* (高資本)")

p_cmp_solow = plot_comparison(
    [sr_below, sr_above];
    var="k",
    title="Solow: 異なる初期資本からの収束",
    ylabel="資本 k（効率労働単位あたり）",
)
# savefig(p_cmp_solow, "solow_convergence_comparison.png")


# ─────────────────────────────────────────────────────────────────
# 生成されたプロット変数の一覧
# ─────────────────────────────────────────────────────────────────
println("\n=== 生成されたプロット ===")
println("  p_rams      : Ramsey 移行経路（K, C）")
println("  p_irf       : RBC 技術ショック IRF（ŷ, ĉ, k̂）")
println("  p_cmp_rbc   : RBC ショック規模比較（産出 ŷ）")
println("  p_solow     : Solow 収束経路（k, y, c）")
println("  p_cmp_solow : Solow 初期資本比較")
println("\nプロットを保存する場合: savefig(p_rams, \"ramsey_transition.png\") など")
