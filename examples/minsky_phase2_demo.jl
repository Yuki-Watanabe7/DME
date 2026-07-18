# examples/minsky_phase2_demo.jl
#
# Minsky 資金調達区分・金融不安定性診断 統合デモ（Phase 2, Issue #114）
#
# Keen モデルの2つのシナリオ（良い均衡への回帰経路・高債務からの崩壊経路）について、
# 資金調達区分診断（#112）・金融不安定性連続診断指標とサマリー（#113）・
# 可視化（regime timeline / diagnostics plot / scenario比較, #114）を一通り実行する。
#
# 実行方法:
#   julia --project=. examples/minsky_phase2_demo.jl
#
# 外部 API キーや実データは不要。固定パラメータ・固定初期値で決定的に実行できる。
# プロットを保存したい場合は savefig 行を有効化。
#
# 関連デモ:
#   モデル横断デモ → examples/model_overview_demo.jl
#   詳細解説       → docs/models/keen.md
#                     docs/models/minsky_regime_diagnostics.md
#                     docs/models/minsky_diagnostics_summary.md

using DME

println("""
╔═══════════════════════════════════════════════════════════════╗
║   Minsky Phase 2 統合デモ — 資金調達区分・金融不安定性診断     ║
╚═══════════════════════════════════════════════════════════════╝

Keen モデルの2シナリオを比較し、「好況の内生的崩壊」が資金調達区分
（Hedge → Speculative → Ponzi）の悪化としてどう表れるかを確認する。

  Step 1  KeenModel の作成と良い均衡の確認
  Step 2  baseline シナリオ（微小攪乱 → 良い均衡へ回帰）
  Step 3  high_debt シナリオ（高初期債務 → 崩壊経路）
  Step 4  資金調達区分診断（Financing Regime Diagnostics）
  Step 5  金融不安定性連続診断指標とサマリー
  Step 6  regime timeline / diagnostics plot の生成
  Step 7  シナリオ比較
  Step 8  主要サマリーの表示

注意: Hedge/Speculative/Ponzi はモデル集計量から導かれる代理診断であり、
実測の企業比率・倒産予測・危機予測ではない（docs/models/keen.md §9 参照）。
""")

# ─────────────────────────────────────────────────────────────────
# Step 1  KeenModel の作成と良い均衡の確認
# ─────────────────────────────────────────────────────────────────
println("=" ^ 60)
println("Step 1  KeenModel の作成 — Grasselli & Costa Lima (2012) 数値例")
println("=" ^ 60)

m = KeenModel(0.025, 0.02, 0.01, 3.0, 0.03, 0.0400641, 6.41e-5, -0.0065, exp(-5), 20.0)
println("モデル: $(model_name(m))")
println("状態変数: $(state_variables(m))")

ss = steady_state(m)
println("\n[良い均衡]")
println(
    "  ω̄ = $(round(ss.ω, digits=4))  λ̄ = $(round(ss.λ, digits=4))  " *
    "d̄ = $(round(ss.d, digits=4))  π̄ = $(round(ss.π, digits=4))  ḡ = $(round(ss.g, digits=4))",
)

# ─────────────────────────────────────────────────────────────────
# Step 2  baseline シナリオ（微小攪乱 → 良い均衡へ回帰）
# ─────────────────────────────────────────────────────────────────
println("\n" * "=" ^ 60)
println("Step 2  baseline シナリオ — 微小債務攪乱からの回帰経路")
println("=" ^ 60)

T_baseline = 100
result_baseline = simulate(m, ss.ω, ss.λ, ss.d + 0.02; T = T_baseline)
sr_baseline = to_simulation_result(m, result_baseline, "baseline")
println("d₀ = d̄ + 0.02 = $(round(ss.d + 0.02, digits=4)) から $(T_baseline) 期を計算")
println(
    "  d: 初期 $(round(result_baseline.d[1], digits=4)) → " *
    "終端 $(round(result_baseline.d[end], digits=4))（d̄ = $(round(ss.d, digits=4)) 近傍へ回帰）",
)

# ─────────────────────────────────────────────────────────────────
# Step 3  high_debt シナリオ（高初期債務 → 崩壊経路）
# ─────────────────────────────────────────────────────────────────
println("\n" * "=" ^ 60)
println("Step 3  high_debt シナリオ — 高初期債務からの崩壊経路")
println("=" ^ 60)

T_collapse = 100
result_collapse = simulate(m, ss.ω, ss.λ, 5.0; T = T_collapse)
sr_collapse = to_simulation_result(m, result_collapse, "high_debt")
n_finite = count(isfinite, result_collapse.d)
println("d₀ = 5.0（良い均衡の約71倍）から $(T_collapse) 期を計算")
println("  発散ガード作動前の有効期間数: $(n_finite) / $(T_collapse)")

# ─────────────────────────────────────────────────────────────────
# Step 4  資金調達区分診断（Financing Regime Diagnostics, #112）
# ─────────────────────────────────────────────────────────────────
println("\n" * "=" ^ 60)
println("Step 4  資金調達区分診断（Hedge / Speculative / Ponzi）")
println("=" ^ 60)

regime_diag_baseline = diagnose_financing_regime(m, result_baseline)
regime_diag_collapse = diagnose_financing_regime(m, result_collapse)

