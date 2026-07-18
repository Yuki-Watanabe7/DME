# ---------------------------------------------------------------------------
# 実データ前処理ユーティリティ
#
# DataSeries を入力・出力とする変換関数群。
# 各関数は変換後も source / frequency / unit 等の metadata を保持し、
# 変換履歴を metadata["transformations"] に追記する。
# ---------------------------------------------------------------------------

"""
    _append_transform!(metadata, description)

変換履歴を `metadata["transformations"]` に追記する内部ヘルパー。
"""
function _append_transform!(meta::Dict{String, Any}, desc::String)
    if !haskey(meta, "transformations")
        meta["transformations"] = String[]
    end
    push!(meta["transformations"], desc)
    return meta
end

# ---------------------------------------------------------------------------
# 欠損値処理
# ---------------------------------------------------------------------------

"""
    fill_missing(series; method=:forward) -> DataSeries

欠損値を補完した新しい `DataSeries` を返す。

`method` の選択肢:
- `:forward`  : 直前の非欠損値で補完（forward fill）
- `:backward` : 直後の非欠損値で補完（backward fill）
- `:zero`     : `0.0` で補完
- `::Real`    : 指定した定数で補完

先頭（`:forward`）または末尾（`:backward`）に残った欠損値はそのまま維持される。
"""
function fill_missing(s::DataSeries; method = :forward)
    vals = copy(s.values)
    n = length(vals)

    if method === :forward
        for i in 2:n
            ismissing(vals[i]) && !ismissing(vals[i - 1]) && (vals[i] = vals[i - 1])
        end
    elseif method === :backward
        for i in (n - 1):-1:1
            ismissing(vals[i]) && !ismissing(vals[i + 1]) && (vals[i] = vals[i + 1])
        end
    elseif method === :zero
        for i in 1:n
            ismissing(vals[i]) && (vals[i] = 0.0)
        end
    elseif method isa Real
        fill_val = Float64(method)
        for i in 1:n
            ismissing(vals[i]) && (vals[i] = fill_val)
        end
    else
        throw(
            ArgumentError(
                "未知の method: $(repr(method)). :forward, :backward, :zero または Real を指定してください。",
            ),
        )
    end

    meta = deepcopy(s.metadata)
    _append_transform!(meta, "fill_missing(method=$(repr(method)))")
    return DataSeries(
        s.id,
        s.name,
        s.source,
        s.frequency,
        s.unit,
        copy(s.dates),
        vals,
        meta,
    )
end

"""
    drop_missing(series) -> DataSeries

欠損値を持つ観測点を除外した新しい `DataSeries` を返す。
"""
function drop_missing(s::DataSeries)
    mask = .!ismissing.(s.values)
    new_dates = s.dates[mask]
    new_values = collect(Float64, s.values[mask])

    meta = deepcopy(s.metadata)
    _append_transform!(meta, "drop_missing")
    return DataSeries(
        s.id,
        s.name,
        s.source,
        s.frequency,
        s.unit,
        new_dates,
        new_values,
        meta,
    )
end

# ---------------------------------------------------------------------------
# 対数変換
# ---------------------------------------------------------------------------

"""
    apply_log(series) -> DataSeries

自然対数変換を適用した新しい `DataSeries` を返す。

非正値（≤ 0）を含む場合は `DomainError` を投げる。
欠損値は欠損のまま維持される。
unit は `"log(<元の unit>)"` に更新される。
"""
function apply_log(s::DataSeries)
    for (i, v) in enumerate(s.values)
        if !ismissing(v) && v <= 0.0
            throw(
                DomainError(
                    v,
                    "対数変換: 非正値が含まれています (dates[$(i)]=$(s.dates[i]), value=$v)",
                ),
            )
        end
    end

    new_vals = Union{Float64, Missing}[ismissing(v) ? missing : log(v) for v in s.values]
    new_unit = "log($(s.unit))"

    meta = deepcopy(s.metadata)
    _append_transform!(meta, "apply_log")
    return DataSeries(
        s.id,
        s.name,
        s.source,
        s.frequency,
        new_unit,
        copy(s.dates),
        new_vals,
        meta,
    )
