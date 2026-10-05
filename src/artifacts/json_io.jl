# JSON の読み書きを 1 か所に寄せる薄いヘルパ（Issue #300）。
#
# DME は JSON3.jl（General registry で deprecated）から JSON.jl 1.x へ移行した。呼び出し側は
# `JSON.parse` / `JSON.json` を直接呼ばず、このファイルの関数を経由する。
# 正準 JSON（RFC 8785）は `json_canonical.jl` の自前実装で、ここには依存しない。artifact の
# content hash は正準 JSON の bytes から計算するため、ここでの書式（キー順・空白・空コンテナの
# 表記）は hash に影響しない。
#
# JSON3.jl からの差分（移行時に全テストで新旧を突き合わせて確認した）:
#   - `json_read` は末尾に余分な文字がある入力を拒否する（JSON3 は先頭の値だけを読んで黙って
#     受理していた）。LLM 応答 parser は `json_read_first` で従来どおり先頭の値だけを読む。
#   - `1.0` は `Float64` として読む（JSON3 は `Int` に丸めていた）。
#   - 読み込み結果は `JSON.Object{String,Any}`（キーは `String`、`obj.key` / `obj[:key]` /
#     `haskey(obj, :key)` も使える）。`Dict{String,Any}` が要る箇所は型を渡す。
#   - 空の `Vector{Union{}}` は `[]` でなく `{}` と書かれるため、空になりうる配列は要素型を
#     明示して作る。

import JSON

"""
    json_read(s) -> JSON.Object{String,Any} / Vector{Any} / scalar
    json_read(s, Dict{String,Any}) -> Dict{String,Any}

JSON 文字列（または bytes）を読む。末尾に余分な文字があれば `ArgumentError`。型を渡した場合は
トップレベルが object でなければ `ArgumentError`。
"""
json_read(s) = JSON.parse(s)

function json_read(s, ::Type{Dict{String, Any}})
    r = JSON.parse(s; dicttype = Dict{String, Any})
    r isa Dict{String, Any} ||
        throw(ArgumentError("JSON のトップレベルが object ではありません"))
    return r
end

"""
    json_write(x) -> String

`x` をコンパクトな JSON 文字列にする。`NaN` / `Inf` は `ArgumentError`。
"""
json_write(x)::String = JSON.json(x)

"""
    json_pretty(io::IO, x)

`x` を 4 スペースインデントの JSON として `io` へ書き出す。
"""
function json_pretty(io::IO, x)
    JSON.json(io, x; pretty = 4)
    return nothing
end

"""
    json_read_first(s::AbstractString) -> Dict{String,Any}

先頭の JSON object（または array）だけを読み、その後ろの文字列を無視する。LLM の応答は JSON の
後ろに説明文が付くことがあり、JSON3.jl は先頭の値だけを読んでいたため、その挙動を応答 parser
のために保つ。artifact など厳密に読むべき入力には使わない（`json_read` を使う）。
"""
function json_read_first(s::AbstractString)
    str = String(s)
    i = firstindex(str)
    n = lastindex(str)
    while i <= n && isspace(str[i])
        i = nextind(str, i)
    end
    (i <= n && str[i] in ('{', '[')) || return json_read(str, Dict{String, Any})
    depth = 0
    in_string = false
    escaped = false
    j = i
    while j <= n
        c = str[j]
        if in_string
            if escaped
                escaped = false
            elseif c == '\\'
                escaped = true
            elseif c == '"'
                in_string = false
            end
        elseif c == '"'
            in_string = true
        elseif c == '{' || c == '['
            depth += 1
        elseif c == '}' || c == ']'
            depth -= 1
            depth == 0 && return json_read(str[i:j], Dict{String, Any})
        end
        j = nextind(str, j)
    end
    return json_read(str, Dict{String, Any})
end
