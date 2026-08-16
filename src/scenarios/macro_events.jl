# macro_events.jl: マクロイベントの4層概念階層（Issue #197 / `E-1`）。
#
# `AbstractMacroEvent`・4層レコード型（`ObservedEvent`/`InterpretedSignal`/`ScenarioAssumption`/
# `AppliedModelInput`）・共通の下位構造（`EventSource`/`EventProvenance`/`PersistenceSpec`/
# `EventTiming`）・語彙定数・層別の内部コンストラクタ検証（§6.1 の層 (1) = `ArgumentError`）・
# `validate_event` を定義する。
#
# 本ファイルは**モデルを知らない**（統合設計 §3.1 契約1）。`CapexCreditCycleModel` や
# `exogenous_variables(m)` を参照しない。イベント型ごとの詳細規則（許可部門・許可単位・
# 既定形状等）を持つレジストリ（`MacroEventTypeSpec`）は Issue #199/#200 が
# `src/scenarios/event_type_registry.jl` へ追加する。モデル固有 mapping（`map_event`）は
# Issue #201、`Scenario` の集合レベル検証（`mixed_timing_basis` 等の構造化拒否）は
# Issue #202 の `run_scenario` が対象とする。
#
# 設計契約:
#   docs/architecture/macro_event_runtime_integration.md §5.1-5.3（型・version 定数・
#     レジストリとの境界）・§6（失敗契約の3層分離）・§11 `E-1` 行
#   docs/architecture/macro_event_contract.md §2（4層概念階層）・§3（共通属性・
#     magnitude捏造禁止・単位語彙・target concept語彙）・§13（`:other` の層限定・
#     `L3` の時点指定2基準・部門集約の非実装）
#   docs/architecture/scenario_time_semantics.md §11.1（時点指定2基準）
#   docs/adr/0015-macro-event-runtime-contract.md 決定2-6・14

# ------------------------------------------------------------
# 抽象型
# ------------------------------------------------------------

"""
    AbstractMacroEvent

マクロイベントの4層概念階層（`ObservedEvent`/`InterpretedSignal`/`ScenarioAssumption`/
`AppliedModelInput`）の抽象親型（マクロイベント変換契約 §2.1）。層を飛ばした変換
（`L1`/`L2` から `AppliedModelInput` を直接生成すること）は型では禁止しない（禁止は
`map_event` の引数型が `ScenarioAssumption` のみであることで強制する、Issue #201）。
"""
abstract type AbstractMacroEvent end

# ------------------------------------------------------------
# version 定数（統合設計 §5.1）
# ------------------------------------------------------------

"マクロイベント変換契約（属性・イベント型マッピング・合成規則）の version。"
const MACRO_EVENT_CONTRACT_VERSION = "macro-event-contract/1.0.2"

"シナリオ時間軸の意味論（内部時刻・割当規則・時間形状）の version。"
const SCENARIO_TIME_SEMANTICS_VERSION = "scenario-time-semantics/1.1.0"

"イベント・シナリオ実行層（公開型・公開API・実行順・失敗契約）の version。"
const MACRO_EVENT_RUNTIME_VERSION = "macro-event-runtime/1.0.0"

"`L2 → L3` / `L3 → L4` 変換ルール実装の version。"
const EVENT_RULE_VERSION = "event-rule/1.0.0"

"`CapexCreditCycleModel` 固有 mapping 表（`CAPEX_CC_EVENT_MAPPING_RULES`、Issue #201）の version。"
const CAPEX_CC_EVENT_MAPPING_VERSION = "ccc-event-mapping/1.0.0"

"シナリオ成果物（`save_scenario_artifact` が書き出す JSON、Issue #203）の schema version。"
const SCENARIO_ARTIFACT_SCHEMA_VERSION = "dme.scenario/1.0.0"

# ------------------------------------------------------------
# 語彙定数（統合設計 §5.2-5.3・マクロイベント変換契約 §3.3・§3.4・§6.2）
# ------------------------------------------------------------

"4層の識別子（マクロイベント変換契約 §2.1・§2.4）。"
const MACRO_EVENT_LAYERS = (:observed, :interpreted, :assumption, :applied)

"""
    MACRO_EVENT_TYPES

初期イベント型9種（マクロイベント変換契約 §4）。実体経済側5種（`:DemandOutlookRevision`・
`:CapexGuidanceRevision`・`:OrderCancellation`・`:PriceOrMarginShock`・
`:EmploymentPlanRevision`、Issue #199）と信用・政策側4種（`:CreditSpreadShock`・
`:LendingStandardChange`・`:RefinancingOrRatingEvent`・`:PolicyRateChange`、Issue #200）。

本定数は**型シンボルの確定集合**のみを持つ。型ごとの許可部門・許可単位・既定形状・
適用不能条件は `MacroEventTypeSpec` レジストリ（`MACRO_EVENT_TYPE_REGISTRY`、
Issue #199/#200 が `src/scenarios/event_type_registry.jl` へ追加）が持つ。本ファイルの
内部コンストラクタ検証は「未登録の `event_type` を拒否する」（統合設計 §10.1 の項目7）
という構造レベルの検査のみを行い、型別の属性検証（許可部門等）は行わない。
"""
const MACRO_EVENT_TYPES = (
    :DemandOutlookRevision,
    :CapexGuidanceRevision,
    :OrderCancellation,
    :PriceOrMarginShock,
    :EmploymentPlanRevision,
    :CreditSpreadShock,
    :LendingStandardChange,
    :RefinancingOrRatingEvent,
    :PolicyRateChange,
)

"target concept のモデル非依存語彙（マクロイベント変換契約 §3.4）。"
const MACRO_EVENT_TARGET_CONCEPTS = (
    :demand_expectation,
    :capex_plan,
    :order_flow,
    :output_price_margin,
    :credit_spread,
    :lending_standard,
    :refinancing_condition,
    :employment_plan,
    :policy_rate,
)

"`L3`/`L4` の適用方式（マクロイベント変換契約 §5.2）。"
const MACRO_EVENT_APPLICATION_MODES = (:absolute, :multiplicative, :additive)

