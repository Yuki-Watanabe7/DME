# 部門別CAPEX・信用循環モデル（CCC）の実証系列catalog。
#
# このファイルの `CAPEX_CC_SERIES_CATALOG` が機械可読な正本である。provider の
# catalog は照合用にのみ使い、返却値によってここで固定した系列選定を変更しない。
# 実データの取得・変換は Issue #242 以降の責務であり、このファイルは HTTP を呼ばない。

const CAPEX_CC_EMPIRICAL_INTEGRATION_VERSION = "capex-credit-cycle-empirical-integration/1.0.0"

const CAPEX_CC_SERIES_ROLES =
    (:calibration_required, :estimation_input, :validation_only, :diagnostic_only)
const CAPEX_CC_SOURCE_KINDS = (:official_statistic, :market_data, :firm_disclosure)
const CAPEX_CC_METHODOLOGY_KINDS = (:direct, :aggregation, :allocation, :proxy)
const CAPEX_CC_OBSERVABILITY_CLASSES = (:D, :C, :P, :E, :A)

"""
    CapexSeriesSpec

CCC実証層の論理観測キーと、一次資料で確認した系列定義・単位・頻度・部門範囲を結ぶ
宣言的な仕様。`declared_*` は DME が一次資料から確認した期待値であり、provider が返す
metadata を補完する値ではない。provider 側が未申告なら Issue #242 の raw observation は
`missing` として保持する。

`reference_key` を持つ系列は「この系列 − reference 系列」として measurement 層で構成する
（両者を四半期化した後、同じ四半期の差を取る。片方が欠測の四半期は欠測のまま。ADR 0029）。
社債利回り − 国債利回りのように、公表系列がスプレッドそのものを提供しない場合に使う。
`observability = :C` を要求し、reference 自身は reference を持てない（連鎖させない）。

`provider = "FRED"` の `provider_series_id` は、接頭辞の無い FRED の元 ID（英数字のみ、例
`"GS10"`）である。EDP は契約6.1.0（EDP ADR 073）で、FRED の系列を素の ID だけで提供し、
`FRED_<id>` を 404 `unsupported_symbol` で拒否すると決めた（Issue #314）。出所は `provider`
で示す。`BEA_`・`CENSUS_` などの他の接頭辞は、EDP 側の安定 ID として未実装のまま残る。

`daily_reduction = :mean` は、provider が日次で返す系列を、raw observation を作る段階で
暦月平均（欠測日を除いた平均）の月次系列へ縮約してよいことを宣言する。`DataFrequency` に
日次が無く、EDP は月次化しない（EDP ADR 073 決定2）ためである。`declared_frequency =
Monthly`・`aggregation = :mean`・`model_timing = :AVG` を要求する。宣言の無い系列が日次で
返った場合は、縮約せず decode error とする。
"""
struct CapexSeriesSpec
    key::Symbol
    model_vars::Vector{Symbol}
    provider_series_id::String
    provider::String
    source_kind::Symbol
    role::Symbol
    observability::Symbol
    methodology::Symbol
    declared_unit::String
    declared_frequency::DataFrequency
    declared_seasonal_adjustment::String
    declared_real_nominal::Symbol
    declared_base_year::Union{Int, Nothing}
    annualized::Bool
    level_form::Symbol
    anchor::Union{Symbol, Nothing}
    sector_scope::String
    scope_bias::Symbol
    aggregation::Symbol
    model_timing::Symbol
    allocation_key::Union{Symbol, Nothing}
    availability_start::Union{String, Nothing}
    availability_end::Union{String, Nothing}
    notes::String
    reference_key::Union{Symbol, Nothing}
    daily_reduction::Union{Symbol, Nothing}
end

function CapexSeriesSpec(;
    key::Symbol,
    model_vars::Vector{Symbol} = Symbol[],
    provider_series_id::String,
    provider::String,
    source_kind::Symbol,
    role::Symbol,
    observability::Symbol,
    methodology::Symbol,
    declared_unit::String,
    declared_frequency::DataFrequency,
    declared_seasonal_adjustment::String,
    declared_real_nominal::Symbol,
    declared_base_year::Union{Int, Nothing} = nothing,
    annualized::Bool = false,
    level_form::Symbol,
    anchor::Union{Symbol, Nothing} = nothing,
    sector_scope::String,
    scope_bias::Symbol,
    aggregation::Symbol,
    model_timing::Symbol,
    allocation_key::Union{Symbol, Nothing} = nothing,
    availability_start::Union{String, Nothing} = nothing,
    availability_end::Union{String, Nothing} = nothing,
    notes::String,
    reference_key::Union{Symbol, Nothing} = nothing,
    daily_reduction::Union{Symbol, Nothing} = nothing,
)
    return CapexSeriesSpec(
        key,
        model_vars,
        provider_series_id,
        provider,
        source_kind,
        role,
        observability,
        methodology,
        declared_unit,
        declared_frequency,
        declared_seasonal_adjustment,
        declared_real_nominal,
        declared_base_year,
        annualized,
        level_form,
        anchor,
        sector_scope,
        scope_bias,
        aggregation,
        model_timing,
        allocation_key,
        availability_start,
        availability_end,
        notes,
        reference_key,
        daily_reduction,
    )
end

const _CAPEX_CC_DECLARED_REAL_NOMINAL = (:real, :nominal, :ratio, :index, :not_applicable)
const _CAPEX_CC_LEVEL_FORMS = (:level, :ratio, :index, :growth)
const _CAPEX_CC_SCOPE_BIASES = (:over, :under, :indeterminate, :none)
const _CAPEX_CC_TIMING_AGGREGATIONS =
    Dict(:SUM => (:sum,), :AVG => (:mean,), :EOP => (:end,))
"`CapexSeriesSpec.daily_reduction` の確定集合（`nothing` は縮約しない）。"
const CAPEX_CC_DAILY_REDUCTIONS = (:mean,)
"`provider = \"FRED\"` の `provider_series_id` の形（FRED の元 ID。EDP ADR 073）。"
const _CAPEX_CC_FRED_SERIES_ID = r"^[A-Z0-9]+$"

