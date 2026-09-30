# Stable, non-interactive command-line interface for DME orchestrators (Issue #220).
#
# `bin/dme` is deliberately a minimal launcher.  Argument handling, model
# invocation, artifact construction, and exit-code classification live here so
# the behavior is equally testable from the library and from the installed CLI.

const _DME_CLI_ARTIFACT_OUTDIR_ENV = "DME_ARTIFACT_OUTDIR"
const _DME_CLI_DEFAULT_ARTIFACT_OUTDIR = "artifacts"

const _DME_CLI_USAGE = """
Usage:
  dme simulate solow [options] [--out DIR] [--run-id ID] [--artifact-sink URI]
  dme quality-export [--out DIR] [--run-id ID] [--artifact-sink URI]
  dme --help

Commands:
  simulate solow    Run the built-in Solow baseline simulation and write a JSON artifact.
  quality-export    Write the Julia quality-export placeholder artifact without running tests.

Output directory:
  --out DIR takes precedence over DME_ARTIFACT_OUTDIR. If neither is set,
  ./artifacts is used relative to the current working directory. Each command
  also writes run-manifest.json next to its artifact.

Run identity and artifact sink:
  --run-id ID takes precedence over DME_RUN_ID, then the ECS task id, then a
  generated local-<timestamp>-<suffix> id.
  --artifact-sink s3://BUCKET[/PREFIX] (or DME_ARTIFACT_SINK) also publishes the
  run bundle to BUCKET/PREFIX/runs/ID/ without overwriting existing objects.

Run `dme simulate solow --help` for simulation options.
"""

const _DME_CLI_SOLOW_USAGE = """
Usage:
  dme simulate solow [--periods N] [--initial-capital K] [--alpha A]
                     [--savings-rate S] [--depreciation-rate D]
                     [--population-growth N] [--technology-growth G] [--out DIR]
                     [--run-id ID] [--artifact-sink URI]

Defaults: periods=100, initial-capital=1.0, alpha=0.3, savings-rate=0.2,
depreciation-rate=0.1, population-growth=0.01, technology-growth=0.02.
"""

const _DME_CLI_QUALITY_EXPORT_USAGE = """
Usage:
  dme quality-export [--out DIR] [--run-id ID] [--artifact-sink URI]

Writes a julia-quality-export/v1 placeholder. This command does not execute the
test suite; tool entries are recorded as skipped.
"""

abstract type _DmeCliError <: Exception end

struct _DmeCliUsageError <: _DmeCliError
    message::String
end

struct _DmeCliModelError <: _DmeCliError
    message::String
end

struct _DmeCliIOError <: _DmeCliError
    message::String
end

Base.showerror(io::IO, error::_DmeCliError) = print(io, error.message)

"""
    dme_main(args=ARGS; stdout=stdout, stderr=stderr, env=ENV) -> Int

Stable entry point behind the `dme` executable. It never requests interactive
input. A return value of `0` indicates success; `2`, `3`, and `4` indicate,
respectively, invalid input, model execution failure, and artifact I/O failure
(including an artifact-sink failure). Unexpected errors return `1`. The
executable converts this value to its process exit code.

The `transport` keyword is an internal test hook for the HTTP calls of the
artifact sink and the ECS metadata endpoint; callers leave it at its default.
"""
function dme_main(
    args::AbstractVector{<:AbstractString} = ARGS;
    stdout::IO = stdout,
    stderr::IO = stderr,
    env = ENV,
    transport = _dme_http_transport,
)::Int
    try
        return _dme_dispatch(String.(args), stdout, stderr, env, transport)
    catch error
        println(stderr, "dme: error: ", sprint(showerror, error))
        return _dme_exit_code(error)
    end
end

function _dme_exit_code(error)::Int
    error isa _DmeCliUsageError && return 2
    error isa _DmeCliModelError && return 3
    error isa _DmeCliIOError && return 4
    return 1
end

function _dme_dispatch(args::Vector{String}, stdout::IO, stderr::IO, env, transport)::Int
    if isempty(args) || args == ["--help"] || args == ["-h"]
        print(stdout, _DME_CLI_USAGE)
        return 0
    end

    command = first(args)
    if command == "simulate"
        length(args) >= 2 || throw(_DmeCliUsageError("simulate requires a model name"))
        model = args[2]
        rest = args[3:end]
        if "--help" in rest || "-h" in rest
            model == "solow" ||
                throw(_DmeCliUsageError("unsupported simulation model: $model"))
            print(stdout, _DME_CLI_SOLOW_USAGE)
            return 0
        end
        model == "solow" || throw(_DmeCliUsageError("unsupported simulation model: $model"))
        return _dme_simulate_solow(rest, stdout, stderr, env, transport)
    elseif command == "quality-export"
        rest = args[2:end]
        if "--help" in rest || "-h" in rest
            print(stdout, _DME_CLI_QUALITY_EXPORT_USAGE)
            return 0
        end
        return _dme_quality_export(rest, stdout, stderr, env, transport)
    end

    throw(_DmeCliUsageError("unknown command: $command"))