"`magnitude` の出所（マクロイベント変換契約 §3.2）。"
const MACRO_EVENT_MAGNITUDE_SOURCES =
    (:observed, :disclosed, :derived, :assumed_default, :external_belief)

"持続・減衰の時間形状6種（シナリオ時間軸の意味論 §5.2・統合設計 §7.4、`Y-10`）。"
const MACRO_EVENT_SHAPES = (:pulse, :step, :ramp, :step_then_ramp, :ar1_decay, :path)

"""
    MACRO_EVENT_REJECTION_CODES

構造化拒否コード12種（統合設計 §6.2）。層(2)「集合の整合違反」に対応し、`EventRejection`
として集めて返す（`status = :rejected_*`。モデルを実行しない）。実装はこれ以外のコードを
生成しない。
"""
const MACRO_EVENT_REJECTION_CODES = (
    :duplicate_event_id,
    :conflicting_absolute,
    :mixed_timing_basis,
    :period_zero_required,
    :horizon_mismatch,
    :unmapped_target,
    :unsupported_event_type,
    :aggregation_not_implemented,
    :constraint_violation,
    :unsupported_model,
    :provenance_broken,
    :model_mismatch,
)

"""
    MACRO_EVENT_WARNING_CODES

警告コード12種（統合設計 §6.2）。層(3)「その他」に対応し、`ScenarioWarning` として記録
する（実行は妨げない）。実装はこれ以外のコードを生成しない。
"""
const MACRO_EVENT_WARNING_CODES = (
    :offsetting_events,
    :contradictory_update,
    :duplicate_dropped,
    :superseded_event,
    :out_of_horizon,
    :low_confidence,
    :timing_derived,
    :timing_sensitive,
    :timing_rule_override,
    :timing_basis_period,
    :extreme_shock,
    :unmapped_target_accepted,
)

# ------------------------------------------------------------
# 内部語彙（export しない。マクロイベント変換契約 §3.1・§3.3）
# ------------------------------------------------------------

"""
単位 × `application_mode` の許容表（マクロイベント変換契約 §3.3。§12.1 の `X-18` 改訂
（`"bn USD (2017 chained)" × :additive` の追加）を反映）。

`src/analysis/capex_credit_cycle_scenarios.jl` の `_CCC_UNIT_APPLICATION_MODE_TABLE` と
内容は同一だが、共通イベント層は `models/` ブロックより前に include され（統合設計 §4.2）
`CapexCreditCycleModel` 固有ファイルへ依存できないため、独立して保持する
（本表はモデル非依存のマクロイベント変換契約 §3.3 が正本であり、CCC固有ファイルの表は
その具体化にすぎない）。
"""
const _MACRO_EVENT_UNIT_APPLICATION_MODE_TABLE = Dict{String, Tuple{Vararg{Symbol}}}(
    "%" => (:multiplicative,),
    "bp" => (:additive,),
    "%pt" => (:additive, :absolute),
    "bn USD (2017 chained)" => (:absolute, :additive, :multiplicative),
)

"`sector` の許容値（マクロイベント変換契約 §3.1 row 12。`:unknown` は「未分類」を表す）。"
const _MACRO_EVENT_SECTORS = (:s1, :s2, :s3, :s4, :s5, :out_of_model, :unknown)

"`direction` の許容値（マクロイベント変換契約 §3.1 row 14）。"
const _MACRO_EVENT_DIRECTIONS = (:up, :down, :none, :unknown)

"`EventTiming.rule` の許容値（`:calendar` 基準3種 + `:period` 基準1種、シナリオ時間軸 §11.1）。"
const _MACRO_EVENT_TIMING_RULES = (:same_quarter, :next_quarter, :cutoff, :explicit_period)

# ------------------------------------------------------------
# 汎用バリデーションヘルパ（層(1)。§6.1）
# ------------------------------------------------------------

function _macro_event_require_nonempty(label::AbstractString, value::AbstractString)
    isempty(value) && throw(
        ArgumentError(
            "$label は空文字であってはいけません（統合設計 §6.1 の層(1)「空ID」）",
        ),
    )
    return nothing
end

function _macro_event_require_finite(label::AbstractString, value::Union{Float64, Missing})
    value === missing && return nothing
    isfinite(value) || throw(
        ArgumentError(
            "$label は有限の値でなければなりません（実値: $(value)。NaN/Infは全層でArgumentError、統合設計 §5.2 契約4）",
        ),
    )
    return nothing
end

function _macro_event_check_enum(
    label::AbstractString,
    value::Symbol,
    allowed::Tuple{Vararg{Symbol}},
)
    value in allowed || throw(
        ArgumentError(
            "$label=$value は $(allowed) のいずれかでなければなりません（未知のenum、統合設計 §6.1 の層(1)）",
        ),
    )
    return nothing
end

function _macro_event_check_unit(unit::Union{AbstractString, Nothing})
    unit === nothing && return nothing
    haskey(_MACRO_EVENT_UNIT_APPLICATION_MODE_TABLE, String(unit)) || throw(
        ArgumentError(
            "unit=\"$unit\" はマクロイベント変換契約 §3.3 の単位語彙にありません" *
            "（許容: $(collect(keys(_MACRO_EVENT_UNIT_APPLICATION_MODE_TABLE)))）",
        ),
    )
    return nothing
end

function _macro_event_check_unit_application_mode(
    unit::AbstractString,
    application_mode::Symbol,
)
    _macro_event_check_unit(unit)
    allowed = _MACRO_EVENT_UNIT_APPLICATION_MODE_TABLE[String(unit)]
    application_mode in allowed || throw(
        ArgumentError(
            "invalid_unit_mode: unit=\"$unit\" と application_mode=$application_mode の組み合わせは" *
            "マクロイベント変換契約 §3.3（§12.1改訂後）の許容表にありません（許容: $allowed）",
        ),
    )
    return nothing
end

function _macro_event_check_confidence(confidence::Union{Float64, Nothing})
    confidence === nothing && return nothing
    (0.0 <= confidence <= 1.0) || throw(
        ArgumentError(
            "confidence=$confidence は [0,1] の範囲でなければなりません（統合設計 §6.1）",
        ),
    )
    return nothing