"""`CapexSeriesSpec` の受け入れ条件を検査する内部ヘルパ。"""
function _validate_capex_series_spec(spec::CapexSeriesSpec, seen::Set{Symbol})::Nothing
    spec.key in seen && throw(ArgumentError("catalog key が重複しています: $(spec.key)"))
    push!(seen, spec.key)
    isempty(spec.provider_series_id) &&
        throw(ArgumentError("provider_series_id は空にできません: $(spec.key)"))
    excluded = _redistribution_excluded_series_id(spec.provider_series_id)
    excluded === nothing || throw(
        ArgumentError(
            "provider_series_id=$(spec.provider_series_id) は再配布できない系列として catalog " *
            "から除外されています（$(_REDISTRIBUTION_EXCLUDED_SERIES[excluded].reference)）: " *
            "$(spec.key)",
        ),
    )
    isempty(spec.provider) && throw(ArgumentError("provider は空にできません: $(spec.key)"))
    spec.provider == "FRED" &&
        !occursin(_CAPEX_CC_FRED_SERIES_ID, spec.provider_series_id) &&
        throw(
            ArgumentError(
                "provider=FRED の provider_series_id は接頭辞の無い FRED の元 ID（英大文字・数字）で" *
                "なければなりません（EDP は FRED_<id> を解決しない。EDP ADR 073）: " *
                "$(spec.key) => $(spec.provider_series_id)",
            ),
        )
    isempty(spec.declared_unit) &&
        throw(ArgumentError("declared_unit は空にできません: $(spec.key)"))
    isempty(spec.sector_scope) &&
        throw(ArgumentError("sector_scope は空にできません: $(spec.key)"))
    isempty(spec.notes) && throw(ArgumentError("notes は空にできません: $(spec.key)"))
    spec.source_kind in CAPEX_CC_SOURCE_KINDS ||
        throw(ArgumentError("未知の source_kind: $(spec.source_kind)"))
    spec.role in CAPEX_CC_SERIES_ROLES || throw(ArgumentError("未知の role: $(spec.role)"))
    spec.observability in CAPEX_CC_OBSERVABILITY_CLASSES ||
        throw(ArgumentError("未知の observability: $(spec.observability)"))
    spec.methodology in CAPEX_CC_METHODOLOGY_KINDS ||
        throw(ArgumentError("未知の methodology: $(spec.methodology)"))
    spec.declared_real_nominal in _CAPEX_CC_DECLARED_REAL_NOMINAL ||
        throw(ArgumentError("未知の declared_real_nominal: $(spec.declared_real_nominal)"))
    spec.level_form in _CAPEX_CC_LEVEL_FORMS ||
        throw(ArgumentError("未知の level_form: $(spec.level_form)"))
    spec.scope_bias in _CAPEX_CC_SCOPE_BIASES ||
        throw(ArgumentError("未知の scope_bias: $(spec.scope_bias)"))
    haskey(_CAPEX_CC_TIMING_AGGREGATIONS, spec.model_timing) ||
        throw(ArgumentError("未知の model_timing: $(spec.model_timing)"))
    spec.aggregation in _CAPEX_CC_TIMING_AGGREGATIONS[spec.model_timing] || throw(
        ArgumentError(
            "時点基準と集計方式が非整合です: $(spec.key) " *
            "($(spec.model_timing), $(spec.aggregation))",
        ),
    )
    if spec.source_kind == :firm_disclosure &&
       spec.role in (:calibration_required, :estimation_input)
        throw(ArgumentError("企業開示を較正・推定入力にできません: $(spec.key)"))
    end
    if spec.level_form == :index && spec.anchor === nothing
        throw(ArgumentError("index 系列には anchor が必要です: $(spec.key)"))
    end
    if spec.methodology == :allocation && spec.allocation_key === nothing
        throw(ArgumentError("allocation 系列には allocation_key が必要です: $(spec.key)"))
    end
    if spec.methodology == :proxy && spec.scope_bias == :none
        throw(ArgumentError("proxy 系列には scope_bias が必要です: $(spec.key)"))
    end
    if spec.observability in (:E, :A) &&
       spec.role in (:calibration_required, :estimation_input)
        throw(ArgumentError("E/A 分類を較正・推定入力にできません: $(spec.key)"))
    end
    if spec.reference_key !== nothing
        spec.reference_key == spec.key &&
            throw(ArgumentError("reference_key に自身を指定できません: $(spec.key)"))
        spec.observability == :C || throw(
            ArgumentError(
                "reference_key を持つ系列は構成系列（observability=:C）でなければなりません: " *
                "$(spec.key)",
            ),
        )
        spec.level_form == :level && !spec.annualized || throw(
            ArgumentError(
                "reference_key による差分は水準系列（level_form=:level・annualized=false）に" *
                "限ります: $(spec.key)",
            ),
        )
        spec.methodology in (:direct, :proxy) || throw(
            ArgumentError(
                "reference_key による差分は methodology=:direct/:proxy に限ります" *
                "（aggregation/allocation と組み合わせない）: $(spec.key)",
            ),
        )
    end
    if spec.daily_reduction !== nothing
        spec.daily_reduction in CAPEX_CC_DAILY_REDUCTIONS || throw(
            ArgumentError("未知の daily_reduction: $(spec.daily_reduction)（$(spec.key)）"),
        )
        (
            spec.declared_frequency == Monthly &&
            spec.aggregation === :mean &&
            spec.model_timing === :AVG
        ) || throw(
            ArgumentError(
                "daily_reduction は月次・平均（declared_frequency=Monthly・aggregation=:mean・" *
                "model_timing=:AVG）の系列に限ります: $(spec.key)",
            ),
        )
    end
    return nothing
end

"""
reference_key の参照先を catalog 内で検査する。参照先が catalog に無い場合は許す
（部分 catalog での取得を妨げない。measurement 層が差分を構成できず、その系列を
`measurement_failed` として記録する）。参照先がある場合は、単位・頻度・時点基準・集計方式が
一致し、参照先自身が reference を持たず、差分を取れる水準系列であることを要求する。
"""
function _validate_capex_reference_keys(catalog::AbstractVector{<:CapexSeriesSpec})::Nothing
    by_key = Dict(spec.key => spec for spec in catalog)
    for spec in catalog
        spec.reference_key === nothing && continue
        ref = get(by_key, spec.reference_key, nothing)
        ref === nothing && continue
        ref.reference_key === nothing || throw(
            ArgumentError(
                "reference 系列 $(ref.key) が reference_key を持っています（連鎖させない）: " *
                "$(spec.key)",
            ),
        )
        ref.observability in (:E, :A) && throw(
            ArgumentError("reference 系列 $(ref.key) が潜在/観測不能系列です: $(spec.key)"),
        )
        ref.level_form == :level && !ref.annualized || throw(
            ArgumentError(
                "reference 系列 $(ref.key) が水準系列ではありません: $(spec.key)",
            ),
        )
        for (field, a, b) in (
            ("declared_unit", spec.declared_unit, ref.declared_unit),
            ("declared_frequency", spec.declared_frequency, ref.declared_frequency),
            ("model_timing", spec.model_timing, ref.model_timing),
            ("aggregation", spec.aggregation, ref.aggregation),
        )
            a == b || throw(
                ArgumentError(
                    "$(spec.key) と reference 系列 $(ref.key) の $field が一致しません: " *
                    "$a != $b",
                ),
            )
        end
    end
    return nothing
end

"""
    validate_capex_series_catalog(catalog = CAPEX_CC_SERIES_CATALOG) -> Nothing

catalog の構造と、ADR 0012 / ADR 0018 が要求する fail-closed な禁止事項を検査する。
違反はすべて `ArgumentError` とする。
"""
function validate_capex_series_catalog(catalog::AbstractVector{<:CapexSeriesSpec})::Nothing
    isempty(catalog) && throw(ArgumentError("catalog は最低1系列必要です"))
    seen = Set{Symbol}()
    for spec in catalog
        _validate_capex_series_spec(spec, seen)
    end
    _validate_capex_reference_keys(catalog)
    return nothing
end

validate_capex_series_catalog()::Nothing =
    validate_capex_series_catalog(CAPEX_CC_SERIES_CATALOG)

_capex_spec(; kwargs...) = CapexSeriesSpec(; kwargs...)

