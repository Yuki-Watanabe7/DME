# ---------------------------------------------------------------------------
# Keen モデル実証データセット構築
#
# Keen モデルの状態変数 ω（賃金シェア）・λ（雇用率）・d（民間債務比率）と
# 外生金利 r を、実データ（FRED fixture/live/rest_api 経路）から取得・変換・整列し、
# キャリブレーション/検証でそのまま使える構造化データセットへまとめる読み取り専用層。
#
# 設計方針は docs/models/keen_empirical_strategy.md（決定記録は docs/adr/0004）。
#   - 観測方程式・単位変換を純粋関数で定義（clamp/0埋めで異常を隠さない）
#   - 公表系列が指数か比率かを検証（指数を水準シェアとして誤利用しない）
#   - 四半期ラベルを構造的に parse し、必須系列を日付ベースで inner join
#   - 年単位 ODE と整合する Δt = 0.25 の観測時間軸を生成
#   - source / mode / 元 unit / 変換式 / aggregation / 採用期間を provenance として保持
#   - 国別設定をモデル本体から分離（米国を初期 MVP、他国は後から追加可能）
# ---------------------------------------------------------------------------

const KEEN_EMPIRICAL_METHODOLOGY_VERSION = "keen-empirical/1.0.0"

# ---------------------------------------------------------------------------
# 変換仕様
# ---------------------------------------------------------------------------

"""
    KeenSeriesSpec

Keen 実証データセットの 1 系列（`ω`・`λ`・`d`・`r` のいずれか）の観測方程式・
単位変換・四半期化方式・妥当域を定義する仕様。

## フィールド
- `variable::Symbol`   : モデル変数（`:ω`・`:λ`・`:d`・`:r`）
- `source_id::String`  : source series ID（例: `"CRDQUSAPABIS"`）。FRED の場合 `DataSeries.id` は `"FRED_<source_id>"`
- `conversion::Symbol` : 観測方程式・単位変換
    - `:ratio_from_percent`      : `v / 100`（% → 比率。ω の % シェア・d の % of GDP・r の % 年率）
    - `:employment_from_unrate`  : `1 - v / 100`（失業率 % → 雇用率）
    - `:identity_ratio`          : `v`（既に比率）
- `aggregation::Symbol` : 月次 → 四半期の集計方式（`:mean`・`:sum`・`:end`）。四半期系列では無視
- `domain_lo::Float64`  : 変換後の妥当域下限（含む）
- `domain_hi::Float64`  : 変換後の妥当域上限（含む）。`Inf` 可
- `forbid_index::Bool`  : source unit に "index" を含む場合に採用を拒否するか（指数の水準シェア誤用防止）
"""
struct KeenSeriesSpec
    variable::Symbol
    source_id::String
    conversion::Symbol
    aggregation::Symbol
    domain_lo::Float64
    domain_hi::Float64
    forbid_index::Bool
end

function KeenSeriesSpec(;
    variable::Symbol,
    source_id::String,
    conversion::Symbol,
    aggregation::Symbol = :mean,
    domain_lo::Float64,
    domain_hi::Float64,
    forbid_index::Bool = false,
)
    conversion in (:ratio_from_percent, :employment_from_unrate, :identity_ratio) ||
        throw(ArgumentError("未知の conversion: $(repr(conversion))"))
    aggregation in (:mean, :sum, :end) ||
        throw(ArgumentError("未知の aggregation: $(repr(aggregation))"))
    domain_lo <= domain_hi ||
        throw(ArgumentError("domain_lo は domain_hi 以下でなければなりません"))
    KeenSeriesSpec(
        variable,
        source_id,
        conversion,
        aggregation,
        domain_lo,
        domain_hi,
        forbid_index,
    )
end

"""
    keen_convert_value(spec, v) -> Union{Float64, Missing}

観測値 `v`（`missing` 可）に `spec.conversion` の観測方程式・単位変換を適用する純粋関数。
`missing`・非有限値は変換せずそのまま返す（`0` へ変換したり clamp したりしない）。
"""
function keen_convert_value(spec::KeenSeriesSpec, v::Union{Float64, Missing})
    ismissing(v) && return missing
    isfinite(v) || return v  # NaN/Inf はそのまま伝播（後段で invalid 判定）
    if spec.conversion === :ratio_from_percent
        return v / 100.0
    elseif spec.conversion === :employment_from_unrate
        return 1.0 - v / 100.0
    else # :identity_ratio
        return v
    end
end

