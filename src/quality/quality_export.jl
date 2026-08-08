# Julia品質Export Contract v1（`julia-quality-export/v1`）— Issue #207。
#
# software-quality-dashboard の Julia Native Provider が読み取る、DME 所有の
# versioned contract。schema は `schemas/julia-quality-export-v1.schema.json`
# （構造はこのファイルの型・バリデーションと一致させる。DME は汎用 JSON Schema
# バリデータを持たない方針 — `src/artifacts/real_rate_model_artifact.jl` と同じ doctrine）。
#
# 規約:
#   - すべて keyword constructor + `ArgumentError` バリデーション（`real_rate_model_artifact.jl` /
#     `sfc/types.jl` と同じ idiom）。
#   - `tools` は `Dict{String,QualityToolExecution}` として保持する。ツール名は dict の
#     キー自身であり、値側に重複したフィールドは持たない（フィクスチャの実例
#     `julia-quality-export/v1` と同形）。
#   - 各ツール実行の `result`（成功時のみ）の中身（フィールド構造）はこの Issue の対象外。
#     `tools` map は open な辞書（`Dict{String,Any}`）として扱い、ツールごとの構造化は
#     後続 Issue（#208 Pkg.test/Aqua/Formatter、#209 Coverage、#211 JET、#212 Benchmark、
#     #213 Documenter）に委ねる。
#   - タイムゾーンは real-rate model artifact と同じ MVP 制約で UTC 固定（`"...Z"` 接尾辞のみ）。
#   - Secret/環境変数/API credential を出力しない redaction 方針（詳細は
#     docs/contract/julia-quality-export-v1.md）: `error.message`/`reason` は自動 redact、
#     `result` に秘匿情報らしき文字列が見つかった場合は `ArgumentError` で拒否する
#     （構造化データを黙って書き換えると壊れるため、redact ではなく reject）。

const QUALITY_EXPORT_SCHEMA = "julia-quality-export/v1"
const QUALITY_EXPORT_DEFAULT_PRODUCER_NAME = "dme-quality-export"
const QUALITY_EXPORT_DEFAULT_PRODUCER_VERSION = "0.1.0"

const QUALITY_EXPORT_TOOL_STATUSES =
    (:success, :failure, :timeout, :skipped, :not_installed)

# Contract上予約するtool名（Issue #207）。実測実行は本Issueの対象外。`tools` map は
# open な辞書のため、これ以外の名前を追加してもスキーマの互換性は破らない
# （新規 metric_id 追加と同様、マイナー扱い）。
const QUALITY_EXPORT_RESERVED_TOOL_NAMES = (
    "Pkg.test",
    "Aqua.jl",
    "JuliaFormatter.jl",
    "Coverage.jl",
    "JET.jl",
    "BenchmarkTools.jl",
    "Documenter.jl",
)

const _QE_TOOL_NAME_RE = r"^[A-Za-z][A-Za-z0-9._-]*$"
const _QE_COMMIT_SHA_RE = r"^[0-9a-f]{40}$"
const _QE_UUID_RE =
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"

# ---------------------------------------------------------------------------
# Redaction: Secret/環境変数/API credential を出力しない方針
# ---------------------------------------------------------------------------

#: DME が実際に使う秘匿環境変数名（docs/development/configuration.md）。
#: 加えて一般的なクラウドトークンの形状・`key=`/`token=` 等の代入パターンも対象にする。
const _QE_SECRET_PATTERNS = (
    r"(?i)ghp_[A-Za-z0-9]{20,}",
    r"(?i)sk-[A-Za-z0-9]{20,}",
    r"(?i)AKIA[0-9A-Z]{12,}",
    r"(?i)Bearer\s+[A-Za-z0-9._-]{10,}",
    r"(?i)(FRED_API_KEY|ESTAT_APP_ID|OPENAI_API_KEY|GITHUB_TOKEN|api[_-]?key|secret|token|password|credential)\s*[:=]\s*\S+",
)

