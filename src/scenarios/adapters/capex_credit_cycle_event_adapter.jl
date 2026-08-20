# capex_credit_cycle_event_adapter.jl: `CapexCreditCycleModel`（CCC）固有のイベント mapping
# adapter（Issue #201 / `E-5`）。
#
# 検証済み `ScenarioAssumption`（`L3`）を、CCC の `exogenous_variables(m)` 7変数へ適用可能な
# `AppliedModelInput`（`L4`）へ変換する `map_event` の既定メソッドと `CCC` メソッド、
# その根拠となる宣言的な `CAPEX_CC_EVENT_MAPPING_RULES`、Phase 1 の `CapexScenario`（`Sc0`–`Sc4`）
# を `L3` へ写す `capex_scenario_assumptions` を定義する。
#
# 本ファイルは Phase 1 のシナリオ層（`src/analysis/capex_credit_cycle_scenarios.jl`）と
# 共通イベント層（`src/scenarios/`）を**接続する**が、両者を変更しない。
# `CapexShockSpec` / `CapexScenario` との互換経路は**逆方向のみ**（`CapexScenario →
# Vector{ScenarioAssumption}`）であり、`ScenarioAssumption → CapexShockSpec` の変換は
# 作らない（統合設計 §11 `E-5` 行「本書による #201 からの変更」1）。
#
# 設計契約:
#   docs/architecture/macro_event_runtime_integration.md §5.6（`EventMappingRule`・
#     `CAPEX_CC_EVENT_MAPPING_RULES`・`map_event` の型・シグネチャ）・§6（失敗契約）・
#     §11 `E-5` 行
#   docs/architecture/macro_event_contract.md §4.1（適用先7変数）・§4.2（イベント型→モデル入力
#     マッピング表。対象・変数・方式・単位）・§4.4（適用不能条件）・§4.5（適用先を持たない
#     イベント型と上流への差し戻し `D1`–`D4`）
#   docs/adr/0015-macro-event-runtime-contract.md 決定16（`unmapped_target`/`untranslatable`/
#     `unsupported_model` を同一視しない、`Y-26`）

# ------------------------------------------------------------
# EventMappingRule（統合設計 §5.6）
# ------------------------------------------------------------

"部門非依存の値に加え、部門横断（sector を問わない）行を表す `:any` を許容する。"
const _CAPEX_CC_MAPPING_RULE_SECTORS = (_MACRO_EVENT_SECTORS..., :any)

