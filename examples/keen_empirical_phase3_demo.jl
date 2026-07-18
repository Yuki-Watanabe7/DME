# examples/keen_empirical_phase3_demo.jl
#
# Keen 実データ接続・限定キャリブレーション・検証の統合デモ（Phase 3, Issue #123）
#
# 米国 Keen 実証 MVP について、実データ入力 → 観測系列変換 → 限定キャリブレーション →
# in-sample/out-of-sample 検証 → 金融不安定性診断 → 感応度分析 → 可視化 →
# 機械可読レポート出力までを 1 本で完走する。
#
# 実行方法（外部 API キー不要の fixture 経路が既定・正）:
#   julia --project=. examples/keen_empirical_phase3_demo.jl
#
# 取得モードの切替（同一の公開契約。live/rest_api は追加経路）:
#   DME_DATA_MODE=fixture   … test/fixtures/keen の固定 JSON（既定・決定的・CI 用）
#   DME_DATA_MODE=live      … FRED API（要 FRED_API_KEY）
#   DME_DATA_MODE=rest_api  … economic-data-provider REST API（要 DATA_PROVIDER_BASE_URL）
#   source unavailable 時に fixture へ暗黙 fallback はせず、失敗理由を表示して停止する。
#
# 図・レポートの出力先（既定は一時ディレクトリ。リポジトリを汚さない）:
#   KEEN_DEMO_OUTDIR=/path/to/dir
#
# 注意（結果の限界・禁止される解釈）:
#   - 観測系列は理論変数（ω・λ・d）の近似 proxy であり厳密に同一ではない
#   - calibrated parameter は採用期間・proxy・weight・bounds に依存する
#   - observed regime も集計 proxy 診断であり企業別実測分類ではない
#   - out-of-sample fit は危機予測能力を意味しない
#   - 本デモは投資助言・政策判断の自動化を目的としない
#
# 関連: docs/models/keen.md / docs/models/keen_empirical_strategy.md / docs/api.md

# ヘッドレス環境（CI・無表示）でプロット保存を可能にする
get!(ENV, "GKSwstype", "nul")

using DME
using Plots

# ─────────────────────────────────────────────────────────────────
# Step 0  取得モード・出力先の解決
# ─────────────────────────────────────────────────────────────────
const MODE = Symbol(get(ENV, "DME_DATA_MODE", "fixture"))
const OUTDIR = get(ENV, "KEEN_DEMO_OUTDIR", mktempdir())
const FIXTURE_DIR = joinpath(@__DIR__, "..", "test", "fixtures", "keen")
isdir(OUTDIR) || mkpath(OUTDIR)

println(
    """
╔═══════════════════════════════════════════════════════════════╗
║   Keen 実証 Phase 3 統合デモ — データ→推定→検証→感応度→可視化   ║
╚═══════════════════════════════════════════════════════════════╝

  Step 1  KeenEmpiricalDataset の構築（採用系列・単位変換・共通期間・quality）
  Step 2  literature default model の作成
  Step 3  calibration 期間での限定キャリブレーション
  Step 4  calibrated model と推定 metadata
  Step 5  in-sample / out-of-sample validation（literature vs calibrated）
  Step 6  observed proxy / model financing regime 比較
  Step 7  感応度分析（amortization_rate ほか）
  Step 8  可視化（実データ・モデル軌跡・診断）の保存
  Step 9  機械可読レポートの保存

取得モード: $(MODE)   出力先: $(OUTDIR)

注意: 実証 fit は因果・危機確率・予測精度と同一ではない。observed regime は集計 proxy 診断。
""",
)

# ─────────────────────────────────────────────────────────────────
# Step 1  KeenEmpiricalDataset の構築
# ─────────────────────────────────────────────────────────────────
println("=" ^ 60)
println("Step 1  KeenEmpiricalDataset の構築（mode=$(MODE)）")
println("=" ^ 60)

client = if MODE === :fixture
    FredClient(; mode = :fixture, fixture_dir = FIXTURE_DIR)
else
    FredClient(; mode = MODE)  # source unavailable 時は fetch_fred_* が明示的に失敗する
end

dataset = build_keen_empirical_dataset(keen_us_default_config(); client = client)

println("採用系列と単位変換:")
for v in (:ω, :λ, :d, :r)
    p = dataset.provenance[v]
    println(
        "  $(v): $(p.series_id)  [$(p.original_unit)] → $(p.conversion_formula)" *
        "  (agg=$(p.aggregation), mode=$(p.mode))",
    )
end
println(
    "\n共通期間: $(dataset.metadata["sample_start"]) .. $(dataset.metadata["sample_end"])" *
    "  観測数=$(length(dataset))  r_param=$(round(dataset.r_param, sigdigits = 4))",
)
println(
    "分割: calibration=$(length(dataset.calibration_indices))  " *
    "validation=$(length(dataset.validation_indices))（後方ホールドアウト・look-ahead なし）",
)
if !isempty(dataset.dropped_dates)
    println(
        "quality warning: 欠損/invalid で除外した四半期 = $(length(dataset.dropped_dates)) 件",
    )
end
println("invalid 内訳（0 化せず記録）: ", dataset.quality_flags["n_invalid"])

# ─────────────────────────────────────────────────────────────────
# Step 2–7  検証（推定・validation・regime・感応度を一括実行）
# ─────────────────────────────────────────────────────────────────
println("\n" * "=" ^ 60)
println("Step 2-3  literature default と限定キャリブレーション")
println("=" ^ 60)

calib_config = keen_default_calibration_config(dataset; n_starts = 5)
valid_config = keen_default_validation_config(dataset; calibration_config = calib_config)
result = validate_keen(dataset, valid_config)