"""
    redact_secrets(s::AbstractString) -> String

`s` の中に秘匿情報らしき部分文字列（既知のクラウドトークン形状・`key=`/`token=` 等の
代入パターン・DME が使う秘匿環境変数名）が見つかった場合、`"[REDACTED]"` へ置換する。
`QualityToolError`/`QualityToolExecution` の自由記述フィールド（`error.message`・`reason`）
に自動適用される。将来 Pkg.test/Aqua 等の実際の出力を扱う実装（#208 等）が、サブプロセスの
生出力をそのまま人間可読フィールドへ渡す前にも呼ぶことを想定する。
"""
function redact_secrets(s::AbstractString)::String
    out = String(s)
    for pat in _QE_SECRET_PATTERNS
        out = replace(out, pat => "[REDACTED]")
    end
    return out
end

function _qe_reject_if_secret_like(prefix::AbstractString, value)
    if value isa AbstractDict
        for (k, v) in value
            _qe_reject_if_secret_like("$prefix.$k", v)
        end
    elseif value isa AbstractVector
        for (i, v) in enumerate(value)
            _qe_reject_if_secret_like("$prefix[$i]", v)
        end
    elseif value isa AbstractString
        for pat in _QE_SECRET_PATTERNS
            occursin(pat, value) && throw(
                ArgumentError(
                    "$prefix に秘匿情報らしき文字列が含まれています（パターン: $pat）。" *
                    "result へ生の環境変数・トークン・認証情報を含めないでください。",
                ),
            )
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# バリデーションヘルパー・timestamp フォーマット（real_rate_model_artifact.jl と同じ規約）
# ---------------------------------------------------------------------------

function _qe_check_nonempty(s::AbstractString, name::AbstractString)
    isempty(s) && throw(ArgumentError("$name は空文字列にできません"))
    return nothing
end

_qe_format_datetime(dt::DateTime) = Dates.format(dt, dateformat"yyyy-mm-ddTHH:MM:SS") * "Z"
function _qe_parse_datetime(s::AbstractString)::DateTime
    endswith(s, "Z") || throw(
        ArgumentError(
            "timestamp は UTC (\"...Z\" 接尾辞) のみサポートします（MVP 制約）: $s",
        ),
    )
    return DateTime(s[1:(end - 1)], dateformat"yyyy-mm-ddTHH:MM:SS")
end

function _qe_check_no_unknown_keys(d::AbstractDict, allowed::Tuple, ctx::AbstractString)
    extra = setdiff(Set(String(k) for k in keys(d)), Set(allowed))
    isempty(extra) || throw(
        ArgumentError(
            "$ctx に未知のフィールドがあります: $(join(sort(collect(extra)), ", "))",
        ),
    )
    return nothing
end

# ---------------------------------------------------------------------------
# Producer / Package / Repository
# ---------------------------------------------------------------------------

struct QualityExportProducer
    name::String
    version::String
end

"""
    QualityExportProducer(; name = QUALITY_EXPORT_DEFAULT_PRODUCER_NAME,
                             version = QUALITY_EXPORT_DEFAULT_PRODUCER_VERSION)

export を生成した Exporter 自身の識別（DME パッケージ自体の識別は `QualityExportPackage`）。
"""
function QualityExportProducer(;
    name::AbstractString = QUALITY_EXPORT_DEFAULT_PRODUCER_NAME,
    version::AbstractString = QUALITY_EXPORT_DEFAULT_PRODUCER_VERSION,
)::QualityExportProducer
    _qe_check_nonempty(name, "producer.name")
    _qe_check_nonempty(version, "producer.version")
    return QualityExportProducer(String(name), String(version))
end

struct QualityExportPackage
    name::String
    uuid::String
    version::String
end

"""`Project.toml` の `name`/`uuid`/`version` に対応する測定対象パッケージの識別。"""
function QualityExportPackage(;
    name::AbstractString,
    uuid::AbstractString,
    version::AbstractString,
)::QualityExportPackage
    _qe_check_nonempty(name, "package.name")
    occursin(_QE_UUID_RE, uuid) ||
        throw(ArgumentError("package.uuid は UUID 形式である必要があります: $uuid"))
    _qe_check_nonempty(version, "package.version")
    return QualityExportPackage(String(name), String(uuid), String(version))
