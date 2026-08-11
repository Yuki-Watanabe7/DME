# Julia品質Export Contract v1（`julia-quality-export/v1`）— Issue #208。
#
# `Pkg.test` / `Aqua.jl` / `JuliaFormatter.jl` の実測結果を `QualityToolExecution.result`
# （`Dict{String,Any}`）へ組み立てる純粋関数群。Test.jl オブジェクト（`Test.AbstractTestSet`・
# `Test.TestSetException` 等）そのものは扱わない — それらへの依存（`record`/`finish`/
# `get_test_counts` といった `Test.jl` の拡張ポイント、および `TestSetException` の
# `pass`/`fail`/`error`/`broken`/`errors_and_fails` フィールド）は `test/runtests.jl` /
# `test/quality_capture_runner.jl`（`Test` が既に `test/Project.toml` の依存として存在する側）
# に閉じ込め、DME 本体（`src/`）が `Test` に依存しないようにする設計上の決定（Issue #208の
# 「tool result捕捉のためにTest internalsへ過度に依存しない設計を選び、制約を文書化する」を、
# 「Test.jl オブジェクトを直接扱う場所を test/ 側の1ファイルへ限定する」という形で満たす）。
#
# 制約（Test internals依存の範囲。test/quality_capture_runner.jl の docstring と対）:
#   - `Test.get_test_counts`・`Test.TestSetException` の各フィールドは Julia の Test stdlib
#     が公式にエクスポートしていない、または挙動を明記したドキュメントが薄い準内部 API。
#     Julia のマイナーバージョン更新で構造が変わる可能性があるため、値が取得できない場合は
#     例外を握りつぶさず `status=:failure` として報告する（本ファイルの `*_result` 関数は
#     そのための単純な Dict を受け取るだけで、取得失敗時の判断は呼び出し側が行う）。

"""
    quality_tool_pkgtest_result(; assertions_total, assertions_passed, failures, errors, broken) -> Dict{String,Any}

`Pkg.test` セクションの `result`。`assertions_total` は `assertions_passed + failures + errors +
broken` と一致する必要がある（`Test.TestSetException`/`Test.TestCounts` から呼び出し側が
集計した値をそのまま渡す想定で、内部で再集計はしない）。`suite_passed`（`failures == 0 &&
errors == 0`）は Dashboard 向けの生の事実の付記であり、閾値判定・品質スコアではない
（ADR 0009/0012 の「事実と評価の分離」と同じ扱い）。
"""
function quality_tool_pkgtest_result(;
    assertions_total::Integer,
    assertions_passed::Integer,
    failures::Integer,
    errors::Integer,
    broken::Integer,
)::Dict{String, Any}
    for (name, v) in (
        ("assertions_total", assertions_total),
        ("assertions_passed", assertions_passed),
        ("failures", failures),
        ("errors", errors),
        ("broken", broken),
    )
        v < 0 && throw(ArgumentError("Pkg.test result: $name は負の値にできません: $v"))
    end
    assertions_total == assertions_passed + failures + errors + broken || throw(
        ArgumentError(
            "Pkg.test result: assertions_total ($assertions_total) は " *
            "assertions_passed + failures + errors + broken ($(assertions_passed + failures + errors + broken)) " *
            "と一致する必要があります",
        ),
    )
    return Dict{String, Any}(
        "assertions_total" => Int(assertions_total),
        "assertions_passed" => Int(assertions_passed),
        "failures" => Int(failures),
        "errors" => Int(errors),
        "broken" => Int(broken),
        "suite_passed" => (failures == 0 && errors == 0),
    )
end

"""
    QualityAquaCheck(; name, passed, message = nothing)

Aqua.jl の1 check（例: `"Method ambiguity"`・`"Piracy"`）の結果。`message` は
`passed == false` のときのみ意味を持つ自由記述（`quality_tool_aqua_result` が
`redact_secrets` を適用する）。
"""
struct QualityAquaCheck
    name::String
    passed::Bool
    message::Union{String, Nothing}
end

function QualityAquaCheck(;
    name::AbstractString,
    passed::Bool,
    message::Union{AbstractString, Nothing} = nothing,
)::QualityAquaCheck
    _qe_check_nonempty(name, "aqua check name")
    return QualityAquaCheck(
        String(name),
        passed,
        message === nothing ? nothing : String(message),
    )
end