"""
    EventMappingRule

`CapexCreditCycleModel` 向けイベント型 → モデル入力マッピングの1行（マクロイベント変換契約
§4.2 の1行に対応、統合設計 §5.6）。

## フィールド
- `event_type::Symbol`: `MACRO_EVENT_TYPES` のいずれか。
- `sector::Symbol`: `_MACRO_EVENT_SECTORS` の値、または部門非依存の行を表す `:any`。
- `target_variable::Union{Symbol,Nothing}`: `exogenous_variables(m)` の7変数のいずれか。
  `nothing` は適用先なし（`unmapped_target`）。
- `application_mode::Symbol`: `MACRO_EVENT_APPLICATION_MODES` のいずれか。
- `unit::String`: `target_variable !== nothing` のとき単位語彙のいずれか
  （マクロイベント変換契約 §3.3）。適用先なしの行は `""`。
- `unmapped_reason::Union{Symbol,Nothing}`: `target_variable === nothing` のときのみ非
  `nothing`（`macro_event_type_spec(event_type).inapplicable_conditions` の語彙を再利用する）。
- `upstream_issue::String`: 差し戻しID（`"D1"`–`"D4"`）または `""`（マクロイベント変換契約
  §4.5）。
- `contract_row::String`: 出典（例 `"macro_event_contract §4.2 row 3c"`）。

`target_variable !== nothing` の行は `unit`×`application_mode` の組がマクロイベント変換契約
§3.3 の許容表に含まれることを構築時に検査する（レジストリ行の内部矛盾をパッケージ読み込み時に
検出する）。
"""
struct EventMappingRule
    event_type::Symbol
    sector::Symbol
    target_variable::Union{Symbol, Nothing}
    application_mode::Symbol
    unit::String
    unmapped_reason::Union{Symbol, Nothing}
    upstream_issue::String
    contract_row::String

    function EventMappingRule(;
        event_type::Symbol,
        sector::Symbol,
        application_mode::Symbol,
        contract_row::AbstractString,
        target_variable::Union{Symbol, Nothing} = nothing,
        unit::AbstractString = "",
        unmapped_reason::Union{Symbol, Nothing} = nothing,
        upstream_issue::AbstractString = "",
    )
        event_type in MACRO_EVENT_TYPES || throw(
            ArgumentError(
                "EventMappingRule.event_type=$event_type は MACRO_EVENT_TYPES のいずれかで" *
                "なければなりません（$(contract_row)）",
            ),
        )
        sector in _CAPEX_CC_MAPPING_RULE_SECTORS || throw(
            ArgumentError(
                "EventMappingRule.sector=$sector は $(_CAPEX_CC_MAPPING_RULE_SECTORS) の" *
                "いずれかでなければなりません（$(contract_row)）",
            ),
        )
        application_mode in MACRO_EVENT_APPLICATION_MODES || throw(
            ArgumentError(
                "EventMappingRule.application_mode=$application_mode は " *
                "$(MACRO_EVENT_APPLICATION_MODES) のいずれかでなければなりません（$(contract_row)）",
            ),
        )
        _macro_event_require_nonempty("EventMappingRule.contract_row", contract_row)
        if target_variable === nothing
            unmapped_reason === nothing && throw(
                ArgumentError(
                    "EventMappingRule: target_variable=nothing（unmapped_target）の行は " *
                    "unmapped_reason を必須とします（$(contract_row)）",
                ),
            )
        else
            target_variable in CAPEX_CC_EXOGENOUS_VARIABLES || throw(
                ArgumentError(
                    "EventMappingRule.target_variable=$target_variable は " *
                    "exogenous_variables(m) の7変数（$(CAPEX_CC_EXOGENOUS_VARIABLES)）に" *
                    "含まれません（マクロイベント変換契約 §4.1。$(contract_row)）",
                ),
            )
            unmapped_reason === nothing || throw(
                ArgumentError(
                    "EventMappingRule: target_variable が非nothingの行（$(contract_row)）に " *
                    "unmapped_reason を設定できません",
                ),
            )
            _macro_event_check_unit_application_mode(unit, application_mode)
        end
        return new(
            event_type,
            sector,
            target_variable,
            application_mode,
            String(unit),
            unmapped_reason,
            String(upstream_issue),
            String(contract_row),
        )
    end
end

# ------------------------------------------------------------
# CAPEX_CC_EVENT_MAPPING_RULES（マクロイベント変換契約 §4.2）
# ------------------------------------------------------------

