# event_type_registry.jl: イベント型レジストリと初期イベント型 9 種（Issue #199 / `E-3`・
# Issue #200 / `E-4`）。
#
# `MacroEventTypeSpec`（イベント型ごとの許容部門・許容単位・既定適用方式・既定 timing rule・
# 既定 shape・適用不能条件・必須 methodology metadata・（`:RefinancingOrRatingEvent` に限り）
# reason code 語彙を宣言的に保持するレコード型）と `MACRO_EVENT_TYPE_REGISTRY`
# （`Dict{Symbol,MacroEventTypeSpec}`）・`macro_event_type_spec` を定義する。実体経済側 5 種
# （`:DemandOutlookRevision`・`:CapexGuidanceRevision`・`:OrderCancellation`・
# `:PriceOrMarginShock`・`:EmploymentPlanRevision`、Issue #199）と信用・金融政策側 4 種
# （`:CreditSpreadShock`・`:LendingStandardChange`・`:RefinancingOrRatingEvent`・
# `:PolicyRateChange`、Issue #200）をレジストリへ登録する。
#
# 型別 smart constructor（`observed_event`・`interpreted_signal`・`scenario_assumption`）を
# 提供する。これらはレジストリを参照して event_type 別の許容 unit・application_mode・
# target_concepts を検証したうえで、`macro_events.jl` の層別コンストラクタ（`ObservedEvent`・
# `InterpretedSignal`・`ScenarioAssumption`）へ委譲する。`:other` は扱わない（型別検証が
# 定義されないため。`:other` を用いる場合は層別コンストラクタを直接使用する）。信用・金融政策側
# 4 種は実体経済側 5 種と同じ検証ヘルパ（`_ert_check_unit`・`_ert_check_application_mode`・
# `_ert_check_target_concepts`・`_ert_check_direction_magnitude_sign`）で足りる
# （`:OrderCancellation`/`:PriceOrMarginShock` のような単位混同分岐は不要）。
#
# 本ファイルは**9 個の event-specific struct を作らない**（統合設計 `Y-22`。データ形状は
# 層ごとに 1 つであり、イベント型ごとの差異は宣言的なレジストリ行で表現する）。
# `sector` の許容値はレジストリに記録するが、構築時には**強制しない**（統合設計 §3.2・
# #199 コメントによる本文からの変更点 3。「target を持たない sector」の判定は
# `unmapped_target` として #201 の mapping adapter が行う。本ファイルは
# `inapplicable_conditions` を宣言するにとどめる）。`:RefinancingOrRatingEvent` の
# rating action / outlook / refinancing availability / maturity wall の区別も同様に
# **新しい struct（subtype）ではなく reason code の語彙**として宣言するにとどめる
# （#200 コメントによる本文からの変更点 3、`Y-22`）。個々のレコードでの reason の記録は
# 既存の `direction`（upgrade/downgrade）・`magnitude`/`unit`（市場価格へ現れた分）・
# `notes`（reason code 語彙を参照する自由記述）で足り、4 層レコード型に新しいフィールドを
# 追加しない（本 Issue の対象ファイルは本ファイルと `src/DME.jl`・テストに限られ、
# `macro_events.jl` の変更は対象外）。
#
# 政策金利と信用スプレッドは別 target concept（`:policy_rate` と `:credit_spread`）・別
# event_type を持つ独立したレコードであり、本ファイルは両者を自動的に相殺（netting）する
# ロジックを持たない（実施内容「`PolicyRateChange`を信用スプレッドへ自動相殺しない」）。
#
# 設計契約:
#   docs/architecture/macro_event_runtime_integration.md §5.3（イベント型レジストリ）・
#     §11 `E-3`・`E-4` 行（#199・#200 コメントによる本文からの変更点）
#   docs/architecture/macro_event_contract.md §3.3（単位語彙）・§4.2（対象・変数・方式・単位）・
#     §4.3（適用時点・持続・合成）・§4.4（適用不能条件・必須 methodology metadata）・
#     §4.5（適用先を持たないイベント型）・§5.5（重複投入の検出・dedup key）
#   Issue #199 本文・#199 コメント（#196 統合設計による確定）
#   Issue #200 本文・#200 コメント（#196 統合設計による確定）

# ------------------------------------------------------------
# MacroEventTypeSpec（統合設計 §5.3）
# ------------------------------------------------------------

"許容 `allowed_scope` の語彙（企業単位／部門単位／経済全体単位。統合設計 §5.3 のコメント）。"
const _EVENT_TYPE_SPEC_SCOPES = (:entity, :sector, :system_wide)

