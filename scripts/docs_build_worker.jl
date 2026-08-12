# scripts/docs_build_worker.jl
#
# Julia品質Export Contract v1（Issue #213）: Documenter.jl のドキュメントビルドを実際に
# 実行する worker。`scripts/quality_export_docs.jl`（driver）が subprocess として起動する想定
# （`julia --project=docs --startup-file=no scripts/docs_build_worker.jl <output-json-path>`）。
# 単体でも実行できる（`<output-json-path>` へ生のビルド結果 JSON を書き出すだけで、
# `julia-quality-export/v1` の envelope は組み立てない — envelope 組み立ては driver 側の責務。
# `scripts/jet_analysis_worker.jl` と同じ分担）。
#
# ## ビルド設定はここに書かない
#
# `makedocs` の設定（対象ページ・`checkdocs`・`warnonly`・`doctest`/`linkcheck` の有無）は
# すべて `docs/make.jl` の `dme_build_docs` に集約されている。本 worker はそれを `include`
# して呼ぶだけで、独自の設定を組み立てない（人手のローカル実行 `julia --project=docs
# docs/make.jl` と CI の測定が同じ設定であることを構造的に保証する）。
#
# ## 何を測るか
#
#   1. ビルド中に記録された warning/error レベルのログ件数（`_DocsCapturingLogger`）。
#      Documenter は問題を `@docerror` 経由で `@warn`/`@error` としてログするため、
#      ログレコードを数えるのが最も網羅的（`size_threshold` 警告のように `@docerror` を
#      経由しない警告も拾える）。
#   2. Documenter エラークラス別の件数（`document.internal.errors`）。`makedocs(debug=true)`
#      が返す `Documenter.Document` から取り出す。**ビルドが例外を投げた場合は
#      `Document` が得られない**ため `categories = nothing`（＝全カテゴリ0件と区別する）。
#
# ## 環境: なぜ `--project=docs` か
#
# Documenter.jl は DME の実行時依存にせず（`using DME` する一般ユーザーへ強制しない）、
# slow-lane ツール（JET/BenchmarkTools が `test/Project.toml`）とも別に、専用の
# `docs/Project.toml` へ置いている（Julia の慣習どおり）。DME 自身はこの環境へ
# `Pkg.develop(path = "..")` で入っているため、`using DME`（`redact_secrets` /
# `quality_tool_documenter_result` / `canonical_json_string`）もそのまま使える。
# JET worker のような `Pkg.activate` の切り替えは不要。
#
# ## 出力形式
#
# 成功時（**ビルドが失敗した場合も含む** — ビルド失敗は「測定できた」であり
# worker の失敗ではない）:
#   `{"tool_version": "<Documenter.jlのバージョン>", "result": <quality_tool_documenter_result の出力>}`
# Documenter が環境に無い場合:
#   `{"worker_status": "not_installed", "message": "..."}` を書き出し `exit(0)`
# worker 自身が失敗した場合（ビルド設定の読み込み失敗・result 組み立ての契約違反など）:
#   `{"worker_error": {"type": "...", "message": "..."}}` を書き出し `exit(1)`
#
# 実行方法（単体）:
#   julia --project=docs scripts/docs_build_worker.jl /tmp/docs-raw.json
#
# 契約・設計判断: docs/contract/julia-quality-export-v1.md §4.5 / §8 方法F、ADR 0017

# --- Documenter の可用性判定（`using DME` より前に行う） ----------------------------
#
# docs 環境が instantiate されていない場合は Documenter も DME もロードできない。
# 「ツールが環境に無い（`not_installed`）」と「worker が異常終了した（`failure`）」を
# driver 側が区別できるようにするため、この判定だけは DME に依存せず行い、出力 JSON も
# 手書きで書き出す（`canonical_json_string` すら使えない状況を想定する）。
# トップレベルの `using Documenter` は失敗時にプロセスごと落ちるため `@eval` を try で包む。

const _DOCUMENTER_LOAD_ERROR = try
    @eval Main using Documenter
    nothing
catch e
    e
end

"""最小限の JSON 文字列エスケープ（DME をロードできない状況でのみ使う）。"""
function _minimal_json_escape(s::AbstractString)::String
    io = IOBuffer()
    for c in s
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\t'
            print(io, "\\t")
        elseif iscntrl(c)
            print(io, ' ')
        else
            print(io, c)
        end
    end
    return String(take!(io))
end

