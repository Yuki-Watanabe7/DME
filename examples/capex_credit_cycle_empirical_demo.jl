# examples/capex_credit_cycle_empirical_demo.jl
#
# 部門別CAPEX・信用循環モデル（CCC）の実証統合デモ（Issue #251 / `P-11`）
#
# #241–#250 が実装した7段
#   [0] series catalog → [1] raw observation → [2] measurement → [3] empirical dataset →
#   [4a] steady-state calibration / [4b] identification / [4c] limited estimation →
#   [5] historical episode replay → [6] validation → [7] robustness/sensitivity
# を、外部API・ネットワークアクセス・API キーなしで公開APIのみで完走し、最終 artifact
# （identity chain・caveats を含む）を保存する。
#
# 本デモの入力データは**すべて合成（synthetic）**であり、実際の米国経済データではない
# （対象外: 実系列の本取得・ETL実装。docs/architecture/capex_credit_cycle_empirical_integration.md
# 対象外節）。`capex_credit_cycle_default_targets()` の定常状態を起点に、`capex_run` で
# 外生パス（`ext_demand_s2`/`ext_demand_s3` の一時的な収縮 + 識別診断用の政策金利の
# ゼロ平均振動）を与えて内部整合な「観測」時系列を生成し、それを実証パイプラインへ流し込む。
# 数値の水準そのものに経済的意味はなく、パイプラインの配線（各段の入出力契約）を実演する
# ことが目的である。
#
# 実行方法:
#   julia --project=. examples/capex_credit_cycle_empirical_demo.jl
#
# 成果物の出力先（既定はリポジトリ内 artifacts/、環境変数で上書き可）:
#   CCC_EMPIRICAL_DEMO_OUTDIR=/path/to/dir
#
# 保存する成果物（`<outdir>/` 配下）:
#   artifact.json                     … identity chain（catalog_version/dataset_hash/
#                                        targets_hash/parameter_set_hash/episode_hash/
#                                        replay_hash）と各ファイルへの索引
#   catalog.json                      … series catalog snapshot（本デモの合成 catalog）
#   raw_observation_manifest.json     … raw observation manifest（#242）
#   measurement_manifest.json         … measured dataset manifest（#243）
#   calibration.json                  … steady-state targets・逆較正・SS検証（#244）
#   identification.json               … EB-1–EB-7 識別診断（#245）
#   parameter_set_literature_default.json / parameter_set_calibrated.json /
#   parameter_set_estimated.json      … parameter artifact 3種（#246）
#   episode.json                      … historical episode spec・NC-1–NC-7 assessment（#247）
#   replay_literature_default.json / replay_calibrated.json / replay_estimated.json
#                                      … 履歴再生 result summary 3種（#248）
#   validation.json                   … dimension別 validation report（#249）
#   robustness.json                   … robustness/sensitivity report（#250）
#   report.md                         … 人間可読レポート（caveats を含む、#251）
#   determinism_check.json            … 2回実行の identity chain 一致確認（§12.7 項目60）
#
# 注意（結果の限界・禁止される解釈。実証統合設計 §10.4・§11.4・ADR 0012・ADR 0014）:
#   1. 入力データはすべて合成であり、real-world の point-in-time replay ではない。
#   2. fit は因果妥当性・景気後退確率・投資助言ではない。
#   3. 観測系列は直接観測（`:D`）・構成（`:C`）・proxy（`:P`）の区別を保持するが、本デモの
#      合成データはすべて `:direct` methodology として構成した簡略版であり、実データの
#      観測可能性分類を代表しない。
#   4. 弱識別（`W1`–`W4`）パラメータは点推定せず、範囲・複数仕様・降格として扱う。
#   5. 企業開示は較正入力に用いていない（本デモはそもそも企業データを使わない）。
#   6. `:as_of` は実装しない。「その時点で判断できた」という主張はしない。
#   7. `SH-EXP`（event magnitude）の走査結果は較正値ではない。
#   8. 表現できないイベント・model boundary を近似で寄せない（本デモは事象を持たない
#      baseline 型の episode のみを使う）。
#   9. `Digital Shadow` / `Digital Twin` を名乗らない（ADR 0014）。
#   10. 本出力は投資判断・政策立案の根拠として使用することを意図していない。
#
# 関連: docs/examples/capex_credit_cycle_empirical_demo.md /
#       docs/architecture/capex_credit_cycle_empirical_integration.md（本デモの正本） /
#       docs/models/capex_credit_cycle_empirical_strategy.md /
#       docs/adr/0012-capex-credit-cycle-empirical-contract.md /
#       docs/adr/0018-capex-credit-cycle-empirical-runtime-contract.md /
#       docs/adr/0014-digital-twin-naming-conditions.md