end

# ---------------------------------------------------------------------------
# 差分・変化率
# ---------------------------------------------------------------------------

"""
    difference(series; periods=1) -> DataSeries

差分変換 `x[t] - x[t-periods]` を適用した新しい `DataSeries` を返す。

先頭の `periods` 観測点は除外される。
どちらかが欠損値の場合はその点の結果も `missing` になる。
unit は `"Δ(<元の unit>)"` に更新される。
"""
function difference(s::DataSeries; periods::Int = 1)
    periods >= 1 || throw(ArgumentError("periods は 1 以上でなければなりません"))
    length(s) > periods ||
        throw(ArgumentError("系列長 ($(length(s))) が periods ($periods) 以下です"))

    n = length(s)
    n_new = n - periods
    new_vals = Vector{Union{Float64, Missing}}(undef, n_new)

    for i in 1:n_new
        curr = s.values[i + periods]
        prev = s.values[i]
        new_vals[i] = (ismissing(curr) || ismissing(prev)) ? missing : curr - prev
    end

    new_dates = s.dates[(periods + 1):end]
    new_unit = "Δ($(s.unit))"

    meta = deepcopy(s.metadata)
    _append_transform!(meta, "difference(periods=$periods)")
    return DataSeries(
        s.id,
        s.name,
        s.source,
        s.frequency,
        new_unit,
        new_dates,
        new_vals,
        meta,
    )
end

"""
    pct_change(series; periods=1) -> DataSeries

前期比変化率（%）を計算した新しい `DataSeries` を返す。

`(x[t] - x[t-periods]) / |x[t-periods]| × 100` を計算する。

- `periods=1`  : 前期比（QoQ / MoM など）
- `periods=4`  : 四半期系列の前年同期比
- `periods=12` : 月次系列の前年同月比

先頭の `periods` 観測点は除外される。
前期値がゼロまたは欠損の場合は `missing` を返す。
unit は `"%"` に更新される。
"""
function pct_change(s::DataSeries; periods::Int = 1)
    periods >= 1 || throw(ArgumentError("periods は 1 以上でなければなりません"))
    length(s) > periods ||
        throw(ArgumentError("系列長 ($(length(s))) が periods ($periods) 以下です"))

    n = length(s)
    n_new = n - periods
    new_vals = Vector{Union{Float64, Missing}}(undef, n_new)

    for i in 1:n_new
        curr = s.values[i + periods]
        prev = s.values[i]
        if ismissing(curr) || ismissing(prev) || prev == 0.0
            new_vals[i] = missing
        else
            new_vals[i] = (curr - prev) / abs(prev) * 100.0
        end
    end

    new_dates = s.dates[(periods + 1):end]

    meta = deepcopy(s.metadata)
    _append_transform!(meta, "pct_change(periods=$periods)")
    return DataSeries(s.id, s.name, s.source, s.frequency, "%", new_dates, new_vals, meta)
end

# ---------------------------------------------------------------------------
# 移動平均
# ---------------------------------------------------------------------------

"""
    moving_average(series; window=3) -> DataSeries

後方移動平均（当期を含む過去 `window` 点の平均）を計算した新しい `DataSeries` を返す。

先頭の `window-1` 点は `missing` になる。
ウィンドウ内に欠損値が含まれる場合もその点は `missing` になる。
"""
function moving_average(s::DataSeries; window::Int = 3)
    window >= 1 || throw(ArgumentError("window は 1 以上でなければなりません"))
    window <= length(s) ||
        throw(ArgumentError("window ($window) が系列長 ($(length(s))) を超えています"))

    n = length(s)
    new_vals = Vector{Union{Float64, Missing}}(undef, n)

    for i in 1:n
        if i < window
            new_vals[i] = missing
        else
            window_vals = s.values[(i - window + 1):i]
            if any(ismissing, window_vals)
                new_vals[i] = missing
            else
                new_vals[i] = sum(skipmissing(window_vals)) / window
            end
        end
    end

    meta = deepcopy(s.metadata)
    _append_transform!(meta, "moving_average(window=$window)")
    return DataSeries(
        s.id,
        s.name,
        s.source,
        s.frequency,
        s.unit,
        copy(s.dates),
        new_vals,
        meta,
    )