"""
    quality_tool_aqua_result(; checks::AbstractVector{QualityAquaCheck}, settings::AbstractDict) -> Dict{String,Any}

`Aqua.jl` セクションの `result`。`checks` は `Aqua.test_all` が実際に実行した check
（`persistent_tasks=false` 等で無効化した check は含まれない — 「未実行toolが success/0件に
ならない」の粒度を check 単位でも満たす: 無効化した check はそもそも `checks_run` に現れない）。
`settings` は `Aqua.test_all` へ渡した設定（`ambiguities`/`persistent_tasks` 等）の provenance。
"""
function quality_tool_aqua_result(;
    checks::AbstractVector{QualityAquaCheck},
    settings::AbstractDict = Dict{String, Any}(),
)::Dict{String, Any}
    isempty(checks) && throw(ArgumentError("Aqua.jl result: checks は最低1件必要です"))
    names = [c.name for c in checks]
    length(names) == length(Set(names)) ||
        throw(ArgumentError("Aqua.jl result: checks に重複した name があります"))

    checks_dict = Dict{String, Any}()
    failed_checks = String[]
    for c in checks
        entry = Dict{String, Any}("passed" => c.passed)
        if !c.passed
            push!(failed_checks, c.name)
            entry["message"] = c.message === nothing ? nothing : redact_secrets(c.message)
        end
        checks_dict[c.name] = entry
    end

    settings_dict = Dict{String, Any}(String(k) => v for (k, v) in settings)
    settings_dict === nothing ||
        _qe_reject_if_secret_like("Aqua.jl.settings", settings_dict)

    return Dict{String, Any}(
        "checks_run" => sort(names),
        "failed_checks" => sort(failed_checks),
        "checks" => checks_dict,
        "settings" => settings_dict,
    )
end

"""
    quality_tool_formatter_result(; formatted, unformatted_files) -> Dict{String,Any}

`JuliaFormatter.jl` セクションの `result`。`formatted == true` のとき `unformatted_files` は
空でなければならない（矛盾した入力を構造的に排除する。`QualityToolExecution` の
`status` ごとの必須/禁止フィールドと同じ考え方）。パスは呼び出し側が `src/` からの相対パスへ
変換してから渡すこと（絶対パスは実行環境依存になり Dashboard 側で比較できない）。
"""
function quality_tool_formatter_result(;
    formatted::Bool,
    unformatted_files::AbstractVector{<:AbstractString},
)::Dict{String, Any}
    if formatted && !isempty(unformatted_files)
        throw(
            ArgumentError(
                "JuliaFormatter.jl result: formatted=true のとき unformatted_files は空である必要があります",
            ),
        )
    end
    if !formatted && isempty(unformatted_files)
        throw(
            ArgumentError(
                "JuliaFormatter.jl result: formatted=false のとき unformatted_files は空にできません",
            ),
        )
    end
    return Dict{String, Any}(
        "formatted" => formatted,
        "unformatted_files" => sort(String.(unformatted_files)),
    )
end

"""現在時刻を UTC の秒精度 `DateTime` として返す（`scripts/quality_export.jl` の `_now_utc()` と
同じ MVP 制約: `TimeZones.jl` を使わない `Dates.unix2datetime` 慣行）。"""
_qc_now_utc()::DateTime = Dates.floor(Dates.unix2datetime(time()), Dates.Second)

# ---------------------------------------------------------------------------
# JET.jl（Issue #211）
# ---------------------------------------------------------------------------
#
# JET.jl 自体は `src/` の実行時依存にしない（`test/Project.toml` のみに追加した
# slow-lane専用ツール。`using DME` する一般ユーザーに JET を強制しない設計判断、
# Pkg.test/Aqua.jl/Coverage.jl と同じ「ツール固有オブジェクトへの依存は src/ の外へ
# 閉じ込める」方針の踏襲）。そのため本ファイルは `JET.InferenceErrorReport` 等の
# JET.jl の型を一切参照しない。JET の生の解析結果（`JETToplevelResult`）から
# `QualityJetFinding` の `Vector` を組み立てる処理は `scripts/jet_report_extract.jl`
# （`using JET` する側）が担い、本ファイルはその後の「すでに文字列/整数へ展開済みの
# finding から result dict を作る」部分だけを純粋関数として提供する
# （`quality_tool_aqua_result` が Test.jl オブジェクトを扱わないのと同じ設計）。
#
# 対象範囲の決定（Issue #211 実施内容「初期対象と除外対象を明文化する」への回答。
# 詳細な根拠は docs/contract/julia-quality-export-v1.md §4.3）:
#   - 解析方式は `JET.report_package(DME; target_modules=(DME,))`
#     （`JET.report_call` ではなく）を採用する。DME に定義された全メソッドの
#     シグネチャから静的に解析するため、個別の entry point（主要公開API・
#     中核モデル実行経路・シナリオ/分析層 等）を手動で列挙する必要がなく、
#     package全体を一度に棚卸しできる。
#   - `target_modules=(DME,)` により、報告対象を「最終的に DME 自身のモジュール
#     コンテキストで発生したもの」に限定し、JuMP/Ipopt/Plots/Base 等の依存
#     パッケージ内部だけで完結する finding を除外する
#     （JET 公式ドキュメントが推奨する「dependency由来reportとDME由来reportを
#     区別する」ための標準的な設定）。
#   - `src/` 配下を一律に対象とし、`examples/`/`scripts/`/`test/` は対象外
#     （`report_package` は module に定義されたメソッドのみを解析するため、
#     これらのディレクトリのコードはそもそも DME モジュールのメソッドとして
#     定義されておらず、追加の除外設定なしに対象外になる）。
#   - 特定ファイル/ディレクトリを個別に除外する設定は初期導入では行わない
#     （実測: `src/data/`（動的 JSON 応答を扱う FRED/e-Stat クライアント）に
#     finding が集中する傾向を確認したが、severity を "unrated"/advisory に
#     留めることで対応し、対象そのものから外して不可視化はしない — ADR 0009/0012
#     等の「事実の保持と評価の分離」を踏襲）。