"""
    CAPEX_CC_EVENT_MAPPING_RULES

マクロイベント変換契約 §4.2 の表と対応する宣言的なマッピング規則。同表の名前付き行
（`1`・`1b`・`2`・`3`・`3b`・`3c`・`4`・`4b`・`5`・`6`・`7`・`7b`・`8`・`9`）ごとに、`target_variable`
（`L4`）が単一 `Symbol` であることを保つため次の2点で細分化する。

1. `1b`（`S2`/`S3`。適用先が `ext_demand_s2`/`ext_demand_s3` で異なる）・`3b`（同様）は
   部門ごとに1行へ分割する。
2. `9`（`:PolicyRateChange`）は `application_mode`（`:absolute`/`:additive`）ごとに1行へ
   分割する（両方とも `unit="%pt"`・`target_variable=:policy_rate` で同一）。

`3c`（`S1` の**着工済み**案件取消。`pipe_cancel_s ≡ 0`、§4.5-1）・`7b`（借換条件そのものの
変更、§4.5-4）は、行として明示的に保持する。両者の扱いは異なる:

- `3c`: `map_event` の第一級の判定結果として選ばれることはない。`ScenarioAssumption` は
  「着工前」か「着工済み」かを区別するフィールドを持たず（`:OrderCancellation` の
  `reason_codes` は `event_type_registry.jl` で空、区別する規約が無い）、`3` と同一の
  `(event_type, sector, application_mode)` を持つ行は常に `3`（マッピング可能）が先に一致
  し選ばれる。`3c` は「この mapping が表現しないもの」を契約と1:1で追跡する監査目的の行
  であり、§4.4 の必須 methodology metadata（`required_methodology_keys`）を通じて分析者に
  明記を要求する形で運用される。
- `7b`: `map_event` から到達可能である。`:RefinancingOrRatingEvent` の reason code
  （`rating_upgrade`/`rating_downgrade`/`outlook_change`/`refinancing_unavailable`/
  `maturity_wall`、`_MACRO_EVENT_REASON_CODES`）は `event_type_registry.jl` が「既存の
  ...notes（reason code 語彙を参照する自由記述）で足りる」と定めている。この規約に従い、
  `a.notes` に `refinancing_unavailable`／`maturity_wall`（借換条件そのものの変更を表す
  reason）が含まれる場合に限り `_capex_cc_select_mapping_rule` は `7`（`spread_shock_ex`、
  可）ではなく `7b`（不可）を選ぶ。それ以外（`rating_upgrade`/`rating_downgrade`/
  `outlook_change`、または reason 未記載）は市場価格に現れた分として `7` を選ぶ（既定）。

`sector = :any` は部門を問わない行（マクロイベント変換契約 §4.2 の「部門横断」）を表す。
`map_event` は `(event_type, sector)` の完全一致を `:any` より優先する（§5.6 実装ノート）。
"""
const CAPEX_CC_EVENT_MAPPING_RULES = EventMappingRule[
    EventMappingRule(;
        event_type = :DemandOutlookRevision,
        sector = :s1,
        target_variable = :ai_exp,
        application_mode = :multiplicative,
        unit = "%",
        contract_row = "macro_event_contract §4.2 row 1",
    ),
    EventMappingRule(;
        event_type = :DemandOutlookRevision,
        sector = :s2,
        target_variable = :ext_demand_s2,
        application_mode = :multiplicative,
        unit = "%",
        contract_row = "macro_event_contract §4.2 row 1b (S2)",
    ),
    EventMappingRule(;
        event_type = :DemandOutlookRevision,
        sector = :s3,
        target_variable = :ext_demand_s3,
        application_mode = :multiplicative,
        unit = "%",
        contract_row = "macro_event_contract §4.2 row 1b (S3)",
    ),
    EventMappingRule(;
        event_type = :CapexGuidanceRevision,
        sector = :s1,
        target_variable = :capex_plan_shock_ex,
        application_mode = :multiplicative,
        unit = "%",
        contract_row = "macro_event_contract §4.2 row 2",
    ),
    EventMappingRule(;
        event_type = :OrderCancellation,
        sector = :s1,
        target_variable = :capex_plan_shock_ex,
        application_mode = :multiplicative,
        unit = "%",
        contract_row = "macro_event_contract §4.2 row 3",
    ),
    EventMappingRule(;
        event_type = :OrderCancellation,
        sector = :s2,
        target_variable = :ext_demand_s2,
        application_mode = :additive,
        unit = "bn USD (2017 chained)",
        contract_row = "macro_event_contract §4.2 row 3b (S2)",
    ),
    EventMappingRule(;
        event_type = :OrderCancellation,
        sector = :s3,
        target_variable = :ext_demand_s3,
        application_mode = :additive,
        unit = "bn USD (2017 chained)",
        contract_row = "macro_event_contract §4.2 row 3b (S3)",
    ),
    EventMappingRule(;                                    # 監査専用（row 3 が常に先に一致する）
        event_type = :OrderCancellation,
        sector = :s1,
        application_mode = :multiplicative,
        unmapped_reason = :pipeline_cancellation_irreversible,
        upstream_issue = "",
        contract_row = "macro_event_contract §4.2 row 3c・§4.5-1",
    ),
    EventMappingRule(;
        event_type = :PriceOrMarginShock,
        sector = :s1,
        target_variable = :price_s1,
        application_mode = :multiplicative,
        unit = "%",
        contract_row = "macro_event_contract §4.2 row 4",
    ),
    EventMappingRule(;
        event_type = :PriceOrMarginShock,
        sector = :any,
        application_mode = :multiplicative,
        unmapped_reason = :sector_ne_s1,
        upstream_issue = "D1",
        contract_row = "macro_event_contract §4.2 row 4b・§4.5-2",
    ),
    EventMappingRule(;
        event_type = :CreditSpreadShock,
        sector = :any,
        target_variable = :spread_shock_ex,
        application_mode = :additive,
        unit = "bp",
        contract_row = "macro_event_contract §4.2 row 5",
    ),
    EventMappingRule(;
        event_type = :LendingStandardChange,
        sector = :any,
        application_mode = :multiplicative,
        unmapped_reason = :lending_standard_has_no_target_variable,
        upstream_issue = "D2",
        contract_row = "macro_event_contract §4.2 row 6・§4.5-3",
    ),
    EventMappingRule(;
        event_type = :RefinancingOrRatingEvent,
        sector = :any,
        target_variable = :spread_shock_ex,
        application_mode = :additive,
        unit = "bp",
        contract_row = "macro_event_contract §4.2 row 7",
    ),
    EventMappingRule(;                                    # 監査専用（row 7 が常に先に一致する）
        event_type = :RefinancingOrRatingEvent,
        sector = :any,
        application_mode = :additive,
        unmapped_reason = :refinancing_condition_target_unavailable,
        upstream_issue = "D3",
        contract_row = "macro_event_contract §4.2 row 7b・§4.5-4",
    ),
    EventMappingRule(;
        event_type = :EmploymentPlanRevision,
        sector = :any,
        application_mode = :multiplicative,
        unmapped_reason = :employment_plan_has_no_target_variable,
        upstream_issue = "D4",
        contract_row = "macro_event_contract §4.2 row 8・§4.5-5",
    ),
    EventMappingRule(;
        event_type = :PolicyRateChange,
        sector = :any,
        target_variable = :policy_rate,
        application_mode = :absolute,
        unit = "%pt",
        contract_row = "macro_event_contract §4.2 row 9 (:absolute)",
    ),
    EventMappingRule(;
        event_type = :PolicyRateChange,
        sector = :any,
        target_variable = :policy_rate,
        application_mode = :additive,
        unit = "%pt",
        contract_row = "macro_event_contract §4.2 row 9 (:additive)",
    ),
]

