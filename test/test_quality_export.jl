# Julia品質Export Contract v1（Issue #207）のテスト。
# schemas/julia-quality-export-v1.schema.json と src/quality/quality_export.jl の整合を、
# valid/invalid fixture（test/fixtures/quality_export/）を通して検証する。
# DME は汎用 JSON Schema バリデータを持たないため、`quality_export_from_dict` 自体が
# validator を兼ねる（real_rate_model_artifact と同じ doctrine）。

const JSON3 = DME.JSON3

const _QE_FIXTURES_DIR = joinpath(@__DIR__, "fixtures", "quality_export")

function _qe_load_fixture_dict(subdir::AbstractString, filename::AbstractString)
    path = joinpath(_QE_FIXTURES_DIR, subdir, filename)
    return DME._qe_to_plain(JSON3.read(read(path, String)))
end

function _qe_valid_fixture_files()
    dir = joinpath(_QE_FIXTURES_DIR, "valid")
    return sort(filter(f -> endswith(f, ".json"), readdir(dir)))
end

function _qe_invalid_fixture_files()
    dir = joinpath(_QE_FIXTURES_DIR, "invalid")
    return sort(filter(f -> endswith(f, ".json"), readdir(dir)))
end

@testset "QualityExport 契約: producer/package/repository" begin
    @test QualityExportProducer().name == QUALITY_EXPORT_DEFAULT_PRODUCER_NAME
    @test QualityExportProducer().version == QUALITY_EXPORT_DEFAULT_PRODUCER_VERSION
    @test_throws ArgumentError QualityExportProducer(; name = "", version = "1.0.0")
    @test_throws ArgumentError QualityExportProducer(; name = "x", version = "")

    pkg = QualityExportPackage(;
        name = "DME",
        uuid = "32de5cd0-ad60-11e9-36bc-9b7c9b1e2078",
        version = "0.1.0",
    )
    @test pkg.name == "DME"
    @test_throws ArgumentError QualityExportPackage(;
        name = "DME",
        uuid = "not-a-uuid",
        version = "0.1.0",
    )
    @test_throws ArgumentError QualityExportPackage(;
        name = "",
        uuid = pkg.uuid,
        version = "0.1.0",
    )

    repo = QualityExportRepository(; owner = "Yuki-Watanabe7", name = "DME")
    @test repo.owner == "Yuki-Watanabe7"
    @test_throws ArgumentError QualityExportRepository(; owner = "", name = "DME")

    identity = quality_export_package_identity()
    @test identity.name == "DME"
    @test identity.uuid == "32de5cd0-ad60-11e9-36bc-9b7c9b1e2078"
    @test occursin(r"^[0-9]+\.[0-9]+\.[0-9]+", identity.version)
end

@testset "QUALITY_EXPORT_RESERVED_TOOL_NAMES" begin
    @test "Pkg.test" in QUALITY_EXPORT_RESERVED_TOOL_NAMES
    @test "Aqua.jl" in QUALITY_EXPORT_RESERVED_TOOL_NAMES
    @test "JuliaFormatter.jl" in QUALITY_EXPORT_RESERVED_TOOL_NAMES
    @test "Coverage.jl" in QUALITY_EXPORT_RESERVED_TOOL_NAMES
    @test "JET.jl" in QUALITY_EXPORT_RESERVED_TOOL_NAMES
    @test "BenchmarkTools.jl" in QUALITY_EXPORT_RESERVED_TOOL_NAMES
    @test "Documenter.jl" in QUALITY_EXPORT_RESERVED_TOOL_NAMES
    @test length(QUALITY_EXPORT_RESERVED_TOOL_NAMES) == 7
end

@testset "redact_secrets" begin
    @test redact_secrets("plain message, no secrets") == "plain message, no secrets"
    @test occursin("[REDACTED]", redact_secrets("token=abcdefghijklmnopqrstuvwxyz0123"))
    @test occursin(
        "[REDACTED]",
        redact_secrets("OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwx"),
    )
    @test occursin(
        "[REDACTED]",
        redact_secrets("Authorization: Bearer abcdefghij0123456789"),
    )
    @test !occursin(
        "sk-abcdefghijklmnopqrstuvwx",
        redact_secrets("OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwx"),
    )
end

@testset "QualityToolError: redaction" begin
    e = QualityToolError(;
        type = "ErrorException",
        message = "leaked FRED_API_KEY=abcd1234efgh5678 in log",
    )
    @test !occursin("abcd1234efgh5678", e.message)
    @test occursin("[REDACTED]", e.message)
    @test_throws ArgumentError QualityToolError(; type = "", message = "message")
    @test_throws ArgumentError QualityToolError(; type = "type", message = "")
end