# ヘッドレス環境でも問題なく完走する（可視化を持たないデモのため不要だが、既存デモとの
# 規約を踏襲する）。
get!(ENV, "GKSwstype", "nul")

using DME

const JSON3 = DME.JSON3

# ─────────────────────────────────────────────────────────────────
# 合成 fixture の構築ヘルパー
# ─────────────────────────────────────────────────────────────────

# デモの合成標本は "1990-Q1" を起点に `_CCED_N` 四半期。baseline（定常）は先頭12四半期
# （"1990-Q1"–"1992-Q4"）。合成ショックは `_CCED_SHOCK_T0`（相対四半期 index 20 = "1995-Q1"）
# に対して `ext_demand_s2`/`ext_demand_s3` を一時的に収縮させる（実証戦略 §9.1 の episode
# 窓 runup=8Q・eval=20Q に収まるよう、runup 窓は完全にbaseline後の定常区間内にある）。
const _CCED_START = "1990-Q1"
const _CCED_N = 140
const _CCED_BASELINE_START = "1990-Q1"
const _CCED_BASELINE_END = "1992-Q4"
const _CCED_SHOCK_T0 = 20
const _CCED_EPISODE_LABEL = "synthetic demo downturn（ext_demand_s2/s3 の一時的収縮）"

function _cced_dates(start_label::String, n::Int)::Vector{String}
    y0, q0 =
        parse(Int, split(start_label, "-Q")[1]), parse(Int, split(start_label, "-Q")[2])
    base = y0 * 4 + (q0 - 1)
    return [string(idx ÷ 4, "-Q", idx % 4 + 1) for idx in base:(base + n - 1)]
end

# 較正必須系列（#170 §4.3・§8.3 の48キーへ対応する合成 raw 系列）。P-8/P-9/P-10 のテスト
# fixture（`test_capex_credit_cycle_historical_replay.jl` 等）と同じキー集合を用いる。
const _CCED_CALIBRATION_KEYS = (
    :y_s1,
    :y_s2,
    :y_s3,
    :y_tot,
    :util_s2,
    :util_s3,
    :emp_s1,
    :emp_s2,
    :emp_s3,
    :emp_tot,
    :cap_s1,
    :cap_s2,
    :cap_s3,
    :dep_s1,
    :dep_s2,
    :dep_s3,
    :order_cap_s2,
    :order_cap_s3,
    :order_inv_s3,
    :order_s2,
    :order_s3,
    :backlog_s2,
    :backlog_s3,
    :inv_s2,
    :inv_s3,
    :va_s1,
    :va_s2,
    :va_s3,
    :wagebill_s1,
    :wagebill_s2,
    :wagebill_s3,
    :wagebill_tot,
    :spread,
    :policy_rate,
    :cons,
    :debt_s1,
    :debt_s2,
    :debt_s3,
    :cash_s1,
    :cash_s2,
    :cash_s3,
    :capex_exec_s1,
)