# provider_series_id は EDP へ要求する安定IDである。EDP が未実装のIDでも、DME の
# 選定を provider の都合で変えない。一次資料・EDP対応状況の根拠は同名のcatalog文書にある。
const CAPEX_CC_SERIES_CATALOG = CapexSeriesSpec[
    _capex_spec(
        key = :capex_exec_s1_equipment,
        model_vars = [:capex_exec_s1],
        provider_series_id = "BEA_NIPA_FIXED_INVESTMENT_INFORMATION_PROCESSING_EQUIPMENT",
        provider = "BEA",
        source_kind = :official_statistic,
        role = :calibration_required,
        observability = :C,
        methodology = :aggregation,
        declared_unit = "Billions of chained dollars, SAAR",
        declared_frequency = Quarterly,
        declared_seasonal_adjustment = "SAAR",
        declared_real_nominal = :real,
        declared_base_year = 2017,
        annualized = true,
        level_form = :level,
        sector_scope = "US nonresidential information-processing equipment; broader than S1 AI/cloud equipment",
        scope_bias = :over,
        aggregation = :sum,
        model_timing = :SUM,
        availability_start = "1947-Q1",
        notes = "BEA NIPA fixed investment component. Sum with software and structures; divide SAAR by 4 in measurement.",
    ),
    _capex_spec(
        key = :capex_exec_s1_software,
        model_vars = [:capex_exec_s1],
        provider_series_id = "BEA_NIPA_FIXED_INVESTMENT_SOFTWARE",
        provider = "BEA",
        source_kind = :official_statistic,
        role = :calibration_required,
        observability = :C,
        methodology = :aggregation,
        declared_unit = "Billions of chained dollars, SAAR",
        declared_frequency = Quarterly,
        declared_seasonal_adjustment = "SAAR",
        declared_real_nominal = :real,
        declared_base_year = 2017,
        annualized = true,
        level_form = :level,
        sector_scope = "US nonresidential software investment; includes non-S1 software",
        scope_bias = :over,
        aggregation = :sum,
        model_timing = :SUM,
        availability_start = "1947-Q1",
        notes = "BEA NIPA fixed investment component. Sum with equipment and structures; divide SAAR by 4 in measurement.",
    ),
    _capex_spec(
        key = :capex_exec_s1_structures,
        model_vars = [:capex_exec_s1],
        provider_series_id = "BEA_NIPA_FIXED_INVESTMENT_COMMERCIAL_HEALTH_CARE_STRUCTURES",
        provider = "BEA",
        source_kind = :official_statistic,
        role = :calibration_required,
        observability = :C,
        methodology = :aggregation,
        declared_unit = "Billions of chained dollars, SAAR",
        declared_frequency = Quarterly,
        declared_seasonal_adjustment = "SAAR",
        declared_real_nominal = :real,
        declared_base_year = 2017,
        annualized = true,
        level_form = :level,
        sector_scope = "Commercial and health-care structures; data-center construction is not separately identified",
        scope_bias = :over,
        aggregation = :sum,
        model_timing = :SUM,
        availability_start = "1947-Q1",
        notes = "BEA NIPA fixed-investment structures proxy. It must remain separate from the S1 equipment/software components.",
    ),
    _capex_spec(
        key = :order_s2,
        model_vars = [:order_s2],
        provider_series_id = "CENSUS_M3_NAICS334_NEW_ORDERS",
        provider = "CENSUS",
        source_kind = :official_statistic,
        role = :calibration_required,
        observability = :D,
        methodology = :aggregation,
        declared_unit = "Millions of current dollars",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = :nominal,
        level_form = :level,
        sector_scope = "NAICS 334 computer and electronic product manufacturing; includes non-semiconductor products",
        scope_bias = :over,
        aggregation = :sum,
        model_timing = :SUM,
        availability_start = "1992-Q1",
        notes = "Census M3 new orders, net of cancellations. Deflate before use; M3 order detail does not isolate AI-related semiconductor demand.",
    ),
    _capex_spec(
        key = :order_s3_manufacturing,
        model_vars = [:order_s3],
        provider_series_id = "CENSUS_M3_NAICS333_NEW_ORDERS",
        provider = "CENSUS",
        source_kind = :official_statistic,
        role = :calibration_required,
        observability = :C,
        methodology = :allocation,
        declared_unit = "Millions of current dollars",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = :nominal,
        level_form = :level,
        sector_scope = "NAICS 333 machinery manufacturing; wider than semiconductor equipment and excludes construction/electric utility activity",
        scope_bias = :indeterminate,
        aggregation = :sum,
        model_timing = :SUM,
        allocation_key = :data_center_construction,
        availability_start = "1992-Q1",
        notes = "Census M3 machinery new orders. The S3 construction component is added using the declared allocation key in measurement.",
    ),
    _capex_spec(
        key = :data_center_construction,
        model_vars = [:order_s3, :capex_pipe_s1],
        provider_series_id = "CENSUS_VIP_DATA_CENTER_CONSTRUCTION",
        provider = "CENSUS",
        source_kind = :official_statistic,
        role = :validation_only,
        observability = :P,
        methodology = :proxy,
        declared_unit = "Millions of current dollars",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "NSA",
        declared_real_nominal = :nominal,
        level_form = :level,
        sector_scope = "Data-center construction spending; does not cover equipment pipeline or power interconnection",
        scope_bias = :under,
        aggregation = :sum,
        model_timing = :SUM,
        availability_start = "2014-Q1",
        notes = "Census Value of Construction Put in Place category. Validation/proxy only; it cannot observe the full S1 capital pipeline.",
    ),
    _capex_spec(
        key = :backlog_s2,
        model_vars = [:backlog_s2],
        provider_series_id = "CENSUS_M3_NAICS334_UNFILLED_ORDERS",
        provider = "CENSUS",
        source_kind = :official_statistic,
        role = :calibration_required,
        observability = :D,
        methodology = :aggregation,
        declared_unit = "Millions of current dollars, end of month",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = :nominal,
        level_form = :level,
        sector_scope = "NAICS 334; broader than semiconductor equipment order backlog",
        scope_bias = :over,
        aggregation = :end,
        model_timing = :EOP,
        availability_start = "1992-Q1",
        notes = "Census M3 unfilled orders. Census defines this as end-of-period orders not yet passed through sales.",
    ),
    _capex_spec(
        key = :backlog_s3,
        model_vars = [:backlog_s3],
        provider_series_id = "CENSUS_M3_NAICS333_UNFILLED_ORDERS",
        provider = "CENSUS",
        source_kind = :official_statistic,
        role = :validation_only,
        observability = :P,
        methodology = :proxy,
        declared_unit = "Millions of current dollars, end of month",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = :nominal,
        level_form = :level,
        sector_scope = "NAICS 333 machinery only; construction and electricity-equipment backlog are absent",
        scope_bias = :under,
        aggregation = :end,
        model_timing = :EOP,
        availability_start = "1992-Q1",
        notes = "Census M3 machinery unfilled orders; validation-only proxy because S3 has a broader sector boundary.",
    ),
    _capex_spec(
        key = :inv_s2,
        model_vars = [:inv_s2],
        provider_series_id = "CENSUS_M3_NAICS334_TOTAL_INVENTORIES",
        provider = "CENSUS",
        source_kind = :official_statistic,
        role = :calibration_required,
        observability = :D,
        methodology = :aggregation,
        declared_unit = "Millions of current dollars, end of month",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = :nominal,
        level_form = :level,
        sector_scope = "NAICS 334 total inventories; includes non-semiconductor electronics",
        scope_bias = :over,
        aggregation = :end,
        model_timing = :EOP,
        availability_start = "1992-Q1",
        notes = "Census M3 total inventory at current cost or market value. Measurement preserves it as an observed inventory value before deflation.",
    ),
    _capex_spec(
        key = :inv_s3,
        model_vars = [:inv_s3],
        provider_series_id = "CENSUS_M3_NAICS333_TOTAL_INVENTORIES",
        provider = "CENSUS",
        source_kind = :official_statistic,
        role = :calibration_required,
        observability = :D,
        methodology = :aggregation,
        declared_unit = "Millions of current dollars, end of month",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = :nominal,
        level_form = :level,
        sector_scope = "NAICS 333 machinery inventories; excludes construction and electrical utilities",
        scope_bias = :under,
        aggregation = :end,
        model_timing = :EOP,
        availability_start = "1992-Q1",
        notes = "Census M3 total inventory. The coverage shortfall is retained rather than imputed as an S3 total.",
    ),
    _capex_spec(
        key = :ship_s2,
        model_vars = [:ship_s2, :deliv_s2],
        provider_series_id = "CENSUS_M3_NAICS334_SHIPMENTS",
        provider = "CENSUS",
        source_kind = :official_statistic,
        role = :calibration_required,
        observability = :D,
        methodology = :aggregation,
        declared_unit = "Millions of current dollars",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = :nominal,
        level_form = :level,
        sector_scope = "NAICS 334 manufacturers' shipments; includes non-semiconductor products",
        scope_bias = :over,
        aggregation = :sum,
        model_timing = :SUM,
        availability_start = "1992-Q1",
        notes = "Census M3 net selling value of products sold. Nominal series maps to delivery value; real shipment needs the declared deflator.",
    ),
    _capex_spec(
        key = :ship_s3,
        model_vars = [:ship_s3, :deliv_s3],
        provider_series_id = "CENSUS_M3_NAICS333_SHIPMENTS",
        provider = "CENSUS",
        source_kind = :official_statistic,
        role = :calibration_required,
        observability = :D,
        methodology = :aggregation,
        declared_unit = "Millions of current dollars",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = :nominal,
        level_form = :level,
        sector_scope = "NAICS 333 machinery shipments; S3 construction/electricity scope remains uncovered",
        scope_bias = :under,
        aggregation = :sum,
        model_timing = :SUM,
        availability_start = "1992-Q1",
        notes = "Census M3 shipments. No direct fallback to a separate Census API is permitted from DME.",
    ),
    _capex_spec(
        key = :y_s2_ip,
        model_vars = [:y_s2],
        provider_series_id = "IPG3344S",
        provider = "FRED",
        source_kind = :official_statistic,
        role = :estimation_input,
        observability = :C,
        methodology = :proxy,
        declared_unit = "Index, 2017=100",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = :index,
        declared_base_year = 2017,
        level_form = :index,
        anchor = :bea_annual_real_value_added,
        sector_scope = "NAICS 3344 semiconductor and other electronic component manufacturing; still broader than S2",
        scope_bias = :over,
        aggregation = :sum,
        model_timing = :SUM,
        availability_start = "1972-Q1",
        notes = "FRB industrial-production index. Measurement averages monthly index first, then anchors its level to BEA annual real value added; it is never a level by itself.",
    ),
    _capex_spec(
        key = :y_s3_ip,
        model_vars = [:y_s3],
        provider_series_id = "IPG333S",
        provider = "FRED",
        source_kind = :official_statistic,
        role = :estimation_input,
        observability = :C,
        methodology = :proxy,
        declared_unit = "Index, 2017=100",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = :index,
        declared_base_year = 2017,
        level_form = :index,
        anchor = :bea_annual_real_value_added,
        sector_scope = "NAICS 333 machinery manufacturing; excludes construction and power capacity",
        scope_bias = :under,
        aggregation = :sum,
        model_timing = :SUM,
        availability_start = "1972-Q1",
        notes = "FRB industrial-production index. Measurement anchors it to BEA annual real value added and records the index-to-level formula.",
    ),
    _capex_spec(
        key = :util_s2,
        model_vars = [:util_s2],
        provider_series_id = "CAPUTLG3344S",
        provider = "FRED",
        source_kind = :official_statistic,
        role = :validation_only,
        observability = :P,
        methodology = :proxy,
        declared_unit = "Percent",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = :ratio,
        level_form = :ratio,
        sector_scope = "NAICS 3344 capacity utilization; FRB's contemporaneous technical-capacity denominator differs from the model's BOP capital denominator",
        scope_bias = :indeterminate,
        aggregation = :mean,
        model_timing = :AVG,
        availability_start = "1972-Q1",
        notes = "FRB capacity utilization. Use changes for validation, not level equality or a direct S2 capacity calibration target.",
    ),
    _capex_spec(
        key = :util_s3,
        model_vars = [:util_s3],
        provider_series_id = "CAPUTLG333S",
        provider = "FRED",
        source_kind = :official_statistic,
        role = :validation_only,
        observability = :P,
        methodology = :proxy,
        declared_unit = "Percent",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = :ratio,
        level_form = :ratio,
        sector_scope = "NAICS 333 capacity utilization; does not cover S3 construction or utility capacity",
        scope_bias = :under,
        aggregation = :mean,
        model_timing = :AVG,
        availability_start = "1972-Q1",
        notes = "FRB capacity utilization proxy. Its scope and contemporaneous denominator are intentionally preserved as caveats.",
    ),
    _capex_spec(
        key = :ycap_s2,
        model_vars = [:ycap_s2],
        provider_series_id = "CAPG3344S",
        provider = "FRED",
        source_kind = :official_statistic,
        role = :validation_only,
        observability = :P,
        methodology = :proxy,
        declared_unit = "Index, 2017=100",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = :index,
        declared_base_year = 2017,
        level_form = :index,
        anchor = :baseline_mean_one,
        sector_scope = "NAICS 3344 technical capacity index, not model capital divided by a fixed capital-output ratio",
        scope_bias = :indeterminate,
        aggregation = :mean,
        model_timing = :AVG,
        availability_start = "1972-Q1",
        notes = "FRB capacity index. It is a movement proxy for capacity, never an observed level of ycap_s2.",
    ),
    _capex_spec(
        key = :ycap_s3,
        model_vars = [:ycap_s3],
        provider_series_id = "CAPG333S",
        provider = "FRED",
        source_kind = :official_statistic,
        role = :validation_only,
        observability = :P,
        methodology = :proxy,
        declared_unit = "Index, 2017=100",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = :index,
        declared_base_year = 2017,
        level_form = :index,
        anchor = :baseline_mean_one,
        sector_scope = "NAICS 333 technical capacity index; narrower than complete S3 sector",
        scope_bias = :under,
        aggregation = :mean,
        model_timing = :AVG,
        availability_start = "1972-Q1",
        notes = "FRB capacity index proxy; baseline rebasing supports only movement comparison.",
    ),
    _capex_spec(
        key = :price_s2,
        model_vars = [:price_s2],
        provider_series_id = "BLS_PPI_NAICS334",
        provider = "BLS",
        source_kind = :official_statistic,
        role = :estimation_input,
        observability = :D,
        methodology = :aggregation,
        declared_unit = "Producer price index",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "NSA",
        declared_real_nominal = :index,
        declared_base_year = 1982,
        level_form = :index,
        anchor = :baseline_mean_one,
        sector_scope = "NAICS 334 producer prices; broader than S2 semiconductors",
        scope_bias = :over,
        aggregation = :mean,
        model_timing = :AVG,
        availability_start = "2003-Q1",
        notes = "BLS PPI industry index. Rebase to the baseline mean and retain the source's seasonal-adjustment declaration.",
    ),
    _capex_spec(
        key = :price_s3,
        model_vars = [:price_s3],
        provider_series_id = "BLS_PPI_NAICS333",
        provider = "BLS",
        source_kind = :official_statistic,
        role = :estimation_input,
        observability = :D,
        methodology = :aggregation,
        declared_unit = "Producer price index",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "NSA",
        declared_real_nominal = :index,
        declared_base_year = 1982,
        level_form = :index,
        anchor = :baseline_mean_one,
        sector_scope = "NAICS 333 producer prices; excludes non-machinery S3 activity",
        scope_bias = :under,
        aggregation = :mean,
        model_timing = :AVG,
        availability_start = "2003-Q1",
        notes = "BLS PPI industry index. It is rebased in measurement, never consumed as a level.",
    ),
    _capex_spec(
        key = :va_s2,
        model_vars = [:va_s2],
        provider_series_id = "BEA_GDPBYIND_NAICS334_REAL_VALUE_ADDED",
        provider = "BEA",
        source_kind = :official_statistic,
        role = :calibration_required,
        observability = :D,
        methodology = :aggregation,
        declared_unit = "Millions of chained dollars, SAAR",
        declared_frequency = Quarterly,
        declared_seasonal_adjustment = "SAAR",
        declared_real_nominal = :real,
        declared_base_year = 2017,
        annualized = true,
        level_form = :level,
        sector_scope = "NAICS 334 value added; includes electronics beyond S2",
        scope_bias = :over,
        aggregation = :sum,
        model_timing = :SUM,
        availability_start = "2005-Q1",
        notes = "BEA quarterly GDP by Industry real value added. Divide SAAR by 4; its start is a candidate binding series for the common sample.",
    ),
    _capex_spec(
        key = :va_s3,
        model_vars = [:va_s3],
        provider_series_id = "BEA_GDPBYIND_NAICS333_REAL_VALUE_ADDED",
        provider = "BEA",
        source_kind = :official_statistic,
        role = :calibration_required,
        observability = :D,
        methodology = :aggregation,
        declared_unit = "Millions of chained dollars, SAAR",
        declared_frequency = Quarterly,
        declared_seasonal_adjustment = "SAAR",
        declared_real_nominal = :real,
        declared_base_year = 2017,
        annualized = true,
        level_form = :level,
        sector_scope = "NAICS 333 machinery value added; excludes construction and utilities in S3",
        scope_bias = :under,
        aggregation = :sum,
        model_timing = :SUM,
        availability_start = "2005-Q1",
        notes = "BEA quarterly GDP by Industry real value added. Divide SAAR by 4; potential common-sample binding series.",
    ),
    _capex_spec(
        key = :y_s1_proxy,
        model_vars = [:y_s1],
        provider_series_id = "BEA_GDPBYIND_NAICS518_REAL_VALUE_ADDED",
        provider = "BEA",
        source_kind = :official_statistic,
        role = :validation_only,
        observability = :P,
        methodology = :proxy,
        declared_unit = "Millions of chained dollars, SAAR",
        declared_frequency = Quarterly,
        declared_seasonal_adjustment = "SAAR",
        declared_real_nominal = :real,
        declared_base_year = 2017,
        annualized = true,
        level_form = :level,
        sector_scope = "NAICS 518 data processing, hosting and related services; broader than cloud/AI S1 output",
        scope_bias = :over,
        aggregation = :sum,
        model_timing = :SUM,
        availability_start = "2005-Q1",
        notes = "BEA GDP-by-industry proxy for S1 output. It is validation-only and must not turn S1 revenue into a calibration input.",
    ),
    _capex_spec(
        key = :cap_s2,
        model_vars = [:cap_s2],
        provider_series_id = "BEA_FIXED_ASSETS_NAICS334_NET_STOCK",
        provider = "BEA",
        source_kind = :official_statistic,
        role = :validation_only,
        observability = :P,
        methodology = :proxy,
        declared_unit = "Billions of chained dollars, end of year",
        declared_frequency = Annual,
        declared_seasonal_adjustment = "not_applicable",
        declared_real_nominal = :real,
        declared_base_year = 2017,
        level_form = :level,
        sector_scope = "NAICS 334 net stock; capital-asset concept differs from S2 productive capital",
        scope_bias = :indeterminate,
        aggregation = :end,
        model_timing = :EOP,
        availability_start = "1997-Q4",
        notes = "BEA Fixed Assets annual net stock. Issue #243 must allocate annual end-of-year values to quarters and flag smoothing.",
    ),
    _capex_spec(
        key = :cap_s3,
        model_vars = [:cap_s3],
        provider_series_id = "BEA_FIXED_ASSETS_NAICS333_NET_STOCK",
        provider = "BEA",
        source_kind = :official_statistic,
        role = :validation_only,
        observability = :P,
        methodology = :proxy,
        declared_unit = "Billions of chained dollars, end of year",
        declared_frequency = Annual,
        declared_seasonal_adjustment = "not_applicable",
        declared_real_nominal = :real,
        declared_base_year = 2017,
        level_form = :level,
        sector_scope = "NAICS 333 net stock; omits construction and power assets in S3",
        scope_bias = :under,
        aggregation = :end,
        model_timing = :EOP,
        availability_start = "1997-Q4",
        notes = "BEA Fixed Assets annual net stock. It supports low-frequency validation only after explicit quarterly allocation.",
    ),
    _capex_spec(
        key = :dep_s2,
        model_vars = [:dep_s2],
        provider_series_id = "BEA_FIXED_ASSETS_NAICS334_DEPRECIATION",
        provider = "BEA",
        source_kind = :official_statistic,
        role = :validation_only,
        observability = :P,
        methodology = :proxy,
        declared_unit = "Billions of chained dollars, annual",
        declared_frequency = Annual,
        declared_seasonal_adjustment = "not_applicable",
        declared_real_nominal = :real,
        declared_base_year = 2017,
        annualized = true,
        level_form = :level,
        sector_scope = "NAICS 334 fixed-capital consumption; asset boundary differs from S2 capital",
        scope_bias = :indeterminate,
        aggregation = :sum,
        model_timing = :SUM,
        availability_start = "1997-Q4",
        notes = "BEA Fixed Assets annual depreciation proxy. Divide by 4 only after the annual-to-quarter allocation rule is recorded.",
    ),
    _capex_spec(
        key = :dep_s3,
        model_vars = [:dep_s3],
        provider_series_id = "BEA_FIXED_ASSETS_NAICS333_DEPRECIATION",
        provider = "BEA",
        source_kind = :official_statistic,
        role = :validation_only,
        observability = :P,
        methodology = :proxy,
        declared_unit = "Billions of chained dollars, annual",
        declared_frequency = Annual,
        declared_seasonal_adjustment = "not_applicable",
        declared_real_nominal = :real,
        declared_base_year = 2017,
        annualized = true,
        level_form = :level,
        sector_scope = "NAICS 333 fixed-capital consumption; S3 construction/power assets are absent",
        scope_bias = :under,
        aggregation = :sum,
        model_timing = :SUM,
        availability_start = "1997-Q4",
        notes = "BEA Fixed Assets annual depreciation proxy. It is not a high-frequency calibration driver.",
    ),
    _capex_spec(
        key = :profit_s2_proxy,
        model_vars = [:profit_s2],
        provider_series_id = "BEA_NIPA_TABLE_6_16_NAICS334_CORPORATE_PROFITS",
        provider = "BEA",
        source_kind = :official_statistic,
        role = :validation_only,
        observability = :P,
        methodology = :proxy,
        declared_unit = "Millions of dollars, annual rate",
        declared_frequency = Quarterly,
        declared_seasonal_adjustment = "SAAR",
        declared_real_nominal = :nominal,
        annualized = true,
        level_form = :level,
        sector_scope = "BEA industry aggregate corporate profits; accounting concept differs from model EBIT-like profit",
        scope_bias = :indeterminate,
        aggregation = :sum,
        model_timing = :SUM,
        availability_start = "2005-Q1",
        notes = "Industry aggregate statistic, not firm disclosure. Keep it validation-only because tax, interest, and inventory-valuation concepts differ.",
    ),
    _capex_spec(
        key = :nfc_debt_total,
        model_vars = [:debt_s1, :debt_s2, :debt_s3],
        provider_series_id = "FRB_Z1_NONFINANCIAL_CORPORATE_DEBT",
        provider = "FRB",
        source_kind = :official_statistic,
        role = :validation_only,
        observability = :P,
        methodology = :allocation,
        declared_unit = "Millions of dollars, end of period",
        declared_frequency = Quarterly,
        declared_seasonal_adjustment = "NSA",
        declared_real_nominal = :nominal,
        level_form = :level,
        sector_scope = "All US nonfinancial corporate debt; requires sector allocation before any S1/S2/S3 comparison",
        scope_bias = :indeterminate,
        aggregation = :end,
        model_timing = :EOP,
        allocation_key = :sector_sales_share,
        availability_start = "1945-Q4",
        notes = "Financial Accounts of the United States aggregate. No department-level debt series is inferred without an explicit allocation sensitivity.",
    ),
    _capex_spec(
        key = :nfc_net_interest,
        model_vars = [:int_burden_s1, :int_burden_s2, :int_burden_s3],
        provider_series_id = "BEA_NIPA_CORPORATE_NET_INTEREST_PAYMENTS",
        provider = "BEA",
        source_kind = :official_statistic,
        role = :validation_only,
        observability = :P,
        methodology = :allocation,
        declared_unit = "Billions of dollars, SAAR",
        declared_frequency = Quarterly,
        declared_seasonal_adjustment = "SAAR",
        declared_real_nominal = :nominal,
        annualized = true,
        level_form = :level,
        sector_scope = "Aggregate corporate net-interest payments; requires the same allocation key as debt",
        scope_bias = :indeterminate,
        aggregation = :sum,
        model_timing = :SUM,
        allocation_key = :sector_sales_share,
        availability_start = "1947-Q1",
        notes = "BEA aggregate statistic. Use the same allocation key as debt so the derived effective-rate proxy does not hide two allocation choices.",
    ),
    # spread: 社債スプレッド。ICE BofA の HY/IG OAS（BAMLH0A0HYM2・BAMLC0A0CM）は
    # 再配布できないため使わない（EDP 契約6.0.0・ADR 072、DME ADR 0029）。FRED 区分
    # "Public Domain: Citation Requested" の利回りから「社債 − 国債」を measurement 層で構成する。
    _capex_spec(
        key = :spread_hqm_corporate,
        model_vars = [:spread],
        provider_series_id = "HQMCB10YRP",
        provider = "FRED",
        source_kind = :market_data,
        role = :calibration_required,
        observability = :C,
        methodology = :proxy,
        declared_unit = "Percent",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "NSA",
        declared_real_nominal = :ratio,
        level_form = :level,
        sector_scope = "US high-quality (AAA/AA/A) corporate bond par yield at 10 years minus the 10-year Treasury CMT yield; investment-grade only, so it understates the credit risk of high-yield borrowers",
        scope_bias = :under,
        aggregation = :mean,
        model_timing = :AVG,
        availability_start = "1984-Q1",
        notes = "U.S. Treasury HQM Corporate Bond Yield Curve 10-year par yield (FRED HQMCB10YRP, Public Domain) minus FRED GS10 (Board H.15, Public Domain), both monthly averages. Replaces the ICE BofA US High Yield OAS, whose redistribution is not permitted (ADR 0029). Par yield is paired with the CMT par yield so the difference does not mix spot and par conventions; it is a spread over Treasuries, not an option-adjusted spread.",
        reference_key = :treasury_10y,
    ),
    _capex_spec(
        key = :treasury_10y,
        model_vars = Symbol[],
        provider_series_id = "GS10",
        provider = "FRED",
        source_kind = :market_data,
        role = :calibration_required,
        observability = :D,
        methodology = :direct,
        declared_unit = "Percent",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "NSA",
        declared_real_nominal = :ratio,
        level_form = :level,
        sector_scope = "US Treasury 10-year constant-maturity yield (monthly average); reference leg of spread_hqm_corporate, not a model variable",
        scope_bias = :none,
        aggregation = :mean,
        model_timing = :AVG,
        availability_start = "1953-Q2",
        notes = "Board of Governors H.15 (FRED GS10, Public Domain). Used only as the reference leg of spread_hqm_corporate; it maps to no model variable.",
    ),
    _capex_spec(
        key = :spread_cp_a2p2,
        model_vars = [:spread],
        provider_series_id = "RIFSPPNA2P2D90NB",
        provider = "FRED",
        source_kind = :market_data,
        role = :validation_only,
        observability = :C,
        methodology = :proxy,
        declared_unit = "Percent",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "NSA",
        declared_real_nominal = :ratio,
        level_form = :level,
        sector_scope = "90-day A2/P2 nonfinancial commercial paper rate minus the 3-month Treasury bill rate; short-term borrowing of lower-tier investment-grade issuers, a different tenor and tier from the bond spread",
        scope_bias = :indeterminate,
        aggregation = :mean,
        model_timing = :AVG,
        availability_start = "1998-Q1",
        notes = "FRB Commercial Paper release (FRED RIFSPPNA2P2D90NB, Public Domain) minus FRED TB3MS (Board H.15, Public Domain). Alternative proxy that replaces the ICE BofA US Corporate OAS (ADR 0029). EDP serves the CP rate daily and does not downsample it (EDP ADR 073), so the DME adapter reduces it to the calendar-month mean of the non-missing days (daily_reduction = :mean) before the quarterly mean; many days are unpublished and stay out of the mean rather than being filled. TB3MS is quoted on a discount basis; the two legs are not converted to a common quotation basis. It is a sensitivity/validation series, not an automatic fallback for spread_hqm_corporate.",
        reference_key = :treasury_bill_3m,
        daily_reduction = :mean,
    ),
    _capex_spec(
        key = :treasury_bill_3m,
        model_vars = Symbol[],
        provider_series_id = "TB3MS",
        provider = "FRED",
        source_kind = :market_data,
        role = :validation_only,
        observability = :D,
        methodology = :direct,
        declared_unit = "Percent",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "NSA",
        declared_real_nominal = :ratio,
        level_form = :level,
        sector_scope = "US 3-month Treasury bill secondary-market rate (discount basis, monthly average); reference leg of spread_cp_a2p2, not a model variable",
        scope_bias = :none,
        aggregation = :mean,
        model_timing = :AVG,
        availability_start = "1934-Q1",
        notes = "Board of Governors H.15 (FRED TB3MS, Public Domain). Used only as the reference leg of spread_cp_a2p2; it maps to no model variable.",
    ),
    _capex_spec(
        key = :lend_stance,
        model_vars = [:lend_stance],
        provider_series_id = "DRTSCILM",
        provider = "FRED",
        source_kind = :official_statistic,
        role = :calibration_required,
        observability = :D,
        methodology = :direct,
        declared_unit = "Net percent of domestic banks tightening C&I standards",
        declared_frequency = Quarterly,
        declared_seasonal_adjustment = "NSA",
        declared_real_nominal = :ratio,
        level_form = :level,
        sector_scope = "US commercial and industrial loan standards; not sector-specific",
        scope_bias = :indeterminate,
        aggregation = :mean,
        model_timing = :AVG,
        availability_start = "1990-Q2",
        notes = "SLOOS C&I standards. Higher values mean tighter standards; measurement standardizes around its baseline without reversing this sign.",
    ),
    _capex_spec(
        key = :fin_cond,
        model_vars = [:fin_cond],
        provider_series_id = "NFCI",
        provider = "FRED",
        source_kind = :official_statistic,
        role = :calibration_required,
        observability = :D,
        methodology = :direct,
        declared_unit = "Standardized index",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "NSA",
        declared_real_nominal = :index,
        level_form = :index,
        anchor = :baseline_mean_zero,
        sector_scope = "US national financial conditions, not CCC-sector-specific",
        scope_bias = :indeterminate,
        aggregation = :mean,
        model_timing = :AVG,
        availability_start = "1971-Q1",
        notes = "Chicago Fed NFCI. Positive values mean tighter-than-average conditions; retain its sign and re-center only at the baseline.",
    ),
    _capex_spec(
        key = :policy_rate,
        model_vars = [:policy_rate],
        provider_series_id = "FEDFUNDS",
        provider = "FRED",
        source_kind = :official_statistic,
        role = :calibration_required,
        observability = :D,
        methodology = :direct,
        declared_unit = "Percent, annual rate",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "NSA",
        declared_real_nominal = :ratio,
        level_form = :level,
        sector_scope = "US effective federal funds rate",
        scope_bias = :none,
        aggregation = :mean,
        model_timing = :AVG,
        availability_start = "1954-Q3",
        notes = "Effective federal funds rate. The model's quarter-length conversion remains in the model layer; catalog value is an annual percentage rate.",
    ),
    _capex_spec(
        key = :equity_val_sector,
        model_vars = [:equity_val],
        provider_series_id = "MARKET_SOXX_TOTAL_RETURN",
        provider = "MARKET",
        source_kind = :market_data,
        role = :validation_only,
        observability = :P,
        methodology = :proxy,
        declared_unit = "Index level",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "NSA",
        declared_real_nominal = :index,
        level_form = :index,
        anchor = :baseline_mean_one,
        sector_scope = "Semiconductor equity index; includes expected cash flows and discount-rate variation absent from model equity valuation",
        scope_bias = :over,
        aggregation = :mean,
        model_timing = :AVG,
        availability_start = "1993-Q1",
        notes = "Market-data validation proxy. Measurement deflates and rebases it; valuation changes must not be narrated as equivalent to real expenditure changes.",
    ),
    _capex_spec(
        key = :emp_tot,
        model_vars = [:emp_tot],
        provider_series_id = "PAYEMS",
        provider = "FRED",
        source_kind = :official_statistic,
        role = :calibration_required,
        observability = :D,
        methodology = :direct,
        declared_unit = "Thousands of persons",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = :not_applicable,
        level_form = :level,
        sector_scope = "US total nonfarm payroll employment",
        scope_bias = :none,
        aggregation = :mean,
        model_timing = :AVG,
        availability_start = "1939-Q1",
        notes = "BLS CES total nonfarm payroll employment via FRED. Quarterly measurement is the mean of monthly levels.",
    ),
    _capex_spec(
        key = :emp_s1,
        model_vars = [:emp_s1],
        provider_series_id = "BLS_CES_NAICS51_ALL_EMPLOYEES",
        provider = "BLS",
        source_kind = :official_statistic,
        role = :estimation_input,
        observability = :D,
        methodology = :aggregation,
        declared_unit = "Thousands of persons",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = :not_applicable,
        level_form = :level,
        sector_scope = "NAICS 51 information; broader than S1 cloud/AI production",
        scope_bias = :over,
        aggregation = :mean,
        model_timing = :AVG,
        availability_start = "1990-Q1",
        notes = "BLS CES information employment. It is an industry-boundary proxy but has a direct, reproducible official statistic.",
    ),
    _capex_spec(
        key = :emp_s2,
        model_vars = [:emp_s2],
        provider_series_id = "BLS_CES_NAICS334_ALL_EMPLOYEES",
        provider = "BLS",
        source_kind = :official_statistic,
        role = :estimation_input,
        observability = :D,
        methodology = :aggregation,
        declared_unit = "Thousands of persons",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = :not_applicable,
        level_form = :level,
        sector_scope = "NAICS 334 computer and electronic product manufacturing; broader than S2",
        scope_bias = :over,
        aggregation = :mean,
        model_timing = :AVG,
        availability_start = "1990-Q1",
        notes = "BLS CES NAICS 334 employment. Quarterly measurement uses the monthly average, not a sum.",
    ),
    _capex_spec(
        key = :emp_s3_machinery,
        model_vars = [:emp_s3],
        provider_series_id = "BLS_CES_NAICS333_ALL_EMPLOYEES",
        provider = "BLS",
        source_kind = :official_statistic,
        role = :estimation_input,
        observability = :C,
        methodology = :aggregation,
        declared_unit = "Thousands of persons",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = :not_applicable,
        level_form = :level,
        sector_scope = "NAICS 333 machinery employment; one component of S3 only",
        scope_bias = :under,
        aggregation = :mean,
        model_timing = :AVG,
        availability_start = "1990-Q1",
        notes = "BLS CES machinery employment. S3 construction and utilities components are separately catalogued and summed in measurement.",
    ),
    _capex_spec(
        key = :emp_s3_construction,
        model_vars = [:emp_s3],
        provider_series_id = "BLS_CES_NAICS23_ALL_EMPLOYEES",
        provider = "BLS",
        source_kind = :official_statistic,
        role = :estimation_input,
        observability = :C,
        methodology = :aggregation,
        declared_unit = "Thousands of persons",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = :not_applicable,
        level_form = :level,
        sector_scope = "NAICS 23 construction employment; broader than data-center construction",
        scope_bias = :over,
        aggregation = :mean,
        model_timing = :AVG,
        availability_start = "1990-Q1",
        notes = "BLS CES construction employment. It is an explicit S3 aggregation component, not a data-center-only count.",
    ),
    _capex_spec(
        key = :emp_s3_utilities,
        model_vars = [:emp_s3],
        provider_series_id = "BLS_CES_NAICS22_ALL_EMPLOYEES",
        provider = "BLS",
        source_kind = :official_statistic,
        role = :estimation_input,
        observability = :C,
        methodology = :aggregation,
        declared_unit = "Thousands of persons",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = :not_applicable,
        level_form = :level,
        sector_scope = "NAICS 22 utilities employment; broader than power equipment supplied to data centers",
        scope_bias = :over,
        aggregation = :mean,
        model_timing = :AVG,
        availability_start = "1990-Q1",
        notes = "BLS CES utilities employment. It is an explicit S3 aggregation component and retains its broad-scope caveat.",
    ),
    _capex_spec(
        key = :wage,
        model_vars = [:wage],
        provider_series_id = "CES0500000003",
        provider = "FRED",
        source_kind = :official_statistic,
        role = :estimation_input,
        observability = :C,
        methodology = :aggregation,
        declared_unit = "Dollars per hour",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = :nominal,
        level_form = :level,
        sector_scope = "US private average hourly earnings; not sector-specific wage compensation",
        scope_bias = :indeterminate,
        aggregation = :mean,
        model_timing = :AVG,
        availability_start = "2006-Q1",
        notes = "BLS CES average hourly earnings via FRED. Measurement deflates with GDPDEF and rebases as prescribed; hours/benefits are not included.",
    ),
    _capex_spec(
        key = :hh_income,
        model_vars = [:hh_income],
        provider_series_id = "DSPIC96",
        provider = "FRED",
        source_kind = :official_statistic,
        role = :validation_only,
        observability = :P,
        methodology = :proxy,
        declared_unit = "Billions of chained dollars, SAAR",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "SAAR",
        declared_real_nominal = :real,
        declared_base_year = 2017,
        annualized = true,
        level_form = :level,
        sector_scope = "US real disposable personal income; includes non-wage and non-CCC income",
        scope_bias = :over,
        aggregation = :sum,
        model_timing = :SUM,
        availability_start = "1959-Q1",
        notes = "Real disposable personal income proxy. Divide SAAR by 4; it cannot be treated as the model's wage-income-only household account.",
    ),
    _capex_spec(
        key = :cons,
        model_vars = [:cons],
        provider_series_id = "PCECC96",
        provider = "FRED",
        source_kind = :official_statistic,
        role = :validation_only,
        observability = :P,
        methodology = :proxy,
        declared_unit = "Billions of chained dollars, SAAR",
        declared_frequency = Monthly,
        declared_seasonal_adjustment = "SAAR",
        declared_real_nominal = :real,
        declared_base_year = 2017,
        annualized = true,
        level_form = :level,
        sector_scope = "US real personal consumption expenditures; includes expenditure outside model S1 and S5 consumption",
        scope_bias = :over,
        aggregation = :sum,
        model_timing = :SUM,
        availability_start = "1959-Q1",
        notes = "Real PCE proxy. Divide SAAR by 4 and retain that it is not a direct sectoral household-consumption counterpart.",
    ),
    _capex_spec(
        key = :y_tot,
        model_vars = [:y_tot],
        provider_series_id = "GDPC1",
        provider = "FRED",
        source_kind = :official_statistic,
        role = :calibration_required,
        observability = :D,
        methodology = :direct,
        declared_unit = "Billions of chained dollars, SAAR",
        declared_frequency = Quarterly,
        declared_seasonal_adjustment = "SAAR",
        declared_real_nominal = :real,
        declared_base_year = 2017,
        annualized = true,
        level_form = :level,
        sector_scope = "US real gross domestic product",
        scope_bias = :none,
        aggregation = :sum,
        model_timing = :SUM,
        availability_start = "1947-Q1",
        notes = "BEA real GDP distributed by FRED. Divide the annual rate by 4 for the model's quarterly flow unit.",
    ),
    _capex_spec(
        key = :ai_exp_unavailable,
        model_vars = [:ai_exp],
        provider_series_id = "UNAVAILABLE_AI_EXPECTATION",
        provider = "UNAVAILABLE",
        source_kind = :firm_disclosure,
        role = :diagnostic_only,
        observability = :A,
        methodology = :proxy,
        declared_unit = "Not applicable",
        declared_frequency = Quarterly,
        declared_seasonal_adjustment = "unknown",
        declared_real_nominal = :not_applicable,
        level_form = :level,
        sector_scope = "No public aggregate series observes AI demand expectations as distinct from firm plans",
        scope_bias = :indeterminate,
        aggregation = :mean,
        model_timing = :AVG,
        notes = "No proxy calibration. Initial MVP holds ai_exp as a scenario/sensitivity input; firm guidance is not an expectation series.",
    ),
    _capex_spec(
        key = :capex_plan_s1_unavailable,
        model_vars = [:capex_plan_s1],
        provider_series_id = "UNAVAILABLE_HYPERSCALER_CAPEX_GUIDANCE",
        provider = "UNAVAILABLE",
        source_kind = :firm_disclosure,
        role = :diagnostic_only,
        observability = :A,
        methodology = :proxy,
        declared_unit = "Not applicable",
        declared_frequency = Quarterly,
        declared_seasonal_adjustment = "unknown",
        declared_real_nominal = :not_applicable,
        level_form = :level,
        sector_scope = "Firm-specific guidance lacks a reproducible aggregate issuer universe",
        scope_bias = :indeterminate,
        aggregation = :sum,
        model_timing = :SUM,
        notes = "Firm disclosures are excluded from initial-MVP calibration and estimation by validator; no DME direct collection fallback is allowed.",
    ),
    _capex_spec(
        key = :s1_financials_unavailable,
        model_vars = [:sales_s1, :profit_s1, :ocf_s1],
        provider_series_id = "UNAVAILABLE_HYPERSCALER_SEGMENT_FINANCIALS",
        provider = "UNAVAILABLE",
        source_kind = :firm_disclosure,
        role = :diagnostic_only,
        observability = :A,
        methodology = :proxy,
        declared_unit = "Not applicable",
        declared_frequency = Quarterly,
        declared_seasonal_adjustment = "unknown",
        declared_real_nominal = :not_applicable,
        level_form = :level,
        sector_scope = "Firm segment sales, profit and operating cash flow are non-uniform and cannot define a reproducible S1 aggregate",
        scope_bias = :indeterminate,
        aggregation = :sum,
        model_timing = :SUM,
        notes = "Corporate disclosure comparison may be added after a separately governed provider contract; it is not a calibration or estimation input.",
    ),
]

