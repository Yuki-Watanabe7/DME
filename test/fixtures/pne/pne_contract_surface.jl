# pne_contract_surface.jl: vendor した PNE schema から「DME が依拠する契約面（contract surface）」を
# 抽出し、schema 駆動の mutation probe を生成するテスト用ヘルパ（Issue #283 / `PN-3`、drift 検出）。
#
# test/test_pne_cross_repo_e2e.jl と test/fixtures/pne/regenerate.jl の両方が include する。
#
# DME の受理層（src/scenarios/pne_sector_output_path.jl）は汎用 JSON Schema バリデータを持たず、
# schema の制約を Julia で個別に再実装している（ADR 0008・ADR 0024 決定 3）。その再実装が vendor した
# schema から黙って乖離しないよう、テスト側で schema を機械的に読み、
#
#   1. contract surface（必須キー・閉じた語彙・固定値・数値範囲・文字列制約・x-semantic-invariants）を
#      golden（golden/pne_contract_surface_v1.json）として固定する。PNE 側の schema を再 vendor した
#      ときに差分が出れば、DME の再実装を見直すまでテストが失敗する。
#   2. surface の各制約から「1 事実だけを破った文書」を生成し、DME の decoder がすべて拒否する
#      ことを検査する（mutation probe）。
#
# ここで行うのは schema の**読み取り**だけであり、src に汎用バリデータを置かない方針は変えない。

const PNE_SCHEMA_PATH = normpath(
    joinpath(@__DIR__, "..", "..", "..", "docs", "contract", "pne", "production-network-sector-output-path-v1.schema.json"),
)

"vendor した PNE schema を plain `Dict` として読む。"
pne_vendored_schema() = DME._scenario_json_to_plain(DME.json_read(read(PNE_SCHEMA_PATH, String)))

function _pne_surface_resolve(node::AbstractDict, defs::AbstractDict)
    haskey(node, "\$ref") || return node
    return defs[String(last(split(node["\$ref"], "/")))]
end

const _PNE_SURFACE_SCALAR_KEYS =
    ("const", "enum", "minimum", "maximum", "minLength", "maxLength", "pattern", "minItems", "maxItems")

"""
    pne_contract_surface(schema) -> Dict{String,Any}

schema を根から辿り、各位置（`\$` が根、`.key` がプロパティ、`[]` が配列要素、`{}` が map の値）の
型と制約を平坦な辞書にする。`\$ref`・`anyOf`（null 許容）を解決する。`title`・`description`・
`default`・`format`（2020-12 では注釈）は契約面に含めない。
"""
function pne_contract_surface(schema::AbstractDict)
    defs = schema["\$defs"]
    nodes = Dict{String, Any}()
    function walk(raw, path::String)
        node = _pne_surface_resolve(raw, defs)
        nullable = false
        if haskey(node, "anyOf")
            branches = [_pne_surface_resolve(b, defs) for b in node["anyOf"]]
            nonnull = [b for b in branches if get(b, "type", nothing) != "null"]
            nullable = length(nonnull) < length(branches)
            length(nonnull) == 1 || error("contract surface: $(path) の anyOf は 1 つの非 null 型でなければなりません")
            node = nonnull[1]
        end
        rec = Dict{String, Any}("type" => node["type"])
        nullable && (rec["nullable"] = true)
        for k in _PNE_SURFACE_SCALAR_KEYS
            haskey(node, k) && (rec[k] = node[k])
        end
        if node["type"] == "object"
            props = get(node, "properties", Dict{String, Any}())
            rec["properties"] = sort(collect(keys(props)))
            rec["required"] = sort(collect(get(node, "required", Any[])))
            ap = get(node, "additionalProperties", true)
            if ap === false
                rec["additional_properties"] = false
            elseif ap isa AbstractDict
                rec["additional_properties"] = "map"
                walk(ap, path * "{}")
            end
            if haskey(node, "propertyNames")
                rec["property_names_enum"] = _pne_surface_resolve(node["propertyNames"], defs)["enum"]
            end
            for k in rec["properties"]
                walk(props[k], path * "." * k)
            end
        elseif node["type"] == "array"
            walk(node["items"], path * "[]")
        end
        nodes[path] = rec
        return nothing
    end
    walk(schema, "\$")
    return Dict{String, Any}(
        "contract_version" => schema["x-contract-version"],
        "schema_id" => schema["\$id"],
        "semantic_invariants" => schema["x-semantic-invariants"],
        "nodes" => nodes,
    )
end

# ---------------------------------------------------------------------------
# mutation probe
# ---------------------------------------------------------------------------