end

function _dme_parse_options_indexed(arguments::Vector{String}, allowed::Set{String})
    options = Dict{String, String}()
    index = 1
    while index <= length(arguments)
        argument = arguments[index]
        startswith(argument, "--") ||
            throw(_DmeCliUsageError("unexpected positional argument: $argument"))

        if occursin('=', argument)
            name, value = split(argument[3:end], '='; limit = 2)
        else
            index < length(arguments) ||
                throw(_DmeCliUsageError("option $argument requires a value"))
            name = argument[3:end]
            value = arguments[index + 1]
            startswith(value, "--") &&
                throw(_DmeCliUsageError("option $argument requires a value"))
            index += 1
        end

        name in allowed || throw(_DmeCliUsageError("unknown option: --$name"))
        haskey(options, name) &&
            throw(_DmeCliUsageError("option --$name was specified more than once"))
        isempty(value) && throw(_DmeCliUsageError("option --$name cannot be empty"))
        options[name] = value
        index += 1
    end
    return options
end

function _dme_output_dir(options::Dict{String, String}, env)::String
    configured = get(options, "out", get(env, _DME_CLI_ARTIFACT_OUTDIR_ENV, ""))
    output_dir = isempty(configured) ? _DME_CLI_DEFAULT_ARTIFACT_OUTDIR : configured
    return abspath(output_dir)
end

function _dme_option_float(
    options::Dict{String, String},
    name::String,
    default::Float64,
)::Float64
    raw = get(options, name, nothing)
    raw === nothing && return default
    value = tryparse(Float64, raw)
    (value === nothing || !isfinite(value)) &&
        throw(_DmeCliUsageError("option --$name must be a finite number: $raw"))
    return value
end

function _dme_option_positive_int(
    options::Dict{String, String},
    name::String,
    default::Int,
)::Int
    raw = get(options, name, nothing)
    raw === nothing && return default
    value = tryparse(Int, raw)
    (value === nothing || value < 1) &&
        throw(_DmeCliUsageError("option --$name must be a positive integer: $raw"))
    return value
end

const _DME_CLI_RUN_OPTIONS = ("out", "run-id", "artifact-sink")

"""Run-level state shared by every command: identity, sink, and start time."""
struct _DmeCliRun
    context::_DmeRunContext
    sink::Union{Nothing, _DmeS3Sink}
    started_at::String
end

function _dme_begin_run(
    options::Dict{String, String},
    env,
    transport,
    stderr::IO,
)::_DmeCliRun
    sink = _dme_artifact_sink(get(options, "artifact-sink", nothing), env)
    context = _dme_run_context(get(options, "run-id", nothing), env, transport, stderr)
    return _DmeCliRun(context, sink, _dme_utc_timestamp())
end

"""
    _dme_execute_run(body, run, command, output_dir, bundle_dir, stderr, env,
                     transport) -> (manifest_path, published)

Run `body`, which writes the command's artifacts under `output_dir` and returns
them as `_DmeRunArtifact`s, then write `<bundle_dir>/run-manifest.json` last and,
when a sink is configured, publish the bundle.

- A failed command still records a failed manifest (without artifacts) and
  publishes it; the command's error is then rethrown, so its exit code is kept.
- A sink failure after a successful command is an artifact error (exit code 4).
  The objects already uploaded remain without a manifest, i.e. incomplete.
- Nothing is published unless the local manifest was written.
"""
function _dme_execute_run(
    body,
    run::_DmeCliRun,
    command::Dict{String, Any},
    output_dir::String,
    bundle_dir::String,
    stderr::IO,
    env,
    transport,
)
    command_failure = nothing
    artifacts = _DmeRunArtifact[]
    try
        artifacts = body()
    catch error
        command_failure = error
        artifacts = _DmeRunArtifact[]
    end

    run_id = run.context.run_id
    # Bundle-relative paths use "/" on every platform: they are also manifest
    # entries and S3 key suffixes.
    manifest_path = "$bundle_dir/$DME_RUN_MANIFEST_FILENAME"
    manifest_failure = nothing
    try
        manifest = _dme_run_manifest(;
            context = run.context,
            command,
            publication = _dme_publication_fields(run.sink, run_id),
            artifacts,
            output_dir,
            exit_code = command_failure === nothing ? 0 : _dme_exit_code(command_failure),
            started_at = run.started_at,
            finished_at = _dme_utc_timestamp(),
        )
        _dme_write_json_artifact(manifest, joinpath(output_dir, manifest_path))
    catch error
        manifest_failure = error
    end

    published = nothing
    sink_failure = nothing
    if manifest_failure === nothing && run.sink !== nothing
        try
            published = _dme_publish_run_bundle(
                run.sink,
                run_id,
                output_dir,
                [artifact.path for artifact in artifacts],
                manifest_path,
                env,
                transport,
            )
        catch error
            sink_failure =
                error isa _DmeCliError ? error :
                _DmeCliIOError("artifact sink failed: $(sprint(showerror, error))")
        end
    end

    if command_failure !== nothing
        # The command's own error decides the exit code; everything else is context.
        manifest_failure === nothing && println(
            stderr,
            "dme: run ",
            run_id,
            " recorded as failed: ",
            joinpath(output_dir, manifest_path),
        )
        published === nothing ||
            println(stderr, "dme: run ", run_id, " failure published to ", published)
        sink_failure === nothing ||
            println(stderr, "dme: error: ", sprint(showerror, sink_failure))
        throw(command_failure)
    end
    manifest_failure === nothing || throw(manifest_failure)
    if sink_failure !== nothing
        println(
            stderr,
            "dme: run ",
            run_id,
            " was not published to ",
            _dme_sink_location(run.sink, run_id),
            " (a run prefix is published only when its run-manifest.json exists)",
        )
        throw(sink_failure)
    end
    return (manifest_path, published)
