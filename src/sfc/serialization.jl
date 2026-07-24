# SFC 会計プリミティブの JSON シリアライズ / デシリアライズ
#
# 規約:
#   - `to_dict(x)` は String キーの `Dict{String,Any}` を返し、`to_json(x)` は
#     `JSON3.write(to_dict(x))`。復元は `sfc_result_from_dict` / `sfc_result_from_json` /
#     `load_sfc_result`。round-trip（保存→復元→再保存で一致）をテストで保証する。
#   - sector・instrument・transaction の順序は型側で stable id 昇順に正準化済みのため、
#     配列として出力すれば決定的になる。
#   - 非有限値（NaN / Inf / -Inf）は文字列タグへ符号化して round-trip で失われないようにする。
#     これが「非有限値を保存・説明する規約」（Issue #146）。metadata / provenance 内の
#     自由記述 float も同じ符号化を通す（ただし復元時は文字列のまま残り、型付き float 場のみ
#     数値へ復元する）。

# ---------------------------------------------------------------------------
# 非有限値の符号化・復号
# ---------------------------------------------------------------------------

"""非有限 Float を文字列タグへ、有限 Float はそのまま返す。"""
_sfc_encode_float(x::Real) =
    isfinite(x) ? Float64(x) : (isnan(x) ? "NaN" : (x > 0 ? "Inf" : "-Inf"))

"""文字列タグ / 数値を Float64 へ復号する。"""
_sfc_decode_float(x::Real) = Float64(x)
function _sfc_decode_float(x::AbstractString)
    x == "NaN" && return NaN
    x == "Inf" && return Inf
    x == "-Inf" && return -Inf
    return parse(Float64, x)
end

_sfc_encode_row(v) = Any[_sfc_encode_float(x) for x in v]
_sfc_encode_matrix(M::AbstractMatrix) =
    Any[_sfc_encode_row(@view M[r, :]) for r in 1:size(M, 1)]

function _sfc_decode_matrix(rows, nrows::Int, ncols::Int)
    M = Matrix{Float64}(undef, nrows, ncols)
    length(rows) == nrows ||
        throw(ArgumentError("行数 $(length(rows)) が期待値 $nrows と一致しません"))
    for r in 1:nrows
        row = rows[r]
        length(row) == ncols || throw(
            ArgumentError("行 $r の要素数 $(length(row)) が期待値 $ncols と一致しません"),
        )
        for c in 1:ncols
            M[r, c] = _sfc_decode_float(row[c])
        end
    end
    return M
end

# 自由記述の metadata / provenance を JSON ネイティブへ正規化（Symbol→String, NamedTuple→Dict）。
_sfc_jsonify(x::Bool) = x
_sfc_jsonify(x::Integer) = x
_sfc_jsonify(x::AbstractFloat) = _sfc_encode_float(x)
_sfc_jsonify(x::AbstractString) = String(x)
_sfc_jsonify(x::Symbol) = String(x)
_sfc_jsonify(::Nothing) = nothing
_sfc_jsonify(x::AbstractVector) = Any[_sfc_jsonify(v) for v in x]
_sfc_jsonify(x::Tuple) = Any[_sfc_jsonify(v) for v in x]
_sfc_jsonify(x::NamedTuple) =
    Dict{String, Any}(String(k) => _sfc_jsonify(v) for (k, v) in pairs(x))
_sfc_jsonify(x::AbstractDict) =
    Dict{String, Any}(string(k) => _sfc_jsonify(v) for (k, v) in x)
_sfc_jsonify(x) = x

# パース済み JSON（JSON3.Object / Array）を素の Dict / Vector へ変換。
_sfc_to_plain(x::AbstractDict) =
    Dict{String, Any}(string(k) => _sfc_to_plain(v) for (k, v) in x)
_sfc_to_plain(x::AbstractVector) = Any[_sfc_to_plain(v) for v in x]
_sfc_to_plain(x) = x

# Dict / JSON3.Object の双方に対応するアクセサ。
_sfc_get(d::AbstractDict, k::AbstractString) = haskey(d, k) ? d[k] : d[Symbol(k)]
_sfc_get(d, k::AbstractString) = getproperty(d, Symbol(k))
_sfc_has(d::AbstractDict, k::AbstractString) = haskey(d, k) || haskey(d, Symbol(k))
_sfc_has(d, k::AbstractString) = haskey(d, Symbol(k))

# ---------------------------------------------------------------------------
# to_dict（`to_dict` 総称関数へメソッドを追加）
# ---------------------------------------------------------------------------