validate_capex_series_catalog(CAPEX_CC_SERIES_CATALOG)

"""
    capex_series_catalog(; role=nothing, provider=nothing) -> Vector{CapexSeriesSpec}

role または provider で絞り込んだ catalog のコピーを返す。未登録の role は空結果で隠さず
`ArgumentError` とする。
"""
function capex_series_catalog(;
    role::Union{Symbol, Nothing} = nothing,
    provider::Union{String, Nothing} = nothing,
)
    role === nothing ||
        role in CAPEX_CC_SERIES_ROLES ||
        throw(ArgumentError("未知の catalog role: $role"))
    return [
        spec for
        spec in CAPEX_CC_SERIES_CATALOG if (role === nothing || spec.role == role) &&
            (provider === nothing || spec.provider == provider)
    ]
end

"""EDP 側の不足能力を、DME の直接fallbackではなくcross-repository handoffとして記録する。"""
struct CapexProviderGap
    key::Symbol
    kind::Symbol
    detail::String
    blocking::Vector{Symbol}
end

const _CAPEX_CC_PROVIDER_GAP_KINDS = (
    :missing_series,
    :missing_metadata,
    :missing_frequency,
    :missing_history,
    :missing_fixture_parity,
    :missing_vintage,
)

function _capex_provider_gap(
    key::Symbol,
    kind::Symbol,
    detail::String,
    blocking::Vector{Symbol},
)::CapexProviderGap
    kind in _CAPEX_CC_PROVIDER_GAP_KINDS ||
        throw(ArgumentError("未知の provider gap: $kind"))
    isempty(detail) && throw(ArgumentError("provider gap detail は空にできません: $key"))
    isempty(blocking) &&
        throw(ArgumentError("provider gap blocking は空にできません: $key"))
    return CapexProviderGap(key, kind, detail, blocking)