end

function _dme_print_run_summary(
    stdout::IO,
    run::_DmeCliRun,
    output_dir::String,
    manifest_path::String,
    published::Union{Nothing, String},
)
    println(stdout, "  run_id: ", run.context.run_id)
    println(stdout, "  manifest: ", joinpath(output_dir, manifest_path))
    published === nothing || println(stdout, "  published: ", published)
    return nothing
end

function _dme_simulate_solow(
    arguments::Vector{String},
    stdout::IO,
    stderr::IO,
    env,
    transport,
)::Int
    options = _dme_parse_options_indexed(
        arguments,
        Set([
            _DME_CLI_RUN_OPTIONS...,
            "periods",
            "initial-capital",
            "alpha",
            "savings-rate",
            "depreciation-rate",
            "population-growth",
            "technology-growth",
        ]),
    )

    periods = _dme_option_positive_int(options, "periods", 100)
    initial_capital = _dme_option_float(options, "initial-capital", 1.0)
    alpha = _dme_option_float(options, "alpha", 0.3)
    savings_rate = _dme_option_float(options, "savings-rate", 0.2)
    depreciation_rate = _dme_option_float(options, "depreciation-rate", 0.1)
    population_growth = _dme_option_float(options, "population-growth", 0.01)
    technology_growth = _dme_option_float(options, "technology-growth", 0.02)

    initial_capital > 0 ||
        throw(_DmeCliUsageError("option --initial-capital must be greater than zero"))
    0 < alpha < 1 || throw(_DmeCliUsageError("option --alpha must be between zero and one"))
    0 < savings_rate < 1 ||
        throw(_DmeCliUsageError("option --savings-rate must be between zero and one"))
    0 < depreciation_rate <= 1 ||
        throw(_DmeCliUsageError("option --depreciation-rate must be in (0, 1]"))
    population_growth >= 0 ||
        throw(_DmeCliUsageError("option --population-growth must be non-negative"))
    technology_growth >= 0 ||
        throw(_DmeCliUsageError("option --technology-growth must be non-negative"))

    output_dir = _dme_output_dir(options, env)
    run = _dme_begin_run(options, env, transport, stderr)
    command = Dict{String, Any}(
        "name" => "simulate",
        "model" => "solow",
        "arguments" => Dict{String, Any}(
            "periods" => periods,
            "initial-capital" => initial_capital,
            "alpha" => alpha,
            "savings-rate" => savings_rate,
            "depreciation-rate" => depreciation_rate,
            "population-growth" => population_growth,
            "technology-growth" => technology_growth,
        ),
    )
    artifact_path = "simulation/solow/simulation.json"

    manifest_path, published = _dme_execute_run(
        run,
        command,
        output_dir,
        dirname(artifact_path),
        stderr,
        env,
        transport,
    ) do
        model = SolowModel(
            alpha,
            savings_rate,
            depreciation_rate,
            population_growth,
            technology_growth,
        )
        simulation = try
            simulate(model, initial_capital; T = periods)
        catch error
            throw(_DmeCliModelError("Solow simulation failed: $(sprint(showerror, error))"))
        end

        artifact = Dict{String, Any}(
            "artifact_schema" => "dme-simulation/v1",
            "generated_at" => _dme_utc_timestamp(),
            "model" => Dict(
                "id" => "solow",
                "name" => model_name(model),
                "parameters" => Dict(
                    "alpha" => alpha,
                    "savings_rate" => savings_rate,
                    "depreciation_rate" => depreciation_rate,
                    "population_growth" => population_growth,
                    "technology_growth" => technology_growth,
                ),
            ),
            "run" => Dict(
                "initial_capital" => initial_capital,
                "periods" => periods,
                "scenario" => "baseline",
            ),
            "variables" => Dict(
                "c" => simulation.c,
                "inv" => simulation.inv,
                "k" => simulation.k,
                "y" => simulation.y,
            ),
        )
        _dme_write_json_artifact(artifact, joinpath(output_dir, artifact_path))
        return [_DmeRunArtifact(artifact_path, "dme-simulation/v1")]
    end

    println(stdout, "dme simulate: success")
    println(stdout, "  model: solow")
    println(stdout, "  periods: ", periods)
    println(stdout, "  artifact: ", joinpath(output_dir, artifact_path))
    _dme_print_run_summary(stdout, run, output_dir, manifest_path, published)
    return 0
