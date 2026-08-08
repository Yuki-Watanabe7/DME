# Stable, non-interactive command-line interface for DME orchestrators (Issue #220).
#
# `bin/dme` is deliberately a minimal launcher.  Argument handling, model
# invocation, artifact construction, and exit-code classification live here so
# the behavior is equally testable from the library and from the installed CLI.

const _DME_CLI_ARTIFACT_OUTDIR_ENV = "DME_ARTIFACT_OUTDIR"
const _DME_CLI_DEFAULT_ARTIFACT_OUTDIR = "artifacts"

const _DME_CLI_USAGE = """
Usage:
  dme simulate solow [options] [--out DIR]
  dme quality-export [--out DIR]
  dme --help

Commands:
  simulate solow    Run the built-in Solow baseline simulation and write a JSON artifact.
  quality-export    Write the Julia quality-export placeholder artifact without running tests.

Output directory:
  --out DIR takes precedence over DME_ARTIFACT_OUTDIR. If neither is set,
  ./artifacts is used relative to the current working directory.

Run `dme simulate solow --help` for simulation options.
"""

const _DME_CLI_SOLOW_USAGE = """
Usage:
  dme simulate solow [--periods N] [--initial-capital K] [--alpha A]
                     [--savings-rate S] [--depreciation-rate D]
                     [--population-growth N] [--technology-growth G] [--out DIR]

Defaults: periods=100, initial-capital=1.0, alpha=0.3, savings-rate=0.2,
depreciation-rate=0.1, population-growth=0.01, technology-growth=0.02.
"""

const _DME_CLI_QUALITY_EXPORT_USAGE = """
Usage:
  dme quality-export [--out DIR]

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
respectively, invalid input, model execution failure, and artifact I/O failure.
Unexpected errors return `1`. The executable converts this value to its process
exit code.
"""
function dme_main(
    args::AbstractVector{<:AbstractString} = ARGS;
    stdout::IO = stdout,
    stderr::IO = stderr,
    env = ENV,
)::Int
    try
        return _dme_dispatch(String.(args), stdout, env)
    catch error
        status = if error isa _DmeCliUsageError
            2
        elseif error isa _DmeCliModelError
            3
        elseif error isa _DmeCliIOError
            4
        else
            1
        end
        println(stderr, "dme: error: ", sprint(showerror, error))
        return status
    end
end

function _dme_dispatch(args::Vector{String}, stdout::IO, env)::Int
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
        return _dme_simulate_solow(rest, stdout, env)
    elseif command == "quality-export"
        rest = args[2:end]
        if "--help" in rest || "-h" in rest
            print(stdout, _DME_CLI_QUALITY_EXPORT_USAGE)
            return 0
        end
        return _dme_quality_export(rest, stdout, env)
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

function _dme_simulate_solow(arguments::Vector{String}, stdout::IO, env)::Int
    options = _dme_parse_options_indexed(
        arguments,
        Set([
            "out",
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
    output_path =
        joinpath(_dme_output_dir(options, env), "simulation", "solow", "simulation.json")
    _dme_write_json_artifact(artifact, output_path)

    println(stdout, "dme simulate: success")
    println(stdout, "  model: solow")
    println(stdout, "  periods: ", periods)
    println(stdout, "  artifact: ", output_path)
    return 0
end

function _dme_quality_export(arguments::Vector{String}, stdout::IO, env)::Int
    options = _dme_parse_options_indexed(arguments, Set(["out"]))
    measured_at = Dates.floor(Dates.unix2datetime(time()), Dates.Second)
    export_ = QualityExport(;
        package = quality_export_package_identity(),
        repository = QualityExportRepository(
            owner = get(env, "DME_QUALITY_EXPORT_REPO_OWNER", "Yuki-Watanabe7"),
            name = get(env, "DME_QUALITY_EXPORT_REPO_NAME", "DME"),
        ),
        branch = _dme_quality_export_branch(env),
        commit = something(_detect_git_commit_sha(), "0"^40),
        measured_at = measured_at,
        generated_at = Dates.floor(Dates.unix2datetime(time()), Dates.Second),
        tools = [
            quality_tool_not_run(
                name,
                "not executed by dme quality-export; use the quality capture workflow for measurements",
            ) for name in QUALITY_EXPORT_RESERVED_TOOL_NAMES
        ],
    )
    output_path = joinpath(_dme_output_dir(options, env), "quality", "quality-export.json")
    try
        save_quality_export(export_, output_path)
    catch error
        throw(
            _DmeCliIOError(
                "failed to write quality export to $output_path: $(sprint(showerror, error))",
            ),
        )
    end

    println(stdout, "dme quality-export: success")
    println(stdout, "  artifact: ", output_path)
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
                "failed to write simulation artifact to $path: $(sprint(showerror, error))",
            ),
        )
    end
    return path
end
