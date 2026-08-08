const _DME_CLI_TEST_OUTDIR_ENV = "DME_ARTIFACT_OUTDIR"

@testset "Stable orchestration CLI" begin
    @testset "Solow simulation writes a requested artifact directory" begin
        mktempdir() do dir
            stdout = IOBuffer()
            stderr = IOBuffer()
            code = dme_main(
                ["simulate", "solow", "--periods", "4", "--out", dir];
                stdout = stdout,
                stderr = stderr,
                env = Dict{String, String}(),
            )

            path = joinpath(dir, "simulation", "solow", "simulation.json")
            @test code == 0
            @test isempty(String(take!(stderr)))
            @test occursin("dme simulate: success", String(take!(stdout)))
            @test isfile(path)

            artifact = DME._qe_to_plain(DME.JSON3.read(read(path, String)))
            @test artifact["artifact_schema"] == "dme-simulation/v1"
            @test artifact["model"]["id"] == "solow"
            @test artifact["run"]["periods"] == 4
            @test length(artifact["variables"]["k"]) == 4
        end
    end

    @testset "Environment output directory and failure exit codes" begin
        mktempdir() do dir
            code = dme_main(
                ["simulate", "solow", "--periods=2"];
                stdout = IOBuffer(),
                stderr = IOBuffer(),
                env = Dict(_DME_CLI_TEST_OUTDIR_ENV => dir),
            )
            @test code == 0
            @test isfile(joinpath(dir, "simulation", "solow", "simulation.json"))
        end

        stderr = IOBuffer()
        @test dme_main(
            ["simulate", "solow", "--periods", "0"];
            stdout = IOBuffer(),
            stderr = stderr,
            env = Dict{String, String}(),
        ) == 2
        @test occursin("positive integer", String(take!(stderr)))

        mktempdir() do dir
            file_path = joinpath(dir, "not-a-directory")
            write(file_path, "x")
            @test dme_main(
                ["simulate", "solow", "--out", file_path];
                stdout = IOBuffer(),
                stderr = IOBuffer(),
                env = Dict{String, String}(),
            ) == 4
        end
    end

    @testset "Quality export uses the same output contract" begin
        mktempdir() do dir
            code = dme_main(
                ["quality-export", "--out", dir];
                stdout = IOBuffer(),
                stderr = IOBuffer(),
                env = Dict{String, String}(),
            )
            path = joinpath(dir, "quality", "quality-export.json")
            @test code == 0
            @test isfile(path)
            @test load_quality_export(path).export_schema == QUALITY_EXPORT_SCHEMA
        end
    end

    @testset "Launcher exposes the documented command without a Julia expression" begin
        repo = normpath(joinpath(@__DIR__, ".."))
        launcher = joinpath(repo, "bin", "dme")
        command = `$(Base.julia_cmd()) --startup-file=no --project=$repo $launcher --help`
        @test success(command)
    end
end
