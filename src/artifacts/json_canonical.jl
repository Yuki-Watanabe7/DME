# RFC 8785 JSON Canonicalization Scheme (JCS) の限定実装。
#
# 汎用 JSON 実装ではなく、DME の real-rate model artifact ドメイン値
# （`Dict{<:AbstractString,<:Any}` のキーは ASCII のみ、値は有限 `AbstractFloat` /
#  `Integer` / `AbstractString` / `Bool` / `Nothing` / `AbstractVector` / `AbstractDict`
#  の入れ子）に限定して正しく動作する実装。
#
# 規約:
#   - オブジェクトキーは Unicode コードポイント順にソートする。DME 側が生成するキーは
#     ASCII のみという前提を `_jcs_check_key_ascii` で強制するため、これは RFC 8785 が
#     要求する UTF-16 コードユニット順ソートと一致する。
#   - 数値は ECMAScript `Number::toString`（`JSON.stringify` が使う表現）と同じ書式で
#     出力する。Julia の `string(::Float64)` が返す最短往復表現（有効数字列）を解析し、
#     ECMAScript の書式規則で再フォーマットする（Julia 自身の科学的記法/固定表記の
#     選択とは独立に、常に正しい表記を導出する）。
#   - 文字列は RFC 8259 の最小エスケープ（`"` `\` 制御文字のみ）で UTF-8 のまま出力する。
#   - 配列の順序はそのまま保持する（正準化しない）。安定順序化（例: observation_id 昇順）
#     は呼び出し側＝各型のコンストラクタの責務。
#   - NaN / Infinity の混入は `ArgumentError` で拒否する。

"""
    canonical_json_bytes(value) -> Vector{UInt8}

RFC 8785 JSON Canonicalization Scheme (JCS) に従い、`value` を正準 JSON バイト列へ変換する。
`value` は `Dict{<:AbstractString,<:Any}` / `AbstractVector` / `AbstractString` / `Bool` /
`Integer` / `AbstractFloat` / `Nothing` の入れ子のみをサポートする。
"""
function canonical_json_bytes(value)
    io = IOBuffer()
    _jcs_write(io, value)
    return take!(io)
end

"""`canonical_json_bytes` の結果を `String` として返す。"""
canonical_json_string(value)::String = String(canonical_json_bytes(value))

"""正準 JSON バイト列の SHA-256 を小文字16進文字列で返す。"""
sha256_hex_of_canonical(value)::String = bytes2hex(SHA.sha256(canonical_json_bytes(value)))

# ---------------------------------------------------------------------------
# 値の書き出し
# ---------------------------------------------------------------------------

_jcs_write(io::IO, ::Nothing) = print(io, "null")
_jcs_write(io::IO, x::Bool) = print(io, x ? "true" : "false")
_jcs_write(io::IO, x::Integer) = print(io, string(x))
_jcs_write(io::IO, s::AbstractString) = _jcs_write_string(io, s)

function _jcs_write(io::IO, x::AbstractFloat)
    isfinite(x) ||
        throw(ArgumentError("JCS は非有限浮動小数点数 (NaN/Inf) を許容しません: $x"))
    _jcs_write_number(io, Float64(x))
    return nothing
end

function _jcs_write(io::IO, v::AbstractVector)
    print(io, "[")
    for (i, x) in enumerate(v)
        i > 1 && print(io, ",")
        _jcs_write(io, x)
    end
    print(io, "]")
    return nothing
end

function _jcs_write(io::IO, d::AbstractDict)
    ks = collect(keys(d))
    for k in ks
        k isa AbstractString || throw(
            ArgumentError("JCS オブジェクトのキーは文字列である必要があります: $(repr(k))"),
        )
        _jcs_check_key_ascii(k)
    end
    sorted_keys = sort(ks)
    print(io, "{")
    for (i, k) in enumerate(sorted_keys)
        i > 1 && print(io, ",")
        _jcs_write_string(io, k)
        print(io, ":")
        _jcs_write(io, d[k])
    end
    print(io, "}")
    return nothing
end

_jcs_write(::IO, x) =
    throw(ArgumentError("canonical_json_bytes がサポートしない型です: $(typeof(x))"))