# 履歴再生の episode 選定（`CAPEX_CC_EPISODE_REQUIRED_MODEL_VARS`、`EB-1`・`EB-6`・`EB-7` の
# 一部）にのみ用いる validation_only 系列。`order_s2`・`capex_exec_s1` 等と異なり、逆較正の
# 48キーには含まれない。
const _CCED_EPISODE_ONLY_KEYS = (
    :fin_cond,
    :lend_stance,
    :wage,
    :ship_s2,
    :ship_s3,
    :hh_income,
    :price_s2,
    :price_s3,
    :equity_val,
)

function _cced_series_spec(key::Symbol; role::Symbol = :calibration_required)
    return CapexSeriesSpec(
        key = key,
        model_vars = [key],
        provider_series_id = uppercase(string(key)),
        provider = "DME-SYNTHETIC",
        source_kind = :official_statistic,
        role = role,
        observability = :D,
        methodology = :direct,
        declared_unit = "synthetic unit",
        declared_frequency = Quarterly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = :real,
        declared_base_year = nothing,
        annualized = false,
        level_form = :level,
        anchor = nothing,
        sector_scope = "capex_credit_cycle_empirical_demo synthetic scope",
        scope_bias = :none,
        aggregation = :sum,
        model_timing = :SUM,
        allocation_key = nothing,
        availability_start = _CCED_START,
        notes = "capex_credit_cycle_empirical_demo.jl の合成 fixture entry（実データではない）",
    )
end

_cced_data_series(key::Symbol, values::AbstractVector, dates::Vector{String}) = DataSeries(
    uppercase(string(key)),
    string(key),
    "DME-SYNTHETIC",
    Quarterly,
    "synthetic unit",
    dates,
    Vector{Union{Float64, Missing}}(values),
)

_cced_raw_observation(spec::CapexSeriesSpec, series::DataSeries) = CapexRawObservation(
    spec.key,
    spec,
    :ok,
    series,
    "synthetic unit",
    Quarterly,
    "SA",
    missing,
    String[],
    nothing,
    :fixture,
    "",
)

"""
    _cced_hump(i, t0, dur, hold, decay) -> Float64

`t0` から `dur` 四半期で1.0まで立ち上がり、`hold` 四半期保持し、`decay` 四半期で0へ戻る
台形型の shock 係数（0–1）。`t0` 以前は常に0。
"""
function _cced_hump(i::Int, t0::Int, dur::Int, hold::Int, decay::Int)::Float64
    i < t0 && return 0.0
    s = i - t0
    if s <= dur
        return s / dur
    elseif s <= dur + hold
        return 1.0
    else
        return max(0.0, 1.0 - (s - dur - hold) / decay)
    end
end

"""
    _cced_build_exog(m, n) -> Dict{Symbol, Vector{Float64}}

`_ccc_baseline_exog`（Sc0 相当）を土台に、`_CCED_SHOCK_T0` から `ext_demand_s2`/
`ext_demand_s3` を台形型に収縮させ（`capex_exec_s1`・`order_s2`・`spread` に NC-2 相当の
深さを生じさせる）、加えて識別診断（EB-1/EB-2/EB-5）用に `policy_rate` へゼロ平均の
振動を重ねる（振動は `ext_demand_s2`/`ext_demand_s3` に触れないため、逆較正の
`ext_demand_s^{ss}` 残差再構成（`Z-12`）を汚染しない）。
"""
function _cced_build_exog(m::CapexCreditCycleModel, n::Int)::Dict{Symbol, Vector{Float64}}
    exog = DME._ccc_baseline_exog(m, n)
    for i in 0:(n - 1)
        f = _cced_hump(i, _CCED_SHOCK_T0, 1, 2, 6)
        exog[:ext_demand_s2][i + 1] *= (1 - 0.99 * f)
        exog[:ext_demand_s3][i + 1] *= (1 - 0.495 * f)
        exog[:policy_rate][i + 1] += 0.4 * sinpi(i / 9.0)
    end
    return exog
end

