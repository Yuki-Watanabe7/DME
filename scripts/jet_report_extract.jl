# scripts/jet_report_extract.jl
#
# Julia品質Export Contract v1（Issue #211）: `JET.get_reports` が返す report オブジェクト
# （`JET.InferenceErrorReport` の具象型。例: `JET.MethodErrorReport`）を
# `QualityJetFinding`（src/quality/quality_capture.jl）へ変換する純ライブラリ。
#
# JET.jl の型に触れる処理をこのファイルへ閉じ込め、DME 本体（`src/`）には一切持ち込まない
# （`test/quality_capture_runner.jl` が Test.jl オブジェクトを、
# `scripts/quality_export_coverage.jl` が Coverage.jl のトレースファイルを同様に閉じ込めて
# いるのと同じ設計判断 — `src/quality/quality_capture.jl` 冒頭「JET.jl（Issue #211）」節参照。
# `using DME` する一般ユーザーに JET.jl を実行時依存として強制しない）。
#
# 本ファイルは `main()` 実行を持たない、副作用なしの `include` 可能ファイル。実際に解析を
# 実行してファイルへ書き出す側は `scripts/jet_analysis_worker.jl`。
# `test/test_quality_jet.jl` からも `include(joinpath(@__DIR__, "..", "scripts",
# "jet_report_extract.jl"))` で直接再利用する（worker を subprocess として起動せずに
# 抽出ロジック自体を検証できるようにするため）。
#
# 呼び出し側は事前に `using DME`（`QualityJetFinding`/`quality_jet_stable_finding_ids` 用）と
# `using JET` を済ませておくこと（本ファイル自体は `using` 文を持たない — 呼び出し側の
# 環境・world に依存させない）。

"""
    jet_virtual_frame_location(report; repo_root) -> (file, line)

`report.vst`（`JET.VirtualFrame` の `Vector`。`report_package`/`report_call` 共通の
インターフェース）の**末尾**（＝最も内側、実際にエラー条件が生じたフレーム）から
file/line を取り出し、`repo_root` からの相対パスへ変換して返す
（`scripts/quality_export_coverage.jl` の「パスは呼び出し側が src/ からの相対パスへ変換して
から渡す」方針と同じ — CI ランナー固有の絶対パスをそのまま export に残さない）。

以下の場合は `(nothing, nothing)` を返す（contract §4「file/lineなしreportもvalid export
になる」への対応）:
  - `report` が `vst` フィールドを持たない（top-level error 等、`InferenceErrorReport` 系
    以外の report 型である可能性がある。`JET.get_reports` の docstring が言及する
    「top-level errors take precedence」の経路）
  - `vst` が空
  - `file` が実ファイルを指さない（マクロ生成コード等で空/`none`/`missing` のような
    sentinel になる場合）
"""
function jet_virtual_frame_location(
    report;
    repo_root::AbstractString,
)::Tuple{Union{String, Nothing}, Union{Int, Nothing}}
    hasproperty(report, :vst) || return (nothing, nothing)
    vst = report.vst
    isempty(vst) && return (nothing, nothing)
    frame = vst[end]
    file_str = String(frame.file)
    (isempty(file_str) || file_str in ("none", "missing", "unknown")) &&
        return (nothing, nothing)
    abs_path = isabspath(file_str) ? file_str : joinpath(repo_root, file_str)
    rel_path = try
        relpath(abs_path, repo_root)
    catch
        file_str
    end
    line =
        (hasproperty(frame, :line) && frame.line isa Integer && frame.line >= 1) ?
        Int(frame.line) : nothing
    return (rel_path, line)
end

"""
    jet_findings_from_reports(reports; repo_root) -> Vector{QualityJetFinding}

`reports`（`JET.get_reports(res)` の戻り値。空でもよい）から `QualityJetFinding` の
`Vector` を作る。finding id は `quality_jet_stable_finding_ids`
（`src/quality/quality_capture.jl`）で `(report_type, file, line, message)` から
安定生成する（同一箇所への複数finding・file/line欠落のいずれでも一意なidになる）。

`report_type` は `typeof(r).name.name`（モジュール修飾子を除いた型名。例:
`"MethodErrorReport"`）を使う。`quality_jet_finding_severity`（呼び出し元の
`QualityJetFinding` コンストラクタが既定で使う）はこの短縮名で severity を引く。
"""
function jet_findings_from_reports(
    reports;
    repo_root::AbstractString,
)::Vector{QualityJetFinding}
    isempty(reports) && return QualityJetFinding[]

    report_types = String[string(typeof(r).name.name) for r in reports]
    locations = [jet_virtual_frame_location(r; repo_root = repo_root) for r in reports]
    messages = String[sprint(JET.print_report_message, r) for r in reports]

    id_entries = [
        (report_types[i], locations[i][1], locations[i][2], messages[i]) for
        i in eachindex(reports)
    ]
    ids = quality_jet_stable_finding_ids(id_entries)

    return QualityJetFinding[
        QualityJetFinding(;
            id = ids[i],
            report_type = report_types[i],
            message = messages[i],
            file = locations[i][1],
            line = locations[i][2],
        ) for i in eachindex(reports)
    ]
end