"""
`:RefinancingOrRatingEvent` の reason code 語彙（#200 コメントによる本文からの変更点 3。
rating action（`:rating_upgrade`/`:rating_downgrade`）・outlook（`:outlook_change`）・
refinancing availability（`:refinancing_unavailable`）・maturity wall（`:maturity_wall`）を
混同しないための語彙。新しい struct（subtype）は作らず、レジストリ行の宣言的な語彙リストと
個々のレコードの `direction`/`magnitude`/`notes` の組み合わせで表現する（他の event_type は
`reason_codes = Symbol[]`）。
"""
const _MACRO_EVENT_REASON_CODES = (
    :rating_upgrade,
    :rating_downgrade,
    :outlook_change,
    :refinancing_unavailable,
    :maturity_wall,
)

"許容 `effective_from_default` の語彙（統合設計 §5.3 のコメント）。"
const _EVENT_TYPE_SPEC_EFFECTIVE_FROM_DEFAULTS = (:announced_at, :observed_at, :explicit)

function _event_type_spec_check_symbols(
    label::AbstractString,
    values::Vector{Symbol},
    allowed::Tuple{Vararg{Symbol}},
)
    for v in values
        v in allowed || throw(
            ArgumentError("$label に未知の値が含まれています: $v（許容: $(allowed)）"),
        )
    end
    return nothing
end

function _event_type_spec_check_units(label::AbstractString, units::Vector{String})
    for u in units
        haskey(_MACRO_EVENT_UNIT_APPLICATION_MODE_TABLE, u) || throw(
            ArgumentError(
                "$label に未知の単位が含まれています: \"$u\"" *
                "（許容: $(collect(keys(_MACRO_EVENT_UNIT_APPLICATION_MODE_TABLE)))。" *
                "マクロイベント変換契約 §3.3）",
            ),
        )
    end
    return nothing
end