"""
    _cced_raw_dataset() -> (raw::CapexRawDataset, sim_run)

合成 fixture 全体（catalog spec・raw observation・raw dataset）を構築する。`sim_run` は
生成に用いた `capex_run` の出力そのもの（デバッグ・注記用。fixture の値の由来を辿れるように
返すが、実証パイプラインの入力としては `raw` のみを用いる）。
"""
function _cced_raw_dataset()
    m = capex_credit_cycle_model(capex_credit_cycle_default_targets())
    exog = _cced_build_exog(m, _CCED_N)
    options = CapexCreditCycleOptions(; horizon_runup = 8, horizon_eval = _CCED_N - 8)
    sim_run = capex_run(
        m;
        exog = exog,
        options = options,
        validate_accounting = false,
        diagnostics = false,
    )
    sim_run.termination_reason === :completed || error(
        "合成 fixture 生成用の capex_run が完走しませんでした: $(sim_run.termination_reason)",
    )

    dates = _cced_dates(_CCED_START, _CCED_N)
    p = parameters(m)

    # order_cap_s2/s3・order_inv_s3 を capex_exec_s1/invest_s2 に比例する動的な値として
    # 再構成し（モデル自身の構造シェア `st_capex_share_s2`/`st_capex_share_s3`/
    # `st_invest_share_s3` を用いる）、observed "order_s2"/"order_s3" を実証戦略 §8.3 の
    # 識別仮定どおり y_s − order_cap_s − ext_demand_s の残差（order_gen_s 相当）として
    # 構成する（P-8 fixture の定常近似を動的へ一般化したもの）。
    order_cap_s2_dyn = p.st_capex_share_s2 .* sim_run.series[:capex_exec_s1]
    order_cap_s3_dyn = p.st_capex_share_s3 .* sim_run.series[:capex_exec_s1]
    order_inv_s3_dyn = p.st_invest_share_s3 .* sim_run.series[:invest_s2]
    order_s2_obs = sim_run.series[:y_s2] .- order_cap_s2_dyn .- exog[:ext_demand_s2]
    order_s3_obs =
        sim_run.series[:y_s3] .- order_cap_s3_dyn .- order_inv_s3_dyn .-
        exog[:ext_demand_s3]
    wagebill_tot_obs =
        sim_run.series[:wagebill_s1] .+ sim_run.series[:wagebill_s2] .+
        sim_run.series[:wagebill_s3] .+ sim_run.series[:wagebill_s5]

    special_values = Dict{Symbol, Vector{Float64}}(
        :order_cap_s2 => order_cap_s2_dyn,
        :order_cap_s3 => order_cap_s3_dyn,
        :order_inv_s3 => order_inv_s3_dyn,
        :order_s2 => order_s2_obs,
        :order_s3 => order_s3_obs,
        :wagebill_tot => wagebill_tot_obs,
    )

    observations = CapexRawObservation[]
    for key in _CCED_CALIBRATION_KEYS
        values = get(special_values, key, nothing)
        values === nothing && (values = sim_run.series[key])
        spec = _cced_series_spec(key)
        push!(
            observations,
            _cced_raw_observation(spec, _cced_data_series(key, values, dates)),
        )
    end
    for key in _CCED_EPISODE_ONLY_KEYS
        spec = _cced_series_spec(key; role = :validation_only)
        push!(
            observations,
            _cced_raw_observation(spec, _cced_data_series(key, sim_run.series[key], dates)),
        )
    end
    # NC-6（ai_exp 代替構成 §8.2 ID-1）用の validation_only proxy。値自体は合成データの
    # y_s1・定数 100 を流用しており、実データにおける compute_dem/equity 系列を代表しない。
    push!(
        observations,
        _cced_raw_observation(
            _cced_series_spec(:y_s1_proxy; role = :validation_only),
            _cced_data_series(:y_s1_proxy, sim_run.series[:y_s1], dates),
        ),
    )
    push!(
        observations,
        _cced_raw_observation(
            _cced_series_spec(:equity_val_sector; role = :validation_only),
            _cced_data_series(:equity_val_sector, fill(100.0, _CCED_N), dates),
        ),
    )

    catalog = [o.spec for o in observations]
    raw = CapexRawDataset(
        Dict(o.key => o for o in observations),
        "capex-credit-cycle-empirical-demo-catalog/1.0.0",
        CAPEX_CC_EMPIRICAL_INTEGRATION_VERSION,
        "",
        Dict{String, Any}(),
        Dict{String, Any}("mode" => "fixture", "n_series" => length(observations)),
    )
    return (raw = raw, catalog = catalog, sim_run = sim_run)
