# japan_fiscal_model_adapters.jl: Japan Fiscal Scenario Lab の model-specific adapter 層
# （Issue #276）。#274 capability/mapping 契約（japan_fiscal_capability.jl）が確定した
# 55 セルのうち adoption=:primary/:supporting の 14 セルについて、`JapanFiscalScenario` の
# assumption を実際のモデル入力へ変換し、baseline/scenario の系列を生成する薄い adapter。
#
# 設計方針（ADR 0023）:
#   - `JapanFiscalScenarioAssumption` は timing/persistence を持たない（#275）ため、本ファイルが
#     Phase 3 の唯一の新しい時間軸方針として「評価区間の先頭期からの恒久的な step」を固定する
#     （`_japan_fiscal_permanent_step_path`）。各 mapping 行の `reason`/`baseline_requirements` が
#     一様に「恒久的」と記述していることと整合する。
#   - 9 モデルいずれも一般 macro-event レイヤー（Scenario/run_scenario/map_event）を経由しない。
#     各モデルの既存 public API（`capex_run`/`_sim_run`/`impulse_response`/`transition_path`/
#     `*_shock`/`*_comparison` 比較ヘルパ）を直接呼ぶ。モデル方程式・`run_scenario`・`map_event`
#     はいずれも変更しない。
#   - `mapping.inputs` が受け付けない concept の assumption は無視する（禁止代理を作らない）。
#     受け付けない事実は `japan_fiscal_coverage`（#285）が mapping registry から機械的に導出する。
#   - baseline は各モデルの既存 example/illustrative パラメータ（`examples/`・`docs/models/` で
#     使われている値と同一）を用いる。日本較正は行わない（G-02）。
#   - 単位換算は `JapanFiscalInputMapping.conversion`（#274）に記述された式をそのまま実行する。
#     期間長に依存し一意でない換算（RBC の TFP 水準シフト・AD-AS の潜在産出シフト）は
#     1 年相当として計算し、その旨を `warnings` へ記録する。
#
# 依存: scenarios/japan_fiscal_capability.jl（JapanFiscalModelMapping 等）・
# scenarios/japan_fiscal_scenario_schema.jl（JapanFiscalScenario）・
# scenarios/scenario_time.jl（shock_shape_path・PersistenceSpec）・models/*.jl（全11モデル）。
#
# 設計契約:
#   docs/architecture/japan_fiscal_scenario_result_contract.md
#   docs/adr/0023-japan-fiscal-scenario-result-artifact-contract.md

"Japan Fiscal Scenario Lab の model adapter 層の契約 version。"
const JAPAN_FISCAL_ADAPTER_CONTRACT_VERSION = "japan-fiscal-scenario-adapter/1.0.0"

"time_path/static_point 系モデルの既定ホライズン（四半期・期）。CCC 実証統合デモの評価区間
（20四半期）と揃える。"
const JAPAN_FISCAL_DEFAULT_HORIZON = 20

# ===========================================================================
# JapanFiscalAppliedInput
# ===========================================================================

"""
    JapanFiscalAppliedInput

`JapanFiscalScenarioAssumption` が実際にモデルへ適用された結果 1 件を保持する traceability
record（assumption → applied input）。#276 の受け入れ条件「result artifact から
assumption→applied input→model output を追跡できる」を満たす。

## フィールド
- `assumption_id::String`: 由来する `JapanFiscalScenarioAssumption.assumption_id`。
- `concept::Symbol`: `JAPAN_FISCAL_ASSUMPTION_CONCEPTS` のいずれか。
- `model::Symbol`: `JAPAN_FISCAL_CANDIDATE_MODELS` のいずれか。
- `target::Symbol`: 適用先のモデル変数・パラメータ名（`JapanFiscalInputMapping.variable`）。
- `input_kind::Symbol`: `JAPAN_FISCAL_INPUT_KINDS` のいずれか。
- `unit::String`: 適用先の単位（`JapanFiscalInputMapping.unit`）。
- `magnitude_model_units::Float64`: 単位換算後、実際にモデルへ加えた大きさ。
- `conversion::String`: 用いた換算式（`JapanFiscalInputMapping.conversion` を provenance として
  そのまま複製する。再導出しない）。
- `notes::String`: 由来する assumption の `notes`。
"""
struct JapanFiscalAppliedInput
    assumption_id::String
    concept::Symbol
    model::Symbol
    target::Symbol
    input_kind::Symbol
    unit::String
    magnitude_model_units::Float64
    conversion::String
    notes::String

    function JapanFiscalAppliedInput(;
        assumption_id::AbstractString,
        concept::Symbol,
        model::Symbol,
        target::Symbol,
        input_kind::Symbol,
        unit::AbstractString,
        magnitude_model_units::Float64,
        conversion::AbstractString,
        notes::AbstractString = "",
    )
        isempty(assumption_id) && throw(
            ArgumentError("JapanFiscalAppliedInput.assumption_id は空であってはいけません"),
        )
        _jf_check(concept, JAPAN_FISCAL_ASSUMPTION_CONCEPTS, "concept")
        _jf_check(model, JAPAN_FISCAL_CANDIDATE_MODELS, "model")
        _jf_check(input_kind, JAPAN_FISCAL_INPUT_KINDS, "input_kind")
        isfinite(magnitude_model_units) || throw(
            ArgumentError(
                "JapanFiscalAppliedInput.magnitude_model_units は有限でなければなりません" *
                "（実値: $(magnitude_model_units)）",
            ),
        )
        isempty(conversion) && throw(
            ArgumentError(
                "JapanFiscalAppliedInput.conversion は空であってはいけません" *
                "（assumption_id=$(assumption_id)）。単位換算式を provenance として記録する。",
            ),
        )
        return new(
            String(assumption_id),
            concept,
            model,
            target,
            input_kind,
            String(unit),
            magnitude_model_units,
            String(conversion),
            String(notes),
        )
    end