end

# ---------------------------------------------------------------------------
# 標準化
# ---------------------------------------------------------------------------

"""
    standardize(series) -> DataSeries

z スコア標準化 `(x - mean) / std` を適用した新しい `DataSeries` を返す。

欠損値は計算から除外され、変換後も欠損のまま維持される。
標準偏差が 0 の場合は `DomainError` を投げる。
unit は `"standardized"` に更新される。
"""
function standardize(s::DataSeries)
    nm = nonmissing_values(s)
    isempty(nm) && throw(ArgumentError("非欠損値が存在しないため標準化できません"))

    mu = sum(nm) / length(nm)
    sigma = sqrt(sum((v - mu)^2 for v in nm) / length(nm))
    sigma == 0.0 && throw(DomainError(sigma, "標準偏差が 0 のため標準化できません"))

    new_vals =
        Union{Float64, Missing}[ismissing(v) ? missing : (v - mu) / sigma for v in s.values]

    meta = deepcopy(s.metadata)
    _append_transform!(meta, "standardize(mean=$mu, std=$sigma)")
    return DataSeries(
        s.id,
        s.name,
        s.source,
        s.frequency,
        "standardized",
        copy(s.dates),
        new_vals,
        meta,
    )
end

# ---------------------------------------------------------------------------
# 期間トリミング
# ---------------------------------------------------------------------------

"""
    trim_period(series; start_date=nothing, end_date=nothing) -> DataSeries

日付ラベルを指定して系列をトリミングした新しい `DataSeries` を返す。

- `start_date` のみ指定: 先頭をその日付に揃える
- `end_date` のみ指定  : 末尾をその日付に揃える
- 両方指定             : 指定範囲に切り出す

指定した日付ラベルが系列に存在しない場合は `KeyError` を投げる。
"""
function trim_period(
    s::DataSeries;
    start_date::Union{String, Nothing} = nothing,
    end_date::Union{String, Nothing} = nothing,
)
    i_start = 1
    i_end = length(s)

    if start_date !== nothing
        idx = findfirst(==(start_date), s.dates)
        idx === nothing && throw(KeyError(start_date))
        i_start = idx
    end
    if end_date !== nothing
        idx = findfirst(==(end_date), s.dates)
        idx === nothing && throw(KeyError(end_date))
        i_end = idx
    end

    i_start <= i_end ||
        throw(ArgumentError("start_date は end_date 以前でなければなりません"))

    new_dates = s.dates[i_start:i_end]
    new_values = collect(s.values[i_start:i_end])

    s_str = something(start_date, "")
    e_str = something(end_date, "")
    meta = deepcopy(s.metadata)
    _append_transform!(meta, "trim_period(start=$s_str, end=$e_str)")
    return DataSeries(
        s.id,
        s.name,
        s.source,
        s.frequency,
        s.unit,
        new_dates,
        new_values,
        meta,
    )
end

# ---------------------------------------------------------------------------
# 頻度変換
# ---------------------------------------------------------------------------