"""
    keen_value_valid(spec, v) -> Bool

変換後の値 `v` が有限かつ妥当域 `[domain_lo, domain_hi]` に入るかを返す。
`missing`・非有限・域外は `false`（clamp せず invalid として扱う）。
"""
function keen_value_valid(spec::KeenSeriesSpec, v::Union{Float64, Missing})
    ismissing(v) && return false
    isfinite(v) || return false
    spec.domain_lo <= v <= spec.domain_hi
end

"""
    keen_conversion_formula(spec) -> String

`spec.conversion` に対応する変換式の可読表現（provenance 記録用）。
"""
function keen_conversion_formula(spec::KeenSeriesSpec)
    if spec.conversion === :ratio_from_percent
        return "value / 100"
    elseif spec.conversion === :employment_from_unrate
        return "1 - value / 100"
    else
        return "value"
    end
end

# ---------------------------------------------------------------------------
# データセット設定
# ---------------------------------------------------------------------------

"""
    KeenEmpiricalDataConfig

Keen 実証データセットの構築設定。国別設定をモデル本体から分離して保持する。

## フィールド
- `country::String`                       : 対象国（初期 MVP は `"US"`）
- `omega::KeenSeriesSpec` 他 `lambda`/`debt`/`rate` : `ω`・`λ`・`d`・`r` の系列仕様
- `sample_start::Union{String,Nothing}`   : 標本開始四半期ラベル（`"YYYY-Qn"`）。`nothing` で共通期間から自動決定
- `sample_end::Union{String,Nothing}`     : 標本終了四半期ラベル。`nothing` で自動
- `min_valid_obs::Int`                     : 有効観測数の下限。下回ると明示的に失敗
- `r_mode::Symbol`                         : `r` を固定パラメータへ落とす方式（`:sample_mean`・`:start`・`:fixed`）
- `r_fixed::Float64`                       : `r_mode == :fixed` のときの外生固定値（小数年率）
- `validation_split`                       : 検証区間の指定。`Float64`（末尾に割り当てる比率 `0..1`）または `String`（分割点四半期ラベル。この点までが calibration）
- `methodology_version::String`            : measurement methodology version

`US` 向け既定は [`keen_us_default_config`](@ref) を参照。
"""
struct KeenEmpiricalDataConfig
    country::String
    omega::KeenSeriesSpec
    lambda::KeenSeriesSpec
    debt::KeenSeriesSpec
    rate::KeenSeriesSpec
    sample_start::Union{String, Nothing}
    sample_end::Union{String, Nothing}
    min_valid_obs::Int
    r_mode::Symbol
    r_fixed::Float64
    validation_split::Union{Float64, String}
    methodology_version::String
end

function KeenEmpiricalDataConfig(;
    country::String,
    omega::KeenSeriesSpec,
    lambda::KeenSeriesSpec,
    debt::KeenSeriesSpec,
    rate::KeenSeriesSpec,
    sample_start::Union{String, Nothing} = nothing,
    sample_end::Union{String, Nothing} = nothing,
    min_valid_obs::Int = 8,
    r_mode::Symbol = :sample_mean,
    r_fixed::Float64 = 0.03,
    validation_split::Union{Float64, String} = 0.3,
    methodology_version::String = KEEN_EMPIRICAL_METHODOLOGY_VERSION,
)
    r_mode in (:sample_mean, :start, :fixed) || throw(
        ArgumentError("r_mode は :sample_mean, :start または :fixed でなければなりません"),
    )
    min_valid_obs >= 1 ||
        throw(ArgumentError("min_valid_obs は 1 以上でなければなりません"))
    if validation_split isa Float64
        0.0 <= validation_split < 1.0 ||
            throw(ArgumentError("validation_split（比率）は [0, 1) でなければなりません"))
    end
    KeenEmpiricalDataConfig(
        country,
        omega,
        lambda,
        debt,
        rate,
        sample_start,
        sample_end,
        min_valid_obs,
        r_mode,
        r_fixed,
        validation_split,
        methodology_version,
    )
end