end

# 2026-09-01 に `economic-data-provider` main の `/v1/catalog/series` と route 実装を
# 照合した結果。現行endpointは実質金利カタログ専用で、CCC series の取得endpointも無い。
# 2026-11-08（EDP 契約6.1.0、EDP ADR 073、Issue #314）: `spread` を構成する4系列
# （HQMCB10YRP・GS10・RIFSPPNA2P2D90NB・TB3MS）は EDP の `us_credit_spread` catalog に
# 載ったため、`:spread_hqm_corporate` の gap を外した。
const CAPEX_CC_PROVIDER_GAPS = CapexProviderGap[
    _capex_provider_gap(
        :capex_exec_s1_equipment,
        :missing_series,
        "BEA fixed-investment components are not catalogued or retrievable through EDP; add stable BEA IDs and a quarterly fixture/live decoder.",
        [:EB1, :CAL_SS],
    ),
    _capex_provider_gap(
        :order_s2,
        :missing_series,
        "Census M3 NAICS 334 new-orders, shipments, inventories and unfilled-orders series are absent from EDP.",
        [:EB3, :H1, :H3, :H5],
    ),
    _capex_provider_gap(
        :order_s3_manufacturing,
        :missing_series,
        "Census M3 NAICS 333 series and data-center construction source are absent from EDP.",
        [:EB3, :H1, :H3, :H5],
    ),
    _capex_provider_gap(
        :data_center_construction,
        :missing_history,
        "The candidate construction category has a shorter public history; EDP must expose availability bounds rather than silently extend it.",
        [:H5, :H6],
    ),
    _capex_provider_gap(
        :y_s2_ip,
        :missing_series,
        "FRB industrial-production and capacity series for NAICS 3344/333 are not in the EDP catalog.",
        [:EB3, :EB6],
    ),
    _capex_provider_gap(
        :price_s2,
        :missing_series,
        "BLS PPI industry indexes for NAICS 334/333 are not in EDP.",
        [:EB1, :EB3],
    ),
    _capex_provider_gap(
        :va_s2,
        :missing_series,
        "BEA quarterly GDP-by-industry real value-added series are not in EDP; their start dates must be returned as provider metadata.",
        [:CAL_SS, :EB6, :H1],
    ),
    _capex_provider_gap(
        :cap_s2,
        :missing_frequency,
        "EDP needs an annual Fixed Assets contract plus an explicit annual-to-quarterly handoff; DME must not infer a quarterly source.",
        [:CAL_SS],
    ),
    _capex_provider_gap(
        :nfc_debt_total,
        :missing_series,
        "FRB Z.1 aggregate nonfinancial-corporate debt is not catalogued; only the aggregate belongs upstream, sector allocation remains DME measurement metadata.",
        [:EB2],
    ),
    _capex_provider_gap(
        :lend_stance,
        :missing_series,
        "SLOOS C&I lending-standard series is not catalogued or retrievable through EDP.",
        [:EB2, :H2],
    ),
    _capex_provider_gap(
        :fin_cond,
        :missing_series,
        "Chicago Fed NFCI is not catalogued or retrievable through EDP.",
        [:EB2, :H2],
    ),
    _capex_provider_gap(
        :policy_rate,
        :missing_vintage,
        "FEDFUNDS is listed by EDP's real-rate catalog, but its catalog response does not provide a vintage/as-of capability field for CCC use.",
        [:H1, :H2, :H5],
    ),
    _capex_provider_gap(
        :emp_s1,
        :missing_series,
        "BLS CES industry employment and average-hourly-earnings series are absent from the EDP catalog.",
        [:EB6, :EB7],
    ),
    _capex_provider_gap(
        :y_tot,
        :missing_fixture_parity,
        "GDPC1 appears in EDP test fixtures but not in `/v1/catalog/series`; catalog, live, and fixture routes must agree before DME consumes it.",
        [:CAL_SS, :H1, :H2, :H5],
    ),
    _capex_provider_gap(
        :ai_exp_unavailable,
        :missing_metadata,
        "No metadata can make an aggregate AI expectation observable; retain this as scenario/sensitivity only rather than adding a synthetic provider fallback.",
        [:SCN],
    ),
]

