# 軽量RAG/参照コンテキスト生成
# docs/ 配下のMarkdownを読み込み、モデル名・変数名・キーワードに基づいて
# 関連セクションを選択して DocsExcerpts を生成する。
# LLM API は呼ばない。

# src/llm/doc_context.jl → src/llm → src → package root
const _DOC_CONTEXT_DOCS_ROOT = joinpath(dirname(dirname(@__DIR__)), "docs")

# モデル識別名 → docs/ 配下の相対パス
const _MODEL_DOC_MAP = Dict{String, String}(
    "RBC Model" => "models/rbc.md",
    "Ramsey Model" => "models/ramsey.md",
    "Solow Model" => "models/solow.md",
    "IS-LM Model" => "models/islm.md",
    "AD-AS Model" => "models/adas.md",
    "New Keynesian Model" => "models/new_keynesian.md",
    "VAR Model" => "models/var.md",
    "Mundell-Fleming Model" => "models/mundell_fleming.md",
)

# 「限界・注意事項」セクションを特定するためのキーワード
const _LIMITATION_SECTION_KEYWORDS =
    String["限界", "注意事項", "前提", "caveats", "limitations"]

"""
    build_docs_excerpts(model_name::String;
        variable_names::Vector{Symbol} = Symbol[],
        scenario_name::String = "",
        keywords::Vector{String} = String[],
        docs_root::String = _DOC_CONTEXT_DOCS_ROOT,
        max_chars_per_doc::Int = 1000,
    ) -> DocsExcerpts

モデル名・変数名・シナリオ名・キーワードに基づいて関連 docs を選択し、
`DocsExcerpts` を返す。

ドキュメントが見つからない場合は該当フィールドを空文字列として安全に fallback する。
LLM API は呼ばない。

## 引数
- `model_name` : モデルの識別名（例: `"RBC Model"`）
- `variable_names` : 変数名リスト（例: `[:K, :A, :C]`）
- `scenario_name` : シナリオ名（例: `"technology_shock"`）
- `keywords` : 追加キーワードリスト（例: `["IRF", "定常状態"]`）
- `docs_root` : docs ディレクトリへのパス（デフォルトはパッケージルートの `docs/`）
- `max_chars_per_doc` : 各フィールドの最大文字数

## 使用例

```julia
de = build_docs_excerpts("RBC Model";
    variable_names = [:K, :A, :C, :L],
    scenario_name  = "technology_shock",
    keywords       = ["IRF"],
)
ctx = AnalysisContext(rbc, irf_result; docs_excerpts = de)
```
"""
function build_docs_excerpts(
    model_name::String;
    variable_names::Vector{Symbol} = Symbol[],
    scenario_name::String = "",
    keywords::Vector{String} = String[],
    docs_root::String = _DOC_CONTEXT_DOCS_ROOT,
    max_chars_per_doc::Int = 1000,
)::DocsExcerpts
    # 変数名を文字列キーワードとして追加し、変数固有セクションの選択精度を高める
    all_keywords = vcat(keywords, String.(variable_names))
    model_doc = _extract_model_doc(model_name, docs_root, max_chars_per_doc)
    output_guide =
        _extract_output_guide(docs_root, scenario_name, all_keywords, max_chars_per_doc)
    caveats_doc = _extract_caveats_doc(model_name, docs_root, max_chars_per_doc)
    DocsExcerpts(model_doc, output_guide, caveats_doc)
end

"""
    build_docs_excerpts(ctx::AnalysisContext;
        docs_root::String = _DOC_CONTEXT_DOCS_ROOT,
        max_chars_per_doc::Int = 1000,
    ) -> DocsExcerpts

`AnalysisContext` からモデル名・変数名・シナリオ名を取得して関連 docs を選択し、
`DocsExcerpts` を返す。

`ctx.docs_excerpts` の内容は変更しない。この関数は新しい `DocsExcerpts` を返すのみ。
LLM API は呼ばない。
"""
function build_docs_excerpts(
    ctx::AnalysisContext;
    docs_root::String = _DOC_CONTEXT_DOCS_ROOT,
    max_chars_per_doc::Int = 1000,
)::DocsExcerpts
    meta = ctx.model_metadata
    srs = ctx.simulation_result_summary
    all_vars = vcat(meta.state_variables, meta.control_variables)
    build_docs_excerpts(
        meta.model_name;
        variable_names = all_vars,
        scenario_name = srs.scenario_name,
        docs_root = docs_root,
        max_chars_per_doc = max_chars_per_doc,
    )
end

# --- 内部ヘルパー ---