end

function to_dict(a::JapanFiscalAppliedInput)
    return Dict{String, Any}(
        "assumption_id" => a.assumption_id,
        "concept" => String(a.concept),
        "model" => String(a.model),
        "target" => String(a.target),
        "input_kind" => String(a.input_kind),
        "unit" => a.unit,
        "magnitude_model_units" => a.magnitude_model_units,
        "conversion" => a.conversion,
        "notes" => a.notes,
    )
end

# ===========================================================================
# JapanFiscalAdapterOutput（adapter の共通戻り値）
# ===========================================================================

"""
    JapanFiscalAdapterOutput

per-model adapter 関数の共通戻り値。`japan_fiscal_run`（japan_fiscal_result.jl）がこれを
`JapanFiscalScenarioResult` へ組み立てる。

## フィールド
- `result_shape::Symbol`: `:time_path`（期別系列を返す）または `:static_point`（均衡 1 点比較）。
- `periods::Vector{Int}`: `result_shape=:time_path` のときの期インデックス。`:static_point` は
  `[1]`（baseline）・`[2]`（scenario）に対応する 2 要素固定。
- `baseline::Dict{Symbol,Vector{Float64}}` / `scenario::Dict{Symbol,Vector{Float64}}`:
  `JAPAN_FISCAL_OUTPUT_CONCEPTS` のうち mapping の `endogenous_outputs` に含まれる概念をキーに
  持つ、モデル単位そのままの系列。
- `applied_inputs::Vector{JapanFiscalAppliedInput}`
- `parameter_identity::NamedTuple`: baseline モデルの `parameters(m)`。
- `sensitivity::Dict{String,Any}`: §5.2/§5.3 が要求する ±50% 感応度・closing-variable 感応度。
- `warnings::Vector{String}`
"""
struct JapanFiscalAdapterOutput
    result_shape::Symbol
    periods::Vector{Int}
    baseline::Dict{Symbol, Vector{Float64}}
    scenario::Dict{Symbol, Vector{Float64}}
    applied_inputs::Vector{JapanFiscalAppliedInput}
    parameter_identity::NamedTuple
    sensitivity::Dict{String, Any}
    warnings::Vector{String}
end

# ===========================================================================
# 共有ヘルパー
# ===========================================================================

"`mapping.inputs` から `concept` の行を引く。無ければ `nothing`。"
function _jf_input_row(mapping::JapanFiscalModelMapping, concept::Symbol)
    for i in mapping.inputs
        i.concept === concept && return i
    end
    return nothing
end

"`scenario.assumptions` から `concept` の assumption を引く。無ければ `nothing`。"
function _jf_assumption_for(scenario::JapanFiscalScenario, concept::Symbol)
    for a in scenario.assumptions
        a.concept === concept && return a
    end
    return nothing
end

"""
    _jf_applied(scenario, mapping)

`mapping` が受け付け（`:not_accepted` でない）、かつ `scenario` に実際に assumption がある
concept を `(assumption, input_row)` の `Vector` として返す（宣言順ではなく `mapping.inputs`
の順）。受け付けない concept の assumption は無視する（禁止代理を作らない。`coverage` が
別途 `unsupported_concepts` として開示する）。
"""
function _jf_applied(scenario::JapanFiscalScenario, mapping::JapanFiscalModelMapping)
    out = Tuple{JapanFiscalScenarioAssumption, JapanFiscalInputMapping}[]
    for row in mapping.inputs
        row.input_kind === :not_accepted && continue
        a = _jf_assumption_for(scenario, row.concept)
        a === nothing && continue
        push!(out, (a, row))
    end
    return out
end

"""
    _japan_fiscal_permanent_step_path(magnitude, t0, periods) -> Vector{Float64}

期 `t0` から恒久的に `magnitude` を適用する期別パス（ADR 0023 決定1）。
`shock_shape_path`（scenarios/scenario_time.jl）をそのまま用いる。
"""
function _japan_fiscal_permanent_step_path(
    magnitude::Float64,
    t0::Int,
    periods::Vector{Int},
)
    return shock_shape_path(
        PersistenceSpec(; shape = :step, duration = nothing),
        magnitude,
        t0,
        periods,
        nothing,
    )