function _capex_series_spec_to_dict(spec::CapexSeriesSpec)::Dict{String, Any}
    return Dict{String, Any}(
        "key" => String(spec.key),
        "model_vars" => String.(spec.model_vars),
        "provider_series_id" => spec.provider_series_id,
        "provider" => spec.provider,
        "source_kind" => String(spec.source_kind),
        "role" => String(spec.role),
        "observability" => String(spec.observability),
        "methodology" => String(spec.methodology),
        "declared_unit" => spec.declared_unit,
        "declared_frequency" => string(spec.declared_frequency),
        "declared_seasonal_adjustment" => spec.declared_seasonal_adjustment,
        "declared_real_nominal" => String(spec.declared_real_nominal),
        "declared_base_year" => spec.declared_base_year,
        "annualized" => spec.annualized,
        "level_form" => String(spec.level_form),
        "anchor" => isnothing(spec.anchor) ? nothing : String(spec.anchor),
        "sector_scope" => spec.sector_scope,
        "scope_bias" => String(spec.scope_bias),
        "aggregation" => String(spec.aggregation),
        "model_timing" => String(spec.model_timing),
        "allocation_key" =>
            isnothing(spec.allocation_key) ? nothing : String(spec.allocation_key),
        "availability_start" => spec.availability_start,
        "availability_end" => spec.availability_end,
        "notes" => spec.notes,
        "reference_key" =>
            isnothing(spec.reference_key) ? nothing : String(spec.reference_key),
        "daily_reduction" =>
            isnothing(spec.daily_reduction) ? nothing : String(spec.daily_reduction),
    )