"""
    MacroEventTypeSpec

イベント型ごとの許容部門・許容 unit・既定 application_mode・既定適用四半期規則・既定
持続形状・適用不能条件・必須 methodology metadata を宣言的に保持するレコード型
（統合設計 §5.3）。イベント型別の struct を作る代わりに、レジストリ 1 行として表現する
（`Y-22`）。

## フィールド
- `event_type::Symbol`: `MACRO_EVENT_TYPES` のいずれか。
- `display_name::String`: 日本語表示名。
- `allowed_sectors::Vector{Symbol}`: マクロイベント変換契約 §4.2 が「可」とする部門。**構築時
  には強制しない**（宣言的データ。`unmapped_target` の判定は #201 の責務）。
- `allowed_scope::Vector{Symbol}`: `:entity` / `:sector` / `:system_wide` の部分集合。
- `allowed_target_concepts::Vector{Symbol}`: `MACRO_EVENT_TARGET_CONCEPTS` の部分集合。
  smart constructor が `target_concepts` の妥当性を検証する際に用いる（**強制する**）。
- `allowed_units::Vector{String}`: マクロイベント変換契約 §3.3 の単位語彙の部分集合。smart
  constructor が `unit` の妥当性を検証する際に用いる（**強制する**）。
- `allowed_application_modes::Vector{Symbol}`: `MACRO_EVENT_APPLICATION_MODES` の部分集合。
  `scenario_assumption` が `application_mode` の妥当性を検証する際に用いる（**強制する**）。
- `effective_from_default::Symbol`: `:announced_at` / `:observed_at` / `:explicit`。
- `default_timing_rule::Union{Symbol,Nothing}`: 適用先を持たない型は `nothing`。
- `default_shape::Union{Symbol,Nothing}`: 同上。
- `default_shape_params::NamedTuple`
- `default_duration::Union{Int,Nothing}`
- `inapplicable_conditions::Vector{Symbol}`: マクロイベント変換契約 §4.4 の適用不能条件
  （宣言のみ。判定は #201）。
- `required_methodology_keys::Vector{String}`: マクロイベント変換契約 §4.4 の必須 metadata。
- `contract_section::String`: 出典（例 `"macro_event_contract §4.2 row 1"`）。
- `reason_codes::Vector{Symbol}`: `:RefinancingOrRatingEvent` に限り
  `_MACRO_EVENT_REASON_CODES` の部分集合を宣言する（宣言のみ。個々のレコードでの検証は
  行わない。他の event_type は空ベクトル、既定 `Symbol[]`）。

`default_shape !== nothing` のとき、`PersistenceSpec(shape=default_shape,
duration=default_duration, params=default_shape_params)` が構築できることをレジストリ登録時に
自己検査する（レジストリ行の内部矛盾をパッケージ読み込み時に検出する）。
"""
struct MacroEventTypeSpec
    event_type::Symbol
    display_name::String
    allowed_sectors::Vector{Symbol}
    allowed_scope::Vector{Symbol}
    allowed_target_concepts::Vector{Symbol}
    allowed_units::Vector{String}
    allowed_application_modes::Vector{Symbol}
    effective_from_default::Symbol
    default_timing_rule::Union{Symbol, Nothing}
    default_shape::Union{Symbol, Nothing}
    default_shape_params::NamedTuple
    default_duration::Union{Int, Nothing}
    inapplicable_conditions::Vector{Symbol}
    required_methodology_keys::Vector{String}
    contract_section::String
    reason_codes::Vector{Symbol}

    function MacroEventTypeSpec(;
        event_type::Symbol,
        display_name::AbstractString,
        allowed_sectors::Vector{Symbol},
        allowed_scope::Vector{Symbol},
        allowed_target_concepts::Vector{Symbol},
        allowed_units::Vector{String},
        allowed_application_modes::Vector{Symbol},
        contract_section::AbstractString,
        effective_from_default::Symbol = :announced_at,
        default_timing_rule::Union{Symbol, Nothing} = nothing,
        default_shape::Union{Symbol, Nothing} = nothing,
        default_shape_params::NamedTuple = NamedTuple(),
        default_duration::Union{Int, Nothing} = nothing,
        inapplicable_conditions::Vector{Symbol} = Symbol[],
        required_methodology_keys::Vector{String} = String[],
        reason_codes::Vector{Symbol} = Symbol[],
    )
        event_type in MACRO_EVENT_TYPES || throw(
            ArgumentError(
                "MacroEventTypeSpec.event_type=$event_type は MACRO_EVENT_TYPES の9種の" *
                "いずれかでなければなりません（generic event へ縮約しない、統合設計 §10.1 項目7）",
            ),
        )
        _macro_event_require_nonempty("MacroEventTypeSpec.display_name", display_name)
        _macro_event_require_nonempty(
            "MacroEventTypeSpec.contract_section",
            contract_section,
        )
        _event_type_spec_check_symbols(
            "MacroEventTypeSpec.allowed_sectors",
            allowed_sectors,
            _MACRO_EVENT_SECTORS,
        )
        _event_type_spec_check_symbols(
            "MacroEventTypeSpec.allowed_scope",
            allowed_scope,
            _EVENT_TYPE_SPEC_SCOPES,
        )
        isempty(allowed_target_concepts) && throw(
            ArgumentError(
                "MacroEventTypeSpec.allowed_target_concepts は空であってはいけません" *
                "（event_type=$event_type はモデル非依存の target concept を最低1つ持つ、" *
                "マクロイベント変換契約 §3.4）",
            ),
        )
        _event_type_spec_check_symbols(
            "MacroEventTypeSpec.allowed_target_concepts",
            allowed_target_concepts,
            MACRO_EVENT_TARGET_CONCEPTS,
        )
        _event_type_spec_check_units("MacroEventTypeSpec.allowed_units", allowed_units)
        _event_type_spec_check_symbols(
            "MacroEventTypeSpec.allowed_application_modes",
            allowed_application_modes,
            MACRO_EVENT_APPLICATION_MODES,
        )
        effective_from_default in _EVENT_TYPE_SPEC_EFFECTIVE_FROM_DEFAULTS || throw(
            ArgumentError(
                "MacroEventTypeSpec.effective_from_default=$effective_from_default は " *
                "$(_EVENT_TYPE_SPEC_EFFECTIVE_FROM_DEFAULTS) のいずれかでなければなりません",
            ),
        )
        if default_timing_rule !== nothing
            default_timing_rule in _MACRO_EVENT_TIMING_RULES || throw(
                ArgumentError(
                    "MacroEventTypeSpec.default_timing_rule=$default_timing_rule は " *
                    "$(_MACRO_EVENT_TIMING_RULES) のいずれか、または nothing（適用先なし）で" *
                    "なければなりません",
                ),
            )
        end
        (default_shape === nothing) == (default_timing_rule === nothing) || throw(
            ArgumentError(
                "MacroEventTypeSpec: default_shape と default_timing_rule は両方 nothing" *
                "（適用先なし、契約 §4.3 の「―」行）か、両方非 nothing でなければなりません" *
                "（実値: default_shape=$default_shape, default_timing_rule=$default_timing_rule）",
            ),
        )
        if default_shape !== nothing
            # レジストリ行の内部矛盾（shape_params欠落等）をパッケージ読み込み時に検出する。
            PersistenceSpec(;
                shape = default_shape,
                duration = default_duration,
                params = default_shape_params,
            )
        end
        _event_type_spec_check_symbols(
            "MacroEventTypeSpec.reason_codes",
            reason_codes,
            _MACRO_EVENT_REASON_CODES,
        )
        length(reason_codes) == length(unique(reason_codes)) || throw(
            ArgumentError(
                "MacroEventTypeSpec.reason_codes に重複があります: $reason_codes",
            ),
        )
        return new(
            event_type,
            String(display_name),
            allowed_sectors,
            allowed_scope,
            allowed_target_concepts,
            allowed_units,
            allowed_application_modes,
            effective_from_default,
            default_timing_rule,
            default_shape,
            default_shape_params,
            default_duration,
            inapplicable_conditions,
            required_methodology_keys,
            String(contract_section),
            reason_codes,
        )
    end