function _jcs_check_key_ascii(k::AbstractString)
    isascii(k) ||
        throw(ArgumentError("JCS オブジェクトキーは ASCII のみサポートします: $(repr(k))"))
    return nothing
end

# ---------------------------------------------------------------------------
# 文字列エスケープ (RFC 8259 最小エスケープ)
# ---------------------------------------------------------------------------

function _jcs_write_string(io::IO, s::AbstractString)
    print(io, '"')
    for c in s
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '\b'
            print(io, "\\b")
        elseif c == '\f'
            print(io, "\\f")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\t'
            print(io, "\\t")
        elseif codepoint(c) < 0x20
            print(io, "\\u", lpad(string(UInt32(c); base = 16), 4, '0'))
        else
            print(io, c)
        end
    end
    print(io, '"')
    return nothing
end

# ---------------------------------------------------------------------------
# 数値フォーマット (ECMAScript Number::toString 相当)
# ---------------------------------------------------------------------------

function _jcs_write_number(io::IO, x::Float64)
    if x == 0.0
        print(io, "0")  # -0.0 も "0" に正規化する（RFC 8785 §3.2.2.3）
        return nothing
    end
    negative = x < 0.0
    ax = abs(x)
    digits, n = _jcs_shortest_digits_and_exponent(ax)
    negative && print(io, "-")
    _jcs_write_ecma_digits(io, digits, n)
    return nothing
end

"""
Julia の最短往復表現 (`string(::Float64)`) を解析し、有効数字文字列 `digits`
（先頭・末尾ゼロを除いた10進表現、長さ `k`）と ECMAScript の exponent 変数 `n`
（`parse(BigInt, digits) * 10.0^(n - k) == ax` が成り立つ）を返す。
`ax` は正の有限値である前提。
"""
function _jcs_shortest_digits_and_exponent(ax::Float64)
    s = string(ax)  # "D.DDD" または "D.DDDeNN" / "D.DDDe-NN" の形式（ax > 0 前提）
    mantissa, exp_from_str = _jcs_split_exponent(s)
    int_part, frac_part = _jcs_split_decimal_point(mantissa)

    if int_part != "0"
        raw = int_part * frac_part
        digits = _jcs_strip_trailing_zeros(raw)
        isempty(digits) && (digits = "0")
        n = length(int_part) + exp_from_str
    else
        lead = 0
        while lead < length(frac_part) && frac_part[lead + 1] == '0'
            lead += 1
        end
        raw = frac_part[(lead + 1):end]
        digits = _jcs_strip_trailing_zeros(raw)
        n = -lead + exp_from_str
    end
    return digits, n
end

function _jcs_split_exponent(s::AbstractString)
    idx = findfirst(==('e'), s)
    idx === nothing && return s, 0
    return s[1:(idx - 1)], parse(Int, s[(idx + 1):end])
end

function _jcs_split_decimal_point(s::AbstractString)
    idx = findfirst(==('.'), s)
    idx === nothing && return s, ""
    return s[1:(idx - 1)], s[(idx + 1):end]
end

function _jcs_strip_trailing_zeros(s::AbstractString)
    last_nonzero = length(s)
    while last_nonzero > 0 && s[last_nonzero] == '0'
        last_nonzero -= 1
    end
    return s[1:last_nonzero]
end

"""
`digits`（先頭・末尾ゼロなしの有効数字列、長さ `k`）と `n`
（`value = parse(BigInt, digits) * 10.0^(n - k)` を満たす整数）から、
ECMAScript `Number::toString` の書式（`JSON.stringify` が使う表現）で出力する。
"""
function _jcs_write_ecma_digits(io::IO, digits::AbstractString, n::Int)
    k = length(digits)
    if k <= n <= 21
        print(io, digits)
        print(io, "0"^(n - k))
    elseif 0 < n <= 21
        print(io, digits[1:n])
        print(io, ".")
        print(io, digits[(n + 1):end])
    elseif -6 < n <= 0
        print(io, "0.")
        print(io, "0"^(-n))
        print(io, digits)
    else
        print(io, digits[1:1])
        if k > 1
            print(io, ".")
            print(io, digits[2:end])
        end
        e = n - 1
        print(io, "e", e >= 0 ? "+" : "", string(e))
    end
    return nothing
end
