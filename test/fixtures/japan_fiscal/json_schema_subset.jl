# json_schema_subset.jl: JSON Schema（draft 2020-12）のうち、DME が所有する Japan fiscal scenario の
# schema（schemas/japan-fiscal-scenario-*.schema.json、Issue #277）が使うキーワードだけを解釈する
# 最小 validator（テスト専用）。
#
# DME の src は汎用 JSON Schema バリデータを持たない（ADR 0008・0016 の doctrine）。一方で consumer
# （Market Analyzer）は Julia 型なしに schema だけで artifact を decode する。schema と DME の実際の
# 出力が乖離していないことを CI で検査するため、テスト側でこの最小 validator を用いる。
#
# 対応キーワード: `$ref`（`#/$defs/...` のみ）・`type`・`enum`・`const`・`properties`・`required`・
# `additionalProperties`・`propertyNames`・`items`・`oneOf`・`pattern`・`minItems`・`minLength`・`minimum`。
# 注釈（`$schema`・`$id`・`$defs`・`title`・`description`・`x-*`）は無視する。これ以外のキーワードが
# schema に現れた場合は `jf_schema_unsupported_keywords` が列挙し、テストが失敗する（黙って無視しない）。

const JF_SCHEMA_DIR = normpath(joinpath(@__DIR__, "..", "..", "..", "schemas"))

const _JF_SCHEMA_ASSERTIONS = Set([
    "\$ref",
    "type",
    "enum",
    "const",
    "properties",
    "required",
    "additionalProperties",
    "propertyNames",
    "items",
    "oneOf",
    "pattern",
    "minItems",
    "minLength",
    "minimum",
])
const _JF_SCHEMA_ANNOTATIONS = Set(["\$schema", "\$id", "\$defs", "title", "description"])

jf_load_schema(name::AbstractString) =
    DME._jf_json_to_plain(DME.JSON3.read(read(joinpath(JF_SCHEMA_DIR, name), String)))

"schema の全ノードを辿り、対応していないキーワードを `\"<位置>: <キーワード>\"` の形で返す。"
function jf_schema_unsupported_keywords(schema::AbstractDict)
    out = String[]
    function walk(node, path)
        node isa AbstractDict || return
        for k in keys(node)
            if !(k in _JF_SCHEMA_ASSERTIONS || k in _JF_SCHEMA_ANNOTATIONS || startswith(k, "x-"))
                push!(out, "$(path): $(k)")
            end
        end
        for key in ("items", "propertyNames")
            haskey(node, key) && walk(node[key], "$(path).$(key)")
        end
        ap = get(node, "additionalProperties", nothing)
        ap isa AbstractDict && walk(ap, "$(path).additionalProperties")
        for (name, sub) in get(node, "properties", Dict{String, Any}())
            walk(sub, "$(path).properties.$(name)")
        end
        for (name, sub) in get(node, "\$defs", Dict{String, Any}())
            walk(sub, "$(path).\$defs.$(name)")
        end
        for (i, sub) in enumerate(get(node, "oneOf", Any[]))
            walk(sub, "$(path).oneOf[$(i)]")
        end
    end
    walk(schema, "\$")
    return out
end

function _jf_schema_resolve(node, root)
    while node isa AbstractDict && haskey(node, "\$ref")
        ref = node["\$ref"]
        startswith(ref, "#/\$defs/") || error("未対応の \$ref: $(ref)")
        node = root["\$defs"][ref[9:end]]
    end
    return node
end

_jf_schema_is_number(x) = x isa Real && !(x isa Bool)

function _jf_schema_type_ok(t::AbstractString, x)
    t == "object" && return x isa AbstractDict
    t == "array" && return x isa AbstractVector
    t == "string" && return x isa AbstractString
    t == "integer" && return (x isa Integer && !(x isa Bool)) || (x isa AbstractFloat && isinteger(x))
    t == "number" && return _jf_schema_is_number(x)
    t == "boolean" && return x isa Bool
    t == "null" && return x === nothing
    error("未対応の type: $(t)")