end

function _dme_quality_export(
    arguments::Vector{String},
    stdout::IO,
    stderr::IO,
    env,
    transport,
)::Int
    options = _dme_parse_options_indexed(arguments, Set(_DME_CLI_RUN_OPTIONS))
    output_dir = _dme_output_dir(options, env)
    run = _dme_begin_run(options, env, transport, stderr)
    command = Dict{String, Any}(
        "name" => "quality-export",
        "model" => nothing,
        "arguments" => Dict{String, Any}(),
    )
    artifact_path = "quality/quality-export.json"

    manifest_path, published = _dme_execute_run(
        run,
        command,
        output_dir,
        dirname(artifact_path),
        stderr,
        env,
        transport,
    ) do
        measured_at = Dates.floor(Dates.unix2datetime(time()), Dates.Second)
        export_ = QualityExport(;
            package = quality_export_package_identity(),
            repository = QualityExportRepository(
                owner = get(env, "DME_QUALITY_EXPORT_REPO_OWNER", "Yuki-Watanabe7"),
                name = get(env, "DME_QUALITY_EXPORT_REPO_NAME", "DME"),
            ),
            branch = _dme_quality_export_branch(env),
            # Inside the image there is no git checkout; the image's source commit
            # (DME_SOURCE_COMMIT) identifies the code instead.
            commit = something(first(_dme_source_commit(env)), "0"^40),
            measured_at = measured_at,
            generated_at = Dates.floor(Dates.unix2datetime(time()), Dates.Second),
            tools = [
                quality_tool_not_run(
                    name,
                    "not executed by dme quality-export; use the quality capture workflow for measurements",
                ) for name in QUALITY_EXPORT_RESERVED_TOOL_NAMES
            ],
        )
        output_path = joinpath(output_dir, artifact_path)
        try
            save_quality_export(export_, output_path)
        catch error
            throw(
                _DmeCliIOError(
                    "failed to write quality export to $output_path: $(sprint(showerror, error))",
                ),
            )
        end
        return [_DmeRunArtifact(artifact_path, QUALITY_EXPORT_SCHEMA)]
    end

    println(stdout, "dme quality-export: success")
    println(stdout, "  artifact: ", joinpath(output_dir, artifact_path))
    _dme_print_run_summary(stdout, run, output_dir, manifest_path, published)
    return 0
end

function _dme_quality_export_branch(env)::String
    configured = get(env, "DME_QUALITY_EXPORT_BRANCH", "")
    isempty(configured) || return configured
    return something(_qe_detect_branch(), "unknown")
end

function _dme_utc_timestamp()::String
    timestamp = Dates.floor(Dates.unix2datetime(time()), Dates.Second)
    return Dates.format(timestamp, dateformat"yyyy-mm-ddTHH:MM:SS") * "Z"
end

function _dme_write_json_artifact(artifact::Dict{String, Any}, path::String)::String
    tmp_path = path * ".tmp"
    try
        mkpath(dirname(path))
        open(tmp_path, "w") do io
            write(io, canonical_json_bytes(artifact))
            flush(io)
            @static if Sys.isunix()
                ccall(:fsync, Cint, (Cint,), fd(io))
            end
        end
        mv(tmp_path, path; force = true)
    catch error
        isfile(tmp_path) && rm(tmp_path; force = true)
        throw(
            _DmeCliIOError(
                "failed to write artifact to $path: $(sprint(showerror, error))",
            ),
        )
    end
    return path
end