"""JET.jl finding の severity 3値。`error`/`warning` は既知の report 型への
advisory的な分類であり、CI gate の判定には使わない（Issue #211「JET error countの
閾値は実データ収集前に固定しない。初期はunratedまたはadvisoryとして扱う」）。
`unrated` は `QUALITY_JET_SEVERITY_MAP` に無い（＝将来 JET.jl が追加する未知の）
report 型の既定値。"""
const QUALITY_JET_SEVERITIES = ("error", "warning", "unrated")

#: JET.jl の report 型名（`JET.` 修飾子を除いた短縮名）→ severity。未知の型は
#: `quality_jet_finding_severity` の既定 `"unrated"` にフォールバックする
#: （このmapに無い型を誤って"error"/"warning"に丸めない）。
#: `error`: 実行時に確実にエラーとなる呼び出し形状を示す report 型
#: （method dispatch 不能・未定義変数・divide error 等）。
#: `warning`: `throw`/`error` 呼び出しに由来する report 型
#: （意図的な interface 未実装・validation 等である可能性があり、`report_package`
#: の既定 `ignore_throws=true` で通常は抑制されるが、明示的に無効化した解析では
#: 現れうる）。
const QUALITY_JET_SEVERITY_MAP = Dict{String, String}(
    "MethodErrorReport" => "error",
    "InvalidInvokeErrorReport" => "error",
    "UndefVarErrorReport" => "error",
    "UndefKeywordErrorReport" => "error",
    "DivideErrorReport" => "error",
    "NonBooleanCondErrorReport" => "error",
    "BuiltinErrorReport" => "error",
    "GeneratorErrorReport" => "error",
    "UncaughtExceptionReport" => "warning",
    "SeriousExceptionReport" => "warning",
    "UnanalyzedCallErrorReport" => "warning",
)

"""`report_type`（例: `"JET.MethodErrorReport"` または `"MethodErrorReport"`）から
severity を引く。`QUALITY_JET_SEVERITY_MAP` に無い型は `"unrated"`。"""
function quality_jet_finding_severity(report_type::AbstractString)::String
    short = String(split(report_type, '.')[end])
    return get(QUALITY_JET_SEVERITY_MAP, short, "unrated")
end

"""
    QualityJetFinding(; id, report_type, message, severity = quality_jet_finding_severity(report_type),
                         file = nothing, line = nothing)

JET.jl の1 finding。`file`/`line` は取得できない場合 `nothing` を許す
（contract doc §4「file/line（取得可能な場合）」）。`message` は自由記述のため
`redact_secrets` を自動適用する（`QualityToolError` と同じ二重防御）。
"""
struct QualityJetFinding
    id::String
    report_type::String
    message::String
    severity::String
    file::Union{String, Nothing}
    line::Union{Int, Nothing}
end

