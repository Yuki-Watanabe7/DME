# examples/real_rate_model_artifact_export.jl
#
# New Keynesian モデルから期待インフレ率・model-implied 実質政策金利の再現可能 JSON
# artifact を構築・検証・保存するデモ（Issue #159 / economic-data-provider ADR 006 準拠）。
#
# New Keynesian モデル（fixture calibration）→ real_rate_model_artifact で
# expected_inflation・nominal_policy_rate・model_implied_real_policy_rate 等の
# observation を構築 → RFC 8785 正準 JSON で atomic 保存 → 読み込み・hash 再検証
# までを 1 本で完走する。乱数を使わず完全に決定的・API キー不要。
#
# 実行方法:
#   julia --project=. examples/real_rate_model_artifact_export.jl
#
# 成果物の出力先（既定はリポジトリ内 artifacts/、環境変数で上書き可）:
#   REAL_RATE_ARTIFACT_OUTDIR=/path/to/dir
#
# 保存するファイル（ADR 006 §6 のファイル名規約に従う atomic write）:
#   artifacts/real-rates/<schema_version>/<country>/<YYYY>/<MM>/
#     <timestamp>__<country>__<model-id>__<run-id>__<artifact_id 64hex>.json
#
# 注意（結果の限界・禁止される解釈）:
#   - ここで使うパラメータは fixture calibration（`calibration_kind=:fixture`）であり、
#     実証推計値ではない（`docs/models/new_keynesian.md` の典型値をそのまま使用）
#   - policy/overnight 以外の rate_type/tenor は非対応
#   - 5年・10年 term structure は現行 New Keynesian モデルから生成しない
#     （`horizons` は `"P3M"`/`"P1Y"` のみサポート）
#   - artifact は診断値であり、投資判断・政策判断の自動化を目的としない
#
# 関連: docs/examples/real_rate_model_artifact.md / docs/models/new_keynesian.md /
#       docs/adr/0008-real-rate-model-artifact-export.md / docs/contract/README.md

using DME
using Dates: DateTime

function _git_commit_sha()
    sha = DME._detect_git_commit_sha()
    sha === nothing || return sha
    # .git が存在しない配布環境向けのフォールバック（40桁hex形式を維持する）
    return "0"^40
end

function build_and_save(;
    country,
    scenario_id,
    run_id,
    shock,
    shock_size,
    model_period_index,
    outdir,
)
    m = NewKeynesianModel(
        1.0,   # σ:      異時点間代替弾力性
        0.02,  # r_n:    自然実質利子率
        0.99,  # β:      割引因子
        0.1,   # κ:      NKPC傾き
        1.5,   # φ_π:    インフレ反応係数（Taylor principle: φ_π > 1）
        0.5,   # φ_x:    産出ギャップ反応係数
        0.02,  # π_star: インフレ目標
        0.8,   # ρ_x:    需要ショック持続性
        0.5,   # ρ_c:    コストプッシュショック持続性
        0.5,   # ρ_m:    金融政策ショック持続性
    )

    # decision_time/data_cutoff_at/generated_at は呼び出し側が明示的に決める
    # （再現可能な golden artifact のため、now() 等の非決定的な既定値は使わない）
    decision_time = DateTime(2026, 7, 27, 9, 0, 0)
    data_cutoff_at = DateTime(2026, 7, 26, 23, 0, 0)
    generated_at = DateTime(2026, 7, 27, 9, 5, 0)

    artifact = real_rate_model_artifact(
        m;
        country = country,
        scenario_id = scenario_id,
        run_id = run_id,
        shock = shock,
        shock_size = shock_size,
        model_period_index = model_period_index,
        decision_time = decision_time,
        data_cutoff_at = data_cutoff_at,
        generated_at = generated_at,
        parameter_set_id = "nk-baseline-fixture",
        calibration_id = "nk-$(lowercase(country))-fixture",
        calibration_version = "1.0.0",
        calibration_kind = :fixture,
        code_commit_sha = _git_commit_sha(),
    )

    # 同じ入力（パラメータ・timing・run_id 等）から再実行すると同じ artifact_id・
    # 同じファイルパスになる（決定論的生成）。既に存在する場合は上書きせず、
    # 既存ファイルをそのまま読み込む（atomic save は「同名ファイルへの上書き」だけを拒否する）。
    path = try
        save_real_rate_model_artifact(artifact, outdir)
    catch e
        e isa ArgumentError || rethrow()
        DME._rra_artifact_file_path(outdir, artifact)
    end

    # 保存（または既存ファイルの読み込み）後に、hash（artifact_id・parameter_hash・
    # calibration_hash・snapshot_hash）が再計算値と一致することを確認する
    # （改ざん・破損の検出）。
    reloaded = load_real_rate_model_artifact(path)
    @assert reloaded.artifact_id == artifact.artifact_id

    return artifact, path
end

function print_summary(artifact::RealRateModelArtifact)
    println("  run_id        = ", artifact.run.run_id)
    println("  output_kind   = ", artifact.run.output_kind)
    println("  artifact_id   = ", artifact.artifact_id)
    for o in artifact.observations
        horizon_label = o.horizon.duration === nothing ? "-" : o.horizon.duration
        println(
            "    ",
            rpad(String(o.metric), 32),
            rpad(horizon_label, 6),
            " value=",
            round(o.value; digits = 4),
            " [",
            o.observation_id,
            "]",
        )
    end
    if !isempty(artifact.warnings)
        println("  warnings:")
        for w in artifact.warnings
            println("    - ", w)
        end
    end
    return nothing
end

function main()
    outdir = get(ENV, "REAL_RATE_ARTIFACT_OUTDIR", joinpath(@__DIR__, "..", "artifacts"))
    mkpath(outdir)

    println("=== Real-rate model artifact 生成デモ（Issue #159） ===")
    println()

    println("[1] steady_state artifact（ショックなし、US）")
    ss_artifact, ss_path = build_and_save(;
        country = "US",
        scenario_id = "baseline-steady-state",
        run_id = "nk-us-steady-state-demo",
        shock = :demand,
        shock_size = 0.0,
        model_period_index = 1,
        outdir = outdir,
    )
    print_summary(ss_artifact)
    println("  saved to: ", ss_path)
    println()

    println("[2] trajectory artifact（需要ショック、US、t=8期）")
    irf_artifact, irf_path = build_and_save(;
        country = "US",
        scenario_id = "demand-shock-trajectory",
        run_id = "nk-us-demand-shock-demo",
        shock = :demand,
        shock_size = 0.01,
        model_period_index = 8,
        outdir = outdir,
    )
    print_summary(irf_artifact)
    println("  saved to: ", irf_path)
    println()

    println("=== 完了 ===")
    println(
        "economic-data-provider への受け渡し手順は docs/examples/real_rate_model_artifact.md を参照。",
    )
    return nothing
end

main()