"""
    keen_us_default_config(; kwargs...) -> KeenEmpiricalDataConfig

米国を対象とした Keen 実証データセットの既定設定。
`docs/models/keen_empirical_strategy.md` §2 の候補系列・変換規則に対応する。

- `ω`: 名目比率での賃金シェア（% シェア → 比率）。指数系列は拒否（`forbid_index=true`）
- `λ`: `1 - UNRATE/100`（月次 → 四半期平均）
- `d`: `CRDQUSAPABIS`（% of GDP → 比率）
- `r`: `DPRIME`（% 年率 → 小数、月次 → 四半期平均）

`kwargs` で標本期間・分割・`r_mode` 等を上書きできる。系列 ID は候補であり、
採用前に provider metadata で「指数か比率か」「部門範囲」を検証すること。
"""
function keen_us_default_config(;
    omega_source_id::String = "USLABORSHARE",
    lambda_source_id::String = "UNRATE",
    debt_source_id::String = "CRDQUSAPABIS",
    rate_source_id::String = "DPRIME",
    kwargs...,
)
    KeenEmpiricalDataConfig(;
        country = "US",
        omega = KeenSeriesSpec(;
            variable = :ω,
            source_id = omega_source_id,
            conversion = :ratio_from_percent,
            aggregation = :mean,
            domain_lo = 0.0,
            domain_hi = 1.0,
            forbid_index = true,
        ),
        lambda = KeenSeriesSpec(;
            variable = :λ,
            source_id = lambda_source_id,
            conversion = :employment_from_unrate,
            aggregation = :mean,
            domain_lo = 0.0,
            domain_hi = 1.0,
        ),
        debt = KeenSeriesSpec(;
            variable = :d,
            source_id = debt_source_id,
            conversion = :ratio_from_percent,
            aggregation = :mean,
            domain_lo = 0.0,
            domain_hi = 100.0,
        ),
        rate = KeenSeriesSpec(;
            variable = :r,
            source_id = rate_source_id,
            conversion = :ratio_from_percent,
            aggregation = :mean,
            domain_lo = 0.0,
            domain_hi = 1.0,
        ),
        kwargs...,
    )
end

# ---------------------------------------------------------------------------
# 出力型
# ---------------------------------------------------------------------------

"""
    KeenSeriesProvenance

1 系列の出所・変換履歴を追跡する記録。

## フィールド
- `variable::Symbol` / `source_id::String` / `series_id::String` / `source::String`
- `mode::Symbol`            : 取得モード（`:fixture`・`:live`・`:rest_api`・`:provided`）
- `original_unit::String`   : 変換前の unit
- `conversion_formula::String` : 適用した観測方程式・単位変換式
- `aggregation::Symbol`     : 四半期化方式（四半期系列は `:none`）
- `original_frequency::DataFrequency`
- `adopted_start::String` / `adopted_end::String` : 採用した共通四半期区間の端点
- `n_used::Int`             : 採用観測数
- `n_source_missing::Int`   : source 系列中の欠損数
- `n_invalid::Int`          : 変換後に妥当域外・非有限となった観測数
- `retrieved_at::Union{String,Nothing}` : 取得日時（省略可・決定性のため既定 nothing）
"""
struct KeenSeriesProvenance
    variable::Symbol
    source_id::String
    series_id::String
    source::String
    mode::Symbol
    original_unit::String
    conversion_formula::String
    aggregation::Symbol
    original_frequency::DataFrequency
    adopted_start::String
    adopted_end::String
    n_used::Int
    n_source_missing::Int
    n_invalid::Int
    retrieved_at::Union{String, Nothing}
end

"""
    KeenEmpiricalDataset

Keen モデルのキャリブレーション/検証にそのまま使える構造化データセット。
元の `MacroDataset`・source 系列を変更せず、派生結果として保持する。

## フィールド
- `config::KeenEmpiricalDataConfig`
- `dates::Vector{String}`               : 共通四半期時間軸（`"YYYY-Qn"`、時間順）
- `observation_times::Vector{Float64}`  : 年単位の観測時点（先頭を `0.0` とし `Δ = 0.25`。欠損四半期は間隔に反映）
- `ω::Vector{Float64}` / `λ` / `d`      : モデル単位へ変換・整列済みの状態系列
- `r::Vector{Float64}`                  : モデル単位へ変換・整列済みの金利系列
- `initial_state::NamedTuple`           : 最初の有効観測 `(ω0, λ0, d0)`
- `r_param::Float64`                    : `r_mode` に基づく固定金利パラメータ
- `calibration_indices::Vector{Int}` / `validation_indices::Vector{Int}` : 再現可能な分割（重複・look-ahead なし）
- `provenance::Dict{Symbol,KeenSeriesProvenance}` : 系列別 provenance
- `dropped_dates::Vector{String}`       : 候補共通四半期のうち欠損/invalid で除外した四半期
- `quality_flags::Dict{String,Any}`     : 有効/除外観測数・invalid 内訳等
- `source_dataset::MacroDataset`        : 元の source 系列（無変更）
- `metadata::Dict{String,Any}`          : methodology version・mode 等
"""
struct KeenEmpiricalDataset
    config::KeenEmpiricalDataConfig
    dates::Vector{String}
    observation_times::Vector{Float64}
    ω::Vector{Float64}
    λ::Vector{Float64}
    d::Vector{Float64}
    r::Vector{Float64}
    initial_state::NamedTuple
    r_param::Float64
    calibration_indices::Vector{Int}
    validation_indices::Vector{Int}
    provenance::Dict{Symbol, KeenSeriesProvenance}
    dropped_dates::Vector{String}
    quality_flags::Dict{String, Any}
    source_dataset::MacroDataset
    metadata::Dict{String, Any}