end

# ------------------------------------------------------------
# レジストリ本体（実体経済側 5 種 Issue #199・信用・金融政策側 4 種 Issue #200）
# ------------------------------------------------------------

"""
    MACRO_EVENT_TYPE_REGISTRY

`event_type => MacroEventTypeSpec` のレジストリ（統合設計 §5.3）。実体経済側 5 種
（Issue #199）と信用・金融政策側 4 種（Issue #200）の計 9 種（`MACRO_EVENT_TYPES` と一致）を
登録する。
"""
const MACRO_EVENT_TYPE_REGISTRY = Dict{Symbol, MacroEventTypeSpec}(
    :DemandOutlookRevision => MacroEventTypeSpec(;
        event_type = :DemandOutlookRevision,
        display_name = "需要見通し改定",
        allowed_sectors = [:s1, :s2, :s3],
        allowed_scope = [:entity, :sector],
        allowed_target_concepts = [:demand_expectation],
        allowed_units = ["%"],
        allowed_application_modes = [:multiplicative],
        effective_from_default = :announced_at,
        default_timing_rule = :cutoff,
        default_shape = :ar1_decay,
        default_shape_params = (half_life = 6,),
        default_duration = nothing,
        inapplicable_conditions = [
            :geography_ne_us,
            :sector_out_of_s1_s3,
            :direction_unknown,
        ],
        required_methodology_keys = ["期待指数への換算式", "baseline参照期"],
        contract_section = "macro_event_contract §4.2 row 1・row 1b・§4.3 row 1・§4.4 row 1",
    ),
    :CapexGuidanceRevision => MacroEventTypeSpec(;
        event_type = :CapexGuidanceRevision,
        display_name = "CAPEXガイダンス改定",
        allowed_sectors = [:s1],
        allowed_scope = [:entity, :sector],
        allowed_target_concepts = [:capex_plan],
        allowed_units = ["%"],
        allowed_application_modes = [:multiplicative],
        effective_from_default = :announced_at,
        default_timing_rule = :cutoff,
        default_shape = :step_then_ramp,
        default_shape_params = (hold = 4, ramp_down = 4),
        default_duration = nothing,
        inapplicable_conditions = [
            :sector_ne_s1,
            :quarterly_allocation_basis_unknown,
            :magnitude_basis_unknown,
        ],
        required_methodology_keys = [
            "基準（前回比／前年比／baseline比）",
            "按分方式",
            "集約対象企業リストとweight",
        ],
        contract_section = "macro_event_contract §4.2 row 2・§4.3 row 2・§4.4 row 2",
    ),
    :OrderCancellation => MacroEventTypeSpec(;
        event_type = :OrderCancellation,
        display_name = "受注・発注キャンセル",
        allowed_sectors = [:s1, :s2, :s3],
        allowed_scope = [:entity, :sector],
        allowed_target_concepts = [:order_flow],
        allowed_units = ["%", "bn USD (2017 chained)"],
        allowed_application_modes = [:multiplicative, :additive],
        effective_from_default = :announced_at,
        default_timing_rule = :same_quarter,
        default_shape = :step,
        default_shape_params = NamedTuple(),
        default_duration = 4,
        inapplicable_conditions = [
            :pipeline_cancellation_irreversible,
            :cancellation_deferral_split_unspecified,
        ],
        required_methodology_keys = [
            "キャンセルと延期の配分は指定しないことの明記",
            "取消金額の基準",
        ],
        contract_section = "macro_event_contract §4.2 row 3・row 3b・row 3c・§4.3 row 3・" *
                           "§4.4 row 3・§4.5-1",
    ),
    :PriceOrMarginShock => MacroEventTypeSpec(;
        event_type = :PriceOrMarginShock,
        display_name = "価格・利益率ショック",
        allowed_sectors = [:s1],
        allowed_scope = [:entity, :sector],
        allowed_target_concepts = [:output_price_margin],
        allowed_units = ["%"],
        allowed_application_modes = [:multiplicative],
        effective_from_default = :announced_at,
        default_timing_rule = :cutoff,
        default_shape = :ar1_decay,
        default_shape_params = (half_life = 4,),
        default_duration = nothing,
        inapplicable_conditions = [:sector_ne_s1, :margin_only_no_price_conversion],
        required_methodology_keys = ["価格指数の基準", "実質化の有無"],
        contract_section = "macro_event_contract §4.2 row 4・row 4b・§4.3 row 4・§4.4 row 4・" *
                           "§4.5-2",
    ),
    :EmploymentPlanRevision => MacroEventTypeSpec(;
        event_type = :EmploymentPlanRevision,
        display_name = "雇用計画改定",
        allowed_sectors = [:s1, :s2, :s3],
        allowed_scope = [:entity, :sector],
        allowed_target_concepts = [:employment_plan],
        allowed_units = ["%"],
        allowed_application_modes = [:multiplicative],
        effective_from_default = :announced_at,
        default_timing_rule = nothing,
        default_shape = nothing,
        default_shape_params = NamedTuple(),
        default_duration = nothing,
        inapplicable_conditions = [:employment_plan_has_no_target_variable],
        required_methodology_keys = [
            "雇用計画を消費・所得への直接ショックへ変換しないことの明記" *
            "（雇用計画conceptとして保持する。マクロイベント変換契約 §4.5-5）",
        ],
        contract_section = "macro_event_contract §4.2 row 8・§4.5-5",
    ),
    :CreditSpreadShock => MacroEventTypeSpec(;
        event_type = :CreditSpreadShock,
        display_name = "信用スプレッドショック",
        allowed_sectors = [:s4, :unknown],
        allowed_scope = [:entity, :sector, :system_wide],
        allowed_target_concepts = [:credit_spread],
        allowed_units = ["bp"],
        allowed_application_modes = [:additive],
        effective_from_default = :announced_at,
        default_timing_rule = :same_quarter,
        default_shape = :ar1_decay,
        default_shape_params = (half_life = 4,),
        default_duration = nothing,
        inapplicable_conditions = [:credit_market_scope_mismatch],
        required_methodology_keys = [
            "参照系列（HY OAS / IG OAS）",
            "内生成分と外生成分の分離方針",
        ],
        contract_section = "macro_event_contract §4.2 row 5・§4.3 row 5・§4.4 row 5",
    ),
    :LendingStandardChange => MacroEventTypeSpec(;
        event_type = :LendingStandardChange,
        display_name = "貸出態度変化",
        allowed_sectors = [:s4],
        allowed_scope = [:sector, :system_wide],
        allowed_target_concepts = [:lending_standard],
        allowed_units = ["%"],
        allowed_application_modes = [:multiplicative],
        effective_from_default = :announced_at,
        default_timing_rule = nothing,
        default_shape = nothing,
        default_shape_params = NamedTuple(),
        default_duration = nothing,
        inapplicable_conditions = [:lending_standard_has_no_target_variable],
        required_methodology_keys = [
            "貸出態度の変化を消費・投資への直接ショックへ変換しないことの明記" *
            "（貸出態度conceptとして保持する。マクロイベント変換契約 §4.5-3）",
            "定性的な引き締め表現の場合は magnitude を捏造せず欠測のまま保持することの明記",
        ],
        contract_section = "macro_event_contract §4.2 row 6・§4.5-3",
    ),
    :RefinancingOrRatingEvent => MacroEventTypeSpec(;
        event_type = :RefinancingOrRatingEvent,
        display_name = "借換・格付イベント",
        allowed_sectors = [:s1, :s2, :s3, :s4],
        allowed_scope = [:entity, :sector, :system_wide],
        allowed_target_concepts = [:refinancing_condition],
        allowed_units = ["bp"],
        allowed_application_modes = [:additive],
        effective_from_default = :announced_at,
        default_timing_rule = :same_quarter,
        default_shape = :ar1_decay,
        default_shape_params = (half_life = 4,),
        default_duration = nothing,
        inapplicable_conditions = [
            :rating_change_not_reflected_in_market_price,
            :refinancing_condition_target_unavailable,
        ],
        required_methodology_keys = [
            "格付→スプレッド換算の根拠",
            "借換条件（rollover）への作用は表現していないことの明記",
        ],
        contract_section = "macro_event_contract §4.2 row 7・row 7b・§4.3 row 7・§4.4 row 7",
        reason_codes = [
            :rating_upgrade,
            :rating_downgrade,
            :outlook_change,
            :refinancing_unavailable,
            :maturity_wall,
        ],
    ),
    :PolicyRateChange => MacroEventTypeSpec(;
        event_type = :PolicyRateChange,
        display_name = "政策金利変更",
        allowed_sectors = [:out_of_model],
        allowed_scope = [:system_wide],
        allowed_target_concepts = [:policy_rate],
        allowed_units = ["%pt"],
        allowed_application_modes = [:absolute, :additive],
        effective_from_default = :announced_at,
        default_timing_rule = :same_quarter,
        default_shape = :step,
        default_shape_params = NamedTuple(),
        default_duration = nothing,
        inapplicable_conditions = [:policy_rate_negative_after_application],
        required_methodology_keys = [
            "実効FF金利ベースか目標レンジベースかの明記",
            "四半期平均への換算方式",
        ],
        contract_section = "macro_event_contract §4.2 row 9・§4.3 row 9・§4.4 row 9",
    ),
)