end

"static_point 2点比較を `JapanFiscalAdapterOutput` の `baseline`/`scenario` 形式へ変換する
（`SimulationResult.variables[name] = [baseline_value, scenario_value]` を分解する）。
`output_map` は `output_concept => SimulationResult 変数名` の対応。"
function _jf_static_point_series(sr::SimulationResult, output_map::Dict{Symbol, String})
    baseline = Dict{Symbol, Vector{Float64}}()
    scenario = Dict{Symbol, Vector{Float64}}()
    for (concept, varname) in output_map
        v = sr.variables[varname]
        baseline[concept] = [v[1]]
        scenario[concept] = [v[2]]
    end
    return (baseline = baseline, scenario = scenario)
end

"`±50%` 感応度を計算する共通ヘルパー。`f(mult)` は倍率 `mult` を当てたときの
`(baseline, scenario)` の出力概念別系列ペアを返す関数。`concept` は代表出力概念（例:
`:output`）。感応度は scenario 系列の最終期における baseline 比の相対差で要約する。"
function _jf_pm50_sensitivity(f::Function, concept::Symbol; label::AbstractString)
    lo = f(0.5)
    hi = f(1.5)
    summarize(pair) = begin
        b = pair.baseline[concept]
        s = pair.scenario[concept]
        bv = b[end]
        sv = s[end]
        abs(bv) < 1e-10 ? nothing : (sv - bv) / bv
    end
    return Dict{String, Any}(
        label => Dict{String, Any}(
            "variable" => String(concept),
            "minus_50pct" => summarize(lo),
            "plus_50pct" => summarize(hi),
        ),
    )
end

# ===========================================================================
# static_point モデル: IS-LM / AD-AS / Mundell-Fleming
# ===========================================================================

"IS-LM/AD-AS/Mundell-Flemingで共通の `government_spending`/`tax` assumption 読み取り。
値が無い concept は baseline のまま（0シフト）とする。"
function _jf_fiscal_shift(scenario::JapanFiscalScenario, mapping::JapanFiscalModelMapping)
    applied = _jf_applied(scenario, mapping)
    g_shift = 0.0
    t_shift = 0.0
    inputs = JapanFiscalAppliedInput[]
    for (a, row) in applied
        if row.concept === :government_spending
            g_shift = a.magnitude
            push!(
                inputs,
                JapanFiscalAppliedInput(;
                    assumption_id = a.assumption_id,
                    concept = a.concept,
                    model = mapping.model,
                    target = row.variable,
                    input_kind = row.input_kind,
                    unit = row.unit,
                    magnitude_model_units = g_shift,
                    conversion = row.conversion,
                    notes = a.notes,
                ),
            )
        elseif row.concept === :tax
            t_shift = a.magnitude
            push!(
                inputs,
                JapanFiscalAppliedInput(;
                    assumption_id = a.assumption_id,
                    concept = a.concept,
                    model = mapping.model,
                    target = row.variable,
                    input_kind = row.input_kind,
                    unit = row.unit,
                    magnitude_model_units = t_shift,
                    conversion = row.conversion,
                    notes = a.notes,
                ),
            )
        end
    end
    return (g_shift = g_shift, t_shift = t_shift, inputs = inputs)
end

function _japan_fiscal_adapt_islm(
    mapping::JapanFiscalModelMapping,
    scenario::JapanFiscalScenario;
    horizon::Int,
)
    m_base = ISLMModel(100.0, 0.8, 200.0, 50.0, 100.0, 100.0, 0.2, 100.0, 1000.0, 1.0)
    shift = _jf_fiscal_shift(scenario, mapping)
    build(mult) = ISLMModel(
        m_base.c0,
        m_base.c1,
        m_base.I0,
        m_base.b,
        m_base.G + mult * shift.g_shift,
        m_base.T + mult * shift.t_shift,
        m_base.l1,
        m_base.l2,
        m_base.M,
        m_base.P,
    )
    output_map =
        Dict(:output => "Y", :nominal_rate => "r", :consumption => "C", :investment => "I")
    sr = islm_policy_shock(m_base, build(1.0))
    series = _jf_static_point_series(sr, output_map)
    sens = _jf_pm50_sensitivity(
        mult ->
            _jf_static_point_series(islm_policy_shock(m_base, build(mult)), output_map),
        :output;
        label = "fiscal_multiplier_c1_b_l1_l2",
    )
    return JapanFiscalAdapterOutput(
        :static_point,
        [1, 2],
        series.baseline,
        series.scenario,
        shift.inputs,
        parameters(m_base),
        sens,
        String[],
    )
end