end

Base.length(ds::KeenEmpiricalDataset) = length(ds.dates)

# ---------------------------------------------------------------------------
# 四半期ラベルの構造的 parse
# ---------------------------------------------------------------------------

"""
    _parse_quarter_label(label) -> (year::Int, quarter::Int)

`"YYYY-Qn"` を構造的に parse する。形式不正は `ArgumentError`。
"""
function _parse_quarter_label(label::String)
    m = match(r"^(\d{4})-Q([1-4])$", label)
    m === nothing && throw(
        ArgumentError("四半期ラベル形式が不正です: '$(label)'. YYYY-Qn 形式が必要です"),
    )
    (parse(Int, m.captures[1]), parse(Int, m.captures[2]))
end

"""
    _quarter_index(year, quarter) -> Int

四半期の絶対通番（`year*4 + (quarter-1)`）。時間順ソート・間隔計算に使う。
"""
_quarter_index(year::Int, quarter::Int) = year * 4 + (quarter - 1)

_quarter_index(label::String) = _quarter_index(_parse_quarter_label(label)...)

# ---------------------------------------------------------------------------
# 系列の四半期化 + 変換 + ラベル→値マップ
# ---------------------------------------------------------------------------

"""
    _quarterize(series, spec) -> DataSeries

`spec.aggregation` に従い月次系列を四半期化する。既に四半期系列ならそのまま返す。
"""
function _quarterize(series::DataSeries, spec::KeenSeriesSpec)
    if series.frequency == Quarterly
        return series
    elseif series.frequency == Monthly
        return to_quarterly(series; method = spec.aggregation)
    else
        throw(
            ArgumentError(
                "系列 $(series.id) は月次または四半期でなければなりません (frequency=$(series.frequency))",
            ),
        )
    end
end

"""
    _assert_not_index(series, spec)

`spec.forbid_index` のとき、source unit が指数（"index" を含む）なら採用を拒否する。
指数系列を水準シェアとして誤利用することを防ぐ。
"""
function _assert_not_index(series::DataSeries, spec::KeenSeriesSpec)
    if spec.forbid_index && occursin("index", lowercase(series.unit))
        throw(
            ArgumentError(
                "系列 $(series.id) は指数（unit=\"$(series.unit)\"）であり、変数 $(spec.variable) の水準比率として直接利用できません。" *
                "比率系列を指定するか、基準年水準へアンカーして比率化してください。",
            ),
        )
    end
    return nothing
end

# 四半期化・変換後の 1 系列を表す中間表現
struct _PreparedSeries
    label_to_value::Dict{String, Float64}   # 有効（変換済み・妥当域内）観測のみ
    labels::Vector{String}                   # 有効観測のラベル（時間順）
    n_source_missing::Int
    n_invalid::Int
    quarterized::DataSeries
end

"""
    _prepare_series(series, spec) -> _PreparedSeries

四半期化 → 変換 → 妥当域検証を行い、有効観測のラベル→値マップを構築する。
重複四半期ラベルは `ArgumentError`（暗黙に上書きしない）。
"""
function _prepare_series(series::DataSeries, spec::KeenSeriesSpec)
    _assert_not_index(series, spec)
    q = _quarterize(series, spec)

    label_to_value = Dict{String, Float64}()
    labels = String[]
    seen = Set{String}()
    n_missing = 0
    n_invalid = 0

    # 時間順に並べ替え（順序不定入力に対して決定的にする）
    order = sortperm(q.dates; by = _quarter_index)
    for i in order
        label = q.dates[i]
        raw = q.values[i]
        if label in seen
            throw(
                ArgumentError(
                    "系列 $(series.id) に重複した四半期ラベルがあります: '$(label)'",
                ),
            )
        end
        push!(seen, label)
        ismissing(raw) && (n_missing += 1)
        converted = keen_convert_value(spec, raw)
        if keen_value_valid(spec, converted)
            label_to_value[label] = converted::Float64
            push!(labels, label)
        else
            # missing でなく変換後に非有限/域外 → invalid（0埋め・clampしない）
            !ismissing(raw) && (n_invalid += 1)
        end
    end

    _PreparedSeries(label_to_value, labels, n_missing, n_invalid, q)
