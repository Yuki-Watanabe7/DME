# capex_credit_cycle_cross_model_adapter.jl: `CapexCreditCycleModel`（CCC）向けの cross-model
# adapter（Issue #282 / `PN-2` の `X5`）。
#
# `ModelDerivedInput`（上流モデル由来入力）を、宣言的 registry `CCC_CROSS_MODEL_MAPPING_RULES` に
# 従って CCC の `exogenous_variables(m)` へ適用する `AppliedModelInput`（`L4`、型は変更しない）へ
# 変換する。event 由来の `map_event`（`capex_credit_cycle_event_adapter.jl`）とは**別の関数**であり、
# イベント型 registry・`MACRO_EVENT_*` 語彙を経由しない（ADR 0024 決定 14）。
#
# v1 で CCC が受理するのは派生中間需要チャネル（`:derived_out_of_model_demand`）の
# `ext_demand_s2` / `ext_demand_s3` のみ。供給能力・総産出の概念は構造上表現しないため拒否し、
# 近い変数（`ext_demand_s`・`capex_plan_shock_ex`・`ai_exp`）へ寄せない（設計 §7.3・`PG-01`）。
# 新しい外生変数は追加しない（#282 Non-goal）。
#
# 設計契約:
#   docs/architecture/pne_sector_output_integration.md §7.2–§7.4・§9.5・§10.2–§10.4
#   docs/adr/0024-pne-sector-output-cross-model-input-contract.md 決定 8・9・13・14

# ===========================================================================
# registry
# ===========================================================================

"""
    CrossModelMappingRule

CCC の cross-model mapping registry の 1 行（設計 §7.3・§10.2）。`target_variable = nothing` の行は
「CCC が構造上その概念を表現しない」ことを表し、`unsupported_reason` と `forbidden_proxies`
（寄せてはならない近い変数）を必須とする。

## フィールド
- `rule_id::String`
- `target_concept::Symbol` / `target_group::Union{Symbol,Nothing}`（`nothing` は concept の全 group）
- `target_variable::Union{Symbol,Nothing}`: `exogenous_variables(m)` の 7 変数のいずれか。
- `application_mode::Symbol` / `unit::String`
- `value_semantics::Symbol`: 受理する `ModelDerivedInput.value_semantics`。
- `baseline_reference::Symbol`: `:ccc_steady_state_exog`（`run_scenario` と同じ定常外生パス）。
- `sign_convention::Symbol`: `:non_positive`（PNE の実現産出比 ≤ 1 のため変化は 0 以下）。
- `frequency::Symbol`: `:quarter`。
- `unsupported_reason::Union{Symbol,Nothing}` / `forbidden_proxies::Vector{Symbol}`
- `contract_row::String`: 設計書の出典。
"""
struct CrossModelMappingRule
    rule_id::String
    target_concept::Symbol
    target_group::Union{Symbol, Nothing}
    target_variable::Union{Symbol, Nothing}
    application_mode::Symbol
    unit::String
    value_semantics::Symbol
    baseline_reference::Symbol
    sign_convention::Symbol
    frequency::Symbol
    unsupported_reason::Union{Symbol, Nothing}
    forbidden_proxies::Vector{Symbol}
    contract_row::String

    function CrossModelMappingRule(;
        rule_id::AbstractString,
        target_concept::Symbol,
        value_semantics::Symbol,
        contract_row::AbstractString,
        target_group::Union{Symbol, Nothing} = nothing,
        target_variable::Union{Symbol, Nothing} = nothing,
        application_mode::Symbol = :multiplicative,
        unit::AbstractString = "%",
        baseline_reference::Symbol = :ccc_steady_state_exog,
        sign_convention::Symbol = :non_positive,
        frequency::Symbol = :quarter,
        unsupported_reason::Union{Symbol, Nothing} = nothing,
        forbidden_proxies::Vector{Symbol} = Symbol[],
    )
        target_concept in CROSS_MODEL_TARGET_CONCEPTS || throw(
            ArgumentError(
                "CrossModelMappingRule.target_concept=$(target_concept) は未知の値です",
            ),
        )
        if target_variable === nothing
            unsupported_reason === nothing && throw(
                ArgumentError(
                    "CrossModelMappingRule($(rule_id)): 適用先なしの行は unsupported_reason を必須とします",
                ),
            )
            isempty(forbidden_proxies) && throw(
                ArgumentError(
                    "CrossModelMappingRule($(rule_id)): 適用先なしの行は forbidden_proxies を必須とします",
                ),
            )
        else
            target_variable in CAPEX_CC_EXOGENOUS_VARIABLES || throw(
                ArgumentError(
                    "CrossModelMappingRule($(rule_id)): target_variable=$(target_variable) は " *
                    "exogenous_variables(m) の 7 変数に含まれません（設計 §7.3）",
                ),
            )
            unsupported_reason === nothing || throw(
                ArgumentError(
                    "CrossModelMappingRule($(rule_id)): 適用先のある行に unsupported_reason を設定できません",
                ),
            )
            _macro_event_check_unit_application_mode(unit, application_mode)
        end
        for p in forbidden_proxies
            p in CAPEX_CC_EXOGENOUS_VARIABLES || throw(
                ArgumentError(
                    "CrossModelMappingRule($(rule_id)): forbidden_proxies の $(p) は CCC の外生変数ではありません",
                ),
            )
        end
        return new(
            String(rule_id),
            target_concept,
            target_group,
            target_variable,
            application_mode,
            String(unit),
            value_semantics,
            baseline_reference,
            sign_convention,
            frequency,
            unsupported_reason,
            forbidden_proxies,
            String(contract_row),
        )
    end