"""
    macro_event_type_spec(event_type::Symbol) -> MacroEventTypeSpec

`event_type` に対応する `MacroEventTypeSpec` を返す。未登録の `event_type`（`:other` を含む）
は `ArgumentError`（generic event へ縮約しない、統合設計 §10.1 項目7）。
"""
function macro_event_type_spec(event_type::Symbol)
    haskey(MACRO_EVENT_TYPE_REGISTRY, event_type) || throw(
        ArgumentError(
            "未登録のevent_type: $event_type はイベント型レジストリ" *
            "（MACRO_EVENT_TYPE_REGISTRY）に登録されていません（登録済み: " *
            "$(sort(collect(keys(MACRO_EVENT_TYPE_REGISTRY))))。統合設計 §5.3・§10.1 項目7）",
        ),
    )
    return MACRO_EVENT_TYPE_REGISTRY[event_type]
end

# ------------------------------------------------------------
# 型別検証ヘルパ（smart constructor から使う）
# ------------------------------------------------------------

function _ert_check_unit(spec::MacroEventTypeSpec, unit::Union{AbstractString, Nothing})
    unit === nothing && return nothing
    String(unit) in spec.allowed_units || throw(
        ArgumentError(
            "unit=\"$unit\" は event_type=$(spec.event_type) の許容単位にありません" *
            "（許容: $(spec.allowed_units)。マクロイベント変換契約 $(spec.contract_section)）",
        ),
    )
    return nothing