function QualityJetFinding(;
    id::AbstractString,
    report_type::AbstractString,
    message::AbstractString,
    severity::AbstractString = quality_jet_finding_severity(report_type),
    file::Union{AbstractString, Nothing} = nothing,
    line::Union{Integer, Nothing} = nothing,
)::QualityJetFinding
    _qe_check_nonempty(id, "JET finding id")
    _qe_check_nonempty(report_type, "JET finding report_type")
    _qe_check_nonempty(message, "JET finding message")
    severity in QUALITY_JET_SEVERITIES || throw(
        ArgumentError(
            "JET finding severity は $(QUALITY_JET_SEVERITIES) のいずれかである必要があります: $severity",
        ),
    )
    (line === nothing || line >= 1) ||
        throw(ArgumentError("JET finding line は1以上である必要があります: $line"))
    return QualityJetFinding(
        String(id),
        String(report_type),
        redact_secrets(String(message)),
        severity,
        file === nothing ? nothing : String(file),
        line === nothing ? nothing : Int(line),
    )
end

"""
    quality_jet_stable_finding_ids(entries::AbstractVector{<:Tuple}) -> Vector{String}

`entries`（`(report_type, file, line, message)` の `Tuple` の `Vector`、`report_package`
が返す順序のまま渡す想定）から finding id を安定的に生成する。id は
`sha1("report_type|file|line|message")` の先頭12桁hex。同一4-tupleが複数回現れる場合
（JET.jl 自体が同一箇所を重複して報告するケースを理論上排除しない）でも `-2`・`-3`...
を付与し一意性を保つ（Issue #211「duplicate finding IDを安定回避できる」要件）。

安定性は「同一コミット・同一 JET.jl バージョンでの解析順序が変わらない限り」という条件
付きである点に注意（JET.jl 自体の解析順序保証に依存する。将来 JET.jl バージョンの更新で
既存 id が変わりうる — Dashboard 側での永続的な finding 追跡には使えない、単一 export
内での一意性のみを保証する）。
"""
function quality_jet_stable_finding_ids(entries::AbstractVector{<:Tuple})::Vector{String}
    seen = Dict{String, Int}()
    ids = String[]
    for (report_type, file, line, message) in entries
        key = string(report_type, "|", file, "|", line, "|", message)
        base = bytes2hex(SHA.sha1(key))[1:12]
        n = get(seen, base, 0) + 1
        seen[base] = n
        push!(ids, n == 1 ? base : "$base-$n")
    end
    return ids
end

#: `quality_tool_jet_result` の `analysis_mode` として初期に許可する値
#: （本ファイル冒頭「JET.jl（Issue #211）」節の対象範囲の決定により、初期導入は
#: `report_package` のみ）。
const QUALITY_JET_ANALYSIS_MODES = ("report_package",)

"""
    quality_tool_jet_result(; findings, target_modules, analysis_mode = "report_package",
                               ignore_missing_comparison = true, ignore_throws = true) -> Dict{String,Any}

`JET.jl` セクションの `result`。`findings` は空でもよい（0件成功。Issue #211
「0件成功、複数finding、timeout、crash、未導入を区別できる」の「0件成功」に対応 —
`status=:success` かつ `findings=[]` は「解析して0件だった」を表し、`status=:skipped`
（未実行）とは構造的に異なる）。`error_count` は `length(findings)` から自動導出する
（呼び出し側の入力にできない。矛盾した入力を構造的に排除する既存方針と同じ）。

`target_modules`/`analysis_mode`/`ignore_missing_comparison`/`ignore_throws` は
「target/ignore configuration」（Issue #211 実施内容）の記録であり、この export
だけから解析条件を再現できるようにする provenance。
"""
function quality_tool_jet_result(;
    findings::AbstractVector{QualityJetFinding},
    target_modules::AbstractVector{<:AbstractString},
    analysis_mode::AbstractString = "report_package",
    ignore_missing_comparison::Bool = true,
    ignore_throws::Bool = true,
)::Dict{String, Any}
    ids = [f.id for f in findings]
    length(ids) == length(Set(ids)) ||
        throw(ArgumentError("JET.jl result: findings に重複した id があります"))
    isempty(target_modules) &&
        throw(ArgumentError("JET.jl result: target_modules は最低1件必要です"))
    analysis_mode in QUALITY_JET_ANALYSIS_MODES || throw(
        ArgumentError(
            "JET.jl result: analysis_mode は $(QUALITY_JET_ANALYSIS_MODES) のいずれかである必要があります: $analysis_mode",
        ),
    )

    findings_arr = Any[
        Dict{String, Any}(
            "id" => f.id,
            "report_type" => f.report_type,
            "message" => f.message,
            "severity" => f.severity,
            "file" => f.file,
            "line" => f.line,
        ) for f in findings
    ]
    return Dict{String, Any}(
        "error_count" => length(findings),
        "findings" => findings_arr,
        "target_modules" => sort(String.(target_modules)),
        "analysis_mode" => String(analysis_mode),
        "config" => Dict{String, Any}(
            "ignore_missing_comparison" => ignore_missing_comparison,
            "ignore_throws" => ignore_throws,
        ),
    )