end

function _macro_event_check_uncertainty(
    uncertainty::Union{Tuple{Float64, Float64}, Nothing},
)
    uncertainty === nothing && return nothing
    low, high = uncertainty
    (isfinite(low) && isfinite(high)) || throw(
        ArgumentError("uncertainty=$uncertainty は有限の (low, high) でなければなりません"),
    )
    low <= high ||
        throw(ArgumentError("uncertainty=$uncertainty は low <= high でなければなりません"))
    return nothing
end

function _macro_event_check_target_concepts(
    target_concepts::Vector{Symbol};
    require_nonempty::Bool = false,
)
    require_nonempty &&
        isempty(target_concepts) &&
        throw(
            ArgumentError(
                "target_concepts は空であってはいけません（マクロイベント変換契約 §3.1 row 21）",
            ),
        )
    for tc in target_concepts
        tc in MACRO_EVENT_TARGET_CONCEPTS || throw(
            ArgumentError(
                "target_concepts に未知の concept が含まれています: $tc" *
                "（許容: $(MACRO_EVENT_TARGET_CONCEPTS)、マクロイベント変換契約 §3.4）",
            ),
        )
    end
    return nothing
end

"""
    _macro_event_check_event_type(event_type, allow_other) -> Nothing

`event_type` が `MACRO_EVENT_TYPES` の9種、または（`allow_other=true` のとき）`:other`
であることを検証する。`:other` は `L1`/`L2` のみで許容し（`allow_other=true`）、
`L3`/`L4` では許容しない（`allow_other=false`。`Y-01`）。`L3`/`L4` に `:other` を渡すことは
「そのようなレコードは構築できない」という層(1)の主張として `ArgumentError` で拒否する
（`unsupported_event_type` の概念に対応。統合設計 §6.1 は同コードを集合レベルの構造化拒否
[層(2)] として分類するが、単一レコードの構築時点で確定的に不成立と分かる場合にまで
`Scenario` 全体の検証を待つ必要はない。集合レベルでの収集・列挙が必要な場面は
`run_scenario`（Issue #202）が担う）。
"""
function _macro_event_check_event_type(event_type::Symbol, allow_other::Bool)
    if event_type === :other
        allow_other && return nothing
        throw(
            ArgumentError(
                "unsupported_event_type: event_type=:other は Scenario Assumption / " *
                "Applied Model Input では許容されません（Observed Event / Interpreted Signal " *
                "限定、マクロイベント変換契約 §13.1、`Y-01`）",
            ),
        )
    end
    event_type in MACRO_EVENT_TYPES || throw(
        ArgumentError(
            "未登録のevent_type: $event_type は $(MACRO_EVENT_TYPES) のいずれか、または " *
            "（Observed Event / Interpreted Signal に限り）:other でなければなりません" *
            "（generic eventへ縮約しない、統合設計 §10.1 項目7）",
        ),
    )
    return nothing
end

function _macro_event_check_provenance_layer(provenance, expected_layer::Symbol)
    provenance.layer === expected_layer || throw(
        ArgumentError(
            "layer不整合: provenance.layer=$(provenance.layer) はこのレコードの層 " *
            "$expected_layer と一致しません（統合設計 §6.1）",
        ),
    )
    return nothing
end

"""
    _macro_event_check_path_persistence(magnitude, persistence) -> Nothing

`persistence.shape === :path` のとき、`magnitude`（欠測でなければ）が
`maximum(abs, persistence.params.values)` と一致することを検証する（`path_magnitude_mismatch`、
シナリオ時間軸の意味論 §5.2・統合設計 §7.4 `Y-12`）。
"""
function _macro_event_check_path_persistence(
    magnitude::Union{Float64, Missing},
    persistence,
)
    (persistence === nothing || persistence.shape !== :path) && return nothing
    magnitude === missing && return nothing
    expected = maximum(abs, persistence.params.values)
    magnitude == expected || throw(
        ArgumentError(
            "path_magnitude_mismatch: magnitude=$magnitude が " *
            "maximum(abs, persistence.params.values)=$expected と一致しません" *
            "（シナリオ時間軸の意味論 §5.2、`Y-12`）",
        ),
    )
    return nothing
end

"""
    _macro_event_check_path_magnitude_source(magnitude_source, persistence) -> Nothing

`persistence.shape === :path` は `magnitude_source ∈ (:observed, :derived)` の場合のみ許可する
（マクロイベント変換契約 §5.2-4）。
"""
function _macro_event_check_path_magnitude_source(magnitude_source::Symbol, persistence)
    (persistence === nothing || persistence.shape !== :path) && return nothing
    magnitude_source in (:observed, :derived) || throw(
        ArgumentError(
            "shape=:path は magnitude_source ∈ (:observed, :derived) の場合のみ許容されます" *
            "（実値: $(magnitude_source)。マクロイベント変換契約 §5.2-4）",
        ),
    )
    return nothing
end

# ------------------------------------------------------------
# EventSource（統合設計 §5.2）
# ------------------------------------------------------------

"""
    EventSource

イベントの出所（マクロイベント変換契約 §2.4「発行主体・文書ID・URL・取得時刻」）。

## フィールド
- `publisher::String`: 発行主体。
- `document_id::String`: 文書ID（重複判定キー。**空文字は不可**）。
- `url::String`: 参照URL。空文字可（正準化・hashの対象外）。
- `retrieved_at::Union{DateTime,Nothing}`: 取得時刻（UTC）。hash対象外。
"""
struct EventSource
    publisher::String
    document_id::String
    url::String
    retrieved_at::Union{DateTime, Nothing}

    function EventSource(;
        publisher::AbstractString,
        document_id::AbstractString,
        url::AbstractString = "",
        retrieved_at::Union{DateTime, Nothing} = nothing,
    )
        _macro_event_require_nonempty("EventSource.document_id", document_id)
        return new(String(publisher), String(document_id), String(url), retrieved_at)
    end
end

# ------------------------------------------------------------
# EventProvenance（統合設計 §5.2・§2.4）
# ------------------------------------------------------------

