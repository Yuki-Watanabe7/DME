# src/quality/quality_capture.jl（Issue #208/#209）のテスト。
# Pkg.test/Aqua.jl/JuliaFormatter.jl/Coverage.jl の result 組み立て（純粋関数、Test.jl
# オブジェクトを扱わない）と、test/quality_capture_runner.jl が依存する Test.jl の挙動の前提
# （本ファイル末尾）を検証する。`run_quality_capture` 自体（実際に Pkg.test() 全体を再帰的に
# 走らせる必要がある）・`scripts/quality_export_coverage.jl` 自体（`Pkg.test(coverage=true)` を
# 再帰的に呼ぶ）はここでは検証しない — 実行（手動/CI）がその役割を担う
# （docs/contract/julia-quality-export-v1.md §8）。

using Coverage  # Coverage.jl 統合テスト用（Issue #209、test/Project.toml の依存）

@testset "quality_tool_pkgtest_result" begin
    r = quality_tool_pkgtest_result(;
        assertions_total = 10,
        assertions_passed = 9,
        failures = 1,
        errors = 0,
        broken = 0,
    )
    @test r["assertions_total"] == 10
    @test r["assertions_passed"] == 9
    @test r["failures"] == 1
    @test r["suite_passed"] == false

    r0 = quality_tool_pkgtest_result(;
        assertions_total = 5,
        assertions_passed = 5,
        failures = 0,
        errors = 0,
        broken = 0,
    )
    @test r0["suite_passed"] == true

    # assertions_total は内訳の合計と一致しなければならない
    @test_throws ArgumentError quality_tool_pkgtest_result(;
        assertions_total = 5,
        assertions_passed = 1,
        failures = 1,
        errors = 1,
        broken = 1,
    )
    # 負の値は拒否する
    @test_throws ArgumentError quality_tool_pkgtest_result(;
        assertions_total = -1,
        assertions_passed = 0,
        failures = 0,
        errors = 0,
        broken = 0,
    )
end

@testset "QualityAquaCheck" begin
    c = QualityAquaCheck(;
        name = "Piracy",
        passed = false,
        message = "leaked FRED_API_KEY=abcd1234efgh5678",
    )
    @test c.name == "Piracy"
    @test c.passed == false
    @test c.message !== nothing
    @test_throws ArgumentError QualityAquaCheck(; name = "", passed = true)
end

@testset "quality_tool_aqua_result" begin
    checks = [
        QualityAquaCheck(; name = "Method ambiguity", passed = true),
        QualityAquaCheck(; name = "Piracy", passed = false, message = "some piracy detail"),
    ]
    r = quality_tool_aqua_result(;
        checks = checks,
        settings = Dict(
            "ambiguities" => Dict("recursive" => false),
            "persistent_tasks" => false,
        ),
    )
    @test r["checks_run"] == ["Method ambiguity", "Piracy"]
    @test r["failed_checks"] == ["Piracy"]
    @test r["checks"]["Method ambiguity"]["passed"] == true
    @test !haskey(r["checks"]["Method ambiguity"], "message")
    @test r["checks"]["Piracy"]["passed"] == false
    @test r["checks"]["Piracy"]["message"] == "some piracy detail"
    @test r["settings"]["persistent_tasks"] == false

    # 空 checks は拒否
    @test_throws ArgumentError quality_tool_aqua_result(; checks = QualityAquaCheck[])

    # 重複した check name は拒否
    dup = [
        QualityAquaCheck(; name = "Piracy", passed = true),
        QualityAquaCheck(; name = "Piracy", passed = false, message = "x"),
    ]
    @test_throws ArgumentError quality_tool_aqua_result(; checks = dup)

    # message 中の秘匿情報らしき文字列は redact される
    secret_checks = [
        QualityAquaCheck(;
            name = "Piracy",
            passed = false,
            message = "token=abcdefghijklmnopqrstuvwxyz0123",
        ),
    ]
    r2 = quality_tool_aqua_result(; checks = secret_checks)
    @test occursin("[REDACTED]", r2["checks"]["Piracy"]["message"])
    @test !occursin("abcdefghijklmnopqrstuvwxyz0123", r2["checks"]["Piracy"]["message"])

    # settings に秘匿情報らしき文字列が含まれる場合は拒否する（構造化データは redact でなく reject）
    @test_throws ArgumentError quality_tool_aqua_result(;
        checks = [QualityAquaCheck(; name = "Piracy", passed = true)],
        settings = Dict("note" => "token=abcdefghijklmnopqrstuvwxyz0123"),
    )
end