end

function _capex_provider_gap_to_dict(gap::CapexProviderGap)::Dict{String, Any}
    return Dict{String, Any}(
        "key" => String(gap.key),
        "kind" => String(gap.kind),
        "detail" => gap.detail,
        "blocking" => String.(gap.blocking),
    )
end

"""
    capex_series_catalog_to_dict(catalog = CAPEX_CC_SERIES_CATALOG) -> Dict{String,Any}

cross-repository handoff 用の、正準JSON化できる辞書を返す。provider gap は catalog と独立の
EDP handoff であるため常に同じ versioned registry から出力する。
"""
function capex_series_catalog_to_dict(
    catalog::AbstractVector{<:CapexSeriesSpec} = CAPEX_CC_SERIES_CATALOG,
)::Dict{String, Any}
    validate_capex_series_catalog(catalog)
    return Dict{String, Any}(
        "catalog_version" => CAPEX_CC_EMPIRICAL_INTEGRATION_VERSION,
        "series" => [_capex_series_spec_to_dict(spec) for spec in catalog],
        "provider_gaps" =>
            [_capex_provider_gap_to_dict(gap) for gap in CAPEX_CC_PROVIDER_GAPS],
    )
end

"""
    save_capex_series_catalog(path, catalog = CAPEX_CC_SERIES_CATALOG) -> String

catalog handoff を正準JSONとして `path` へ atomic に保存する。対象ファイルは上書き可能な
handoff artifact であり、失敗時は一時ファイルを削除して既存ファイルを保持する。
"""
function save_capex_series_catalog(
    path::AbstractString,
    catalog::AbstractVector{<:CapexSeriesSpec} = CAPEX_CC_SERIES_CATALOG,
)::String
    dir = dirname(path)
    isempty(dir) || mkpath(dir)
    tmp_path = path * ".tmp"
    bytes = canonical_json_bytes(capex_series_catalog_to_dict(catalog))
    try
        open(tmp_path, "w") do io
            write(io, bytes)
            flush(io)
            @static if Sys.isunix()
                ccall(:fsync, Cint, (Cint,), fd(io))
            end
        end
        mv(tmp_path, path; force = true)
    catch
        isfile(tmp_path) && rm(tmp_path; force = true)
        rethrow()
    end
    return String(path)
end