"""
    EventProvenance

各層のレコードが保持する provenance 鎖（マクロイベント変換契約 §2.4）。

## フィールド
- `layer::Symbol`: `MACRO_EVENT_LAYERS` のいずれか。
- `derived_from::Vector{String}`: 直上流のレコードID（`:observed` は空でよい。それ以外は
  空であってはいけない、`provenance_broken` の防止）。
- `rule_id::String` / `rule_version::String`: 生成に用いた変換ルールの識別子とバージョン。
- `generated_at::Union{DateTime,Nothing}`: 生成時刻（UTC）。hash対象外（`Y-04`）。
- `generator::String`: 生成主体（`"human"` / システム名 / スクリプト名）。
"""
struct EventProvenance
    layer::Symbol
    derived_from::Vector{String}
    rule_id::String
    rule_version::String
    generated_at::Union{DateTime, Nothing}
    generator::String

    function EventProvenance(;
        layer::Symbol,
        rule_id::AbstractString,
        rule_version::AbstractString,
        generator::AbstractString,
        derived_from::Vector{String} = String[],
        generated_at::Union{DateTime, Nothing} = nothing,
    )
        _macro_event_check_enum("EventProvenance.layer", layer, MACRO_EVENT_LAYERS)
        _macro_event_require_nonempty("EventProvenance.rule_id", rule_id)
        _macro_event_require_nonempty("EventProvenance.rule_version", rule_version)
        _macro_event_require_nonempty("EventProvenance.generator", generator)
        if layer !== :observed && isempty(derived_from)
            throw(
                ArgumentError(
                    "provenance欠落: layer=$layer の EventProvenance は derived_from が" *
                    "空であってはいけません（L1以外は直上流のレコードIDを保持する、" *
                    "マクロイベント変換契約 §2.2・§2.4）",
                ),
            )
        end
        return new(
            layer,
            derived_from,
            String(rule_id),
            String(rule_version),
            generated_at,
            String(generator),
        )
    end
end

# ------------------------------------------------------------
# PersistenceSpec（統合設計 §5.2・§7.4）
# ------------------------------------------------------------

function _macro_event_validate_persistence_params(
    shape::Symbol,
    duration::Union{Int, Nothing},
    params::NamedTuple,
)
    if shape === :pulse
        # パラメータなし（シナリオ時間軸の意味論 §5.2）
    elseif shape === :step
        (duration === nothing || duration > 0) || throw(
            ArgumentError(
                "shape_params欠落: shape=:step の duration は正の整数または nothing（恒久）で" *
                "なければなりません（実値: $duration）",
            ),
        )
    elseif shape === :ramp
        (duration isa Int && duration > 0) || throw(
            ArgumentError(
                "shape_params欠落: shape=:ramp は duration（正の整数）を必須とします（実値: $duration）",
            ),
        )
    elseif shape === :step_then_ramp
        (haskey(params, :hold) && haskey(params, :ramp_down)) || throw(
            ArgumentError(
                "shape_params欠落: shape=:step_then_ramp は params.hold・params.ramp_down を必須とします",
            ),
        )
        (params.hold > 0 && params.ramp_down > 0) || throw(
            ArgumentError(
                "shape_params欠落: params.hold・params.ramp_down は正でなければなりません" *
                "（実値: hold=$(params.hold), ramp_down=$(params.ramp_down)）",
            ),
        )
    elseif shape === :ar1_decay
        haskey(params, :half_life) || throw(
            ArgumentError(
                "shape_params欠落: shape=:ar1_decay は params.half_life を必須とします",
            ),
        )
        params.half_life > 0 || throw(
            ArgumentError(
                "shape_params欠落: params.half_life は正でなければなりません（実値: $(params.half_life)）",
            ),
        )
        (duration === nothing || duration > 0) || throw(
            ArgumentError(
                "shape_params欠落: shape=:ar1_decay の duration（打ち切り四半期数）は正の整数" *
                "または nothing（打ち切りなし）でなければなりません（実値: $duration）",
            ),
        )
    else # :path
        haskey(params, :values) || throw(
            ArgumentError(
                "shape_params欠落: shape=:path は params.values（Vector{Float64}）を必須とします",
            ),
        )
        (params.values isa AbstractVector{<:Real}) || throw(
            ArgumentError(
                "shape_params欠落: params.values は Vector{Float64} でなければなりません（実値の型: $(typeof(params.values))）",
            ),
        )
        isempty(params.values) && throw(
            ArgumentError(
                "shape_params欠落: shape=:path の params.values は空であってはいけません",
            ),
        )
    end
    return nothing
end

"""
    PersistenceSpec

持続・減衰の時間形状の指定（シナリオ時間軸の意味論 §5）。

## フィールド
- `shape::Symbol`: `MACRO_EVENT_SHAPES` の6種のいずれか。
- `duration::Union{Int,Nothing}`: 四半期数。`nothing` = 恒久／打ち切りなし。
- `params::NamedTuple`: 形状別の追加パラメータ（`half_life`/`hold`/`ramp_down`/`values`）。

形状ごとに必須のパラメータが異なる（シナリオ時間軸の意味論 §5.2、統合設計 §7.4 `Y-11`）。
不足は `shape_params欠落` として `ArgumentError`（統合設計 §6.1 層(1)）。
離散式の計算（`shock_shape_path`）自体は Issue #198 が実装する。
"""
struct PersistenceSpec
    shape::Symbol
    duration::Union{Int, Nothing}
    params::NamedTuple

    function PersistenceSpec(;
        shape::Symbol,
        duration::Union{Int, Nothing} = nothing,
        params::NamedTuple = NamedTuple(),
    )
        _macro_event_check_enum("PersistenceSpec.shape", shape, MACRO_EVENT_SHAPES)
        _macro_event_validate_persistence_params(shape, duration, params)
        return new(shape, duration, params)
    end
end

# ------------------------------------------------------------
# EventTiming（統合設計 §5.2・§7.2、`Y-02`）
# ------------------------------------------------------------