# ------------------------------------------------------------
# map_event（統合設計 §5.6・§6.2、`Y-26`）
# ------------------------------------------------------------

"""
    map_event(m::AbstractMacroModel, a::ScenarioAssumption; kwargs...) -> EventRejection

既定メソッド。`m` に固有の `map_event` メソッドが実装されていないモデルへは常に
`:unsupported_model` を返す（`:unmapped_target`・`:untranslatable` と同一視しない、`Y-26`）。
"""
function map_event(m::AbstractMacroModel, a::ScenarioAssumption; kwargs...)
    return EventRejection(;
        code = :unsupported_model,
        layer = :assumption,
        subject_ids = [a.assumption_id],
        event_type = a.event_type,
        target_concept = isempty(a.target_concepts) ? nothing : a.target_concepts[1],
        detail = "モデル $(typeof(m)) 向けの map_event 実装がありません" *
                 "（unsupported_model。unmapped_target/untranslatableとは別のコード、" *
                 "統合設計 §6.2 契約2・`Y-26`）",
        upstream_issue = "",
    )
end

"""
    _capex_cc_refinancing_reason_codes(a::ScenarioAssumption) -> Vector{Symbol}

`a.notes` に含まれる `:RefinancingOrRatingEvent` の reason code（`_MACRO_EVENT_REASON_CODES`、
`event_type_registry.jl`）を検出する。同ファイルの設計注記「個々のレコードでの reason の
記録は既存の...notes（reason code 語彙を参照する自由記述）で足りる」に基づく規約であり、
`event_type !== :RefinancingOrRatingEvent` では常に空を返す。
"""
function _capex_cc_refinancing_reason_codes(a::ScenarioAssumption)
    a.event_type === :RefinancingOrRatingEvent || return Symbol[]
    return [rc for rc in _MACRO_EVENT_REASON_CODES if occursin(String(rc), a.notes)]
end

