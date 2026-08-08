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