end

function _ert_check_application_mode(spec::MacroEventTypeSpec, application_mode::Symbol)
    application_mode in spec.allowed_application_modes || throw(
        ArgumentError(
            "application_mode=$application_mode は event_type=$(spec.event_type) の許容" *
            " application_mode にありません（許容: $(spec.allowed_application_modes)。" *
            "マクロイベント変換契約 $(spec.contract_section)）",
        ),
    )
    return nothing
end

function _ert_check_target_concepts(
    spec::MacroEventTypeSpec,
    target_concepts::Vector{Symbol},
)
    for tc in target_concepts
        tc in spec.allowed_target_concepts || throw(
            ArgumentError(
                "target_concepts に event_type=$(spec.event_type) では許容されない concept が" *
                "含まれています: $tc（許容: $(spec.allowed_target_concepts)。" *
                "マクロイベント変換契約 $(spec.contract_section)）",
            ),
        )
    end
    return nothing
end

"""
    _ert_check_direction_magnitude_sign(direction, magnitude) -> Nothing

`direction` と `magnitude` の符号規約を検証する（実施内容「directionとmagnitudeの符号規約」）。
`direction=:up` なら `magnitude > 0`、`:down` なら `magnitude < 0`、`:none` なら
`magnitude == 0`。`magnitude` が欠測、または `direction=:unknown`（判定不能）のときは検証を
スキップする。
"""
function _ert_check_direction_magnitude_sign(
    direction::Symbol,
    magnitude::Union{Float64, Missing},
)
    magnitude === missing && return nothing
    direction === :unknown && return nothing
    if direction === :up
        magnitude > 0 || throw(
            ArgumentError(
                "符号不一致: direction=:up のとき magnitude は正でなければなりません" *
                "（実値: magnitude=$magnitude）",
            ),
        )
    elseif direction === :down
        magnitude < 0 || throw(
            ArgumentError(
                "符号不一致: direction=:down のとき magnitude は負でなければなりません" *
                "（実値: magnitude=$magnitude）",
            ),
        )
    else # :none
        magnitude == 0.0 || throw(
            ArgumentError(
                "符号不一致: direction=:none のとき magnitude は0でなければなりません" *
                "（実値: magnitude=$magnitude）",
            ),
        )
    end
    return nothing
end