to_dict(s::SFCSector) = Dict{String, Any}(
    "id" => String(s.id),
    "name" => s.name,
    "sector_type" => String(s.sector_type),
    "metadata" => _sfc_jsonify(s.metadata),
)

to_dict(i::SFCInstrument) = Dict{String, Any}(
    "id" => String(i.id),
    "name" => i.name,
    "issuers" => String[String(x) for x in i.issuers],
    "holders" => String[String(x) for x in i.holders],
    "unit" => i.unit,
    "metadata" => _sfc_jsonify(i.metadata),
)

to_dict(bs::BalanceSheetMatrix) = Dict{String, Any}(
    "instruments" => String[String(x) for x in bs.instruments],
    "sectors" => String[String(x) for x in bs.sectors],
    "holdings" => _sfc_encode_matrix(bs.holdings),
)

to_dict(tf::TransactionFlowMatrix) = Dict{String, Any}(
    "transactions" => String[String(x) for x in tf.transactions],
    "sectors" => String[String(x) for x in tf.sectors],
    "flows" => _sfc_encode_matrix(tf.flows),
)

to_dict(snap::SFCPeriodSnapshot) = Dict{String, Any}(
    "period" => snap.period,
    "balance_sheet" => to_dict(snap.balance_sheet),
    "transaction_flow" => to_dict(snap.transaction_flow),
    "valuation_adjustment" => to_dict(snap.valuation_adjustment),
    "warnings" => String[String(w) for w in snap.warnings],
)

to_dict(m::SFCMethodologyMetadata) = Dict{String, Any}(
    "contract_version" => m.contract_version,
    "model_version" => m.model_version,
    "sign_convention" => String(m.sign_convention),
    "time_convention" => String(m.time_convention),
    "tolerance_abs" => _sfc_encode_float(m.tolerance_abs),
    "tolerance_rel" => _sfc_encode_float(m.tolerance_rel),
    "provenance" => _sfc_jsonify(m.provenance),
)

_sfc_simresult_to_dict(sr::SimulationResult) = Dict{String, Any}(
    "model_name" => sr.model_name,
    "scenario_name" => sr.scenario_name,
    "variables" =>
        Dict{String, Any}(string(k) => _sfc_encode_row(v) for (k, v) in sr.variables),
    "metadata" => _sfc_jsonify(sr.metadata),
)

to_dict(r::SFCResult) = Dict{String, Any}(
    "contract_version" => SFC_CONTRACT_VERSION,
    "model_name" => r.model_name,
    "scenario_name" => r.scenario_name,
    "sectors" => Any[to_dict(s) for s in r.sectors],
    "instruments" => Any[to_dict(i) for i in r.instruments],
    "snapshots" => Any[to_dict(s) for s in r.snapshots],
    "simulation_result" =>
        r.simulation_result === nothing ? nothing :
        _sfc_simresult_to_dict(r.simulation_result),
    "methodology" => to_dict(r.methodology),
    "warnings" => String[String(w) for w in r.warnings],
    "metadata" => _sfc_jsonify(r.metadata),
)

# to_json（`to_json` 総称関数へメソッドを追加）
to_json(x::SFCSector) = JSON3.write(to_dict(x))
to_json(x::SFCInstrument) = JSON3.write(to_dict(x))
to_json(x::BalanceSheetMatrix) = JSON3.write(to_dict(x))
to_json(x::TransactionFlowMatrix) = JSON3.write(to_dict(x))
to_json(x::SFCPeriodSnapshot) = JSON3.write(to_dict(x))
to_json(x::SFCMethodologyMetadata) = JSON3.write(to_dict(x))
to_json(x::SFCResult) = JSON3.write(to_dict(x))

# ---------------------------------------------------------------------------
# from_dict（復元）
# ---------------------------------------------------------------------------

sfc_sector_from_dict(d) = SFCSector(
    Symbol(_sfc_get(d, "id")),
    String(_sfc_get(d, "name")),
    Symbol(_sfc_get(d, "sector_type")),
    _sfc_to_plain(_sfc_get(d, "metadata")),
)

sfc_instrument_from_dict(d) = SFCInstrument(
    Symbol(_sfc_get(d, "id")),
    String(_sfc_get(d, "name")),
    Symbol[Symbol(x) for x in _sfc_get(d, "issuers")],
    Symbol[Symbol(x) for x in _sfc_get(d, "holders")],
    String(_sfc_get(d, "unit")),
    _sfc_to_plain(_sfc_get(d, "metadata")),
)