end

"""
    quality_export_package_identity() -> QualityExportPackage

`Base.PkgId`/`pkgversion` から DME 自身の name/uuid/version を取得する。値は
`Project.toml` と常に一致する（ハードコードによる乖離が構造的に発生しない）。
"""
function quality_export_package_identity()::QualityExportPackage
    pkgid = Base.PkgId(@__MODULE__)
    pkgid.uuid === nothing && throw(
        ArgumentError(
            "DME モジュールに UUID が見つかりません（Project.toml を確認してください）",
        ),
    )
    return QualityExportPackage(;
        name = String(pkgid.name),
        uuid = string(pkgid.uuid),
        version = string(pkgversion(@__MODULE__)),
    )
end

struct QualityExportRepository
    owner::String
    name::String
end

function QualityExportRepository(;
    owner::AbstractString,
    name::AbstractString,
)::QualityExportRepository
    _qe_check_nonempty(owner, "repository.owner")
    _qe_check_nonempty(name, "repository.name")
    return QualityExportRepository(String(owner), String(name))
end

# ---------------------------------------------------------------------------
# ToolError / ToolExecution
# ---------------------------------------------------------------------------

struct QualityToolError
    type::String
    message::String
end

"""
    QualityToolError(; type, message)

`status ∈ (:failure, :timeout)` のときに必須。`type`/`message` はいずれも
`redact_secrets` を通してから保持する（生のサブプロセス出力をそのまま渡さない前提だが、
二重の防御として自動適用する）。keyword constructor を使うこと。位置引数版
`QualityToolError(type::String, message::String)`（`struct` が自動生成するデフォルト
コンストラクタ）はバリデーション・redaction を経由しないため呼び出し禁止
（以前 `(type::AbstractString, message::AbstractString)` という位置引数版を併置していたが、
`String` 引数に対しては型シグネチャがより特殊なデフォルトコンストラクタが優先され、
バリデーションが黙って迂回されるバグがあったため keyword-only にした）。
"""
function QualityToolError(; type::AbstractString, message::AbstractString)::QualityToolError
    _qe_check_nonempty(type, "error.type")
    _qe_check_nonempty(message, "error.message")
    return QualityToolError(redact_secrets(String(type)), redact_secrets(String(message)))
end

struct QualityToolExecution
    tool_name::String
    status::Symbol
    version::Union{String, Nothing}
    started_at::Union{DateTime, Nothing}
    completed_at::Union{DateTime, Nothing}
    duration_seconds::Union{Float64, Nothing}
    result::Union{Dict{String, Any}, Nothing}
    error::Union{QualityToolError, Nothing}
    reason::Union{String, Nothing}
end