"""
    _ert_check_order_cancellation_unit(sector, unit, application_mode) -> Nothing

`:OrderCancellation` の率（`S1`・着工前の計画取消・`unit="%"`・`:multiplicative`）と数量
（`S2`/`S3`・モデル外顧客からの取消・`unit="bn USD (2017 chained)"`・`:additive`）を混同しない
検証（マクロイベント変換契約 §4.2 row 3・row 3b）。`sector` がどちらでもない場合は検証しない
（`unmapped_target` の判定は #201）。`application_mode` は `nothing`（`L1`/`L2` は当該
フィールドを持たない）を許す。
"""
function _ert_check_order_cancellation_unit(
    sector::Symbol,
    unit::Union{AbstractString, Nothing},
    application_mode::Union{Symbol, Nothing},
)
    unit === nothing && return nothing
    u = String(unit)
    if sector === :s1
        u == "%" || throw(
            ArgumentError(
                "率と数量の混同: OrderCancellation の sector=:s1（着工前の計画取消）は " *
                "unit=\"%\"（取消率）で表現します。unit=\"$u\" は率と数量を混同しています" *
                "（マクロイベント変換契約 §4.2 row 3）",
            ),
        )
        (application_mode === nothing || application_mode === :multiplicative) || throw(
            ArgumentError(
                "OrderCancellation の sector=:s1 は application_mode=:multiplicative で" *
                "なければなりません（実値: $(application_mode)。マクロイベント変換契約 §4.2 row 3）",
            ),
        )
    elseif sector in (:s2, :s3)
        u == "bn USD (2017 chained)" || throw(
            ArgumentError(
                "率と数量の混同: OrderCancellation の sector=$sector（モデル外顧客からの取消）は " *
                "unit=\"bn USD (2017 chained)\"（取消金額）で表現します。unit=\"$u\" は率と数量を" *
                "混同しています（マクロイベント変換契約 §4.2 row 3b）",
            ),
        )
        (application_mode === nothing || application_mode === :additive) || throw(
            ArgumentError(
                "OrderCancellation の sector=$sector は application_mode=:additive で" *
                "なければなりません（実値: $(application_mode)。マクロイベント変換契約 §4.2 row 3b）",
            ),
        )
    end
    return nothing
end

"""
    _ert_check_price_margin_unit(unit) -> Nothing

`:PriceOrMarginShock` の価格（`unit="%"`）と margin（`unit="%pt"`、金利等で用いるポイント表記）
を混同しない検証（マクロイベント変換契約 §4.2 row 4、`allowed_units` は `"%"` のみ）。
"""
function _ert_check_price_margin_unit(unit::Union{AbstractString, Nothing})
    unit === nothing && return nothing
    if String(unit) == "%pt"
        throw(
            ArgumentError(
                "価格とmarginの混同: PriceOrMarginShock の unit=\"%pt\" は margin の変化幅" *
                "（ポイント）であり、価格変化率（unit=\"%\"）と混同しています。本モデルは " *
                "price_s1 のみを外生入力とし、margin を直接の適用先として持ちません" *
                "（マクロイベント変換契約 §4.2 row 4・§4.4 row 4）",
            ),
        )
    end
    return nothing
end

# ------------------------------------------------------------
# smart constructor（統合設計 §11 `E-3` 行）
# ------------------------------------------------------------