end

# ---------------------------------------------------------------------------
# データセット構築
# ---------------------------------------------------------------------------

"""
    build_keen_empirical_dataset(config, dataset::MacroDataset; mode=:provided, retrieved_at=nothing)
        -> KeenEmpiricalDataset

取得済みの `MacroDataset` から Keen 実証データセットを構築する。`dataset` は変更しない。

`config` の各系列 `source_id` に対応する `DataSeries` を `"FRED_<source_id>"` または
`source_id` の順で探索する。必須系列（ω・λ・d・r）を四半期化・変換・inner join し、
Δt = 0.25 の観測時間軸・初期状態・固定金利パラメータ・calibration/validation 分割を構築する。
"""
function build_keen_empirical_dataset(
    config::KeenEmpiricalDataConfig,
    dataset::MacroDataset;
    mode::Symbol = :provided,
    retrieved_at::Union{String, Nothing} = nothing,
)
    specs = (ω = config.omega, λ = config.lambda, d = config.debt, r = config.rate)

    raw = Dict{Symbol, DataSeries}()
    prepared = Dict{Symbol, _PreparedSeries}()
    for (var, spec) in pairs(specs)
        s = _lookup_series(dataset, spec.source_id)
        raw[var] = s
        prepared[var] = _prepare_series(s, spec)
    end

    # 候補共通四半期 = 全系列で有効な観測が存在するラベルの積集合（日付 intersection）
    common = _intersect_labels((prepared[v].labels for v in (:ω, :λ, :d, :r))...)

    # 標本期間フィルタ（指定があれば）
    common = _apply_sample_window(common, config.sample_start, config.sample_end)

    # 時間順にソート
    sort!(common; by = _quarter_index)

    # 除外四半期の追跡: いずれかの系列で有効だが共通には残らなかったもの
    all_labels = _union_labels((prepared[v].labels for v in (:ω, :λ, :d, :r))...)
    all_labels = _apply_sample_window(all_labels, config.sample_start, config.sample_end)
    dropped = sort(collect(setdiff(Set(all_labels), Set(common))); by = _quarter_index)

    if length(common) < config.min_valid_obs
        throw(
            ArgumentError(
                "有効観測数 $(length(common)) が下限 min_valid_obs=$(config.min_valid_obs) を下回りました。" *
                "共通四半期軸（日付 intersection）で揃う観測が不足しています。",
            ),
        )
    end

    # 整列済みベクトル
    ωv = [prepared[:ω].label_to_value[l] for l in common]
    λv = [prepared[:λ].label_to_value[l] for l in common]
    dv = [prepared[:d].label_to_value[l] for l in common]
    rv = [prepared[:r].label_to_value[l] for l in common]

    # Δt = 0.25 の観測時間軸（先頭 0.0、欠損四半期は間隔に反映）
    idx0 = _quarter_index(common[1])
    obs_times = [(_quarter_index(l) - idx0) * 0.25 for l in common]

    initial_state = (ω0 = ωv[1], λ0 = λv[1], d0 = dv[1])
    r_param = _resolve_r_param(config, rv)

    calib_idx, valid_idx = _make_split(config.validation_split, common)

    provenance = Dict{Symbol, KeenSeriesProvenance}()
    for (var, spec) in pairs(specs)
        s = raw[var]
        p = prepared[var]
        agg = s.frequency == Monthly ? spec.aggregation : :none
        provenance[var] = KeenSeriesProvenance(
            var,
            spec.source_id,
            s.id,
            s.source,
            mode,
            s.unit,
            keen_conversion_formula(spec),
            agg,
            s.frequency,
            common[1],
            common[end],
            length(common),
            p.n_source_missing,
            p.n_invalid,
            retrieved_at,
        )
    end

    quality_flags = Dict{String, Any}(
        "n_common" => length(common),
        "n_dropped" => length(dropped),
        "n_invalid" =>
            Dict(string(v) => prepared[v].n_invalid for v in (:ω, :λ, :d, :r)),
        "n_source_missing" =>
            Dict(string(v) => prepared[v].n_source_missing for v in (:ω, :λ, :d, :r)),
        "min_valid_obs" => config.min_valid_obs,
    )

    metadata = Dict{String, Any}(
        "methodology_version" => config.methodology_version,
        "country" => config.country,
        "mode" => mode,
        "r_mode" => config.r_mode,
        "sample_start" => common[1],
        "sample_end" => common[end],
        "vintage" => "revised",  # 初版は確報値（非 vintage）
    )

    KeenEmpiricalDataset(
        config,
        common,
        obs_times,
        ωv,
        λv,
        dv,
        rv,
        initial_state,
        r_param,
        calib_idx,
        valid_idx,
        provenance,
        dropped,
        quality_flags,
        dataset,
        metadata,
    )