"surface の位置を文書上の具体的な位置（親コンテナとキー / index）の列へ解決する。無ければ `nothing`。"
function _pne_surface_locate(doc, path::String)
    tokens = String[]
    for m in eachmatch(r"\.([A-Za-z0-9_]+)|(\[\])|(\{\})", path[2:end])
        push!(tokens, m.match)
    end
    parent = nothing
    key = nothing
    cur = doc
    for t in tokens
        parent = cur
        if t == "[]"
            (cur isa AbstractVector && !isempty(cur)) || return nothing
            key = 1
        elseif t == "{}"
            (cur isa AbstractDict && !isempty(cur)) || return nothing
            key = first(sort(collect(keys(cur))))
        else
            (cur isa AbstractDict && haskey(cur, t[2:end])) || return nothing
            key = t[2:end]
        end
        cur = parent[key]
    end
    return (parent = parent, key = key, value = cur)
end

"位置 `path` の最後の名前（エラーメッセージに現れることを期待する断片）。"
function _pne_surface_label(path::String)
    m = collect(eachmatch(r"\.([A-Za-z0-9_]+)", path))
    return isempty(m) ? "" : m[end].captures[1]
end

_pne_wrong_type_value(t) =
    t == "string" ? 12345 :
    t in ("number", "integer") ? "1" :
    t == "boolean" ? "true" :
    t == "array" ? Dict{String, Any}("dme_drift_probe" => 1) :
    t == "object" ? Any["dme_drift_probe"] :
    t == "null" ? "dme_drift_probe" : error("unknown type $(t)")

function _pne_other_const(c)
    c isa Bool && return !c
    c isa Integer && return c + 1
    c isa AbstractString && return c * "_dme_drift_probe"
    return "dme_drift_probe"
end

"""
    pne_contract_mutations(surface, doc) -> Vector{NamedTuple}

surface の制約それぞれについて、`doc`（有効な PNE artifact）の 1 事実だけを破る mutation を返す。
各要素は `(name, fragment, mutate!)`。`fragment` は decode エラーのメッセージに現れるべき断片。
文書に該当位置が無い制約（空配列の要素など）は生成しない。
"""
function pne_contract_mutations(surface::AbstractDict, doc)
    out = NamedTuple[]
    add!(name, fragment, f) = push!(out, (name = name, fragment = fragment, mutate! = f))
    for path in sort(collect(keys(surface["nodes"])))
        rec = surface["nodes"][path]
        loc = _pne_surface_locate(doc, path)
        loc === nothing && continue
        label = _pne_surface_label(path)
        # 各 mutate! は deepcopy された文書に対して同じ位置を解決し直して書き換える
        at(f) = d -> begin
            l = _pne_surface_locate(d, path)
            f(l)
        end
        t = rec["type"]
        # 型違い（null 許容でも別の型は拒否される）
        path == "\$" || add!("$(path): wrong type", label, at(l -> (l.parent[l.key] = _pne_wrong_type_value(t))))
        if t == "object"
            for k in rec["required"]
                add!("$(path): missing required $(k)", k, at(l -> delete!(l.value, k)))
            end
            if get(rec, "additional_properties", true) === false
                add!("$(path): unknown key", "dme_drift_probe", at(l -> (l.value["dme_drift_probe"] = 1)))
            end
            if haskey(rec, "property_names_enum")
                add!("$(path): key outside vocabulary", "dme_drift_probe", at(l -> (l.value["dme_drift_probe"] = 1)))
            end
        end
        if haskey(rec, "const")
            add!("$(path): const", label, at(l -> (l.parent[l.key] = _pne_other_const(rec["const"]))))
        end
        if haskey(rec, "enum")
            add!("$(path): enum", label, at(l -> (l.parent[l.key] = "dme_drift_probe")))
        end
        if haskey(rec, "minimum") && t in ("number", "integer")
            below = t == "integer" ? rec["minimum"] - 1 : rec["minimum"] - 0.5
            add!("$(path): below minimum", label, at(l -> (l.parent[l.key] = below)))
        end
        if haskey(rec, "maximum") && t in ("number", "integer")
            above = t == "integer" ? rec["maximum"] + 1 : rec["maximum"] + 0.5
            add!("$(path): above maximum", label, at(l -> (l.parent[l.key] = above)))
        end
        if get(rec, "minLength", 0) >= 1
            add!("$(path): below minLength", label, at(l -> (l.parent[l.key] = "")))
        end
        if haskey(rec, "maxLength")
            add!(
                "$(path): above maxLength",
                label,
                at(l -> (l.parent[l.key] = "a" * repeat("a", rec["maxLength"]))),
            )
        end
        if haskey(rec, "pattern")
            add!("$(path): pattern", label, at(l -> (l.parent[l.key] = "!dme drift probe")))
        end
        if haskey(rec, "minItems") && rec["minItems"] >= 1
            add!("$(path): below minItems", label, at(l -> empty!(l.value)))
        end
        if haskey(rec, "maxItems")
            add!("$(path): above maxItems", label, at(l -> push!(l.value, deepcopy(l.value[end]))))
        end
    end
    return out
end