@testset "quality_tool_formatter_result" begin
    r_ok = quality_tool_formatter_result(; formatted = true, unformatted_files = String[])
    @test r_ok["formatted"] == true
    @test r_ok["unformatted_files"] == String[]

    r_bad = quality_tool_formatter_result(;
        formatted = false,
        unformatted_files = ["models/ramsey.jl", "core/simulation_result.jl"],
    )
    @test r_bad["formatted"] == false
    @test r_bad["unformatted_files"] == ["core/simulation_result.jl", "models/ramsey.jl"]  # sorted

    # 矛盾した入力は拒否する
    @test_throws ArgumentError quality_tool_formatter_result(;
        formatted = true,
        unformatted_files = ["a.jl"],
    )
    @test_throws ArgumentError quality_tool_formatter_result(;
        formatted = false,
        unformatted_files = String[],
    )
end

@testset "quality_tool_coverage_result" begin
    r = quality_tool_coverage_result(; covered_lines = 1224, coverable_lines = 1642)
    @test r["covered_lines"] == 1224
    @test r["coverable_lines"] == 1642
    @test r["target_paths"] == QUALITY_COVERAGE_TARGET_PATHS
    @test r["excluded_paths"] == sort(QUALITY_COVERAGE_EXCLUDED_PATHS)

    r2 = quality_tool_coverage_result(;
        covered_lines = 3,
        coverable_lines = 4,
        target_paths = ["src"],
        excluded_paths = ["test", "examples"],
    )
    @test r2["target_paths"] == ["src"]
    @test r2["excluded_paths"] == ["examples", "test"]  # sorted

    # covered_lines == coverable_lines（100%）は許容される
    full = quality_tool_coverage_result(; covered_lines = 10, coverable_lines = 10)
    @test full["covered_lines"] == full["coverable_lines"] == 10

    # coverable_lines <= 0 は「0%」ではなく計測不能であり拒否する（§4.2）
    @test_throws ArgumentError quality_tool_coverage_result(;
        covered_lines = 0,
        coverable_lines = 0,
    )
    @test_throws ArgumentError quality_tool_coverage_result(;
        covered_lines = 0,
        coverable_lines = -1,
    )
    # covered_lines は負にできない
    @test_throws ArgumentError quality_tool_coverage_result(;
        covered_lines = -1,
        coverable_lines = 10,
    )
    # covered_lines は coverable_lines を超えられない
    @test_throws ArgumentError quality_tool_coverage_result(;
        covered_lines = 11,
        coverable_lines = 10,
    )
    # target_paths は最低1件必要
    @test_throws ArgumentError quality_tool_coverage_result(;
        covered_lines = 1,
        coverable_lines = 1,
        target_paths = String[],
    )
end

@testset "quality_jet_finding_severity" begin
    @test quality_jet_finding_severity("MethodErrorReport") == "error"
    @test quality_jet_finding_severity("JET.MethodErrorReport") == "error"  # モジュール修飾子つきでも解決できる
    @test quality_jet_finding_severity("UndefVarErrorReport") == "error"
    @test quality_jet_finding_severity("UncaughtExceptionReport") == "warning"
    # QUALITY_JET_SEVERITY_MAP に無い（将来 JET.jl が追加しうる）型は unrated にフォールバックする
    @test quality_jet_finding_severity("SomeFutureReportType") == "unrated"
    @test quality_jet_finding_severity("") == "unrated"
end

@testset "QualityJetFinding" begin
    f = QualityJetFinding(;
        id = "abc123",
        report_type = "MethodErrorReport",
        message = "no matching method found `+(::Int64, ::String)`",
        file = "src/foo.jl",
        line = 10,
    )
    @test f.id == "abc123"
    @test f.severity == "error"  # 既定は quality_jet_finding_severity(report_type)
    @test f.file == "src/foo.jl"
    @test f.line == 10

    # file/line は省略可能（contract §4「file/lineなしreportもvalid exportになる」）
    f_no_loc = QualityJetFinding(;
        id = "def456",
        report_type = "SomeFutureReportType",
        message = "unknown report kind",
    )
    @test f_no_loc.file === nothing
    @test f_no_loc.line === nothing
    @test f_no_loc.severity == "unrated"

    # severity を明示的に上書きできる
    f_override = QualityJetFinding(;
        id = "ghi789",
        report_type = "MethodErrorReport",
        message = "m",
        severity = "warning",
    )
    @test f_override.severity == "warning"

    @test_throws ArgumentError QualityJetFinding(;
        id = "",
        report_type = "MethodErrorReport",
        message = "m",
    )
    @test_throws ArgumentError QualityJetFinding(;
        id = "x",
        report_type = "MethodErrorReport",
        message = "m",
        severity = "critical",  # QUALITY_JET_SEVERITIES に無い値
    )
    @test_throws ArgumentError QualityJetFinding(;
        id = "x",
        report_type = "MethodErrorReport",
        message = "m",
        line = 0,  # 1未満は不正
    )

    # message 中の秘匿情報らしき文字列は redact される（QualityToolError と同じ二重防御）
    f_secret = QualityJetFinding(;
        id = "secret1",
        report_type = "MethodErrorReport",
        message = "token=abcdefghijklmnopqrstuvwxyz0123",
    )
    @test occursin("[REDACTED]", f_secret.message)
    @test !occursin("abcdefghijklmnopqrstuvwxyz0123", f_secret.message)