"""
    observed_event(; event_type, kwargs...) -> ObservedEvent

`ObservedEvent` の型別 smart constructor。`event_type` をレジストリで引き、`unit`・符号規約
（`direction`/`magnitude`）・（`:OrderCancellation`/`:PriceOrMarginShock` に限り）率と数量・
価格と margin の混同を検証したうえで `ObservedEvent` を構築する。`:other` は扱わない
（レジストリに型別規則が無いため。`:other` を用いる場合は `ObservedEvent` を直接使用する）。
引数は `ObservedEvent` と同一。
"""
function observed_event(;
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
    spec = macro_event_type_spec(event_type)
    event_type === :OrderCancellation &&
        _ert_check_order_cancellation_unit(sector, unit, nothing)
    event_type === :PriceOrMarginShock && _ert_check_price_margin_unit(unit)
    _ert_check_unit(spec, unit)
    _ert_check_direction_magnitude_sign(direction, magnitude)
    return ObservedEvent(;
        event_id = event_id,
        event_type = event_type,
        announced_at = announced_at,
        observed_at = observed_at,
        known_at = known_at,
        source = source,
        provenance = provenance,
        schema_version = schema_version,
        effective_from = effective_from,
        effective_until = effective_until,
        entity = entity,
        sector = sector,
        geography = geography,
        direction = direction,
        magnitude = magnitude,
        unit = unit,
        supersedes = supersedes,
        notes = notes,
    )
end

"""
    interpreted_signal(; event_type, kwargs...) -> InterpretedSignal

`InterpretedSignal` の型別 smart constructor。`observed_event` と同じ検証に加え、
`target_concepts` が `event_type` の `allowed_target_concepts` の部分集合であることを検証する
（`:EmploymentPlanRevision` を消費・所得等の他 concept へ変換させない）。引数は
`InterpretedSignal` と同一。
"""
function interpreted_signal(;
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
    spec = macro_event_type_spec(event_type)
    event_type === :OrderCancellation &&
        _ert_check_order_cancellation_unit(sector, unit, nothing)
    event_type === :PriceOrMarginShock && _ert_check_price_margin_unit(unit)
    _ert_check_unit(spec, unit)
    _ert_check_target_concepts(spec, target_concepts)
    _ert_check_direction_magnitude_sign(direction, magnitude)
    return InterpretedSignal(;
        event_id = event_id,
        event_type = event_type,
        announced_at = announced_at,
        observed_at = observed_at,
        known_at = known_at,
        source = source,
        provenance = provenance,
        sector = sector,
        direction = direction,
        magnitude_source = magnitude_source,
        confidence = confidence,
        schema_version = schema_version,
        effective_from = effective_from,
        effective_until = effective_until,
        entity = entity,
        geography = geography,
        magnitude = magnitude,
        unit = unit,
        supersedes = supersedes,
        notes = notes,
        uncertainty = uncertainty,
        target_concepts = target_concepts,
        persistence = persistence,
    )
end

"""
    scenario_assumption(; event_type, kwargs...) -> ScenarioAssumption

`ScenarioAssumption` の型別 smart constructor。`unit`・`application_mode`・`target_concepts`
の型別許容と符号規約を検証したうえで `ScenarioAssumption` を構築する。`:OrderCancellation`
（率と数量）・`:PriceOrMarginShock`（価格と margin）の混同はここで検出する。`:other` は
扱わない（`ScenarioAssumption` 自体が `:other` を許容しない、`Y-01`）。引数は
`ScenarioAssumption` と同一。
"""
function scenario_assumption(;
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
    spec = macro_event_type_spec(event_type)
    event_type === :OrderCancellation &&
        _ert_check_order_cancellation_unit(sector, unit, application_mode)
    event_type === :PriceOrMarginShock && _ert_check_price_margin_unit(unit)
    _ert_check_unit(spec, unit)
    _ert_check_application_mode(spec, application_mode)
    _ert_check_target_concepts(spec, target_concepts)
    _ert_check_direction_magnitude_sign(direction, magnitude)
    return ScenarioAssumption(;
        assumption_id = assumption_id,
        event_type = event_type,
        sector = sector,
        direction = direction,
        magnitude = magnitude,
        unit = unit,
        magnitude_source = magnitude_source,
        application_mode = application_mode,
        timing = timing,
        persistence = persistence,
        target_concepts = target_concepts,
        provenance = provenance,
        schema_version = schema_version,
        geography = geography,
        confidence = confidence,
        uncertainty = uncertainty,
        notes = notes,
        caveats = caveats,
    )
end

# ------------------------------------------------------------
# duplicate key（マクロイベント変換契約 §5.5）
# ------------------------------------------------------------

"""
    macro_event_dedup_key(e::ObservedEvent) -> Tuple
    macro_event_dedup_key(e::InterpretedSignal) -> Tuple

内容重複の判定キー（マクロイベント変換契約 §5.5）。`(source.document_id, entity, event_type,
announced_at, magnitude, unit)` に、`InterpretedSignal` では正準化のためソートした
`target_concepts` を加える。`notes`/`caveats` は含めない（自由記述の差で重複が見逃されるのを
防ぐ、契約 §5.5）。`magnitude` が欠測（`missing`）どうしの場合もタプルの等価性により一致と
判定される。実際の重複除去（採用・`duplicate_dropped` 記録）は `event_id` 一致を扱う
`schedule_events`（Issue #198）または `run_scenario`（Issue #202）が行う。本関数は判定キーの
算出のみを提供する。
"""
function macro_event_dedup_key(e::ObservedEvent)
    return (
        e.source.document_id,
        e.entity,
        e.event_type,
        e.announced_at,
        e.magnitude,
        e.unit,
    )
end

function macro_event_dedup_key(e::InterpretedSignal)
    return (
        e.source.document_id,
        e.entity,
        e.event_type,
        e.announced_at,
        Tuple(sort(e.target_concepts)),
        e.magnitude,
        e.unit,
    )
end