end

# ---------------------------------------------------------------------------
# Coverage.jl（Issue #209）
# ---------------------------------------------------------------------------
#
# 測定対象は `src/**` に限定する（`examples/`・`scripts/`・`test/` は対象外）。
# `Coverage.process_folder` に渡すフォルダをこの1箇所だけに固定することで、
# 対象/除外の判断が呼び出し側（`scripts/quality_export_coverage.jl`）ごとにばらつかない
# ようにする。`docs/contract/julia-quality-export-v1.md` §4.2 と対。
#
# `src/` だけを渡すことで、JuMP・Ipopt・Plots 等の依存パッケージ本体のコード
# （`~/.julia/packages/...` 以下にインストールされる。`--code-coverage=user` はそれらにも
# `.cov` を生成するが、別ディレクトリに書かれるため `process_folder("src")` はそもそも
# 読みに行かない）が測定対象へ混入することはない。DME 自身がサブプロセスを spawn しないため
# （`addprocs`/`Distributed`/`` `julia ...` `` 呼び出しは無し）、`Pkg.test()` が spawn する
# 唯一のテスト実行サブプロセス以外の coverage 欠落も発生しない。
const QUALITY_COVERAGE_TARGET_PATHS = ["src"]
const QUALITY_COVERAGE_EXCLUDED_PATHS = ["examples", "scripts", "test"]

"""
    quality_tool_coverage_result(; covered_lines, coverable_lines,
                                    target_paths = QUALITY_COVERAGE_TARGET_PATHS,
                                    excluded_paths = QUALITY_COVERAGE_EXCLUDED_PATHS) -> Dict{String,Any}

`Coverage.jl` セクションの `result`。`covered_lines`/`coverable_lines` は
`Coverage.process_folder(folder) |> Coverage.get_summary` の戻り値（`(covered, total)`）を
そのまま渡す想定。

DME 側では coverage **percent は計算しない**（`covered_lines`/`coverable_lines` の2値のみを
保持する）。`software-quality-dashboard` の Julia Native Provider
（`providers/julia/mapper.py` の `"Coverage.jl"` ケース）が `covered_lines/coverable_lines` から
`julia.line_coverage` を算出する契約側であり、Producer（DME）側でも percent を持つと
丸め方式の食い違いで2つの数字が矛盾しうる（Issue #209 の「line_coverage percent は
Producer/Consumer どちらで計算するか」を Consumer 側の既存実装に合わせて確定した）。

`coverable_lines <= 0` は「0%」ではなく計測不能（`.cov` トレースファイルが1件も生成されな
かった等）を意味するため拒否する。呼び出し側はこの場合 `quality_tool_coverage_result` を
呼ばず、`status = :failure` の `QualityToolExecution` を直接組み立てること
（`quality_tool_pkgtest_result`/`quality_tool_formatter_result` と同じ「矛盾した入力を
構造的に排除する」方針）。
"""
function quality_tool_coverage_result(;
    covered_lines::Integer,
    coverable_lines::Integer,
    target_paths::AbstractVector{<:AbstractString} = QUALITY_COVERAGE_TARGET_PATHS,
    excluded_paths::AbstractVector{<:AbstractString} = QUALITY_COVERAGE_EXCLUDED_PATHS,
)::Dict{String, Any}
    covered_lines < 0 && throw(
        ArgumentError(
            "Coverage.jl result: covered_lines は負の値にできません: $covered_lines",
        ),
    )
    coverable_lines <= 0 && throw(
        ArgumentError(
            "Coverage.jl result: coverable_lines は正の値である必要があります " *
            "（0以下は計測不能であり status=:failure として報告すること）: $coverable_lines",
        ),
    )
    covered_lines <= coverable_lines || throw(
        ArgumentError(
            "Coverage.jl result: covered_lines ($covered_lines) は coverable_lines " *
            "($coverable_lines) を超えられません",
        ),
    )
    isempty(target_paths) &&
        throw(ArgumentError("Coverage.jl result: target_paths は最低1件必要です"))
    return Dict{String, Any}(
        "covered_lines" => Int(covered_lines),
        "coverable_lines" => Int(coverable_lines),
        "target_paths" => sort(String.(target_paths)),
        "excluded_paths" => sort(String.(excluded_paths)),
    )
end