"""
    QualityToolExecution(; tool_name, status, version = nothing,
                            started_at = nothing, completed_at = nothing,
                            result = nothing, error = nothing, reason = nothing)

1ツールの1回の実行結果。`status` に応じて必須フィールドが変わる
（`0`・未計測・未導入・実行失敗を混同しないための強制。docs/contract/julia-quality-export-v1.md
の表を参照）:

| status | 必須 | 禁止 |
|---|---|---|
| `:success` | `started_at`・`completed_at`・空でない `result` | `error` |
| `:failure`/`:timeout` | `started_at`・`completed_at`・`error`（type/message） | `result` |
| `:skipped`/`:not_installed` | `reason` | `result`・`error` |

`duration_seconds` は呼び出し側が渡すものではなく `completed_at - started_at` から自動導出する
（矛盾した入力を構造的に排除する）。`result` の値は `canonical_json_bytes` がサポートする型
（`Dict`/`Vector`/`String`/`Bool`/`Integer`/有限`AbstractFloat`/`Nothing` の入れ子）に限る。
`result` に秘匿情報らしき文字列が含まれる場合は `ArgumentError` で拒否する（黙って redact
すると構造化データが壊れるため）。
"""
function QualityToolExecution(;
    tool_name::AbstractString,
    status::Symbol,
    version::Union{AbstractString, Nothing} = nothing,
    started_at::Union{DateTime, Nothing} = nothing,
    completed_at::Union{DateTime, Nothing} = nothing,
    result::Union{AbstractDict, Nothing} = nothing,
    error::Union{QualityToolError, Nothing} = nothing,
    reason::Union{AbstractString, Nothing} = nothing,
)::QualityToolExecution
    _qe_check_nonempty(tool_name, "tool_name")
    occursin(_QE_TOOL_NAME_RE, tool_name) ||
        throw(ArgumentError("tool_name の形式が不正です: $tool_name"))
    status in QUALITY_EXPORT_TOOL_STATUSES || throw(
        ArgumentError(
            "$tool_name: status は $(QUALITY_EXPORT_TOOL_STATUSES) のいずれかである必要があります: $status",
        ),
    )
    if started_at !== nothing && completed_at !== nothing && completed_at < started_at
        throw(
            ArgumentError(
                "$tool_name: completed_at は started_at 以降である必要があります",
            ),
        )
    end

    result_dict = result === nothing ? nothing : Dict{String, Any}(result)
    result_dict === nothing || _qe_reject_if_secret_like("$tool_name.result", result_dict)
    reason_str = reason === nothing ? nothing : redact_secrets(String(reason))

    if status == :success
        started_at === nothing &&
            throw(ArgumentError("$tool_name: status=success は started_at が必須です"))
        completed_at === nothing &&
            throw(ArgumentError("$tool_name: status=success は completed_at が必須です"))
        (result_dict === nothing || isempty(result_dict)) &&
            throw(ArgumentError("$tool_name: status=success は空でない result が必須です"))
        error === nothing ||
            throw(ArgumentError("$tool_name: status=success では error を指定できません"))
    elseif status in (:failure, :timeout)
        started_at === nothing &&
            throw(ArgumentError("$tool_name: status=$status は started_at が必須です"))
        completed_at === nothing &&
            throw(ArgumentError("$tool_name: status=$status は completed_at が必須です"))
        error === nothing && throw(
            ArgumentError("$tool_name: status=$status は error（type/message）が必須です"),
        )
        result_dict === nothing ||
            throw(ArgumentError("$tool_name: status=$status では result を指定できません"))
    else # :skipped, :not_installed
        reason_str === nothing &&
            throw(ArgumentError("$tool_name: status=$status は reason が必須です"))
        result_dict === nothing ||
            throw(ArgumentError("$tool_name: status=$status では result を指定できません"))
        error === nothing ||
            throw(ArgumentError("$tool_name: status=$status では error を指定できません"))
    end

    duration_seconds =
        (started_at !== nothing && completed_at !== nothing) ?
        Dates.value(completed_at - started_at) / 1000.0 : nothing

    return QualityToolExecution(
        String(tool_name),
        status,
        version === nothing ? nothing : String(version),
        started_at,
        completed_at,
        duration_seconds,
        result_dict,
        error,
        reason_str,
    )
end

"""
    quality_tool_not_run(tool_name, reason; status = :skipped) -> QualityToolExecution

`status ∈ (:skipped, :not_installed)` の `QualityToolExecution` を作る糖衣関数。
`scripts/quality_export.jl` が未配線のツールを埋めるために使う。
"""
function quality_tool_not_run(
    tool_name::AbstractString,
    reason::AbstractString;
    status::Symbol = :skipped,
)::QualityToolExecution
    status in (:skipped, :not_installed) || throw(
        ArgumentError("quality_tool_not_run は :skipped/:not_installed 専用です: $status"),
    )
    return QualityToolExecution(; tool_name = tool_name, status = status, reason = reason)
end

# ---------------------------------------------------------------------------
# QualityExport（トップレベル envelope）
# ---------------------------------------------------------------------------

struct QualityExport
    export_schema::String
    producer::QualityExportProducer
    package::QualityExportPackage
    repository::QualityExportRepository
    branch::String
    commit::String
    measured_at::DateTime
    generated_at::DateTime
    julia_version::String
    tools::Dict{String, QualityToolExecution}
end