cal = result.calibration_result
println("推定対象: $(calib_config.estimated_params)")
println("固定: ", sort(collect(keys(cal.fixed))))
println("literature default（推定対象の文献値）:")
for p in calib_config.estimated_params
    println("  $(p) = $(getproperty(KEEN_LITERATURE_PARAMS, p))")
end

println("\n" * "=" ^ 60)
println("Step 4  calibrated model と推定 metadata")
println("=" ^ 60)
for p in calib_config.estimated_params
    println("  $(p) = $(round(cal.estimated[p], sigdigits = 6))")
end
println("objective(calibrated) = $(round(cal.objective_value, sigdigits = 6))")
println("objective(literature) = $(round(cal.literature_objective, sigdigits = 6))")
println(
    "converged=$(cal.converged)  boundary_hits=$(cal.boundary_hits)  weak_id=$(cal.weak_identification)",
)
println("標準誤差は本 methodology version では未対応（sensitivity は曲率近似）。")

println("\n" * "=" ^ 60)
println("Step 5  in-sample / out-of-sample validation（literature vs calibrated）")
println("=" ^ 60)
println("（RMSE。初期化アンカーは fit から除外。発散・欠損は 0 化せず NaN のまま）")
for e in result.evaluations
    parts = String[]
    for v in valid_config.eval_variables
        mt = e.metrics[v]
        push!(
            parts,
            "$(v):rmse=$(isnan(mt.rmse) ? "NaN" : string(round(mt.rmse, sigdigits = 3)))",
        )
    end
    div = e.diverged ? "  [DIVERGED offset=$(e.divergence_offset)]" : ""
    println(
        "  $(e.model_label)/$(e.period)/$(e.initial_state_mode): ",
        join(parts, "  "),
        div,
    )
end
println(
    "\n集計 RMSE: literature=$(result.metadata["aggregate_rmse_literature"])  " *
    "calibrated=$(result.metadata["aggregate_rmse_calibrated"])",
)
println("calibrated が literature より悪化: $(result.calibrated_worse_than_literature)")

println("\n" * "=" ^ 60)
println("Step 6  observed proxy / model financing regime 比較")
println("=" ^ 60)
rc = result.regime_comparison
for (label, s) in (
    ("observed", rc.observed_summary),
    ("literature", rc.literature_summary),
    ("calibrated", rc.calibrated_summary),
)
    println(
        "  $(label): first_spec=$(s.first_speculative_time)  first_ponzi=$(s.first_ponzi_time)" *
        "  peak_d=$(s.peak_debt_ratio === nothing ? "-" : round(s.peak_debt_ratio, sigdigits = 4))" *
        "  diverged=$(s.diverged)",
    )
end
println("※ observed proxy は集計系列への操作的定義の代理であり企業別実測分類ではない。")

println("\n" * "=" ^ 60)
println("Step 7  感応度分析（base を含む）")
println("=" ^ 60)
for s in result.sensitivity
    est = join(
        ["$(k)=$(round(v, sigdigits = 4))" for (k, v) in sort(collect(s.estimated))],
        ", ",
    )
    println(
        "  [$(s.scenario.name)] reuse_base=$(s.reused_base_calibration)  obj=$(round(s.objective_value, sigdigits = 4))" *
        "  peak_d=$(s.peak_debt_ratio === nothing ? "-" : round(s.peak_debt_ratio, sigdigits = 4))",
    )
    println("      estimated: $(est)")
end
println("※ amortization_rate 変更は ODE・推定を変えず診断のみ変える（reuse_base=true）。")

if !isempty(result.warnings)
    println("\n[warnings]（不利な結果・発散を隠さない）")
    for w in result.warnings
        println("  - ", w)
    end
end

# ─────────────────────────────────────────────────────────────────
# Step 8  可視化の保存
# ─────────────────────────────────────────────────────────────────
println("\n" * "=" ^ 60)
println("Step 8  可視化の保存（欠損・発散後は補間・0 化せず線を途切れさせる）")
println("=" ^ 60)
artifact_paths = String[]
figs = (
    ("keen_trajectories.png", plot_keen_empirical_trajectories(result)),
    ("keen_regime_comparison.png", plot_keen_regime_comparison(result)),
    (
        "keen_sensitivity_peak_debt.png",
        plot_keen_sensitivity(result; metric = :peak_debt_ratio),
    ),
    ("keen_calibrated_diagnostics.png", plot_minsky_diagnostics(rc.calibrated)),
)
for (name, fig) in figs
    path = joinpath(OUTDIR, name)
    savefig(fig, path)
    push!(artifact_paths, path)
    println("  saved: $(path)")
end

# ─────────────────────────────────────────────────────────────────
# Step 9  機械可読レポートの保存
# ─────────────────────────────────────────────────────────────────
println("\n" * "=" ^ 60)
println("Step 9  機械可読レポートの保存（秘密情報は含めない）")
println("=" ^ 60)
report_path = joinpath(OUTDIR, "keen_empirical_report.json")
save_keen_empirical_report(
    report_path,
    dataset,
    result;
    mode = client.mode,
    artifact_paths = artifact_paths,
)
validation_path = joinpath(OUTDIR, "keen_validation.json")
save_keen_validation(validation_path, result)
config_path = joinpath(OUTDIR, "keen_calibration_config.json")
save_keen_calibration_config(config_path, calib_config)
println("  report: $(report_path)")
println("  validation: $(validation_path)")
println("  calibration config: $(config_path)")

println("""

完了。出力ディレクトリ: $(OUTDIR)

再現性: fixture mode は固定データ・固定設定・固定 seed で決定的に完走する。
限界: 実証 fit は因果・危機確率・投資判断ではない。observed regime は集計 proxy 診断。
詳細: docs/models/keen.md / docs/models/keen_empirical_strategy.md §6
""")