end

"""
    _cced_episode_spec() -> CapexHistoricalEpisodeSpec

本デモ専用の合成 episode（`H1` の id を再利用するが `CAPEX_CC_EPISODE_SPECS` の実際の
`H1`（2000年ドットコム後の調整）とは無関係。`test_capex_credit_cycle_historical_replay.jl`
と同じ規律）。`_CCED_SHOCK_T0`（"1995-Q1"）を `period_zero` とする。
"""
function _cced_episode_spec()::CapexHistoricalEpisodeSpec
    return CapexHistoricalEpisodeSpec(;
        id = :H1,
        label = _CCED_EPISODE_LABEL,
        period_zero = CalendarQuarter(1995, 1),
        runup_quarters = 8,
        eval_quarters = 20,
        in_sample = true,
        expected_diagnostic_label = :broad_downturn,
        notes = "examples/capex_credit_cycle_empirical_demo.jl の合成 episode。" *
                "実 H1（2000年ドットコム後のIT・半導体設備投資調整）とは無関係。",
    )
end

# ─────────────────────────────────────────────────────────────────
# パイプライン本体（[0]–[7] の7段。1回の呼び出しで全段を実行する）
# ─────────────────────────────────────────────────────────────────

"""
    _cced_run_pipeline() -> NamedTuple

catalog → raw → measurement/dataset → 較正 → 識別 → 推定 → episode → 履歴再生 → 検証 →
robustness を公開APIのみで1回実行し、全段の中間結果を1つの NamedTuple として返す。
同一のこの関数を2回呼び出すことで決定性（§12.7 項目60）を確認できる。
"""
function _cced_run_pipeline()
    raw, catalog, _ = _cced_raw_dataset()
    ds = build_capex_empirical_dataset(raw; min_valid_obs = 8)

    b0 = capex_credit_cycle_default_targets().values
    calibration = calibrate_capex_credit_cycle(
        ds;
        baseline_start = _CCED_BASELINE_START,
        baseline_end = _CCED_BASELINE_END,
        literature = (
            cost_capital_intercept_s1 = b0.cost_capital_s1 - b0.spread / 100,
            cost_capital_intercept_s2 = b0.cost_capital_s2 - b0.spread / 100,
            cost_capital_intercept_s3 = b0.cost_capital_s3 - b0.spread / 100,
        ),
        assumptions = (cons_s1 = b0.cons_s1,),
    )

    identification_config = CapexIdentificationConfig()
    identification =
        diagnose_capex_identification(ds, calibration; config = identification_config)

    estimates = CapexBlockEstimate[]
    for diag in identification
        diag.status in (:estimable, :weakly_identified) || continue
        push!(estimates, estimate_capex_block(diag.block, ds, calibration, diag))
    end

    parameter_sets = Dict{Symbol, CapexParameterSet}(
        :literature_default => capex_parameter_set(
            calibration,
            identification;
            kind = :literature_default,
        ),
        :calibrated =>
            capex_parameter_set(calibration, identification; kind = :calibrated),
        :estimated => capex_parameter_set(
            calibration,
            identification,
            estimates;
            kind = :estimated,
        ),
    )

    episode = _cced_episode_spec()
    # 8. 選択した historical episode: 本デモ専用の合成 episode を NC-1–NC-7 で機械的に評価する
    # （選定条件の全充足は主張しない。emp_tot の NC-2 深さ閾値未達を理由に `:excluded` となる
    # ことを想定している。理由は `exclusion_reason` に構造化して保持する）。
    episode_assessment = first(assess_capex_episodes(ds; specs = [episode]))
    # 参考: 実際の H1–H6 registry（`CAPEX_CC_EPISODE_SPECS`）に対する評価も実行し、
    # 本デモの合成データが実候補のいずれも選定しないことを honest に記録する
    # （選定ロジック自体は #247 の `test_capex_credit_cycle_history.jl` で別途検証済み）。
    registry_assessments = assess_capex_episodes(ds)

    replay_options = Dict{Symbol, CapexReplayOptions}(
        :literature_default =>
            CapexReplayOptions(; parameter_set_kind = :literature_default),
        :calibrated => CapexReplayOptions(),
        :estimated => CapexReplayOptions(; parameter_set_kind = :estimated),
    )
    replay_runs = Dict{Symbol, CapexHistoricalReplayRun}()
    for (kind, ps) in parameter_sets
        model = capex_replay_model(calibration, ps; kind = kind)
        replay_runs[kind] =
            capex_historical_replay(model, episode, ds, ps; options = replay_options[kind])
    end

    validation = validate_capex_empirical(replay_runs[:calibrated], ds)

    calibrated_model =
        capex_replay_model(calibration, parameter_sets[:calibrated]; kind = :calibrated)
    robustness = capex_empirical_sensitivity_suite(
        calibrated_model,
        episode,
        ds,
        parameter_sets[:calibrated],
    )

    accounting =
        replay_runs[:calibrated].model_run === nothing ? nothing :
        validate_capex_accounting(calibrated_model, replay_runs[:calibrated].model_run)

    artifact = capex_empirical_artifact_to_dict(;
        catalog = catalog,
        raw = raw,
        dataset = ds,
        calibration = calibration,
        identification = identification,
        identification_config = identification_config,
        parameter_sets = parameter_sets,
        episode = episode,
        episode_assessment = episode_assessment,
        replay_runs = replay_runs,
        validation = validation,
        robustness = robustness,
    )

    return (;
        raw,
        catalog,
        ds,
        calibration,
        identification,
        estimates,
        parameter_sets,
        episode,
        episode_assessment,
        registry_assessments,
        replay_runs,
        validation,
        robustness,
        accounting,
        artifact,
    )