end

"""
    build_keen_empirical_dataset(config; client=FredClient(), retrieved_at=nothing)
        -> KeenEmpiricalDataset

`FredClient` を用いて必須系列を取得してから Keen 実証データセットを構築する。
`fixture`・`live`・`rest_api` のいずれのモードでも同一のデータセット契約を返す
（`fetch_fred_series` が同じ `DataSeries` 契約を返すため）。API キー未設定や provider 停止時に
fixture へ暗黙 fallback はしない（`FredClient` の挙動に従い明示的に失敗する）。
"""
function build_keen_empirical_dataset(
    config::KeenEmpiricalDataConfig;
    client::FredClient = FredClient(),
    retrieved_at::Union{String, Nothing} = nothing,
)
    ids = unique([
        config.omega.source_id,
        config.lambda.source_id,
        config.debt.source_id,
        config.rate.source_id,
    ])
    dataset = fetch_fred_dataset(
        ids;
        client = client,
        name = "Keen Empirical ($(config.country))",
    )
    build_keen_empirical_dataset(
        config,
        dataset;
        mode = client.mode,
        retrieved_at = retrieved_at,
    )
end

# ---------------------------------------------------------------------------
# ヘルパー
# ---------------------------------------------------------------------------

function _lookup_series(dataset::MacroDataset, source_id::String)
    for candidate in ("FRED_$(source_id)", source_id)
        haskey(dataset, candidate) && return get_series(dataset, candidate)
    end
    throw(
        KeyError(
            "系列 '$(source_id)'（'FRED_$(source_id)' も含む）が MacroDataset に見つかりません",
        ),
    )
end

function _intersect_labels(label_lists...)
    isempty(label_lists) && return String[]
    acc = Set(first(label_lists))
    for l in Base.tail(label_lists)
        intersect!(acc, Set(l))
    end
    collect(acc)
end

function _union_labels(label_lists...)
    acc = Set{String}()
    for l in label_lists
        union!(acc, Set(l))
    end
    collect(acc)
end

function _apply_sample_window(
    labels::Vector{String},
    start_label::Union{String, Nothing},
    end_label::Union{String, Nothing},
)
    lo = start_label === nothing ? typemin(Int) : _quarter_index(start_label)
    hi = end_label === nothing ? typemax(Int) : _quarter_index(end_label)
    lo <= hi || throw(ArgumentError("sample_start は sample_end 以前でなければなりません"))
    filter(l -> lo <= _quarter_index(l) <= hi, labels)
end

function _resolve_r_param(config::KeenEmpiricalDataConfig, rv::Vector{Float64})
    if config.r_mode === :sample_mean
        return sum(rv) / length(rv)
    elseif config.r_mode === :start
        return rv[1]
    else # :fixed
        return config.r_fixed
    end
end

"""
    _make_split(validation_split, common) -> (calibration_indices, validation_indices)

calibration/validation 分割を決定論的に生成する。calibration は時間的に前、
validation は後（look-ahead・重複なし）。
- `validation_split::Float64` : 末尾の割合 `frac` を validation に割り当てる（`n_val = floor(n*frac)`）
- `validation_split::String`  : この四半期ラベルまで（含む）を calibration、以降を validation
"""
function _make_split(validation_split::Float64, common::Vector{String})
    n = length(common)
    n_val = floor(Int, n * validation_split)
    n_cal = n - n_val
    (collect(1:n_cal), collect((n_cal + 1):n))
end

function _make_split(validation_split::String, common::Vector{String})
    split_idx = _quarter_index(validation_split)
    n = length(common)
    n_cal = count(l -> _quarter_index(l) <= split_idx, common)
    (collect(1:n_cal), collect((n_cal + 1):n))
end