end

function _jf_json_eq(a, b)
    _jf_schema_is_number(a) && _jf_schema_is_number(b) && return a == b
    (a isa Bool || b isa Bool) && return a === b
    if a isa AbstractDict && b isa AbstractDict
        return Set(keys(a)) == Set(keys(b)) && all(_jf_json_eq(a[k], b[k]) for k in keys(a))
    end
    if a isa AbstractVector && b isa AbstractVector
        return length(a) == length(b) && all(_jf_json_eq(x, y) for (x, y) in zip(a, b))
    end
    return isequal(a, b)
end

function _jf_schema_check!(errs::Vector{String}, raw, x, path::String, root)
    node = _jf_schema_resolve(raw, root)
    if haskey(node, "oneOf")
        n_ok = count(b -> isempty(jf_schema_errors(b, x, root; path = path)), node["oneOf"])
        n_ok == 1 || push!(errs, "$(path): oneOf の $(n_ok) 個の分岐に一致（ちょうど 1 個でなければならない）")
    end
    if haskey(node, "type")
        ts = node["type"] isa AbstractVector ? node["type"] : [node["type"]]
        if !any(t -> _jf_schema_type_ok(t, x), ts)
            push!(errs, "$(path): type $(ts) に一致しません（実値: $(repr(x))）")
            return errs
        end
    end
    haskey(node, "const") && !_jf_json_eq(node["const"], x) &&
        push!(errs, "$(path): const $(repr(node["const"])) と一致しません（実値: $(repr(x))）")
    haskey(node, "enum") && !any(e -> _jf_json_eq(e, x), node["enum"]) &&
        push!(errs, "$(path): enum に含まれません（実値: $(repr(x))）")
    if x isa AbstractString
        haskey(node, "minLength") && length(x) < node["minLength"] &&
            push!(errs, "$(path): minLength $(node["minLength"]) 未満")
        haskey(node, "pattern") && !occursin(Regex(node["pattern"]), x) &&
            push!(errs, "$(path): pattern $(node["pattern"]) に一致しません（実値: $(repr(x))）")
    end
    if _jf_schema_is_number(x) && haskey(node, "minimum") && x < node["minimum"]
        push!(errs, "$(path): minimum $(node["minimum"]) 未満（実値: $(x)）")
    end
    if x isa AbstractVector
        haskey(node, "minItems") && length(x) < node["minItems"] &&
            push!(errs, "$(path): minItems $(node["minItems"]) 未満")
        if haskey(node, "items")
            for (i, v) in enumerate(x)
                _jf_schema_check!(errs, node["items"], v, "$(path)[$(i)]", root)
            end
        end
    end
    if x isa AbstractDict
        for k in get(node, "required", Any[])
            haskey(x, k) || push!(errs, "$(path): 必須キー $(k) がありません")
        end
        props = get(node, "properties", Dict{String, Any}())
        ap = get(node, "additionalProperties", true)
        for (k, v) in x
            if haskey(props, k)
                _jf_schema_check!(errs, props[k], v, "$(path).$(k)", root)
            elseif ap === false
                push!(errs, "$(path): 未知のキー $(k)")
            elseif ap isa AbstractDict
                _jf_schema_check!(errs, ap, v, "$(path).$(k)", root)
            end
            if haskey(node, "propertyNames")
                _jf_schema_check!(errs, node["propertyNames"], String(k), "$(path){$(k)}", root)
            end
        end
    end
    return errs
end

"""
    jf_schema_errors(schema, doc, root=schema; path="\$") -> Vector{String}

`doc` を `schema` で検証し、違反の一覧を返す（空なら適合）。
"""
jf_schema_errors(schema, doc, root = schema; path::String = "\$") =
    _jf_schema_check!(String[], schema, doc, path, root)