function balance_sheet_from_dict(d)
    inst = Symbol[Symbol(x) for x in _sfc_get(d, "instruments")]
    sect = Symbol[Symbol(x) for x in _sfc_get(d, "sectors")]
    H = _sfc_decode_matrix(_sfc_get(d, "holdings"), length(inst), length(sect))
    return BalanceSheetMatrix(inst, sect, H)
end

function transaction_flow_from_dict(d)
    tx = Symbol[Symbol(x) for x in _sfc_get(d, "transactions")]
    sect = Symbol[Symbol(x) for x in _sfc_get(d, "sectors")]
    F = _sfc_decode_matrix(_sfc_get(d, "flows"), length(tx), length(sect))
    return TransactionFlowMatrix(tx, sect, F)
end

sfc_snapshot_from_dict(d) = SFCPeriodSnapshot(
    String(_sfc_get(d, "period")),
    balance_sheet_from_dict(_sfc_get(d, "balance_sheet")),
    transaction_flow_from_dict(_sfc_get(d, "transaction_flow")),
    balance_sheet_from_dict(_sfc_get(d, "valuation_adjustment")),
    String[String(w) for w in _sfc_get(d, "warnings")],
)

sfc_methodology_from_dict(d) = SFCMethodologyMetadata(
    String(_sfc_get(d, "contract_version")),
    String(_sfc_get(d, "model_version")),
    Symbol(_sfc_get(d, "sign_convention")),
    Symbol(_sfc_get(d, "time_convention")),
    _sfc_decode_float(_sfc_get(d, "tolerance_abs")),
    _sfc_decode_float(_sfc_get(d, "tolerance_rel")),
    _sfc_to_plain(_sfc_get(d, "provenance")),
)

function _sfc_simresult_from_dict(d)
    vars = Dict{String, Vector{Float64}}()
    for (k, v) in _sfc_get(d, "variables")
        vars[string(k)] = Float64[_sfc_decode_float(x) for x in v]
    end
    return SimulationResult(
        String(_sfc_get(d, "model_name")),
        String(_sfc_get(d, "scenario_name")),
        vars,
        _sfc_to_plain(_sfc_get(d, "metadata")),
    )
end

"""
    sfc_result_from_dict(d) -> SFCResult

`to_dict(::SFCResult)` 相当の Dict / `JSON3.Object` から `SFCResult` を復元する。
"""
function sfc_result_from_dict(d)
    sectors = SFCSector[sfc_sector_from_dict(x) for x in _sfc_get(d, "sectors")]
    instruments =
        SFCInstrument[sfc_instrument_from_dict(x) for x in _sfc_get(d, "instruments")]
    snapshots =
        SFCPeriodSnapshot[sfc_snapshot_from_dict(x) for x in _sfc_get(d, "snapshots")]
    sr_raw = _sfc_has(d, "simulation_result") ? _sfc_get(d, "simulation_result") : nothing
    simres = sr_raw === nothing ? nothing : _sfc_simresult_from_dict(sr_raw)
    methodology = sfc_methodology_from_dict(_sfc_get(d, "methodology"))
    warnings = String[String(w) for w in _sfc_get(d, "warnings")]
    metadata = _sfc_to_plain(_sfc_get(d, "metadata"))
    return SFCResult(
        String(_sfc_get(d, "model_name")),
        String(_sfc_get(d, "scenario_name")),
        sectors,
        instruments,
        snapshots,
        simres,
        methodology,
        warnings,
        metadata,
    )
end

"""
    sfc_result_from_json(s::AbstractString) -> SFCResult

JSON 文字列から `SFCResult` を復元する。
"""
sfc_result_from_json(s::AbstractString) = sfc_result_from_dict(JSON3.read(s))

# ---------------------------------------------------------------------------
# 保存 / 読み込み
# ---------------------------------------------------------------------------

"""
    save_sfc_result(path::AbstractString, r::SFCResult) -> String

`SFCResult` を整形 JSON としてファイルへ保存し、保存パスを返す。
"""
function save_sfc_result(path::AbstractString, r::SFCResult)
    open(path, "w") do io
        JSON3.pretty(io, to_dict(r))
    end
    return path
end

"""
    load_sfc_result(path::AbstractString) -> SFCResult

`save_sfc_result` で保存した JSON ファイルを読み込み `SFCResult` を復元する。
"""
load_sfc_result(path::AbstractString) = sfc_result_from_dict(JSON3.read(read(path, String)))
