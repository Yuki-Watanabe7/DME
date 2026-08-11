# test/test_quality_jet.jl
#
# JET.jl 統合（Issue #211）の回帰テスト。`scripts/jet_report_extract.jl`
# （JET.jl の生のreportオブジェクトから `QualityJetFinding` への抽出ロジック）を、
# 実際に `JET.report_call` を実行して検証する。
#
# **opt-in専用**: `test/runtests.jl` は `DME_QUALITY_EXPORT_JET_ENABLED` が設定されている
# ときだけ本ファイルを実行する（既定の `Pkg.test()` には含まれない）。JET.jl は slow lane
# 専用ツールであり、fast lane の所要時間へ影響を与えないという Issue #211 の要件
# （「通常CIの所要時間へ影響しない」）を保つため、`using JET` はこのファイル（および
# `scripts/jet_analysis_worker.jl`/`scripts/jet_report_extract.jl`）に限定する。
#
# `scripts/jet_analysis_worker.jl` 自体（subprocess・timeout制御を含む driver 経路）は
# ここでは検証しない — `scripts/quality_export_coverage.jl` 等の他 driver スクリプトと同じく
# 実行（手動/CI slow lane）がその役割を担う（test/test_quality_capture.jl 冒頭コメント
# 「run_quality_capture 自体...はここでは検証しない」と同じ方針）。
#
# 実行方法:
#   DME_QUALITY_EXPORT_JET_ENABLED=1 julia --project=. -e "using Pkg; Pkg.test()"

using JET

include(joinpath(@__DIR__, "..", "scripts", "jet_report_extract.jl"))

module _JetTestFixture
buggy(x::Int) = x + "not a number"  # 意図的な型エラー（JET.jl が検出することを期待する）
end

#: `hasproperty` の `:vst` 欠落フォールバックを検証するための、JET.jl に依存しない
#: 最小限のダミー report 型。
struct _NoVstFakeReport end

@testset "jet_report_extract: report_call against a synthetic buggy function" begin
    res = JET.report_call(_JetTestFixture.buggy, (Int,))
    reports = JET.get_reports(res)
    @test length(reports) >= 1

    findings = jet_findings_from_reports(reports; repo_root = @__DIR__)
    @test length(findings) == length(reports)
    @test all(f -> f.severity in QUALITY_JET_SEVERITIES, findings)
    @test any(f -> f.report_type == "MethodErrorReport", findings)

    method_error = only(filter(f -> f.report_type == "MethodErrorReport", findings))
    # buggy() はこのファイル自身に定義されているため、file は解決できるはず
    # （repo_root = @__DIR__ からの相対パスで "test_quality_jet.jl" になる）。
    @test method_error.file == "test_quality_jet.jl"
    @test method_error.line !== nothing
    @test method_error.severity == "error"

    ids = [f.id for f in findings]
    @test length(unique(ids)) == length(ids)

    result = quality_tool_jet_result(; findings = findings, target_modules = ["DME"])
    @test result["error_count"] == length(findings)
    @test result["analysis_mode"] == "report_package"
end

@testset "jet_virtual_frame_location: vst が使えない report へのフォールバック" begin
    @test jet_virtual_frame_location(_NoVstFakeReport(); repo_root = @__DIR__) ==
          (nothing, nothing)

    fake_empty_vst = (vst = [],)
    @test jet_virtual_frame_location(fake_empty_vst; repo_root = @__DIR__) ==
          (nothing, nothing)
end

@testset "jet_findings_from_reports: 空入力" begin
    @test jet_findings_from_reports([]; repo_root = @__DIR__) == QualityJetFinding[]
end