end

# ─────────────────────────────────────────────────────────────────
# 保存・決定性・reload 確認
# ─────────────────────────────────────────────────────────────────

function _cced_identity_summary(artifact::AbstractDict)
    identity = artifact["identity"]
    return (
        catalog_version = identity["catalog_version"],
        dataset_hash = identity["dataset_hash"],
        targets_hash = identity["targets_hash"],
        parameter_set_hash = identity["parameter_set_hash"],
        episode_hash = identity["episode_hash"],
        replay_hash = identity["replay_hash"],
    )
end

"""
    run_capex_credit_cycle_empirical_demo(; outdir::AbstractString, verbose::Bool=true) -> NamedTuple

パイプラインを2回実行して決定性（§12.7 項目60）を確認し、1回目の artifact を `outdir` へ
保存する。保存済み artifact を再読み込みして identity chain が一致すること（§12.7 項目61）、
会計検証12項目が `acc_pass`（§12.7 項目62）であることも確認する。
"""
function run_capex_credit_cycle_empirical_demo(;
    outdir::AbstractString,
    verbose::Bool = true,
)
    isdir(outdir) || mkpath(outdir)

    verbose && println("[1/4] パイプライン1回目を実行中（catalog→…→robustness）…")
    result1 = _cced_run_pipeline()

    verbose && println("[2/4] パイプライン2回目を実行中（決定性確認 §12.7-60）…")
    result2 = _cced_run_pipeline()

    identity1 = _cced_identity_summary(result1.artifact)
    identity2 = _cced_identity_summary(result2.artifact)
    determinism_ok =
        identity1.dataset_hash == identity2.dataset_hash &&
        identity1.targets_hash == identity2.targets_hash &&
        identity1.parameter_set_hash == identity2.parameter_set_hash &&
        identity1.episode_hash == identity2.episode_hash &&
        identity1.replay_hash == identity2.replay_hash

    verbose && println("[3/4] artifact・report を保存中…")
    artifact_paths = save_capex_empirical_artifact(outdir, result1.artifact)
    report_path =
        save_capex_empirical_report(joinpath(outdir, "report.md"), result1.artifact)
    determinism_path = joinpath(outdir, "determinism_check.json")
    write(
        determinism_path,
        JSON3.write(
            Dict{String, Any}(
                "determinism_ok" => determinism_ok,
                "run1_identity" =>
                    Dict{String, Any}(String(k) => v for (k, v) in pairs(identity1)),
                "run2_identity" =>
                    Dict{String, Any}(String(k) => v for (k, v) in pairs(identity2)),
            ),
        ),
    )

    verbose && println("[4/4] 保存済み artifact の reload を確認中（§12.7-61）…")
    loaded = load_capex_empirical_artifact(outdir)
    reload_ok =
        loaded["identity"]["dataset_hash"] == identity1.dataset_hash &&
        loaded["identity"]["targets_hash"] == identity1.targets_hash &&
        loaded["identity"]["parameter_set_hash"] == identity1.parameter_set_hash

    accounting_ok = result1.accounting !== nothing && accounting_passed(result1.accounting)

    return (;
        outdir = outdir,
        result = result1,
        determinism_ok = determinism_ok,
        reload_ok = reload_ok,
        accounting_ok = accounting_ok,
        accounting_checks_performed = result1.accounting === nothing ? 0 :
                                      result1.accounting.checks_performed,
        registry_selected = [
            a.id for a in result1.registry_assessments if a.status === :selected
        ],
        episode_status = result1.episode_assessment.status,
        artifact_paths = vcat(artifact_paths, [report_path, determinism_path]),
    )