"""
    QualityExport(; producer = QualityExportProducer(), package, repository,
                    branch, commit, measured_at, generated_at,
                    julia_version = string(VERSION), tools)

`julia-quality-export/v1` の1ファイル分（1コミットに対する1回の実行）。`tools` は
`QualityToolExecution` の `Vector`（`tool_name` で重複を検出し、内部で
`Dict{String,QualityToolExecution}` として保持する）。
"""
function QualityExport(;
    producer::QualityExportProducer = QualityExportProducer(),
    package::QualityExportPackage,
    repository::QualityExportRepository,
    branch::AbstractString,
    commit::AbstractString,
    measured_at::DateTime,
    generated_at::DateTime,
    julia_version::AbstractString = string(VERSION),
    tools::AbstractVector{QualityToolExecution},
)::QualityExport
    _qe_check_nonempty(branch, "branch")
    occursin(_QE_COMMIT_SHA_RE, commit) ||
        throw(ArgumentError("commit は40桁小文字16進数である必要があります: $commit"))
    generated_at >= measured_at ||
        throw(ArgumentError("generated_at は measured_at 以上である必要があります"))
    _qe_check_nonempty(julia_version, "julia_version")
    isempty(tools) && throw(ArgumentError("tools は最低1件必要です"))

    tools_dict = Dict{String, QualityToolExecution}()
    for t in tools
        haskey(tools_dict, t.tool_name) &&
            throw(ArgumentError("tools に重複した tool_name があります: $(t.tool_name)"))
        tools_dict[t.tool_name] = t
    end

    return QualityExport(
        QUALITY_EXPORT_SCHEMA,
        producer,
        package,
        repository,
        String(branch),
        lowercase(String(commit)),
        measured_at,
        generated_at,
        String(julia_version),
        tools_dict,
    )
end

"""
    quality_export_with_tool(e::QualityExport, tool::QualityToolExecution;
                              generated_at::DateTime = e.generated_at) -> QualityExport

`e` の `tools` のうち `tool.tool_name` と同名のエントリを `tool` で置き換えた（無ければ追加した）
新しい `QualityExport` を返す（`e` 自体は変更しない。`QualityExport`/`QualityToolExecution` は
どちらもイミュータブルという既存の設計を維持する）。

Coverage.jl（Issue #209）のように、コード coverage の `.cov` トレースファイルはそれを生成した
julia プロセスが**終了した後**でなければディスクへ確定しない（Coverage.jl 自体の制約であり
DME 側の実装選択ではない）。そのため `test/quality_capture_runner.jl`（`Pkg.test()` のテスト
サブプロセス内で実行される）は Coverage.jl を実測できず、`status=:skipped` のプレースホルダで
埋めた export を書き出すところまでしかできない。この関数は、テストサブプロセスが終了した**後**
（`Pkg.test()` を呼び出した外側のプロセス）で Coverage.jl の実測結果を後から差し込むために使う
（`scripts/quality_export_coverage.jl`）。`generated_at` は既定では元の値を保持するが、ファイルを
実際に再保存する呼び出し側は「書き出した時刻」の意味を保つため新しい時刻を渡すこと。
"""
function quality_export_with_tool(
    e::QualityExport,
    tool::QualityToolExecution;
    generated_at::DateTime = e.generated_at,
)::QualityExport
    others = QualityToolExecution[t for (name, t) in e.tools if name != tool.tool_name]
    return QualityExport(;
        producer = e.producer,
        package = e.package,
        repository = e.repository,
        branch = e.branch,
        commit = e.commit,
        measured_at = e.measured_at,
        generated_at = generated_at,
        julia_version = e.julia_version,
        tools = push!(others, tool),
    )
end

# ---------------------------------------------------------------------------
# シリアライズ（正準 JSON。既存 to_dict/to_json 慣行に準拠。改行方針は real-rate model
# artifact と同じ: canonical_json_bytes のみ、末尾改行は付与しない）
# ---------------------------------------------------------------------------