"""
    _capex_cc_select_mapping_rule(a::ScenarioAssumption) -> Union{EventMappingRule,Nothing}

`a.event_type`・`a.sector`・`a.application_mode` から `CAPEX_CC_EVENT_MAPPING_RULES` の
該当行を選ぶ。`(event_type, sector)` の完全一致を `(event_type, :any)` より優先し、
`application_mode` が一致する行を優先し、その中で `target_variable !== nothing`（マッピング
可能）な行を優先する。該当する `event_type` の行が1つも無い場合は `nothing`。

`:RefinancingOrRatingEvent` に限り、`a.notes` が `refinancing_unavailable`／`maturity_wall`
（借換条件そのものの変更を表す reason code）を含む場合は例外的に `7b`（不可）を選ぶ
（`_capex_cc_refinancing_reason_codes`。マクロイベント変換契約 §4.2 row 7b・§4.5-4）。
"""
function _capex_cc_select_mapping_rule(a::ScenarioAssumption)
    candidates = filter(r -> r.event_type === a.event_type, CAPEX_CC_EVENT_MAPPING_RULES)
    isempty(candidates) && return nothing

    sector_specific = filter(r -> r.sector === a.sector, candidates)
    pool = if !isempty(sector_specific)
        sector_specific
    else
        any_sector = filter(r -> r.sector === :any, candidates)
        isempty(any_sector) ? candidates : any_sector
    end

    mode_matched = filter(r -> r.application_mode === a.application_mode, pool)
    chosen = isempty(mode_matched) ? pool : mode_matched

    if a.event_type === :RefinancingOrRatingEvent
        reasons = _capex_cc_refinancing_reason_codes(a)
        if :refinancing_unavailable in reasons || :maturity_wall in reasons
            unmapped_only = filter(r -> r.target_variable === nothing, chosen)
            isempty(unmapped_only) || return first(unmapped_only)
        end
    end

    mappable = filter(r -> r.target_variable !== nothing, chosen)
    return isempty(mappable) ? first(chosen) : first(mappable)
end

const _CAPEX_CC_UNMAPPED_REASON_TEXT = Dict{Symbol, String}(
    :pipeline_cancellation_irreversible =>
        "着工済み案件の取消は表現しません（pipe_cancel_s ≡ 0、" *
        "#166 §5.2）。着工前の計画取消（本行の row 3）とは構造上" *
        "区別され、着工済み案件の取消を capex_plan_shock_ex 等" *
        "既存の適用先へ寄せません",
    :sector_ne_s1 =>
        "S2/S3 の価格・利益率ショックは表現しません（price_s2/price_s3 は control で" *
        "_shock_ex を持たず、構造上外生入力の適用先がありません）",
    :lending_standard_has_no_target_variable =>
        "貸出態度の変化は表現しません（lend_stance は " *
        "control でありモデルは構造上外生入力の適用先を" *
        "持ちません。spread_shock_ex への代理適用も行いません）",
    :refinancing_condition_target_unavailable =>
        "借換条件（rollover）そのものの変更は表現しません" *
        "（rollover は control で構造上外生入力の適用先が" *
        "ありません。格付変更のうち市場価格に現れた分のみ " *
        "spread_shock_ex（本行の row 7）で表現します）",
    :employment_plan_has_no_target_variable =>
        "雇用計画の改定は表現しません（emp_s は control で" *
        "あり、加えて雇用計画は需要・CAPEX見通し下方修正の" *
        "帰結であるため、独立入力として与えると二重計上に" *
        "なります。構造上の適用先がありません）",
)