function _macro_event_validate_timing(
    basis::Symbol,
    rule::Symbol,
    effective_from::Union{Date, Nothing},
    effective_until::Union{Date, Nothing},
    t_apply::Union{Int, Nothing},
    t_until::Union{Int, Nothing},
    from_source::Symbol,
)
    _macro_event_check_enum("EventTiming.basis", basis, (:calendar, :period))
    _macro_event_check_enum("EventTiming.from_source", from_source, (:given, :derived))
    if basis === :calendar
        rule in (:same_quarter, :next_quarter, :cutoff) || throw(
            ArgumentError(
                "EventTiming: basis=:calendar のとき rule は :same_quarter/:next_quarter/:cutoff の" *
                "いずれかでなければなりません（実値: $(rule)。シナリオ時間軸の意味論 §11.1）",
            ),
        )
        effective_from === nothing && throw(
            ArgumentError(
                "EventTiming: basis=:calendar のとき effective_from は必須です（シナリオ時間軸の意味論 §11.1）",
            ),
        )
        t_apply === nothing || throw(
            ArgumentError(
                "EventTiming: basis=:calendar のとき t_apply は指定できません" *
                "（暦日基準とモデル期基準を1レコード内で混在させない、`Y-02`）",
            ),
        )
        t_until === nothing || throw(
            ArgumentError(
                "EventTiming: basis=:calendar のとき t_until は指定できません（effective_until を用いる）",
            ),
        )
    else # :period
        rule === :explicit_period || throw(
            ArgumentError(
                "EventTiming: basis=:period のとき rule は :explicit_period でなければなりません" *
                "（実値: $(rule)。シナリオ時間軸の意味論 §11.1）",
            ),
        )
        t_apply === nothing && throw(
            ArgumentError(
                "EventTiming: basis=:period のとき t_apply は必須です（シナリオ時間軸の意味論 §11.1）",
            ),
        )
        effective_from === nothing || throw(
            ArgumentError(
                "EventTiming: basis=:period のとき effective_from は指定できません" *
                "（暦日基準とモデル期基準を1レコード内で混在させない、`Y-02`）",
            ),
        )
        effective_until === nothing || throw(
            ArgumentError(
                "EventTiming: basis=:period のとき effective_until は指定できません（t_until を用いる）",
            ),
        )
    end
    return nothing
end

"""
    EventTiming

`Scenario Assumption` の時点指定（統合設計 §5.2・§7.2、`Y-02`）。**`:calendar`（暦日基準）と
`:period`（モデル期基準）のいずれか一方のみを完備する**。混在（例: `:calendar` なのに
`t_apply` も指定する）は `ArgumentError`。

## フィールド
- `basis::Symbol`: `:calendar` または `:period`。
- `rule::Symbol`: `:calendar` のとき `:same_quarter`/`:next_quarter`/`:cutoff`、`:period` の
  とき `:explicit_period`。
- `effective_from::Union{Date,Nothing}`: `basis=:calendar` のとき必須。
- `effective_until::Union{Date,Nothing}`: `basis=:calendar` のときのみ指定可（打ち切り）。
- `t_apply::Union{Int,Nothing}`: `basis=:period` のとき必須。
- `t_until::Union{Int,Nothing}`: `basis=:period` のときのみ指定可（打ち切り）。
- `rule_overridden::Bool`: イベント型の既定規則を上書きしたか（`timing_rule_override`）。
- `from_source::Symbol`: `:given`（明示指定）または `:derived`（`announced_at` 等から導出、
  `timing_derived`）。

適用四半期の決定アルゴリズム（`offset(:cutoff, ...)` 等）は Issue #198 が実装する。
"""
struct EventTiming
    basis::Symbol
    rule::Symbol
    effective_from::Union{Date, Nothing}
    effective_until::Union{Date, Nothing}
    t_apply::Union{Int, Nothing}
    t_until::Union{Int, Nothing}
    rule_overridden::Bool
    from_source::Symbol

    function EventTiming(;
        basis::Symbol,
        rule::Symbol,
        effective_from::Union{Date, Nothing} = nothing,
        effective_until::Union{Date, Nothing} = nothing,
        t_apply::Union{Int, Nothing} = nothing,
        t_until::Union{Int, Nothing} = nothing,
        rule_overridden::Bool = false,
        from_source::Symbol = :given,
    )
        _macro_event_validate_timing(
            basis,
            rule,
            effective_from,
            effective_until,
            t_apply,
            t_until,
            from_source,
        )
        return new(
            basis,
            rule,
            effective_from,
            effective_until,
            t_apply,
            t_until,
            rule_overridden,
            from_source,
        )
    end
end

# ------------------------------------------------------------
# ObservedEvent（L1、統合設計 §5.2）
# ------------------------------------------------------------

"""
    ObservedEvent <: AbstractMacroEvent

`L1` Observed Event。決算・統計・格付・政策発表等の観測事実（マクロイベント変換契約 §2.1）。
解釈を含んではならない。

## フィールド
`event_id`・`event_type`（`MACRO_EVENT_TYPES` または `:other`）・`schema_version`・
`announced_at`・`observed_at`・`known_at`（監査属性。as-of判定には用いない、`Y-08`）・
`effective_from`・`effective_until`・`source::EventSource`・`entity`（空文字可）・
`sector`（既定 `:unknown`）・`geography`（既定 `"US"`）・`direction`（既定 `:unknown`）・
`magnitude::Union{Float64,Missing}`（欠測を0に置き換えない）・`unit`（`magnitude` があるとき
必須）・`supersedes`・`provenance::EventProvenance`・`notes`。
"""
struct ObservedEvent <: AbstractMacroEvent
    event_id::String
    event_type::Symbol
    schema_version::String
    announced_at::Date
    observed_at::Date
    known_at::Date
    effective_from::Union{Date, Nothing}
    effective_until::Union{Date, Nothing}
    source::EventSource
    entity::String
    sector::Symbol
    geography::String
    direction::Symbol
    magnitude::Union{Float64, Missing}
    unit::Union{String, Nothing}
    supersedes::Union{String, Nothing}
    provenance::EventProvenance
    notes::String

    function ObservedEvent(;
        event_id::AbstractString,
        event_type::Symbol,
        announced_at::Date,
        observed_at::Date,
        known_at::Date,
        source::EventSource,
        provenance::EventProvenance,
        schema_version::AbstractString = MACRO_EVENT_CONTRACT_VERSION,
        effective_from::Union{Date, Nothing} = nothing,
        effective_until::Union{Date, Nothing} = nothing,
        entity::AbstractString = "",
        sector::Symbol = :unknown,
        geography::AbstractString = "US",
        direction::Symbol = :unknown,
        magnitude::Union{Float64, Missing} = missing,
        unit::Union{AbstractString, Nothing} = nothing,
        supersedes::Union{AbstractString, Nothing} = nothing,
        notes::AbstractString = "",
    )
        _macro_event_check_observed_fields(
            event_id,
            event_type,
            sector,
            direction,
            magnitude,
            unit,
            supersedes,
            provenance,
        )
        return new(
            String(event_id),
            event_type,
            String(schema_version),
            announced_at,
            observed_at,
            known_at,
            effective_from,
            effective_until,
            source,
            String(entity),
            sector,
            String(geography),
            direction,
            magnitude,
            unit === nothing ? nothing : String(unit),
            supersedes === nothing ? nothing : String(supersedes),
            provenance,
            String(notes),
        )
    end