function _japan_fiscal_adapt_adas(
    mapping::JapanFiscalModelMapping,
    scenario::JapanFiscalScenario;
    horizon::Int,
)
    m_base = ADASModel(
        100.0,
        0.8,
        200.0,
        50.0,
        100.0,
        100.0,
        0.2,
        100.0,
        300.0,
        1500.0,
        500.0,
        1.0,
    )
    shift = _jf_fiscal_shift(scenario, mapping)

    # productivity_growth → Y_n（high_growth_productivity のみ。fiscal_consolidation では
    # 常に concept が無く 0）。§4.4 の換算は期間長に依存し一意でない（1年相当として計算する）。
    warnings = String[]
    y_n_shift = 0.0
    pg_input = nothing
    pg_row = _jf_input_row(mapping, :productivity_growth)
    if pg_row !== nothing && pg_row.input_kind !== :not_accepted
        a = _jf_assumption_for(scenario, :productivity_growth)
        if a !== nothing
            y_n_shift = m_base.Y_n * ((1.0 + a.magnitude / 100.0) - 1.0)
            push!(
                warnings,
                "productivity_growth→Y_n の換算は対象期間を1年相当と仮定した結果であり、一意ではない（#274 §4.4）。",
            )
            pg_input = JapanFiscalAppliedInput(;
                assumption_id = a.assumption_id,
                concept = :productivity_growth,
                model = mapping.model,
                target = pg_row.variable,
                input_kind = pg_row.input_kind,
                unit = pg_row.unit,
                magnitude_model_units = y_n_shift,
                conversion = pg_row.conversion,
                notes = a.notes,
            )
        end
    end

    build(mult) = ADASModel(
        m_base.c0,
        m_base.c1,
        m_base.I0,
        m_base.b,
        m_base.G + mult * shift.g_shift,
        m_base.T + mult * shift.t_shift,
        m_base.l1,
        m_base.l2,
        m_base.M,
        m_base.Y_n + mult * y_n_shift,
        m_base.v,
        m_base.P_e,
    )
    output_map = Dict(
        :output => "Y",
        :price_level => "P",
        :nominal_rate => "r",
        :consumption => "C",
        :investment => "I",
    )
    sr = adas_shock_compare(m_base, build(1.0))
    series = _jf_static_point_series(sr, output_map)
    sens = _jf_pm50_sensitivity(
        mult -> _jf_static_point_series(
            adas_shock_compare(m_base, build(mult)),
            output_map,
        ),
        :output;
        label = "sras_slope_v_expected_price",
    )
    inputs = copy(shift.inputs)
    pg_input === nothing || push!(inputs, pg_input)
    return JapanFiscalAdapterOutput(
        :static_point,
        [1, 2],
        series.baseline,
        series.scenario,
        inputs,
        parameters(m_base),
        sens,
        warnings,
    )
end

function _japan_fiscal_adapt_mundell_fleming(
    mapping::JapanFiscalModelMapping,
    scenario::JapanFiscalScenario;
    horizon::Int,
)
    m_base = MundellFlemingModel(
        100.0,
        0.8,
        200.0,
        50.0,
        100.0,
        100.0,
        0.2,
        100.0,
        1000.0,
        1.0,
        0.02,
        50.0,
        10.0,
    )
    shift = _jf_fiscal_shift(scenario, mapping)
    build(mult) = MundellFlemingModel(
        m_base.c0,
        m_base.c1,
        m_base.I0,
        m_base.b,
        m_base.G + mult * shift.g_shift,
        m_base.T + mult * shift.t_shift,
        m_base.l1,
        m_base.l2,
        m_base.M,
        m_base.P,
        m_base.r_star,
        m_base.nx0,
        m_base.nx1,
    )
    output_map = Dict(
        :output => "Y",
        :exchange_rate => "e",
        :net_exports => "NX",
        :consumption => "C",
        :investment => "I",
    )
    sr = mf_policy_shock(m_base, build(1.0))
    series = _jf_static_point_series(sr, output_map)
    sens = _jf_pm50_sensitivity(
        mult ->
            _jf_static_point_series(mf_policy_shock(m_base, build(mult)), output_map),
        :net_exports;
        label = "nx_exchange_rate_sensitivity_nx1",
    )
    return JapanFiscalAdapterOutput(
        :static_point,
        [1, 2],
        series.baseline,
        series.scenario,
        shift.inputs,
        parameters(m_base),
        sens,
        String[],
    )
end

# ===========================================================================
# static_point（2 インスタンス比較）: Keen
# ===========================================================================