"""
    map_event(m::CapexCreditCycleModel, a::ScenarioAssumption;
              periods::Vector{Int}, baseline::Dict{Symbol,Vector{Float64}},
              timing_rules::TimingRuleSet = TimingRuleSet(),
              period_zero::Union{CalendarQuarter,Nothing} = nothing) ->
        Union{AppliedModelInput,EventRejection}

`a`（`L3`）を `CAPEX_CC_EVENT_MAPPING_RULES` に従って CCC の外生変数（`L4`）へ変換する
（統合設計 §5.6）。適用先が無い行に該当した場合は `EventRejection(:unmapped_target, ...)`
を返す（近い変数への代理適用は行わない）。`confidence`/`uncertainty`/`source` は `L4` へ
写さない（`assumption_id` 経由でのみ遡る、統合設計 §5.6 契約5）。

## 引数
- `periods::Vector{Int}`: `AppliedModelInput.values`/`baseline_values` の期インデックス列
  （`baseline` の各系列と同じ長さ）。
- `baseline::Dict{Symbol,Vector{Float64}}`: baseline 外生パス（`exogenous_variables(m)` の
  7キーを含む）。
- `timing_rules::TimingRuleSet` / `period_zero`: `a.timing.basis === :calendar` のときのみ
  `resolve_t_apply` へ渡す（`:period` 基準では未使用）。
"""
function map_event(
    m::CapexCreditCycleModel,
    a::ScenarioAssumption;
    periods::Vector{Int},
    baseline::Dict{Symbol, Vector{Float64}},
    timing_rules::TimingRuleSet = TimingRuleSet(),
    period_zero::Union{CalendarQuarter, Nothing} = nothing,
)
    rule = _capex_cc_select_mapping_rule(a)

    if rule === nothing || rule.target_variable === nothing
        reason_text =
            rule === nothing ? nothing :
            get(_CAPEX_CC_UNMAPPED_REASON_TEXT, rule.unmapped_reason, nothing)
        detail = if rule === nothing
            "event_type=$(a.event_type)・sector=$(a.sector) に対応する " *
            "CAPEX_CC_EVENT_MAPPING_RULES の行がありません。モデルが構造上その事象を表現しません"
        elseif reason_text === nothing
            "$(rule.contract_row): モデルが構造上その事象を表現しません（$(rule.unmapped_reason)）"
        else
            "$(rule.contract_row): " * reason_text
        end
        return EventRejection(;
            code = :unmapped_target,
            layer = :assumption,
            subject_ids = [a.assumption_id],
            event_type = a.event_type,
            target_concept = isempty(a.target_concepts) ? nothing : a.target_concepts[1],
            detail = detail,
            upstream_issue = rule === nothing ? "" : rule.upstream_issue,
        )
    end

    target = rule.target_variable
    haskey(baseline, target) || throw(
        ArgumentError(
            "map_event: baseline に target_variable=$target がありません" *
            "（呼び出し側は exogenous_variables(m) の7キーすべてを持つ baseline を渡す必要が" *
            "あります）",
        ),
    )

    t_apply = resolve_t_apply(a.timing, period_zero, timing_rules)
    t_until = _capex_cc_resolve_t_until(a.timing, period_zero)
    values = shock_shape_path(a.persistence, a.magnitude, t_apply, periods, t_until)
    baseline_values = copy(baseline[target])

    warnings = Symbol[]
    a.timing.from_source === :derived && push!(warnings, :timing_derived)
    a.timing.rule_overridden && push!(warnings, :timing_rule_override)

    provenance = EventProvenance(;
        layer = :applied,
        derived_from = [a.assumption_id],
        rule_id = rule.contract_row,
        rule_version = CAPEX_CC_EVENT_MAPPING_VERSION,
        generator = "map_event(CapexCreditCycleModel)",
    )

    return AppliedModelInput(;
        input_id = "$(a.assumption_id)->$(target)",
        assumption_id = a.assumption_id,
        model = :capex_credit_cycle,
        target_variable = target,
        application_mode = a.application_mode,
        unit = a.unit,
        magnitude = a.magnitude,
        persistence = a.persistence,
        t_apply = t_apply,
        values = values,
        baseline_values = baseline_values,
        mapping_id = rule.contract_row,
        mapping_version = CAPEX_CC_EVENT_MAPPING_VERSION,
        warnings = warnings,
        provenance = provenance,
    )
end

"""
    _capex_cc_resolve_t_until(timing::EventTiming,
                               period_zero::Union{CalendarQuarter,Nothing}) -> Union{Int,Nothing}

`timing.basis === :period` のとき `timing.t_until` をそのまま返す。`:calendar` のとき
`timing.effective_until`（あれば）を `resolve_t_apply` と同じ `quarter_index` 変換で `t` へ写す
（`:same_quarter` 相当のオフセット。打ち切り境界は境界四半期自体を含めるため、`:cutoff` の
早出し規則は適用しない）。
"""
function _capex_cc_resolve_t_until(
    timing::EventTiming,
    period_zero::Union{CalendarQuarter, Nothing},
)
    timing.basis === :period && return timing.t_until
    timing.effective_until === nothing && return nothing
    period_zero === nothing && throw(
        ArgumentError(
            "period_zero_required: timing.basis=:calendar かつ effective_until が指定されて" *
            "いるとき period_zero は必須です（シナリオ時間軸の意味論 §2.1）",
        ),
    )
    q = quarter_of(timing.effective_until)
    return quarter_index(q, period_zero)