# ファイルを安全に読み込む。存在しない場合は "" を返す。
function _read_doc_file(filepath::String)::String
    isfile(filepath) ? read(filepath, String) : ""
end

# テキストを max_chars 以内に切り詰める。
function _truncate_text(text::String, max_chars::Int)::String
    length(text) <= max_chars && return text
    # Julia の文字列インデックスは バイト位置のため、文字単位で切り詰める
    String(collect(text)[1:max_chars]) * "…"
end

# Markdown からキーワードに一致する heading のセクション本文を抽出する。
# heading_keywords のいずれかを見出し行が含む最初のセクションを返す。
# 次の同レベル以上の見出しでセクション終了とみなす。
# 一致しない場合は "" を返す。
function _extract_section_by_keywords(
    content::String,
    heading_keywords::Vector{String},
    max_chars::Int,
)::String
    isempty(content) && return ""
    lines = split(content, '\n')
    in_section = false
    in_code_block = false
    section_lines = String[]

    for line in lines
        # コードブロック（```）の内外を追跡し、コード内の `#` を見出しと混同しない
        if startswith(line, "```")
            in_code_block = !in_code_block
            in_section && push!(section_lines, line)
            continue
        end
        in_code_block && (in_section && push!(section_lines, line); continue)

        is_h3 = startswith(line, "### ")
        is_h2 = startswith(line, "## ") && !is_h3
        is_h1 = startswith(line, "# ") && !startswith(line, "## ")

        if is_h1 || is_h2 || is_h3
            # h1/h2 は常にセクション区切り。h3 は in_section 中のみ区切り。
            (in_section && (is_h1 || is_h2 || is_h3)) && break
            line_lower = lowercase(line)
            if any(occursin(lowercase(kw), line_lower) for kw in heading_keywords)
                in_section = true
            end
        elseif in_section
            push!(section_lines, line)
        end
    end

    isempty(section_lines) && return ""
    _truncate_text(String(strip(join(section_lines, '\n'))), max_chars)
end

# docs 内の "LLM向け要約" 行からテキストを抽出する。
function _extract_llm_summary(content::String)::String
    for line in split(content, '\n')
        occursin("LLM向け要約", line) || continue
        m = match(r"LLM向け要約[^:：]*[:：]\s*(.*)", line)
        isnothing(m) || return strip(String(m.captures[1]))
    end
    ""
end

# モデルドキュメント抜粋を生成する。
# "LLM向け要約" と "目的" セクションを優先的に抽出する。
function _extract_model_doc(model_name::String, docs_root::String, max_chars::Int)::String
    rel_path = get(_MODEL_DOC_MAP, model_name, "")
    isempty(rel_path) && return ""

    content = _read_doc_file(joinpath(docs_root, rel_path))
    isempty(content) && return ""

    llm_summary = _extract_llm_summary(content)
    purpose_section = _extract_section_by_keywords(
        content,
        ["目的", "モデルの目的", "purpose"],
        max_chars,
    )

    parts = String[]
    isempty(llm_summary) || push!(parts, "【モデル概要】$(llm_summary)")
    isempty(purpose_section) || push!(parts, purpose_section)

    isempty(parts) ? _truncate_text(content, max_chars) :
    _truncate_text(join(parts, "\n\n"), max_chars)
end

# 出力ガイド抜粋を生成する。
# scenario_name と keywords を参照し IRF/移行経路に応じたセクションを選択する。
function _extract_output_guide(
    docs_root::String,
    scenario_name::String,
    keywords::Vector{String},
    max_chars::Int,
)::String
    content = _read_doc_file(joinpath(docs_root, "simulation_outputs.md"))
    isempty(content) && return ""

    irf_terms = ["shock", "irf", "impulse", "ショック"]
    is_irf =
        any(t -> occursin(t, lowercase(scenario_name)), irf_terms) ||
        any(t -> any(occursin(t, lowercase(kw)) for kw in keywords), irf_terms)

    heading_keywords = if is_irf
        String["インパルス", "irf", "impulse", "ショック"]
    else
        String["移行経路", "transition", "定常状態", "steady"]
    end

    section = _extract_section_by_keywords(content, heading_keywords, max_chars)
    isempty(section) ? _truncate_text(content, max_chars) : section
end

# モデルの限界・注意事項セクションを抽出する。
function _extract_caveats_doc(model_name::String, docs_root::String, max_chars::Int)::String
    rel_path = get(_MODEL_DOC_MAP, model_name, "")
    isempty(rel_path) && return ""

    content = _read_doc_file(joinpath(docs_root, rel_path))
    isempty(content) && return ""

    _extract_section_by_keywords(content, _LIMITATION_SECTION_KEYWORDS, max_chars)
end