function _japan_fiscal_adapt_keen(
    mapping::JapanFiscalModelMapping,
    scenario::JapanFiscalScenario;
    horizon::Int,
)
    m_base =
        KeenModel(0.025, 0.02, 0.01, 3.0, 0.03, 0.0400641, 6.41e-5, -0.0065, exp(-5), 20.0)
    applied = _jf_applied(scenario, mapping)
    r_shift = 0.0
    alpha_shift = 0.0
    inputs = JapanFiscalAppliedInput[]
    sens_label = ""
    for (a, row) in applied
        if row.concept === :long_rate_funding_condition
            # bp → 年率実質金利（decimal）。bp/10000（#274 conversion）。
            r_shift = a.magnitude / 10000.0
            sens_label = "lending_rate_r_bistability"
            push!(
                inputs,
                JapanFiscalAppliedInput(;
                    assumption_id = a.assumption_id,
                    concept = a.concept,
                    model = mapping.model,
                    target = row.variable,
                    input_kind = row.input_kind,
                    unit = row.unit,
                    magnitude_model_units = r_shift,
                    conversion = row.conversion,
                    notes = a.notes,
                ),
            )
        elseif row.concept === :productivity_growth
            alpha_shift = a.magnitude / 100.0
            sens_label = "labor_productivity_growth_alpha_bistability"
            push!(
                inputs,
                JapanFiscalAppliedInput(;
                    assumption_id = a.assumption_id,
                    concept = a.concept,
                    model = mapping.model,
                    target = row.variable,
                    input_kind = row.input_kind,
                    unit = row.unit,
                    magnitude_model_units = alpha_shift,
                    conversion = row.conversion,
                    notes = a.notes,
                ),
            )
        end
    end
    build(mult) = KeenModel(
        m_base.α + mult * alpha_shift,
        m_base.β,
        m_base.δ,
        m_base.ν,
        m_base.r + mult * r_shift,
        m_base.φ0,
        m_base.φ1,
        m_base.κ0,
        m_base.κ1,
        m_base.κ2,
    )
    output_map = Dict(:private_debt => "d", :employment => "λ")
    sr = keen_scenario_comparison(m_base, build(1.0))
    series = _jf_static_point_series(sr, output_map)
    sens =
        isempty(sens_label) ? Dict{String, Any}() :
        _jf_pm50_sensitivity(
            mult -> _jf_static_point_series(
                keen_scenario_comparison(m_base, build(mult)),
                output_map,
            ),
            :private_debt;
            label = sens_label,
        )
    return JapanFiscalAdapterOutput(
        :static_point,
        [1, 2],
        series.baseline,
        series.scenario,
        inputs,
        parameters(m_base),
        sens,
        [
            "Keen は双安定系であり、軌道の時間形状は初期値・パラメータに過敏である（G-09）。" *
            "本結果は恒久パラメータ変更後の良い均衡2点比較であり、時点の主張は行わない。",
        ],
    )
end

# ===========================================================================
# time_path: Solow
# ===========================================================================

function _japan_fiscal_adapt_solow(
    mapping::JapanFiscalModelMapping,
    scenario::JapanFiscalScenario;
    horizon::Int,
)
    m_base = SolowModel(0.3, 0.2, 0.1, 0.01, 0.02)
    applied = _jf_applied(scenario, mapping)
    g_shift = 0.0
    inputs = JapanFiscalAppliedInput[]
    for (a, row) in applied
        row.concept === :productivity_growth || continue
        g_shift = a.magnitude / 100.0
        push!(
            inputs,
            JapanFiscalAppliedInput(;
                assumption_id = a.assumption_id,
                concept = a.concept,
                model = mapping.model,
                target = row.variable,
                input_kind = row.input_kind,
                unit = row.unit,
                magnitude_model_units = g_shift,
                conversion = row.conversion,
                notes = a.notes,
            ),
        )
    end
    k0 = solow_ep(m_base)[1]
    build(mult) =
        SolowModel(m_base.α, m_base.s, m_base.δ, m_base.n, m_base.g + mult * g_shift)
    periods = collect(1:horizon)
    tp_base = transition_path(m_base, k0; T = horizon)
    tp_scn = transition_path(build(1.0), k0; T = horizon)
    baseline = Dict{Symbol, Vector{Float64}}(
        :output => tp_base.y,
        :capital_stock => tp_base.k,
        :consumption => tp_base.c,
    )
    scn = Dict{Symbol, Vector{Float64}}(
        :output => tp_scn.y,
        :capital_stock => tp_scn.k,
        :consumption => tp_scn.c,
    )
    sens = _jf_pm50_sensitivity(
        mult -> (
            baseline = Dict(:output => tp_base.y),
            scenario = Dict(:output => transition_path(build(mult), k0; T = horizon).y),
        ),
        :output;
        label = "growth_rate_g_sensitivity",
    )
    return JapanFiscalAdapterOutput(
        :time_path,
        periods,
        baseline,
        scn,
        inputs,
        parameters(m_base),
        sens,
        [
            "output/capital_stock/consumption は効率労働単位あたりの量であり、Y=y·A·L による" *
            "水準量への変換は行わない（日本の量として提示しない、G-02）。",
        ],
    )
end

# ===========================================================================
# time_path: RBC
# ===========================================================================