end

# ------------------------------------------------------------
# capex_scenario_assumptions（統合設計 §5.6 契約6。Sc0–Sc4 の L3 表現）
# ------------------------------------------------------------

"""
`capex_scenario(id).shocks` の各 `CapexShockSpec.target` から、対応する `event_type`・`sector`・
`target_concepts` を引く表（`capex_scenario_assumptions` 専用）。`_ccc_default_shock_sequence`
（`SH-EXP`/`SH-CAPEX`/`SH-CREDIT`/`SH-EASING`）が用いる4つの適用先のみを持つ。
"""
const _CAPEX_CC_SCENARIO_ASSUMPTION_META = Dict{Symbol, NamedTuple}(
    :ai_exp => (
        event_type = :DemandOutlookRevision,
        sector = :s1,
        target_concepts = Symbol[:demand_expectation],
    ),
    :capex_plan_shock_ex => (
        event_type = :CapexGuidanceRevision,
        sector = :s1,
        target_concepts = Symbol[:capex_plan],
    ),
    :spread_shock_ex => (
        event_type = :CreditSpreadShock,
        sector = :unknown,
        target_concepts = Symbol[:credit_spread],
    ),
    :policy_rate => (
        event_type = :PolicyRateChange,
        sector = :out_of_model,
        target_concepts = Symbol[:policy_rate],
    ),
)

"""
    capex_scenario_assumptions(id::Symbol) -> Vector{ScenarioAssumption}

`capex_scenario(id).shocks`（`CapexShockSpec`、Phase 1）を `ScenarioAssumption`（`L3`、
Phase 2）へ変換する。すべての仮定は `magnitude_source = :assumed_default`・
`timing.basis = :period`・`provenance.generator = "capex_scenario"` を持つ（観測由来と
誤読されないため、統合設計 §5.6 契約6）。`CapexShockSpec` を保持したまま変換するため、
`map_event` → `schedule_events` → `compose_exogenous_paths` の経路は `capex_exogenous_paths`
と同一の外生パスを再現する（統合設計 §11 `E-5` 受け入れ条件「Phase 1のSc0–Sc4を互換adapter
経由で再現できる」）。

`Sc0`（baseline）は `shocks` が空のため空ベクトルを返す。
"""
function capex_scenario_assumptions(id::Symbol)
    scenario = capex_scenario(id)
    assumptions = ScenarioAssumption[]
    for shock in scenario.shocks
        meta = get(_CAPEX_CC_SCENARIO_ASSUMPTION_META, shock.target, nothing)
        meta === nothing && throw(
            ArgumentError(
                "capex_scenario_assumptions: target=$(shock.target) に対応する " *
                "event_type/sector/target_concepts が _CAPEX_CC_SCENARIO_ASSUMPTION_META に" *
                "登録されていません",
            ),
        )
        direction = shock.magnitude > 0 ? :up : (shock.magnitude < 0 ? :down : :none)
        timing = EventTiming(;
            basis = :period,
            rule = :explicit_period,
            t_apply = shock.timing,
            from_source = :given,
        )
        provenance = EventProvenance(;
            layer = :assumption,
            derived_from = ["capex_scenario:$(id)"],
            rule_id = "capex_scenario_assumptions",
            rule_version = CAPEX_CC_EVENT_MAPPING_VERSION,
            generator = "capex_scenario",
        )
        push!(
            assumptions,
            scenario_assumption(;
                assumption_id = "capex_scenario:$(id):$(shock.target)",
                event_type = meta.event_type,
                sector = meta.sector,
                direction = direction,
                magnitude = shock.magnitude,
                unit = shock.unit,
                magnitude_source = :assumed_default,
                application_mode = shock.application_mode,
                timing = timing,
                persistence = _ccc_persistence_spec(shock),
                target_concepts = copy(meta.target_concepts),
                provenance = provenance,
                notes = shock.meaning,
            ),
        )
    end
    return assumptions
end