"""
    to_quarterly(series; method=:mean) -> DataSeries

月次系列を四半期次に変換した新しい `DataSeries` を返す。

入力の日付形式は `"YYYY-MM"` を想定し、出力は `"YYYY-Qn"` 形式になる。
各四半期の集計方法:
- `method=:mean` : 平均（デフォルト）
- `method=:sum`  : 合計
- `method=:end`  : 期末値（四半期内で最も遅い月の非欠損値）

四半期内に欠損値がある場合は欠損を除いて集計する（`:end` は最も遅い月の非欠損値を採用）。
四半期内がすべて欠損の場合は `missing` を返す。
入力月の順序に依存せず、月番号に基づいて集計する。
"""
function to_quarterly(s::DataSeries; method::Symbol = :mean)
    s.frequency == Monthly ||
        throw(ArgumentError("月次系列が必要です (frequency=$(s.frequency))"))
    method in (:mean, :sum, :end) ||
        throw(ArgumentError("method は :mean, :sum または :end でなければなりません"))

    q_keys = String[]
    # 各四半期を (月番号, 値) の組で保持し、順序不定・期末集計に対応する
    q_groups = Dict{String, Vector{Tuple{Int, Union{Float64, Missing}}}}()

    for (date, val) in zip(s.dates, s.values)
        m = match(r"^(\d{4})-(\d{2})$", date)
        m === nothing && throw(
            ArgumentError("月次日付形式が不正です: '$(date)'. YYYY-MM 形式が必要です"),
        )
        year = m.captures[1]
        mon = parse(Int, m.captures[2])
        qnum = cld(mon, 3)
        key = "$(year)-Q$(qnum)"
        if !haskey(q_groups, key)
            push!(q_keys, key)
            q_groups[key] = Tuple{Int, Union{Float64, Missing}}[]
        end
        push!(q_groups[key], (mon, val))
    end

    new_dates = q_keys
    new_values = Vector{Union{Float64, Missing}}(undef, length(q_keys))
    for (i, key) in enumerate(q_keys)
        pairs = q_groups[key]
        if method === :end
            # 月番号が最大の非欠損値を採用（欠損月は無視）
            sorted = sort(pairs; by = first, rev = true)
            v = missing
            for (_, pv) in sorted
                if !ismissing(pv)
                    v = pv
                    break
                end
            end
            new_values[i] = v
            continue
        end
        non_miss = collect(Float64, skipmissing(p[2] for p in pairs))
        if isempty(non_miss)
            new_values[i] = missing
        elseif method === :mean
            new_values[i] = sum(non_miss) / length(non_miss)
        else
            new_values[i] = sum(non_miss)
        end
    end

    meta = deepcopy(s.metadata)
    _append_transform!(meta, "to_quarterly(method=$method)")
    return DataSeries(
        s.id,
        s.name,
        s.source,
        Quarterly,
        s.unit,
        new_dates,
        new_values,
        meta,
    )
end

"""
    to_annual(series; method=:mean) -> DataSeries

四半期次系列を年次に変換した新しい `DataSeries` を返す。

入力の日付形式は `"YYYY-Qn"` を想定し、出力は `"YYYY"` 形式になる。
各年の集計方法:
- `method=:mean` : 平均（デフォルト）
- `method=:sum`  : 合計

年内に欠損値がある場合は欠損を除いて集計する。
年内がすべて欠損の場合は `missing` を返す。
"""
function to_annual(s::DataSeries; method::Symbol = :mean)
    s.frequency == Quarterly ||
        throw(ArgumentError("四半期次系列が必要です (frequency=$(s.frequency))"))
    method in (:mean, :sum) ||
        throw(ArgumentError("method は :mean または :sum でなければなりません"))

    a_keys = String[]
    a_groups = Dict{String, Vector{Union{Float64, Missing}}}()

    for (date, val) in zip(s.dates, s.values)
        m = match(r"^(\d{4})-Q\d$", date)
        m === nothing && throw(
            ArgumentError("四半期日付形式が不正です: '$(date)'. YYYY-Qn 形式が必要です"),
        )
        year = m.captures[1]
        if !haskey(a_groups, year)
            push!(a_keys, year)
            a_groups[year] = Union{Float64, Missing}[]
        end
        push!(a_groups[year], val)
    end

    new_dates = a_keys
    new_values = Vector{Union{Float64, Missing}}(undef, length(a_keys))
    for (i, key) in enumerate(a_keys)
        non_miss = collect(Float64, skipmissing(a_groups[key]))
        if isempty(non_miss)
            new_values[i] = missing
        elseif method === :mean
            new_values[i] = sum(non_miss) / length(non_miss)
        else
            new_values[i] = sum(non_miss)
        end
    end

    meta = deepcopy(s.metadata)
    _append_transform!(meta, "to_annual(method=$method)")
    return DataSeries(s.id, s.name, s.source, Annual, s.unit, new_dates, new_values, meta)
end