if _DOCUMENTER_LOAD_ERROR !== nothing
    isempty(ARGS) && error(
        "usage: julia --project=docs scripts/docs_build_worker.jl <output-json-path>",
    )
    _msg =
        "Documenter.jl could not be loaded from the docs environment " *
        "(run `julia --project=docs -e 'using Pkg; Pkg.instantiate()'`): " *
        sprint(showerror, _DOCUMENTER_LOAD_ERROR)
    _dir = dirname(ARGS[1])
    isempty(_dir) || mkpath(_dir)
    write(
        ARGS[1],
        "{\"message\":\"" *
        _minimal_json_escape(_msg) *
        "\",\"worker_status\":\"not_installed\"}",
    )
    println(stderr, "Documenter.jl is not available in the docs environment")
    exit(0)
end

using DME
using Logging

const _REPO_ROOT = normpath(joinpath(@__DIR__, ".."))
const _MAKE_JL = joinpath(_REPO_ROOT, "docs", "make.jl")

#: 内部で保持するログレコードの上限（export へ載せるのは `QUALITY_DOCS_MESSAGE_LIMIT` 件
#: までだが、選別（error 優先）のために一旦これだけは溜める）。件数自体は
#: `warnings`/`errors` のカウンタが保持するため、ここで溢れても0件には丸まらない。
const _RECORD_CAPACITY = 500

function _worker_output_path()::String
    isempty(ARGS) && error(
        "usage: julia --project=docs scripts/docs_build_worker.jl <output-json-path>",
    )
    return ARGS[1]
end

"""
    _DocsCapturingLogger(inner)

ビルド中の warning/error レベルのログを数えつつ、`inner`（通常は元のグローバルロガー）へ
そのまま転送するロガー。件数は上限なしで数え、本文は `_RECORD_CAPACITY` 件まで保持する。
"""
mutable struct _DocsCapturingLogger <: Logging.AbstractLogger
    inner::Logging.AbstractLogger
    warnings::Int
    errors::Int
    records::Vector{Tuple{String, String}}
end

_DocsCapturingLogger(inner::Logging.AbstractLogger) =
    _DocsCapturingLogger(inner, 0, 0, Tuple{String, String}[])

Logging.min_enabled_level(l::_DocsCapturingLogger) = Logging.min_enabled_level(l.inner)
Logging.shouldlog(l::_DocsCapturingLogger, args...) = Logging.shouldlog(l.inner, args...)
Logging.catch_exceptions(l::_DocsCapturingLogger) = Logging.catch_exceptions(l.inner)

"""ログレコード1件を1つの文字列へ整形する。Documenter は補足情報をキーワード引数
（`link = @ast ...`・`exception = ...` 等）で渡すため、本文だけでは何が問題か分からない
ことが多い。長大になりうるが `QualityDocsMessage` 側で切り詰められる。"""
function _format_record(message, kwargs)::String
    io = IOBuffer()
    print(io, message)
    for (k, v) in kwargs
        try
            if k === :exception
                ex = v isa Tuple ? first(v) : v
                print(io, "\n  exception = ", sprint(showerror, ex))
            else
                print(io, "\n  ", k, " = ", v)
            end
        catch
            print(io, "\n  ", k, " = <unprintable>")
        end
    end
    return String(take!(io))
end

function Logging.handle_message(
    l::_DocsCapturingLogger,
    level,
    message,
    _module,
    group,
    id,
    filepath,
    line;
    kwargs...,
)
    if level >= Logging.Error
        l.errors += 1
        length(l.records) < _RECORD_CAPACITY &&
            push!(l.records, ("error", _format_record(message, kwargs)))
    elseif level >= Logging.Warn
        l.warnings += 1
        length(l.records) < _RECORD_CAPACITY &&
            push!(l.records, ("warning", _format_record(message, kwargs)))
    end
    return Logging.handle_message(
        l.inner,
        level,
        message,
        _module,
        group,
        id,
        filepath,
        line;
        kwargs...,
    )
end

"""
    _select_messages(records) -> Vector{QualityDocsMessage}

export へ載せる抜粋を選ぶ。**error を先に**、次に warning を、合わせて
`QUALITY_DOCS_MESSAGE_LIMIT` 件まで採る（大量の warning でビルド失敗の原因が
押し出されないようにするため）。空文字列のレコードは捨てる
（`QualityDocsMessage` が空 message を拒否するため）。
"""
function _select_messages(
    records::AbstractVector{Tuple{String, String}},
)::Vector{QualityDocsMessage}
    selected = QualityDocsMessage[]
    for want in ("error", "warning")
        for (level, text) in records
            length(selected) < QUALITY_DOCS_MESSAGE_LIMIT || return selected
            level == want || continue
            isempty(strip(text)) && continue
            push!(selected, QualityDocsMessage(; level = level, message = text))
        end
    end
    return selected