function _qe_tool_execution_to_dict(t::QualityToolExecution)::Dict{String, Any}
    return Dict{String, Any}(
        "status" => String(t.status),
        "version" => t.version,
        "started_at" =>
            t.started_at === nothing ? nothing : _qe_format_datetime(t.started_at),
        "completed_at" =>
            t.completed_at === nothing ? nothing : _qe_format_datetime(t.completed_at),
        "duration_seconds" => t.duration_seconds,
        "result" => t.result,
        "error" =>
            t.error === nothing ? nothing :
            Dict{String, Any}("type" => t.error.type, "message" => t.error.message),
        "reason" => t.reason,
    )
end

function to_dict(e::QualityExport)::Dict{String, Any}
    tools =
        Dict{String, Any}(name => _qe_tool_execution_to_dict(t) for (name, t) in e.tools)
    return Dict{String, Any}(
        "export_schema" => e.export_schema,
        "producer" =>
            Dict{String, Any}("name" => e.producer.name, "version" => e.producer.version),
        "package" => Dict{String, Any}(
            "name" => e.package.name,
            "uuid" => e.package.uuid,
            "version" => e.package.version,
        ),
        "repository" =>
            Dict{String, Any}("owner" => e.repository.owner, "name" => e.repository.name),
        "branch" => e.branch,
        "commit" => e.commit,
        "measured_at" => _qe_format_datetime(e.measured_at),
        "generated_at" => _qe_format_datetime(e.generated_at),
        "julia_version" => e.julia_version,
        "tools" => tools,
    )
end

"""`to_dict` を正準 JSON 文字列へ変換する（保存と同じ経路）。"""
to_json(e::QualityExport)::String = canonical_json_string(to_dict(e))

const _QE_TOP_LEVEL_KEYS = (
    "export_schema",
    "producer",
    "package",
    "repository",
    "branch",
    "commit",
    "measured_at",
    "generated_at",
    "julia_version",
    "tools",
)
const _QE_TOOL_EXECUTION_KEYS = (
    "status",
    "version",
    "started_at",
    "completed_at",
    "duration_seconds",
    "result",
    "error",
    "reason",
)

function _qe_tool_execution_from_dict(
    tool_name::AbstractString,
    t::AbstractDict,
)::QualityToolExecution
    _qe_check_no_unknown_keys(t, _QE_TOOL_EXECUTION_KEYS, "tools.$tool_name")
    haskey(t, "status") || throw(ArgumentError("tools.$tool_name: status がありません"))
    status = Symbol(t["status"])
    error_d = get(t, "error", nothing)
    err =
        error_d === nothing ? nothing :
        QualityToolError(; type = error_d["type"], message = error_d["message"])
    started_raw = get(t, "started_at", nothing)
    completed_raw = get(t, "completed_at", nothing)
    return QualityToolExecution(;
        tool_name = tool_name,
        status = status,
        version = get(t, "version", nothing),
        started_at = started_raw === nothing ? nothing : _qe_parse_datetime(started_raw),
        completed_at = completed_raw === nothing ? nothing :
                       _qe_parse_datetime(completed_raw),
        result = get(t, "result", nothing),
        error = err,
        reason = get(t, "reason", nothing),
    )
end

"""
    quality_export_from_dict(d::AbstractDict) -> QualityExport

生の `Dict`（`JSON3.read` を `_qe_to_plain` した後の Native Dict、あるいは valid/invalid
fixture のパース結果）から `QualityExport` を再構築する。契約が要求する制約
（必須フィールド・enum・timestamp 形式・commit SHA 形式・status ごとの必須/禁止フィールド）は
すべてこの経路（および各型のキーワードコンストラクタ）で検証する。DME はこの schema に対する
汎用 JSON Schema バリデータを持たないため、この関数がそのまま validator を兼ねる
（`real_rate_model_artifact_from_dict` と同じ doctrine）。
"""
function quality_export_from_dict(d::AbstractDict)::QualityExport
    _qe_check_no_unknown_keys(d, _QE_TOP_LEVEL_KEYS, "quality export")
    haskey(d, "export_schema") || throw(ArgumentError("export_schema がありません"))
    d["export_schema"] == QUALITY_EXPORT_SCHEMA || throw(
        ArgumentError(
            "unsupported_export_schema: このパッケージがサポートするのは $(QUALITY_EXPORT_SCHEMA) のみです（実際: $(d["export_schema"])）",
        ),
    )

    producer_d = d["producer"]
    package_d = d["package"]
    repository_d = d["repository"]
    tools_d = d["tools"]
    isempty(tools_d) && throw(ArgumentError("tools は最低1件必要です"))

    tools = QualityToolExecution[
        _qe_tool_execution_from_dict(String(name), t) for (name, t) in tools_d
    ]

    return QualityExport(;
        producer = QualityExportProducer(;
            name = producer_d["name"],
            version = producer_d["version"],
        ),
        package = QualityExportPackage(;
            name = package_d["name"],
            uuid = package_d["uuid"],
            version = package_d["version"],
        ),
        repository = QualityExportRepository(;
            owner = repository_d["owner"],
            name = repository_d["name"],
        ),
        branch = d["branch"],
        commit = d["commit"],
        measured_at = _qe_parse_datetime(d["measured_at"]),
        generated_at = _qe_parse_datetime(d["generated_at"]),
        julia_version = d["julia_version"],
        tools = tools,
    )