@testset "QualityToolExecution: status ごとの必須/禁止フィールド" begin
    started = DateTime(2026, 8, 3, 8, 0, 0)
    completed = DateTime(2026, 8, 3, 8, 5, 0)

    # success: result 必須・空不可、error 禁止
    ok = QualityToolExecution(;
        tool_name = "Pkg.test",
        status = :success,
        started_at = started,
        completed_at = completed,
        result = Dict("assertions_total" => 10, "failures" => 0),
    )
    @test ok.status == :success
    @test ok.duration_seconds == 300.0
    @test_throws ArgumentError QualityToolExecution(;
        tool_name = "Pkg.test",
        status = :success,
        started_at = started,
        completed_at = completed,
    )
    @test_throws ArgumentError QualityToolExecution(;
        tool_name = "Pkg.test",
        status = :success,
        started_at = started,
        completed_at = completed,
        result = Dict{String, Any}(),
    )
    @test_throws ArgumentError QualityToolExecution(;
        tool_name = "Pkg.test",
        status = :success,
        started_at = started,
        completed_at = completed,
        result = Dict("a" => 1),
        error = QualityToolError(; type = "X", message = "should not be allowed"),
    )

    # failure/timeout: error 必須、result 禁止
    for status in (:failure, :timeout)
        failed = QualityToolExecution(;
            tool_name = "JET.jl",
            status = status,
            started_at = started,
            completed_at = completed,
            error = QualityToolError(; type = "OutOfMemoryError", message = "crashed"),
        )
        @test failed.status == status
        @test_throws ArgumentError QualityToolExecution(;
            tool_name = "JET.jl",
            status = status,
            started_at = started,
            completed_at = completed,
        )
        @test_throws ArgumentError QualityToolExecution(;
            tool_name = "JET.jl",
            status = status,
            started_at = started,
            completed_at = completed,
            error = QualityToolError(; type = "X", message = "y"),
            result = Dict("a" => 1),
        )
    end

    # skipped/not_installed: reason 必須、result/error 禁止
    for status in (:skipped, :not_installed)
        na = QualityToolExecution(;
            tool_name = "BenchmarkTools.jl",
            status = status,
            reason = "not wired up yet",
        )
        @test na.status == status
        @test na.result === nothing
        @test na.error === nothing
        @test_throws ArgumentError QualityToolExecution(;
            tool_name = "BenchmarkTools.jl",
            status = status,
        )
    end

    # 不正な tool_name / status
    @test_throws ArgumentError QualityToolExecution(;
        tool_name = "",
        status = :skipped,
        reason = "x",
    )
    @test_throws ArgumentError QualityToolExecution(;
        tool_name = "1bad-name",
        status = :skipped,
        reason = "x",
    )
    @test_throws ArgumentError QualityToolExecution(;
        tool_name = "Pkg.test",
        status = :bogus,
        reason = "x",
    )

    # completed_at < started_at は拒否
    @test_throws ArgumentError QualityToolExecution(;
        tool_name = "Pkg.test",
        status = :success,
        started_at = completed,
        completed_at = started,
        result = Dict("a" => 1),
    )

    # result に秘匿情報らしき文字列が含まれる場合は拒否（redact ではなく reject）
    @test_throws ArgumentError QualityToolExecution(;
        tool_name = "Pkg.test",
        status = :success,
        started_at = started,
        completed_at = completed,
        result = Dict("log" => "token=abcdefghijklmnopqrstuvwxyz0123"),
    )
end

@testset "quality_tool_not_run" begin
    t = quality_tool_not_run("Documenter.jl", "docs build is slow-lane only")
    @test t.status == :skipped
    t2 = quality_tool_not_run("Aqua.jl", "not resolved"; status = :not_installed)
    @test t2.status == :not_installed
    @test_throws ArgumentError quality_tool_not_run("JET.jl", "x"; status = :success)
end

function _qe_sample_export(; commit::AbstractString = "a"^40)
    pkg = quality_export_package_identity()
    repo = QualityExportRepository(; owner = "Yuki-Watanabe7", name = "DME")
    t1 = QualityToolExecution(;
        tool_name = "Pkg.test",
        status = :success,
        version = "1.12.6",
        started_at = DateTime(2026, 8, 3, 8, 0, 0),
        completed_at = DateTime(2026, 8, 3, 8, 5, 0),
        result = Dict("assertions_total" => 10, "failures" => 0),
    )
    t2 = quality_tool_not_run("JET.jl", "not wired up yet (Issue #207)")
    return QualityExport(;
        package = pkg,
        repository = repo,
        branch = "develop",
        commit = commit,
        measured_at = DateTime(2026, 8, 3, 8, 0, 0),
        generated_at = DateTime(2026, 8, 3, 8, 6, 0),
        tools = [t1, t2],
    )
end