println("baseline  区分遷移数: $(length(regime_diag_baseline.transitions))")
println("high_debt 区分遷移数: $(length(regime_diag_collapse.transitions))")
println("high_debt 発散後(invalid)期間数: $(length(regime_diag_collapse.invalid_periods))")

# ─────────────────────────────────────────────────────────────────
# Step 5  金融不安定性連続診断指標とサマリー（#113）
# ─────────────────────────────────────────────────────────────────
println("\n" * "=" ^ 60)
println("Step 5  金融不安定性連続診断指標とサマリー")
println("=" ^ 60)

diag_baseline = minsky_diagnostics(m, result_baseline; scenario_name = "baseline")
diag_collapse = minsky_diagnostics(m, result_collapse; scenario_name = "high_debt")

summary_baseline = minsky_diagnostics_summary(diag_baseline)
summary_collapse = minsky_diagnostics_summary(diag_collapse)

println("[baseline]")
println("  regime 滞在比率: $(summary_baseline.regime_share_of_valid)")
println("  発散: $(summary_baseline.diverged)")

println("[high_debt]")
println("  regime 滞在比率: $(summary_collapse.regime_share_of_valid)")
println("  最初に speculative へ移行: $(summary_collapse.first_speculative_time)")
println("  最初に ponzi へ移行:       $(summary_collapse.first_ponzi_time)")
println("  発散ガード作動時点:        $(summary_collapse.divergence_time)")
println(
    "  債務比率のピーク:          $(round(summary_collapse.peak_debt_ratio, digits=4)) " *
    "(t = $(summary_collapse.peak_debt_ratio_time))",
)

# ─────────────────────────────────────────────────────────────────
# Step 6  regime timeline / diagnostics plot の生成
# ─────────────────────────────────────────────────────────────────
println("\n" * "=" ^ 60)
println("Step 6  regime timeline / diagnostics plot の生成")
println("=" ^ 60)

p_regimes_baseline = plot_financing_regimes(diag_baseline)
p_regimes_collapse = plot_financing_regimes(diag_collapse)
p_diag_baseline = plot_minsky_diagnostics(diag_baseline)
p_diag_collapse = plot_minsky_diagnostics(diag_collapse)
println(
    "plot_financing_regimes・plot_minsky_diagnostics を baseline / high_debt それぞれで生成した",
)

# 保存する場合は以下のコメントを解除する:
# savefig(p_regimes_baseline, "minsky_regimes_baseline.png")
# savefig(p_regimes_collapse, "minsky_regimes_high_debt.png")
# savefig(p_diag_baseline, "minsky_diagnostics_baseline.png")
# savefig(p_diag_collapse, "minsky_diagnostics_high_debt.png")

# ─────────────────────────────────────────────────────────────────
# Step 7  シナリオ比較
# ─────────────────────────────────────────────────────────────────
println("\n" * "=" ^ 60)
println("Step 7  シナリオ比較（baseline vs high_debt）")
println("=" ^ 60)

cmp = minsky_diagnostics_comparison([
    "baseline" => diag_baseline,
    "high_debt" => diag_collapse,
],)
p_compare_d = plot_minsky_scenario_comparison(cmp; var = :debt_ratio)
p_compare_margin = plot_minsky_scenario_comparison(cmp; var = :ponzi_margin)
println(
    "同一診断設定（methodology_version・config が一致）であることを確認した上で、" *
    "債務比率(:debt_ratio)・ponzi margin(:ponzi_margin) を比較するプロットを生成した",
)

# savefig(p_compare_d, "minsky_scenario_comparison_debt_ratio.png")
# savefig(p_compare_margin, "minsky_scenario_comparison_ponzi_margin.png")

# ─────────────────────────────────────────────────────────────────
# Step 8  主要サマリーの表示
# ─────────────────────────────────────────────────────────────────
println("\n" * "=" ^ 60)
println("Step 8  主要サマリー")
println("=" ^ 60)

for (name, s) in [("baseline", summary_baseline), ("high_debt", summary_collapse)]
    println("\n[$(name)]")
    println("  n_valid / n_periods: $(s.n_valid) / $(s.n_periods)")
    println(
        "  最小 interest coverage ratio: " *
        "$(s.min_interest_coverage_ratio === nothing ? "N/A" : round(s.min_interest_coverage_ratio, digits=4)) " *
        "(t = $(s.min_interest_coverage_ratio_time))",
    )
    println(
        "  最小 hedge margin: " *
        "$(s.min_hedge_margin === nothing ? "N/A" : round(s.min_hedge_margin, digits=4)) " *
        "(t = $(s.min_hedge_margin_time))",
    )
    println("  発散: $(s.diverged)" * (s.diverged ? " (t = $(s.divergence_time))" : ""))
end

println("""

────────────────────────────────────────────────────────────────
デモ完了。baseline は良い均衡近傍を保ち続け（発散なし）、high_debt は
Speculative → Ponzi へと悪化した後、発散ガードが作動して打ち切られた
（打ち切り後は NaN 埋め・invalid 区分として扱われ、経済状態としては
表示されない）。詳細な指標定義は docs/models/keen.md と
docs/models/minsky_diagnostics_summary.md を参照。
────────────────────────────────────────────────────────────────
""")