end

_qe_to_plain(x::JSON3.Object) =
    Dict{String, Any}(String(k) => _qe_to_plain(v) for (k, v) in pairs(x))
_qe_to_plain(x::JSON3.Array) = Any[_qe_to_plain(v) for v in x]
_qe_to_plain(x) = x

"""`quality_export_from_dict(_qe_to_plain(JSON3.read(s)))` の糖衣関数。"""
quality_export_from_json(s::AbstractString)::QualityExport =
    quality_export_from_dict(_qe_to_plain(JSON3.read(s)))

# ---------------------------------------------------------------------------
# 保存・読み込み（atomic rename）
# ---------------------------------------------------------------------------

"""
    save_quality_export(e::QualityExport, path::AbstractString; overwrite::Bool = true) -> String

`e` を `path` へ正準 JSON バイト列として atomic に保存する（`.tmp` へ書いて `fsync` した後
`mv`）。real-rate model artifact の atomic-write 規約を踏襲するが、こちらは
cross-repository の permanent content-addressed store ではなく CI 実行ごとの ephemeral
artifact（GitHub Actions Artifact としてのアップロードを想定、Issue #210）なので、
同名ファイルへの上書きを既定で許可する（`overwrite=false` で real-rate と同様に拒否できる）。
"""
function save_quality_export(
    e::QualityExport,
    path::AbstractString;
    overwrite::Bool = true,
)::String
    if !overwrite && isfile(path)
        throw(
            ArgumentError(
                "quality export ファイルが既に存在します（上書きしません）: $path",
            ),
        )
    end
    dir = dirname(path)
    isempty(dir) || mkpath(dir)
    tmp_path = path * ".tmp"
    bytes = canonical_json_bytes(to_dict(e))
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
    return path
end

"""`save_quality_export` が書いたファイルを読み込む。"""
load_quality_export(path::AbstractString)::QualityExport =
    quality_export_from_json(read(path, String))

# ---------------------------------------------------------------------------
# git commit/branch 自動検出（`scripts/quality_export.jl` から使う）
# ---------------------------------------------------------------------------

"""
    _qe_detect_branch(; dir = pkgdir(@__MODULE__)) -> Union{String,Nothing}

`GITHUB_HEAD_REF`/`GITHUB_REF_NAME`（GitHub Actions が設定する環境変数）を優先し、
なければ `git rev-parse --abbrev-ref HEAD` にフォールバックする。detached HEAD
（`"HEAD"` が返る）やいずれも失敗した場合は `nothing`。
"""
function _qe_detect_branch(;
    dir::AbstractString = pkgdir(@__MODULE__),
)::Union{String, Nothing}
    for var in ("GITHUB_HEAD_REF", "GITHUB_REF_NAME")
        v = get(ENV, var, "")
        isempty(v) || return v
    end
    try
        b = readchomp(`git -C $dir rev-parse --abbrev-ref HEAD`)
        return (isempty(b) || b == "HEAD") ? nothing : b
    catch
        return nothing
    end
end