end

@testset "quality_jet_stable_finding_ids" begin
    ids = quality_jet_stable_finding_ids([
        ("MethodErrorReport", "a.jl", 1, "m1"),
        ("MethodErrorReport", "a.jl", 2, "m2"),
        ("UndefVarErrorReport", "b.jl", 3, "m3"),
    ])
    @test length(ids) == 3
    @test length(unique(ids)) == 3  # 一意

    # 同一4-tupleが重複しても、id は連番付きで一意になる（Issue #211「duplicate finding ID
    # を安定回避できる」要件）
    dup_ids = quality_jet_stable_finding_ids([
        ("MethodErrorReport", "a.jl", 1, "m1"),
        ("MethodErrorReport", "a.jl", 1, "m1"),
        ("MethodErrorReport", "a.jl", 1, "m1"),
    ])
    @test length(unique(dup_ids)) == 3
    @test dup_ids[1] != dup_ids[2] != dup_ids[3]
    @test !occursin("-", dup_ids[1])  # 最初の出現は連番なしのベースid
    @test endswith(dup_ids[2], "-2")
    @test endswith(dup_ids[3], "-3")

    # 同じ入力からは同じ id 列が決定的に得られる（安定性）
    ids_again = quality_jet_stable_finding_ids([
        ("MethodErrorReport", "a.jl", 1, "m1"),
        ("MethodErrorReport", "a.jl", 2, "m2"),
        ("UndefVarErrorReport", "b.jl", 3, "m3"),
    ])
    @test ids == ids_again

    # file/line が nothing（未取得）でも動く
    ids_no_loc = quality_jet_stable_finding_ids([("SomeReport", nothing, nothing, "m")])
    @test length(ids_no_loc) == 1
end

@testset "quality_tool_jet_result" begin
    findings = [
        QualityJetFinding(;
            id = "f1",
            report_type = "MethodErrorReport",
            message = "m1",
            file = "src/a.jl",
            line = 1,
        ),
        QualityJetFinding(; id = "f2", report_type = "UndefVarErrorReport", message = "m2"),
    ]
    r = quality_tool_jet_result(; findings = findings, target_modules = ["DME"])
    @test r["error_count"] == 2
    @test length(r["findings"]) == 2
    @test r["target_modules"] == ["DME"]
    @test r["analysis_mode"] == "report_package"
    @test r["config"]["ignore_missing_comparison"] == true
    @test r["config"]["ignore_throws"] == true

    # 0件成功（「未実行」の :skipped とは異なる、「実行して0件だった」という別の意味）
    r0 = quality_tool_jet_result(; findings = QualityJetFinding[], target_modules = ["DME"])
    @test r0["error_count"] == 0
    @test r0["findings"] == Any[]

    # target_modules は最低1件必要
    @test_throws ArgumentError quality_tool_jet_result(;
        findings = QualityJetFinding[],
        target_modules = String[],
    )

    # 未知の analysis_mode は拒否する
    @test_throws ArgumentError quality_tool_jet_result(;
        findings = QualityJetFinding[],
        target_modules = ["DME"],
        analysis_mode = "report_call",
    )

    # 重複した id を持つ findings は拒否する
    dup_findings = [
        QualityJetFinding(; id = "same", report_type = "MethodErrorReport", message = "m1"),
        QualityJetFinding(;
            id = "same",
            report_type = "UndefVarErrorReport",
            message = "m2",
        ),
    ]
    @test_throws ArgumentError quality_tool_jet_result(;
        findings = dup_findings,
        target_modules = ["DME"],
    )
end