end

"""`document.internal.errors`（`@docerror` のタグ列）をカテゴリ別件数へ集計する。"""
function _category_counts(tags)::Dict{String, Int}
    counts = Dict{String, Int}()
    for tag in tags
        key = String(tag)
        counts[key] = get(counts, key, 0) + 1
    end
    return counts
end

function _run_docs_build()::Dict{String, Any}
    logger = _DocsCapturingLogger(Logging.global_logger())
    document = nothing
    build_exception = nothing
    Logging.with_logger(logger) do
        try
            document = dme_build_docs(; debug = true)
        catch e
            build_exception = e
        end
    end

    build_failed = build_exception !== nothing
    records = copy(logger.records)
    errors = logger.errors
    if build_failed
        # ビルドを終了させた例外そのものも error レベルの事実として1件数える
        # （Documenter は通常その前に @error をログするが、ログを経由せずに投げる経路
        # （設定エラー等）でも `errors > 0` になり `build_status = "failed"` が
        # 件数と整合する）。
        errors += 1
        length(records) < _RECORD_CAPACITY && push!(
            records,
            ("error", "makedocs threw: " * sprint(showerror, build_exception)),
        )
    end

    result = quality_tool_documenter_result(;
        build_failed = build_failed,
        warnings = logger.warnings,
        errors = errors,
        messages = _select_messages(records),
        categories = document === nothing ? nothing :
                     _category_counts(document.internal.errors),
        target = Dict{String, Any}(
            "source" => "docs/src",
            "pages" => ["index.md"; ["api/$(name).md" for (name, _, _) in DME_API_GROUPS]],
            "modules" => ["DME"],
            "format" => "html",
        ),
        config = Dict{String, Any}(
            "checkdocs" => String(DME_DOCS_CHECKDOCS),
            "doctest" => DME_DOCS_DOCTEST,
            "linkcheck" => DME_DOCS_LINKCHECK,
            "warnonly" => String.(DME_DOCS_WARNONLY),
        ),
    )

    version = try
        string(pkgversion(Documenter))
    catch
        nothing
    end
    return Dict{String, Any}("tool_version" => version, "result" => result)
end

function _write_payload(output_path::AbstractString, payload::AbstractDict)
    dir = dirname(output_path)
    isempty(dir) || mkpath(dir)
    write(output_path, canonical_json_string(payload))
    return nothing
end

function _worker_error_payload(e)::Dict{String, Any}
    return Dict{String, Any}(
        "worker_error" => Dict{String, Any}(
            "type" => redact_secrets(string(typeof(e))),
            "message" => redact_secrets(sprint(showerror, e)),
        ),
    )
end

function main()
    output_path = _worker_output_path()
    payload = try
        _run_docs_build()
    catch e
        _write_payload(output_path, _worker_error_payload(e))
        println(stderr, "docs build worker failed: ", sprint(showerror, e))
        exit(1)
    end

    _write_payload(output_path, payload)
    println(
        "Documenter build complete: build_status=",
        payload["result"]["build_status"],
        " warnings=",
        payload["result"]["warnings"],
        " errors=",
        payload["result"]["errors"],
        " -> ",
        output_path,
    )
    return nothing
end

# --- 以下はトップレベルの逐次文として書く（world age の都合） ------------------------
# `include(docs/make.jl)` で新しく定義される `dme_build_docs` を、同じ関数呼び出しの中から
# 呼ぶことはできない（呼び出し側は include 前の world に固定される）。そのため
# 「include → main()」を関数に包まずトップレベルへ並べる
# （`scripts/jet_analysis_worker.jl` が `using JET` をトップレベルへ置いているのと同じ理由）。

# ビルド設定の正本（`docs/make.jl`）を読み込む。ここ自体が失敗する場合
# （`DME_API_GROUPS` の割り当て漏れ検査に引っかかった等）は worker の失敗として報告する。
try
    include(_MAKE_JL)
catch e
    _write_payload(_worker_output_path(), _worker_error_payload(e))
    println(stderr, "failed to load docs/make.jl: ", sprint(showerror, e))
    exit(1)
end

main()