end

function _macro_event_check_observed_fields(
    event_id::AbstractString,
    event_type::Symbol,
    sector::Symbol,
    direction::Symbol,
    magnitude::Union{Float64, Missing},
    unit::Union{AbstractString, Nothing},
    supersedes::Union{AbstractString, Nothing},
    provenance::EventProvenance,
)
    _macro_event_require_nonempty("ObservedEvent.event_id", event_id)
    _macro_event_check_event_type(event_type, true)
    _macro_event_check_enum("ObservedEvent.sector", sector, _MACRO_EVENT_SECTORS)
    _macro_event_check_enum("ObservedEvent.direction", direction, _MACRO_EVENT_DIRECTIONS)
    _macro_event_require_finite("ObservedEvent.magnitude", magnitude)
    if magnitude !== missing && unit === nothing
        throw(
            ArgumentError(
                "ObservedEvent.unit は magnitude が指定されているとき必須です（マクロイベント変換契約 §3.1 row 16）",
            ),
        )
    end
    _macro_event_check_unit(unit)
    supersedes !== nothing &&
        _macro_event_require_nonempty("ObservedEvent.supersedes", supersedes)
    _macro_event_check_provenance_layer(provenance, :observed)
    return nothing
end

"""
    validate_event(e::AbstractMacroEvent) -> Nothing

`e` が§6.1の層(1)不変条件（空ID・NaN/Inf・未知のenum・unit×application_modeの非許容・
layer不整合・shape_params欠落・confidence∉[0,1]・duration≤0・pathのmagnitude不一致・
provenance欠落 等）を満たすことを再検証する。**すべての4層レコード型はコンストラクタで既に
これらを検証済みであるため、正常に構築された値に対しては常に `nothing` を返す。**
デシリアライズ等コンストラクタを経由しない経路で得たレコードの検査（Issue #203）や、
API の安定した再検証エントリポイントとして提供する。
"""
function validate_event(e::ObservedEvent)
    _macro_event_check_observed_fields(
        e.event_id,
        e.event_type,
        e.sector,
        e.direction,
        e.magnitude,
        e.unit,
        e.supersedes,
        e.provenance,
    )
    return nothing
end

# ------------------------------------------------------------
# InterpretedSignal（L2、統合設計 §5.2）
# ------------------------------------------------------------

"""
    InterpretedSignal <: AbstractMacroEvent

`L2` Interpreted Signal。観測事実から抽出した方向・対象・信頼度（マクロイベント変換契約
§2.1）。`L1` の全属性に加えて `magnitude_source`・`confidence`・`uncertainty`・
`target_concepts`・`persistence` を持つ。`sector`・`direction` は必須（欠測不可。ただし
`:unknown` という値自体は許容する）。数量を作ってはならない（原文に無ければ `magnitude`
は欠測のままにする）。
"""
struct InterpretedSignal <: AbstractMacroEvent
    event_id::String
    event_type::Symbol
    schema_version::String
    announced_at::Date
    observed_at::Date
    known_at::Date
    effective_from::Union{Date, Nothing}
    effective_until::Union{Date, Nothing}
    source::EventSource
    entity::String
    sector::Symbol
    geography::String
    direction::Symbol
    magnitude::Union{Float64, Missing}
    unit::Union{String, Nothing}
    supersedes::Union{String, Nothing}
    provenance::EventProvenance
    notes::String
    magnitude_source::Symbol
    confidence::Float64
    uncertainty::Union{Tuple{Float64, Float64}, Nothing}
    target_concepts::Vector{Symbol}
    persistence::Union{PersistenceSpec, Nothing}

    function InterpretedSignal(;
        event_id::AbstractString,
        event_type::Symbol,
        announced_at::Date,
        observed_at::Date,
        known_at::Date,
        source::EventSource,
        provenance::EventProvenance,
        sector::Symbol,
        direction::Symbol,
        magnitude_source::Symbol,
        confidence::Float64,
        schema_version::AbstractString = MACRO_EVENT_CONTRACT_VERSION,
        effective_from::Union{Date, Nothing} = nothing,
        effective_until::Union{Date, Nothing} = nothing,
        entity::AbstractString = "",
        geography::AbstractString = "US",
        magnitude::Union{Float64, Missing} = missing,
        unit::Union{AbstractString, Nothing} = nothing,
        supersedes::Union{AbstractString, Nothing} = nothing,
        notes::AbstractString = "",
        uncertainty::Union{Tuple{Float64, Float64}, Nothing} = nothing,
        target_concepts::Vector{Symbol} = Symbol[],
        persistence::Union{PersistenceSpec, Nothing} = nothing,
    )
        _macro_event_check_interpreted_fields(
            event_id,
            event_type,
            sector,
            direction,
            magnitude,
            unit,
            supersedes,
            provenance,
            magnitude_source,
            confidence,
            uncertainty,
            target_concepts,
            persistence,
        )
        return new(
            String(event_id),
            event_type,
            String(schema_version),
            announced_at,
            observed_at,
            known_at,
            effective_from,
            effective_until,
            source,
            String(entity),
            sector,
            String(geography),
            direction,
            magnitude,
            unit === nothing ? nothing : String(unit),
            supersedes === nothing ? nothing : String(supersedes),
            provenance,
            String(notes),
            magnitude_source,
            confidence,
            uncertainty,
            target_concepts,
            persistence,
        )
    end