end

# ─────────────────────────────────────────────────────────────────
# スクリプトとして直接実行された場合のみ走らせる（include では実行しない）
# ─────────────────────────────────────────────────────────────────
if abspath(PROGRAM_FILE) == @__FILE__
    outdir = get(
        ENV,
        "CCC_EMPIRICAL_DEMO_OUTDIR",
        joinpath(@__DIR__, "..", "artifacts", "capex_credit_cycle_empirical_demo"),
    )

    println(
        """
╔═══════════════════════════════════════════════════════════════════╗
║  部門別CAPEX・信用循環モデル 実証統合デモ                              ║
║  catalog→raw→measurement→較正/識別/推定→episode→replay→検証→感応度 ║
╚═══════════════════════════════════════════════════════════════════╝

  出力先: $(outdir)

注意: 入力データはすべて合成（synthetic）であり、実際の米国経済データではない。
      fit は因果妥当性・景気後退確率・投資助言ではない。本デモは投資判断・政策立案の
      根拠として使用することを意図していない。詳細: docs/examples/capex_credit_cycle_empirical_demo.md
""",
    )

    out = run_capex_credit_cycle_empirical_demo(; outdir = outdir)

    println(
        """

完了。出力ディレクトリ: $(out.outdir)

決定性（2回実行でidentity chainが一致）: $(out.determinism_ok)
reload一致（保存済みartifactからidentityを再構築）: $(out.reload_ok)
会計検証12項目 acc_pass（checks_performed=$(out.accounting_checks_performed)）: $(out.accounting_ok)
本デモの合成 episode の NC-1–NC-7 判定: $(out.episode_status)
実 H1–H6 registry で :selected となった候補: $(out.registry_selected)

詳細: docs/examples/capex_credit_cycle_empirical_demo.md
""",
    )
end