end

"""
    CCC_CROSS_MODEL_MAPPING_RULES

CCC の cross-model mapping registry（`ccc-cross-model-mapping/1.0.0`、設計 §7.3 の表と 1:1）。
受理行は派生中間需要チャネルの 2 行（`ext_demand_s2`・`ext_demand_s3`）のみ。
"""
const CCC_CROSS_MODEL_MAPPING_RULES = [
    CrossModelMappingRule(;
        rule_id = "ccc-xm/derived_out_of_model_demand/ext_demand_s2",
        target_concept = :derived_out_of_model_demand,
        target_group = :ext_demand_s2_customers,
        target_variable = :ext_demand_s2,
        value_semantics = :target_relative_change,
        contract_row = "pne_sector_output_integration §7.3 row 5",
    ),
    CrossModelMappingRule(;
        rule_id = "ccc-xm/derived_out_of_model_demand/ext_demand_s3",
        target_concept = :derived_out_of_model_demand,
        target_group = :ext_demand_s3_customers,
        target_variable = :ext_demand_s3,
        value_semantics = :target_relative_change,
        contract_row = "pne_sector_output_integration §7.3 row 6",
    ),
    CrossModelMappingRule(;
        rule_id = "ccc-xm/sector_supply_capacity",
        target_concept = :sector_supply_capacity,
        value_semantics = :group_realized_output_ratio,
        unsupported_reason = :no_exogenous_supply_capacity,
        forbidden_proxies = [:ext_demand_s2, :ext_demand_s3, :capex_plan_shock_ex, :ai_exp],
        contract_row = "pne_sector_output_integration §7.3 row supply-capacity (PG-01)",
    ),
    CrossModelMappingRule(;
        rule_id = "ccc-xm/aggregate_realized_output",
        target_concept = :aggregate_realized_output,
        value_semantics = :group_realized_output_ratio,
        unsupported_reason = :endogenous_outcome_in_target_model,
        forbidden_proxies = [:ext_demand_s2, :ext_demand_s3, :ai_exp],
        contract_row = "pne_sector_output_integration §7.3 row aggregate-output",
    ),
]

"""
    CCC_CROSS_MODEL_EXOGENOUS_COVERAGE

CCC の外生 7 変数ごとの PNE 由来入力の受理状況（設計 §7.3 の表の変数行）。`:accepted` は
`CCC_CROSS_MODEL_MAPPING_RULES` の受理行の適用先と一致しなければならない（テストで検査）。
"""
const CCC_CROSS_MODEL_EXOGENOUS_COVERAGE = (
    ai_exp = :expectation_not_realized_output,
    capex_plan_shock_ex = :decision_not_realized_output,
    spread_shock_ex = :financial_condition_not_produced_by_upstream,
    policy_rate = :financial_condition_not_produced_by_upstream,
    ext_demand_s2 = :accepted,
    ext_demand_s3 = :accepted,
    price_s1 = :price_not_produced_by_upstream,
)

const _CCC_CROSS_MODEL_UNSUPPORTED_TEXT = Dict{Symbol, String}(
    :no_exogenous_supply_capacity =>
        "CCC は部門の供給能力を外生入力として持たず（ycap_s = cap_s[t−1] / st_cor_s は内生）、" *
        "対応部門自身の供給制約を構造上表現しません（PG-01）",
    :endogenous_outcome_in_target_model =>
        "部門産出・総産出は CCC の内生変数であり、外生入力で上書きするとモデルの解を置き換える" *
        "ため構造上表現しません",
)