end

function _macro_event_check_interpreted_fields(
    event_id::AbstractString,
    event_type::Symbol,
    sector::Symbol,
    direction::Symbol,
    magnitude::Union{Float64, Missing},
    unit::Union{AbstractString, Nothing},
    supersedes::Union{AbstractString, Nothing},
    provenance::EventProvenance,
    magnitude_source::Symbol,
    confidence::Float64,
    uncertainty::Union{Tuple{Float64, Float64}, Nothing},
    target_concepts::Vector{Symbol},
    persistence::Union{PersistenceSpec, Nothing},
)
    _macro_event_require_nonempty("InterpretedSignal.event_id", event_id)
    _macro_event_check_event_type(event_type, true)
    _macro_event_check_enum("InterpretedSignal.sector", sector, _MACRO_EVENT_SECTORS)
    _macro_event_check_enum(
        "InterpretedSignal.direction",
        direction,
        _MACRO_EVENT_DIRECTIONS,
    )
    _macro_event_require_finite("InterpretedSignal.magnitude", magnitude)
    if magnitude !== missing && unit === nothing
        throw(
            ArgumentError(
                "InterpretedSignal.unit は magnitude が指定されているとき必須です（マクロイベント変換契約 §3.1 row 16）",
            ),
        )
    end
    _macro_event_check_unit(unit)
    supersedes !== nothing &&
        _macro_event_require_nonempty("InterpretedSignal.supersedes", supersedes)
    _macro_event_check_provenance_layer(provenance, :interpreted)
    _macro_event_check_enum(
        "InterpretedSignal.magnitude_source",
        magnitude_source,
        MACRO_EVENT_MAGNITUDE_SOURCES,
    )
    _macro_event_check_confidence(confidence)
    _macro_event_check_uncertainty(uncertainty)
    _macro_event_check_target_concepts(target_concepts)
    _macro_event_check_path_magnitude_source(magnitude_source, persistence)
    _macro_event_check_path_persistence(magnitude, persistence)
    return nothing
end

function validate_event(e::InterpretedSignal)
    _macro_event_check_interpreted_fields(
        e.event_id,
        e.event_type,
        e.sector,
        e.direction,
        e.magnitude,
        e.unit,
        e.supersedes,
        e.provenance,
        e.magnitude_source,
        e.confidence,
        e.uncertainty,
        e.target_concepts,
        e.persistence,
    )
    return nothing
end

# ------------------------------------------------------------
# ScenarioAssumption（L3、統合設計 §5.2、`Y-01`・`Y-02`・`Y-03`・`Y-05`）
# ------------------------------------------------------------

"""
    ScenarioAssumption <: AbstractMacroEvent

`L3` Scenario Assumption。分析者が設定したモデル非依存のショック仮定（マクロイベント変換
契約 §2.1）。7項目（`sector`・`direction`・`magnitude`・`unit`・`magnitude_source`・
`application_mode`・`timing`・`persistence`・`target_concepts`）を完備する。

`entity` フィールドを**持たない**（企業レベルイベントの部門集約は初期実装の対象外、
`Y-03`）。`event_type = :other` は許容しない（`Y-01`）。`is_scenario_assumption` は常に
`true` であり構築時パラメータでは受け付けない。
"""
struct ScenarioAssumption <: AbstractMacroEvent
    assumption_id::String
    event_type::Symbol
    schema_version::String
    sector::Symbol
    geography::String
    direction::Symbol
    magnitude::Float64
    unit::String
    magnitude_source::Symbol
    application_mode::Symbol
    timing::EventTiming
    persistence::PersistenceSpec
    target_concepts::Vector{Symbol}
    is_scenario_assumption::Bool
    confidence::Union{Float64, Nothing}
    uncertainty::Union{Tuple{Float64, Float64}, Nothing}
    provenance::EventProvenance
    notes::String
    caveats::String

    function ScenarioAssumption(;
        assumption_id::AbstractString,
        event_type::Symbol,
        sector::Symbol,
        direction::Symbol,
        magnitude::Float64,
        unit::AbstractString,
        magnitude_source::Symbol,
        application_mode::Symbol,
        timing::EventTiming,
        persistence::PersistenceSpec,
        target_concepts::Vector{Symbol},
        provenance::EventProvenance,
        schema_version::AbstractString = MACRO_EVENT_CONTRACT_VERSION,
        geography::AbstractString = "US",
        confidence::Union{Float64, Nothing} = nothing,
        uncertainty::Union{Tuple{Float64, Float64}, Nothing} = nothing,
        notes::AbstractString = "",
        caveats::AbstractString = "",
    )
        _macro_event_check_assumption_fields(
            assumption_id,
            event_type,
            sector,
            direction,
            magnitude,
            unit,
            magnitude_source,
            application_mode,
            target_concepts,
            provenance,
            confidence,
            uncertainty,
            persistence,
        )
        return new(
            String(assumption_id),
            event_type,
            String(schema_version),
            sector,
            String(geography),
            direction,
            magnitude,
            String(unit),
            magnitude_source,
            application_mode,
            timing,
            persistence,
            target_concepts,
            true,
            confidence,
            uncertainty,
            provenance,
            String(notes),
            String(caveats),
        )
    end
end