@testset "QualityExport: 構築バリデーション" begin
    e = _qe_sample_export()
    @test e.export_schema == QUALITY_EXPORT_SCHEMA
    @test e.commit == "a"^40
    @test length(e.tools) == 2

    pkg = quality_export_package_identity()
    repo = QualityExportRepository(; owner = "o", name = "n")
    t = quality_tool_not_run("Pkg.test", "x")

    @test_throws ArgumentError QualityExport(;
        package = pkg,
        repository = repo,
        branch = "main",
        commit = "not-a-sha",
        measured_at = DateTime(2026, 1, 1),
        generated_at = DateTime(2026, 1, 1),
        tools = [t],
    )
    @test_throws ArgumentError QualityExport(;
        package = pkg,
        repository = repo,
        branch = "",
        commit = "a"^40,
        measured_at = DateTime(2026, 1, 1),
        generated_at = DateTime(2026, 1, 1),
        tools = [t],
    )
    @test_throws ArgumentError QualityExport(;
        package = pkg,
        repository = repo,
        branch = "main",
        commit = "a"^40,
        measured_at = DateTime(2026, 1, 2),
        generated_at = DateTime(2026, 1, 1),
        tools = [t],
    )
    @test_throws ArgumentError QualityExport(;
        package = pkg,
        repository = repo,
        branch = "main",
        commit = "a"^40,
        measured_at = DateTime(2026, 1, 1),
        generated_at = DateTime(2026, 1, 1),
        tools = QualityToolExecution[],
    )
    dup = quality_tool_not_run("Pkg.test", "dup")
    @test_throws ArgumentError QualityExport(;
        package = pkg,
        repository = repo,
        branch = "main",
        commit = "a"^40,
        measured_at = DateTime(2026, 1, 1),
        generated_at = DateTime(2026, 1, 1),
        tools = [t, dup],
    )
end

@testset "to_dict/to_json/from_dict/from_json round-trip" begin
    e = _qe_sample_export()
    d = to_dict(e)
    @test d["export_schema"] == QUALITY_EXPORT_SCHEMA
    @test d["tools"]["Pkg.test"]["status"] == "success"
    @test d["tools"]["JET.jl"]["status"] == "skipped"
    @test d["tools"]["JET.jl"]["result"] === nothing

    e2 = quality_export_from_dict(d)
    @test to_json(e2) == to_json(e)
    @test e2.commit == e.commit
    @test length(e2.tools) == length(e.tools)

    j = to_json(e)
    e3 = quality_export_from_json(j)
    @test to_json(e3) == j
end

@testset "同一入力から安定した JSON を生成する（determinism）" begin
    e1 = _qe_sample_export(; commit = "b"^40)
    e2 = _qe_sample_export(; commit = "b"^40)
    @test to_json(e1) == to_json(e2)
    # tools の Vector の順序を変えても出力は不変（内部 Dict 化 + JCS のキーソート）
    pkg = quality_export_package_identity()
    repo = QualityExportRepository(; owner = "Yuki-Watanabe7", name = "DME")
    t1 = QualityToolExecution(;
        tool_name = "Pkg.test",
        status = :success,
        started_at = DateTime(2026, 1, 1),
        completed_at = DateTime(2026, 1, 1, 0, 1),
        result = Dict("a" => 1),
    )
    t2 = quality_tool_not_run("JET.jl", "x")
    common = (;
        package = pkg,
        repository = repo,
        branch = "main",
        commit = "c"^40,
        measured_at = DateTime(2026, 1, 1),
        generated_at = DateTime(2026, 1, 1, 0, 2),
    )
    ea = QualityExport(; common..., tools = [t1, t2])
    eb = QualityExport(; common..., tools = [t2, t1])
    @test to_json(ea) == to_json(eb)
end

@testset "valid fixtures: quality_export_from_dict に成功する" begin
    for f in _qe_valid_fixture_files()
        d = _qe_load_fixture_dict("valid", f)
        e = quality_export_from_dict(d)
        @test e.export_schema == QUALITY_EXPORT_SCHEMA
        # round-trip: 再構築した dict も再度 from_dict に通る（自己無矛盾性）
        e2 = quality_export_from_dict(to_dict(e))
        @test to_json(e2) == to_json(e)
    end
    @test length(_qe_valid_fixture_files()) >= 3
end

@testset "invalid fixtures: quality_export_from_dict が拒否する" begin
    for f in _qe_invalid_fixture_files()
        d = _qe_load_fixture_dict("invalid", f)
        @test_throws Exception quality_export_from_dict(d)
    end
    @test length(_qe_invalid_fixture_files()) >= 5
end

@testset "save_quality_export / load_quality_export" begin
    e = _qe_sample_export(; commit = "d"^40)
    mktempdir() do dir
        path = joinpath(dir, "nested", "quality-export.json")
        saved = save_quality_export(e, path)
        @test saved == path
        @test isfile(path)
        @test !isfile(path * ".tmp")

        loaded = load_quality_export(path)
        @test to_json(loaded) == to_json(e)

        # 既定は上書き可能
        e2 = _qe_sample_export(; commit = "e"^40)
        save_quality_export(e2, path)
        @test to_json(load_quality_export(path)) == to_json(e2)

        # overwrite=false は既存ファイルを拒否する
        @test_throws ArgumentError save_quality_export(e, path; overwrite = false)
    end
end