"`(target_concept, target_group)` に該当する registry 行（group 指定行を優先）。無ければ `nothing`。"
function _ccc_cross_model_select_rule(concept::Symbol, group::Symbol)
    specific = filter(
        r -> r.target_concept === concept && r.target_group === group,
        CCC_CROSS_MODEL_MAPPING_RULES,
    )
    isempty(specific) || return first(specific)
    generic = filter(
        r -> r.target_concept === concept && r.target_group === nothing,
        CCC_CROSS_MODEL_MAPPING_RULES,
    )
    return isempty(generic) ? nothing : first(generic)
end

# ===========================================================================
# 配置（設計 §9.5）
# ===========================================================================

"""
    _cross_model_resolve_t0(x::ModelDerivedInput, period_zero) -> Union{Int,CrossModelRejection}

`x` の PNE 期 0 を置くモデル期 `t0` を決める。配置基準は `Scenario.period_zero` の有無で決まり、
`x.timing_basis` と一致しなければ `timing_basis_conflict`（設計 §9.5）。`t0 < 0`（助走区間）は
`upstream_path_in_runup`（助走区間の外生は定常固定、ADR 0018）。
"""
function _cross_model_resolve_t0(
    x::ModelDerivedInput,
    period_zero::Union{CalendarQuarter, Nothing};
    stage::Symbol = :model_mapping,
)
    if period_zero !== nothing && x.timing_basis !== :calendar
        return CrossModelRejection(;
            code = :timing_basis_conflict,
            stage = stage,
            subject_ids = [x.input_id],
            detail = "Scenario は period_zero=$(quarter_label(period_zero)) を持つ暦日基準ですが、" *
                     "入力 $(x.input_id) は timing_basis=:period（t_start 指定）です。1 シナリオ内で" *
                     "基準を混在させません（設計 §9.5・ADR 0015 決定 5）",
        )
    elseif period_zero === nothing && x.timing_basis !== :period
        return CrossModelRejection(;
            code = :timing_basis_conflict,
            stage = stage,
            subject_ids = [x.input_id],
            detail = "Scenario は period_zero を持たないモデル期基準ですが、入力 $(x.input_id) は" *
                     " timing_basis=:calendar です。モデル期基準では t_start を明示します（設計 §9.5）",
        )
    end
    t0 =
        x.timing_basis === :calendar ? quarter_index(x.anchor_quarter, period_zero) :
        x.t_start
    t0 < 0 && return CrossModelRejection(;
        code = :upstream_path_in_runup,
        stage = stage,
        subject_ids = [x.input_id],
        detail = "入力 $(x.input_id) の PNE 期 0 がモデル期 t=$(t0)（助走区間）に置かれます。" *
                 "助走区間の外生は定常に固定するため配置できません（設計 §9.5・ADR 0018）",
    )
    return t0
end

# ===========================================================================
# map_model_derived_input（`X5`）
# ===========================================================================

"""
    map_model_derived_input(m::AbstractMacroModel, x::ModelDerivedInput; kwargs...)
        -> (Union{AppliedModelInput,CrossModelRejection}, Vector{CrossModelWarning})

既定メソッド。cross-model の mapping registry を持たないモデルへは常に
`unsupported_target_model` を返す（設計 §7.1）。
"""
function map_model_derived_input(m::AbstractMacroModel, x::ModelDerivedInput; kwargs...)
    return (
        CrossModelRejection(;
            code = :unsupported_target_model,
            stage = :model_mapping,
            subject_ids = [x.input_id],
            detail = "モデル $(typeof(m)) には cross-model の mapping registry がありません" *
                     "（v1 で受理するのは CapexCreditCycleModel のみ。設計 §7.1）",
        ),
        CrossModelWarning[],
    )
end