function _japan_fiscal_adapt_rbc(
    mapping::JapanFiscalModelMapping,
    scenario::JapanFiscalScenario;
    horizon::Int,
)
    m_base = RBCModel(0.3, 0.99, 1.0, 0.025, 1.0, 0.9)
    applied = _jf_applied(scenario, mapping)
    shock_size = 0.0
    inputs = JapanFiscalAppliedInput[]
    warnings = String[]
    for (a, row) in applied
        row.concept === :productivity_growth || continue
        # %pt年率成長率 → 1年相当の対数水準シフト（一意でない、#274 conversion）。
        shock_size = log(1.0 + a.magnitude / 100.0)
        push!(
            warnings,
            "productivity_growth→A の換算は対象期間を1年相当と仮定した対数水準シフトであり、" *
            "一意ではない（#274 §4.4）。",
        )
        push!(
            inputs,
            JapanFiscalAppliedInput(;
                assumption_id = a.assumption_id,
                concept = a.concept,
                model = mapping.model,
                target = row.variable,
                input_kind = row.input_kind,
                unit = row.unit,
                magnitude_model_units = shock_size,
                conversion = row.conversion,
                notes = a.notes,
            ),
        )
    end
    irf = impulse_response(m_base, shock_size; maxT = horizon)
    n = length(irf.ŷ)  # RBC の impulse_response は maxT+1 要素を返す
    periods = collect(1:n)
    baseline = Dict{Symbol, Vector{Float64}}(
        :output => zeros(n),
        :capital_stock => zeros(n),
        :consumption => zeros(n),
        :employment => zeros(n),
        :real_rate => zeros(n),
    )
    scn = Dict{Symbol, Vector{Float64}}(
        :output => collect(irf.ŷ),
        :capital_stock => collect(irf.k̂),
        :consumption => collect(irf.ĉ),
        :employment => collect(irf.l̂),
        :real_rate => collect(irf.r̂),
    )
    sens = _jf_pm50_sensitivity(
        mult -> (
            baseline = Dict(:output => zeros(n)),
            scenario = Dict(
                :output => collect(
                    impulse_response(m_base, shock_size * mult; maxT = horizon).ŷ,
                ),
            ),
        ),
        :output;
        label = "tfp_shock_size_sensitivity",
    )
    push!(warnings, "系列は定常状態からの対数偏差（%）であり、水準経路ではない。")
    return JapanFiscalAdapterOutput(
        :time_path,
        periods,
        baseline,
        scn,
        inputs,
        parameters(m_base),
        sens,
        warnings,
    )
end

# ===========================================================================
# time_path: New Keynesian
# ===========================================================================

function _japan_fiscal_adapt_new_keynesian(
    mapping::JapanFiscalModelMapping,
    scenario::JapanFiscalScenario;
    horizon::Int,
)
    m_base = NewKeynesianModel(1.0, 0.02, 0.99, 0.1, 1.5, 0.5, 0.02, 0.8, 0.5, 0.5)
    applied = _jf_applied(scenario, mapping)
    monetary_shock = 0.0
    pi_star_shift = 0.0
    inputs = JapanFiscalAppliedInput[]
    warnings = String[]
    for (a, row) in applied
        if row.concept === :policy_rate
            monetary_shock = a.magnitude / 100.0
            push!(
                inputs,
                JapanFiscalAppliedInput(;
                    assumption_id = a.assumption_id,
                    concept = a.concept,
                    model = mapping.model,
                    target = row.variable,
                    input_kind = row.input_kind,
                    unit = row.unit,
                    magnitude_model_units = monetary_shock,
                    conversion = row.conversion,
                    notes = a.notes,
                ),
            )
        elseif row.concept === :inflation
            pi_star_shift = a.magnitude / 100.0
            push!(
                inputs,
                JapanFiscalAppliedInput(;
                    assumption_id = a.assumption_id,
                    concept = a.concept,
                    model = mapping.model,
                    target = row.variable,
                    input_kind = row.input_kind,
                    unit = row.unit,
                    magnitude_model_units = pi_star_shift,
                    conversion = row.conversion,
                    notes = a.notes,
                ),
            )
        end
    end
    if m_base.ρ_m >= 0.95
        push!(warnings, "ρ_m が1に近く MSV 解が不安定化しうる（#274 §5.2）。")
    end

    m_scn = NewKeynesianModel(
        m_base.σ,
        m_base.r_n,
        m_base.β,
        m_base.κ,
        m_base.φ_π,
        m_base.φ_x,
        m_base.π_star + pi_star_shift,
        m_base.ρ_x,
        m_base.ρ_c,
        m_base.ρ_m,
    )
    periods = collect(1:horizon)
    irf =
        monetary_shock == 0.0 ?
        (x = zeros(horizon), π = zeros(horizon), i = zeros(horizon)) :
        impulse_response(m_scn, monetary_shock; shock = :monetary, T = horizon)

    baseline = Dict{Symbol, Vector{Float64}}(
        :output_gap => zeros(horizon),
        :inflation => fill(m_base.π_star, horizon),
        :nominal_rate => fill(m_base.r_n + m_base.π_star, horizon),
        :real_rate => fill(m_base.r_n, horizon),
    )
    infl_level = [nk_inflation_level(m_scn, irf.π[t]) for t in 1:horizon]
    nom_level = [nk_nominal_rate_level(m_scn, irf.i[t]) for t in 1:horizon]
    scn = Dict{Symbol, Vector{Float64}}(
        :output_gap => collect(irf.x),
        :inflation => infl_level,
        :nominal_rate => nom_level,
        :real_rate => nom_level .- infl_level,
    )
    sens = _jf_pm50_sensitivity(
        mult -> (
            baseline = Dict(:output_gap => zeros(horizon)),
            scenario = Dict(
                :output_gap => collect(
                    impulse_response(
                        m_scn,
                        monetary_shock * mult;
                        shock = :monetary,
                        T = horizon,
                    ).x,
                ),
            ),
        ),
        :output_gap;
        label = "monetary_shock_size_sensitivity",
    )
    return JapanFiscalAdapterOutput(
        :time_path,
        periods,
        baseline,
        scn,
        inputs,
        parameters(m_base),
        sens,
        warnings,
    )