@testset "Coverage.jl: process_folder/get_summary against a known fixture" begin
    # DME 本体の src/ は行数が変わりうるため決定的な期待値を置けない。既知の
    # covered/coverable 行数になる小規模 fixture module を実際にサブプロセスで
    # `--code-coverage=user` 付きで実行し、Coverage.process_folder/get_summary の戻り値が
    # scripts/quality_export_coverage.jl（driver プロセス側）が期待する形と一致することを
    # 検証する。`.cov` はそれを生成したプロセスが終了したときにのみディスクへ書かれるため
    # （scripts/quality_export_coverage.jl 冒頭コメント参照）、サブプロセスの終了を
    # `run(...)` で待ってから読む。
    mktempdir() do dir
        fixture_path = joinpath(dir, "coverage_fixture.jl")
        write(
            fixture_path,
            """
            module CoverageFixture

            function classify(x)
                if x > 0
                    return :positive
                else
                    return :nonpositive
                end
            end

            end # module
            """,
        )
        driver_path = joinpath(dir, "run_fixture.jl")
        write(
            driver_path,
            """
            include("coverage_fixture.jl")
            using .CoverageFixture
            CoverageFixture.classify(5)
            """,
        )
        run(`$(Base.julia_cmd()) --startup-file=no --code-coverage=user $driver_path`)

        file_coverages = process_folder(dir)
        covered, coverable = get_summary(file_coverages)
        # classify(5) だけ呼んでいるため: function 行・if 行・:positive 行の3行が実行され、
        # :nonpositive 行（else 節）は coverable だが未実行の4行目として残る（本 Issue の
        # 作業中に実測して固定した既知値。coverage_fixture.jl の内容を変えたら要更新）。
        @test covered == 3
        @test coverable == 4

        result = quality_tool_coverage_result(;
            covered_lines = covered,
            coverable_lines = coverable,
        )
        @test result["covered_lines"] == 3
        @test result["coverable_lines"] == 4

        clean_folder(dir)
        @test isempty(filter(f -> endswith(f, ".cov"), readdir(dir; join = true)))
    end
end

# test/quality_capture_runner.jl が依存する Test.jl 自身の挙動の前提（Julia の Test stdlib の
# マイナーバージョン更新で壊れうる、準内部 API への依存の回帰テスト。
# src/quality/quality_capture.jl 冒頭コメント・test/quality_capture_runner.jl 冒頭コメント参照）。
#
# 検証のため意図的に失敗する @test を1件実行するが、`Test.push_testset`/`pop_testset` で
# 現在のテストセットスタックから完全に隔離した使い捨てルート（`fresh_root`）の中で実行する
# ため、この意図的な失敗はこのファイル自身のテスト結果には一切影響しない（下の
# "isolated harness root" 配下の Pass/Total には現れるが、それを包む
# "Test.jl assumptions..." 自体は影響を受けない。このブロックだけで独立に検証済み:
# 隔離しない場合、深さ0まで伝播してこのテストファイル自体を失敗させてしまう）。
# 下に1行、赤い "Test Failed" が印字されるのは意図的なもの（Test.jl は `record` 時に
# 即座に印字するため。`Test.finish(fresh_root)` は呼ばないので集計・throw には影響しない）。
@info "以下の1件の Test Failed は意図的（isolated harness root の検証用）: このテストセット自体は成功する"
@testset "Test.jl assumptions used by quality_capture_runner.jl" begin
    fresh_root = Test.DefaultTestSet("isolated harness root")
    Test.push_testset(fresh_root)
    try
        @testset "synthetic check A" begin
            @test 1 == 1
        end
        @testset "synthetic check B (deliberately fails; isolated from the real suite)" begin
            @test 1 == 2
        end
    finally
        Test.pop_testset()
    end

    # 1) 親テストセットを持つ（深さ>0の）テストセットは、子が失敗しても例外を投げず、
    #    親へ record されるだけで @testset 式の戻り値として得られる
    #    （run_quality_capture が "DME (quality capture)" の下で各テストファイルを実行し、
    #    test_quality.jl 内の "Aqua.jl package quality" テストセットの戻り値を捕捉するための前提）。
    @test fresh_root isa Test.DefaultTestSet
    @test length(fresh_root.results) == 2

    # 2) Test.get_test_counts が再帰的な集計（cumulative_*）を提供する
    #    （_qc_pkgtest_tool/_qc_aqua_tool が assertions_total 等を導出するための前提）。
    tc = Test.get_test_counts(fresh_root)
    @test tc.cumulative_passes + tc.passes == 1
    @test tc.cumulative_fails + tc.fails == 1
    @test tc.cumulative_errors + tc.errors == 0

    # 3) Test.TestSetException が pass/fail/error/broken/errors_and_fails フィールドを持つ
    #    （_qc_pkgtest_tool が深さ0で失敗した場合のフォールバックとして依存する前提）。
    @test fieldnames(Test.TestSetException) ==
          (:pass, :fail, :error, :broken, :errors_and_fails)
end