"""
    map_model_derived_input(m::CapexCreditCycleModel, x::ModelDerivedInput;
                            periods::Vector{Int}, baseline::Dict{Symbol,Vector{Float64}},
                            period_zero::Union{CalendarQuarter,Nothing} = nothing)
        -> (Union{AppliedModelInput,CrossModelRejection}, Vector{CrossModelWarning})

`x` を `CCC_CROSS_MODEL_MAPPING_RULES` に従って CCC の外生変数へ適用する `AppliedModelInput`
（`L4`）へ変換する（`X5`、設計 §7.4・§10.3）。

- 適用先: 受理行の `target_variable`（`ext_demand_s2` / `ext_demand_s3`）のみ。registry に行が無い・
  適用先なしの行は `unmapped_target_concept`（近い変数へ寄せない）。
- 配置: `_cross_model_resolve_t0`（`timing_basis_conflict`・`upstream_path_in_runup`）。
- 値: `AppliedModelInput.values[t] = 100 · x.values[t − t0 + 1]`（`unit = "%"`・
  `:multiplicative`。同一時点の定常外生パスに対する比）。PNE horizon 後は 0（X2 が回復を保証）。
  `persistence = PersistenceSpec(shape = :path, params = (values = 100 · x.values,))` とし、値は
  `shock_shape_path` で導く（event 層と同じ形状計算）。評価区間を超える末尾は適用されず
  `upstream_path_truncated` 警告を出す。
- `AppliedModelInput.assumption_id` は `x.input_id`、`input_id` は `"<x.input_id>/<target_variable>"`、
  `provenance.derived_from = [x.input_id]`。`warnings` は `MACRO_EVENT_WARNING_CODES` のみとし、
  cross-model 警告は戻り値の第 2 要素で返す。
"""
function map_model_derived_input(
    m::CapexCreditCycleModel,
    x::ModelDerivedInput;
    periods::Vector{Int},
    baseline::Dict{Symbol, Vector{Float64}},
    period_zero::Union{CalendarQuarter, Nothing} = nothing,
)
    warnings = CrossModelWarning[]
    rejection(code, detail) = (
        CrossModelRejection(;
            code = code,
            stage = :model_mapping,
            subject_ids = [x.input_id],
            detail = detail,
        ),
        warnings,
    )

    x.target_model === :capex_credit_cycle || return rejection(
        :unsupported_target_model,
        "入力 $(x.input_id) の target_model=$(x.target_model) は実行対象 CapexCreditCycleModel と一致しません",
    )

    rule = _ccc_cross_model_select_rule(x.target_concept, x.target_group)
    if rule === nothing
        return rejection(
            :unmapped_target_concept,
            "CCC は target_concept=$(x.target_concept)・target_group=$(x.target_group) を構造上表現しません" *
            "（CCC_CROSS_MODEL_MAPPING_RULES に行がありません。設計 §7.3）",
        )
    elseif rule.target_variable === nothing
        text = get(_CCC_CROSS_MODEL_UNSUPPORTED_TEXT, rule.unsupported_reason, "")
        return rejection(
            :unmapped_target_concept,
            "$(rule.contract_row): $(text)（$(rule.unsupported_reason)）。" *
            "$(rule.forbidden_proxies) への代理適用は行いません",
        )
    end
    x.value_semantics === rule.value_semantics || return rejection(
        :unmapped_target_concept,
        "$(rule.contract_row): CCC は value_semantics=$(x.value_semantics) の入力を構造上表現しません" *
        "（受理: $(rule.value_semantics)）",
    )

    t0 = _cross_model_resolve_t0(x, period_zero)
    t0 isa CrossModelRejection && return (t0, warnings)

    if period_zero === nothing && x.anchor_quarter !== nothing
        push!(
            warnings,
            CrossModelWarning(;
                code = :upstream_calendar_anchor_unused,
                subject_ids = [x.input_id],
                detail = "モデル期基準のシナリオのため、PNE の calendar_anchor（" *
                         "$(quarter_label(x.anchor_quarter))）を配置に使わず t_start=$(x.t_start) に置きました",
            ),
        )
    end

    target = rule.target_variable
    haskey(baseline, target) || throw(
        ArgumentError(
            "map_model_derived_input: baseline に target_variable=$(target) がありません" *
            "（exogenous_variables(m) の 7 キーすべてを持つ baseline を渡す必要があります）",
        ),
    )
    path = Float64[100.0 * v for v in x.values]
    magnitude = maximum(abs, path)
    persistence = PersistenceSpec(; shape = :path, params = (values = path,))
    values = shock_shape_path(persistence, magnitude, t0, periods, nothing)

    last_t = t0 + length(path) - 1
    if last_t > maximum(periods)
        n_cut = last_t - maximum(periods)
        push!(
            warnings,
            CrossModelWarning(;
                code = :upstream_path_truncated,
                subject_ids = [x.input_id],
                detail = "PNE 由来パスの末尾 $(n_cut) 四半期（t=$(maximum(periods) + 1)…$(last_t)）は" *
                         "評価区間を超えるため適用しません（評価区間内の値は変えません。設計 §9.5）",
            ),
        )
    end

    provenance = EventProvenance(;
        layer = :applied,
        derived_from = [x.input_id],
        rule_id = rule.rule_id,
        rule_version = CCC_CROSS_MODEL_MAPPING_VERSION,
        generator = "map_model_derived_input(CapexCreditCycleModel)",
    )
    input = AppliedModelInput(;
        input_id = "$(x.input_id)/$(target)",
        assumption_id = x.input_id,
        model = :capex_credit_cycle,
        target_variable = target,
        application_mode = rule.application_mode,
        unit = rule.unit,
        magnitude = magnitude,
        persistence = persistence,
        t_apply = t0,
        values = values,
        baseline_values = copy(baseline[target]),
        mapping_id = rule.rule_id,
        mapping_version = CCC_CROSS_MODEL_MAPPING_VERSION,
        provenance = provenance,
    )
    return (input, warnings)
end