end

# ===========================================================================
# time_path: SIM
# ===========================================================================

function _japan_fiscal_adapt_sim(
    mapping::JapanFiscalModelMapping,
    scenario::JapanFiscalScenario;
    horizon::Int,
)
    m_base = SIMModel(; α1 = 0.6, α2 = 0.4, θ = 0.2, G = 20.0, W = 1.0)
    applied = _jf_applied(scenario, mapping)
    g_shift = 0.0
    theta_shift = 0.0
    inputs = JapanFiscalAppliedInput[]
    for (a, row) in applied
        if row.concept === :government_spending
            g_shift = a.magnitude
            push!(
                inputs,
                JapanFiscalAppliedInput(;
                    assumption_id = a.assumption_id,
                    concept = a.concept,
                    model = mapping.model,
                    target = row.variable,
                    input_kind = row.input_kind,
                    unit = row.unit,
                    magnitude_model_units = g_shift,
                    conversion = row.conversion,
                    notes = a.notes,
                ),
            )
        elseif row.concept === :tax
            theta_shift = a.magnitude
            push!(
                inputs,
                JapanFiscalAppliedInput(;
                    assumption_id = a.assumption_id,
                    concept = a.concept,
                    model = mapping.model,
                    target = row.variable,
                    input_kind = row.input_kind,
                    unit = row.unit,
                    magnitude_model_units = theta_shift,
                    conversion = row.conversion,
                    notes = a.notes,
                ),
            )
        end
    end
    H0 = steady_state(m_base).H
    periods = collect(1:horizon)
    Gseq_base = fill(m_base.G, horizon)
    θseq_base = fill(m_base.θ, horizon)

    run_scn(mult) = begin
        Gpath = m_base.G .+ _japan_fiscal_permanent_step_path(mult * g_shift, 1, periods)
        θpath =
            m_base.θ .+ _japan_fiscal_permanent_step_path(mult * theta_shift, 1, periods)
        _sim_run(m_base, H0, Gpath, θpath)
    end
    base_run = _sim_run(m_base, H0, Gseq_base, θseq_base)
    scn_run = run_scn(1.0)

    build_series(r) = Dict{Symbol, Vector{Float64}}(
        :output => r.Y,
        :government_balance => r.T .- r.G,
        :consumption => r.C,
        :employment => r.N,
        :money_stock => r.H,
    )
    baseline = build_series(base_run)
    scn = build_series(scn_run)
    sens = _jf_pm50_sensitivity(
        mult -> (
            baseline = Dict(:output => base_run.Y),
            scenario = Dict(:output => run_scn(mult).Y),
        ),
        :output;
        label = "alpha1_alpha2_multiplier_sensitivity",
    )
    return JapanFiscalAdapterOutput(
        :time_path,
        periods,
        baseline,
        scn,
        inputs,
        parameters(m_base),
        sens,
        String[],
    )
end

# ===========================================================================
# time_path: CCC（capex_credit_cycle）
# ===========================================================================