function _macro_event_check_assumption_fields(
    assumption_id::AbstractString,
    event_type::Symbol,
    sector::Symbol,
    direction::Symbol,
    magnitude::Float64,
    unit::AbstractString,
    magnitude_source::Symbol,
    application_mode::Symbol,
    target_concepts::Vector{Symbol},
    provenance::EventProvenance,
    confidence::Union{Float64, Nothing},
    uncertainty::Union{Tuple{Float64, Float64}, Nothing},
    persistence::PersistenceSpec,
)
    _macro_event_require_nonempty("ScenarioAssumption.assumption_id", assumption_id)
    _macro_event_check_event_type(event_type, false)
    _macro_event_check_enum("ScenarioAssumption.sector", sector, _MACRO_EVENT_SECTORS)
    direction === :unknown && throw(
        ArgumentError(
            "ScenarioAssumption.direction=:unknown は許容されません（マクロイベント変換契約 §3.1。仮定は方向を明示する）",
        ),
    )
    _macro_event_check_enum(
        "ScenarioAssumption.direction",
        direction,
        _MACRO_EVENT_DIRECTIONS,
    )
    _macro_event_require_finite("ScenarioAssumption.magnitude", magnitude)
    _macro_event_check_unit_application_mode(unit, application_mode)
    _macro_event_check_enum(
        "ScenarioAssumption.magnitude_source",
        magnitude_source,
        MACRO_EVENT_MAGNITUDE_SOURCES,
    )
    _macro_event_check_target_concepts(target_concepts; require_nonempty = true)
    _macro_event_check_provenance_layer(provenance, :assumption)
    _macro_event_check_confidence(confidence)
    _macro_event_check_uncertainty(uncertainty)
    _macro_event_check_path_magnitude_source(magnitude_source, persistence)
    _macro_event_check_path_persistence(magnitude, persistence)
    return nothing
end

function validate_event(e::ScenarioAssumption)
    _macro_event_check_assumption_fields(
        e.assumption_id,
        e.event_type,
        e.sector,
        e.direction,
        e.magnitude,
        e.unit,
        e.magnitude_source,
        e.application_mode,
        e.target_concepts,
        e.provenance,
        e.confidence,
        e.uncertainty,
        e.persistence,
    )
    return nothing
end

# ------------------------------------------------------------
# AppliedModelInput（L4、統合設計 §5.2、`Y-05`）
# ------------------------------------------------------------

"""
    AppliedModelInput <: AbstractMacroEvent

`L4` Applied Model Input。特定モデルの変数へ適用された変更（マクロイベント変換契約
§2.1）。`baseline_values` を必ず保持し、`:multiplicative` は「同一時点の baseline 値に
対する比」として一律に解釈する（`Y-05`）。`target_variable` の妥当性（`exogenous_variables(m)`
への所属）はモデル固有 mapping 層（`map_event`、Issue #201）が検証する。**本層はモデルを
知らないため、ここでは検証しない**（統合設計 §3.1 契約1）。
"""
struct AppliedModelInput <: AbstractMacroEvent
    input_id::String
    assumption_id::String
    model::Symbol
    target_variable::Symbol
    application_mode::Symbol
    unit::String
    magnitude::Float64
    persistence::PersistenceSpec
    t_apply::Int
    values::Vector{Float64}
    baseline_values::Vector{Float64}
    mapping_id::String
    mapping_version::String
    warnings::Vector{Symbol}
    provenance::EventProvenance

    function AppliedModelInput(;
        input_id::AbstractString,
        assumption_id::AbstractString,
        model::Symbol,
        target_variable::Symbol,
        application_mode::Symbol,
        unit::AbstractString,
        magnitude::Float64,
        persistence::PersistenceSpec,
        t_apply::Int,
        values::Vector{Float64},
        baseline_values::Vector{Float64},
        mapping_id::AbstractString,
        mapping_version::AbstractString,
        provenance::EventProvenance,
        warnings::Vector{Symbol} = Symbol[],
    )
        _macro_event_check_applied_fields(
            input_id,
            assumption_id,
            unit,
            application_mode,
            magnitude,
            values,
            baseline_values,
            mapping_id,
            mapping_version,
            warnings,
            provenance,
            persistence,
        )
        return new(
            String(input_id),
            String(assumption_id),
            model,
            target_variable,
            application_mode,
            String(unit),
            magnitude,
            persistence,
            t_apply,
            values,
            baseline_values,
            String(mapping_id),
            String(mapping_version),
            warnings,
            provenance,
        )
    end
end

function _macro_event_check_applied_fields(
    input_id::AbstractString,
    assumption_id::AbstractString,
    unit::AbstractString,
    application_mode::Symbol,
    magnitude::Float64,
    values::Vector{Float64},
    baseline_values::Vector{Float64},
    mapping_id::AbstractString,
    mapping_version::AbstractString,
    warnings::Vector{Symbol},
    provenance::EventProvenance,
    persistence::PersistenceSpec,
)
    _macro_event_require_nonempty("AppliedModelInput.input_id", input_id)
    _macro_event_require_nonempty("AppliedModelInput.assumption_id", assumption_id)
    _macro_event_check_unit_application_mode(unit, application_mode)
    _macro_event_require_finite("AppliedModelInput.magnitude", magnitude)
    isempty(values) &&
        throw(ArgumentError("AppliedModelInput.values は空であってはいけません"))
    length(values) == length(baseline_values) || throw(
        ArgumentError(
            "AppliedModelInput.values（長さ$(length(values))）と baseline_values" *
            "（長さ$(length(baseline_values))）は同じ長さでなければなりません",
        ),
    )
    _macro_event_require_nonempty("AppliedModelInput.mapping_id", mapping_id)
    _macro_event_require_nonempty("AppliedModelInput.mapping_version", mapping_version)
    for w in warnings
        w in MACRO_EVENT_WARNING_CODES || throw(
            ArgumentError(
                "AppliedModelInput.warnings に未知のコードが含まれています: $w（許容: $(MACRO_EVENT_WARNING_CODES)）",
            ),
        )
    end
    _macro_event_check_provenance_layer(provenance, :applied)
    _macro_event_check_path_persistence(magnitude, persistence)
    return nothing
end

function validate_event(e::AppliedModelInput)
    _macro_event_check_applied_fields(
        e.input_id,
        e.assumption_id,
        e.unit,
        e.application_mode,
        e.magnitude,
        e.values,
        e.baseline_values,
        e.mapping_id,
        e.mapping_version,
        e.warnings,
        e.provenance,
        e.persistence,
    )
    return nothing
end