function _japan_fiscal_adapt_capex_credit_cycle(
    mapping::JapanFiscalModelMapping,
    scenario::JapanFiscalScenario;
    horizon::Int,
)
    m_base = capex_credit_cycle_model(capex_credit_cycle_default_targets())
    applied = _jf_applied(scenario, mapping)
    policy_shift = 0.0
    spread_shift = 0.0
    inputs = JapanFiscalAppliedInput[]
    for (a, row) in applied
        if row.concept === :policy_rate
            policy_shift = a.magnitude
            push!(
                inputs,
                JapanFiscalAppliedInput(;
                    assumption_id = a.assumption_id,
                    concept = a.concept,
                    model = mapping.model,
                    target = row.variable,
                    input_kind = row.input_kind,
                    unit = row.unit,
                    magnitude_model_units = policy_shift,
                    conversion = row.conversion,
                    notes = a.notes,
                ),
            )
        elseif row.concept === :long_rate_funding_condition
            spread_shift = a.magnitude
            push!(
                inputs,
                JapanFiscalAppliedInput(;
                    assumption_id = a.assumption_id,
                    concept = a.concept,
                    model = mapping.model,
                    target = row.variable,
                    input_kind = row.input_kind,
                    unit = row.unit,
                    magnitude_model_units = spread_shift,
                    conversion = row.conversion,
                    notes = a.notes,
                ),
            )
        end
    end

    options = CapexCreditCycleOptions(; horizon_eval = horizon)
    n = options.horizon_runup + options.horizon_eval
    periods_full = collect((-options.horizon_runup):(options.horizon_eval - 1))
    exog_base = _ccc_baseline_exog(m_base, n)

    build_exog(mult) = begin
        e = copy(exog_base)
        e[:policy_rate] =
            exog_base[:policy_rate] .+
            _japan_fiscal_permanent_step_path(mult * policy_shift, 0, periods_full)
        e[:spread_shock_ex] =
            exog_base[:spread_shock_ex] .+
            _japan_fiscal_permanent_step_path(mult * spread_shift, 0, periods_full)
        e
    end

    run_base = capex_run(m_base; exog = exog_base, options = options)
    run_scn = capex_run(m_base; exog = build_exog(1.0), options = options)

    eval_idx = findall(t -> t >= 0, run_base.periods)
    periods = run_base.periods[eval_idx]

    borrowing_cost(r) = Float64.(r.series.cost_capital_s1)[eval_idx]
    output(r) = Float64.(r.series.y_tot)[eval_idx]
    debt(r) = (Float64.(r.series.debt_s1) .+ Float64.(r.series.debt_s2) .+ Float64.(
        r.series.debt_s3,
    ))[eval_idx]
    investment(r) =
        (Float64.(r.series.capex_exec_s1) .+ Float64.(r.series.invest_s2) .+ Float64.(
            r.series.invest_s3,
        ))[eval_idx]
    employment(r) = Float64.(r.series.emp_tot)[eval_idx]
    consumption(r) = Float64.(r.series.cons)[eval_idx]

    baseline = Dict{Symbol, Vector{Float64}}(
        :output => output(run_base),
        :private_borrowing_cost => borrowing_cost(run_base),
        :private_debt => debt(run_base),
        :investment => investment(run_base),
        :employment => employment(run_base),
        :consumption => consumption(run_base),
    )
    scn = Dict{Symbol, Vector{Float64}}(
        :output => output(run_scn),
        :private_borrowing_cost => borrowing_cost(run_scn),
        :private_debt => debt(run_scn),
        :investment => investment(run_scn),
        :employment => employment(run_scn),
        :consumption => consumption(run_scn),
    )

    sens = Dict{String, Any}()
    merge!(
        sens,
        _jf_pm50_sensitivity(
            mult -> (
                baseline = Dict(:output => output(run_base)),
                scenario = Dict(
                    :output => output(
                        capex_run(m_base; exog = build_exog(mult), options = options),
                    ),
                ),
            ),
            :output;
            label = "funding_shock_pass_through_sensitivity",
        ),
    )

    warnings =
        String["ai_exp は baseline 値から動かしていない（#274 §5.2、日本シナリオの assumption ではない）。",]
    if policy_shift != 0.0 && spread_shift != 0.0
        push!(
            warnings,
            "policy_rate と spread_shock_ex を同時に適用した。両者の寄与分解（反実仮想）は" *
            "sensitivity.contribution_decomposition に記録する。",
        )
        run_policy_only = capex_run(
            m_base;
            exog = merge(exog_base, Dict(:policy_rate => build_exog(1.0)[:policy_rate])),
            options = options,
        )
        run_spread_only = capex_run(
            m_base;
            exog = merge(
                exog_base,
                Dict(:spread_shock_ex => build_exog(1.0)[:spread_shock_ex]),
            ),
            options = options,
        )
        sens["contribution_decomposition"] = Dict{String, Any}(
            "variable" => "output",
            "policy_rate_only" => output(run_policy_only)[end] - output(run_base)[end],
            "long_rate_funding_condition_only" =>
                output(run_spread_only)[end] - output(run_base)[end],
            "both" => output(run_scn)[end] - output(run_base)[end],
        )
    end

    return JapanFiscalAdapterOutput(
        :time_path,
        periods,
        baseline,
        scn,
        inputs,
        parameters(m_base),
        sens,
        warnings,
    )
end

# ===========================================================================
# registry
# ===========================================================================

"""
    JAPAN_FISCAL_MODEL_ADAPTERS

`model::Symbol => adapter 関数` の宣言的 registry（`adoption != :not_adopted` を持つ 9 モデル
のみ）。関数シグネチャは
`(mapping::JapanFiscalModelMapping, scenario::JapanFiscalScenario; horizon::Int) -> JapanFiscalAdapterOutput`
で統一する。
"""
const JAPAN_FISCAL_MODEL_ADAPTERS = Dict{Symbol, Function}(
    :islm => _japan_fiscal_adapt_islm,
    :adas => _japan_fiscal_adapt_adas,
    :mundell_fleming => _japan_fiscal_adapt_mundell_fleming,
    :keen => _japan_fiscal_adapt_keen,
    :solow => _japan_fiscal_adapt_solow,
    :rbc => _japan_fiscal_adapt_rbc,
    :new_keynesian => _japan_fiscal_adapt_new_keynesian,
    :sim => _japan_fiscal_adapt_sim,
    :capex_credit_cycle => _japan_fiscal_adapt_capex_credit_cycle,
)
