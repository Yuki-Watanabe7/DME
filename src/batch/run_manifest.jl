# Run identity, provenance, and the run manifest for batch executions (Issue #252).
#
# A run is one invocation of a `dme` command. Each command writes its artifacts and
# then, last, a `run-manifest.json` next to them. The manifest is the commit marker
# of the run bundle: it names the run, the command and its effective arguments, the
# source commit and image the code came from, where it executed, whether it
# succeeded, and the SHA-256 of every artifact it produced. The contract is
# docs/deployment/batch_container.md §"Run bundle" and ADR 0026.
#
# Nothing here is AWS-specific except reading the optional ECS task metadata
# endpoint, which only adds correlation fields when the platform provides it.

"""Schema identifier of the run manifest (`schemas/dme-run-manifest-v1.schema.json`)."""
const DME_RUN_MANIFEST_SCHEMA = "dme-run-manifest/v1"

"""File name of the run manifest inside a command's artifact directory."""
const DME_RUN_MANIFEST_FILENAME = "run-manifest.json"

const _DME_REPOSITORY_URL = "https://github.com/Yuki-Watanabe7/DME"
const _DME_RUN_ID_ENV = "DME_RUN_ID"
const _DME_SOURCE_COMMIT_ENV = "DME_SOURCE_COMMIT"
const _DME_IMAGE_VERSION_ENV = "DME_IMAGE_VERSION"
const _DME_ECS_METADATA_ENV = "ECS_CONTAINER_METADATA_URI_V4"

# A run id becomes one path segment of a sink key, so it is restricted to
# characters that need no escaping in an S3 key or a file name.
const _DME_RUN_ID_RE = r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"
const _DME_SOURCE_COMMIT_RE = r"^[0-9a-f]{40}$"
const _DME_IMAGE_DIGEST_RE = r"^sha256:[0-9a-f]{64}$"
const _DME_ECS_TASK_ARN_RE =
    r"^arn:aws[a-z-]*:ecs:[a-z0-9-]+:[0-9]{12}:task/[A-Za-z0-9_-]+/([0-9a-f]{32})$"

"""Failure categories recorded in a failed run manifest (no free text is recorded)."""
const _DME_RUN_FAILURE_CATEGORIES = Dict(3 => "model_error", 4 => "artifact_io_error")

"""
Correlation fields read from the ECS task metadata endpoint (v4). Every field
comes from the platform; DME never derives them.
"""
struct _DmeEcsTaskMetadata
    task_arn::String
    task_id::String
    cluster::Union{Nothing, String}
    task_definition_family::Union{Nothing, String}
    task_definition_revision::Union{Nothing, String}
    container_name::Union{Nothing, String}
    image_digest::Union{Nothing, String}
    log_group::Union{Nothing, String}
    log_stream::Union{Nothing, String}
end

"""Everything a run manifest records about where the running code came from."""
struct _DmeRunContext
    run_id::String
    run_id_source::String
    source_commit::Union{Nothing, String}
    source_commit_origin::Union{Nothing, String}
    image_version::Union{Nothing, String}
    ecs::Union{Nothing, _DmeEcsTaskMetadata}
    platform::String
end

"""One file of a run bundle, addressed relative to the output directory."""
struct _DmeRunArtifact
    path::String
    schema::String
end

"""
    _dme_http_transport(method, url, headers, body; timeout = 30) -> NamedTuple

Default HTTP transport for the batch layer: `(status = Int, body = Vector{UInt8})`.
A transport error (DNS, TLS, timeout) is thrown as `_DmeCliIOError` without the
request headers, so a signed request never reaches a log.
"""
function _dme_http_transport(
    method::AbstractString,
    url::AbstractString,
    headers::Vector{Pair{String, String}},
    body::Union{Nothing, Vector{UInt8}};
    timeout::Real = 30,
)
    output = IOBuffer()
    response = if body === nothing
        Downloads.request(url; method, headers, output, timeout, throw = false)
    else
        Downloads.request(
            url;
            method,
            headers,
            input = IOBuffer(body),
            output,
            timeout,
            throw = false,
        )
    end
    if response isa Downloads.RequestError
        throw(_DmeCliIOError("HTTP $method $url failed: $(response.message)"))
    end
    return (status = response.status, body = take!(output))
end

function _dme_optional_string(dict, key)::Union{Nothing, String}
    value = get(dict, key, nothing)
    value isa AbstractString || return nothing
    return isempty(value) ? nothing : String(value)
end

"""
    _dme_ecs_task_metadata(env, transport) -> (metadata, warning)

Read the container metadata that ECS exposes at `ECS_CONTAINER_METADATA_URI_V4`.
Outside ECS both values are `nothing`. Correlation fields are best effort and never
fail a run, but an unreadable endpoint is returned as a `warning` for stderr: on
ECS it usually means the task has no writable `/tmp`, which Julia's HTTP client
needs (docs/deployment/batch_container.md §"Writable paths").
"""
function _dme_ecs_task_metadata(env, transport)
    uri = get(env, _DME_ECS_METADATA_ENV, "")
    isempty(uri) && return (nothing, nothing)
    try
        response = transport("GET", uri, Pair{String, String}[], nothing; timeout = 2)
        response.status == 200 ||
            return (nothing, "ECS task metadata endpoint returned HTTP $(response.status)")
        metadata = json_read(response.body)
        labels = get(metadata, :Labels, Dict{Symbol, Any}())
        task_arn = _dme_optional_string(labels, Symbol("com.amazonaws.ecs.task-arn"))
        match_ = task_arn === nothing ? nothing : match(_DME_ECS_TASK_ARN_RE, task_arn)
        match_ === nothing && return (nothing, "ECS task metadata has no valid task ARN")
        image_digest = _dme_optional_string(metadata, :ImageID)
        if image_digest !== nothing && !occursin(_DME_IMAGE_DIGEST_RE, image_digest)
            image_digest = nothing
        end
        log_options = get(metadata, :LogOptions, Dict{Symbol, Any}())
        ecs = _DmeEcsTaskMetadata(
            task_arn,
            match_.captures[1],
            _dme_optional_string(labels, Symbol("com.amazonaws.ecs.cluster")),
            _dme_optional_string(
                labels,
                Symbol("com.amazonaws.ecs.task-definition-family"),
            ),
            _dme_optional_string(
                labels,
                Symbol("com.amazonaws.ecs.task-definition-version"),
            ),
            _dme_optional_string(labels, Symbol("com.amazonaws.ecs.container-name")),
            image_digest,
            _dme_optional_string(log_options, Symbol("awslogs-group")),
            _dme_optional_string(log_options, Symbol("awslogs-stream")),
        )
        return (ecs, nothing)
    catch error
        return (nothing, "ECS task metadata could not be read: $(sprint(showerror, error))")
    end
end

"""
    _dme_source_commit(env) -> (commit, origin)

The image sets `DME_SOURCE_COMMIT` from the same build argument as its OCI
`revision` label. Outside an image, a git checkout supplies the commit. Anything
that is not a full 40-character hex SHA is treated as unknown.
"""
function _dme_source_commit(env)
    configured = get(env, _DME_SOURCE_COMMIT_ENV, "")
    occursin(_DME_SOURCE_COMMIT_RE, configured) && return (configured, "environment")
    detected = _detect_git_commit_sha()
    detected === nothing || return (detected, "git")
    return (nothing, nothing)
end

function _dme_generated_run_id(now_ns::UInt64 = time_ns())::String
    timestamp = Dates.format(Dates.unix2datetime(time()), dateformat"yyyymmddTHHMMSS") * "Z"
    suffix = bytes2hex(sha256(string(now_ns, "-", getpid(), "-", time())))[1:12]
    return "local-$timestamp-$suffix"
end

"""
    _dme_run_context(run_id_option, env, transport, stderr = devnull) -> _DmeRunContext

Resolve the run identity. Precedence: `--run-id`, `DME_RUN_ID`, the ECS task id,
then a generated `local-<UTC timestamp>-<suffix>`. An invalid explicit value is an
input error (exit code 2). A warning about unreadable ECS metadata goes to `stderr`.
"""
function _dme_run_context(
    run_id_option::Union{Nothing, String},
    env,
    transport,
    stderr::IO = devnull,
)::_DmeRunContext
    ecs, warning = _dme_ecs_task_metadata(env, transport)
    warning === nothing || println(stderr, "dme: warning: ", warning)
    environment_run_id = get(env, _DME_RUN_ID_ENV, "")
    run_id, run_id_source = if run_id_option !== nothing
        (run_id_option, "cli")
    elseif !isempty(environment_run_id)
        (environment_run_id, "environment")
    elseif ecs !== nothing
        (ecs.task_id, "ecs_task")
    else
        (_dme_generated_run_id(), "generated")
    end
    occursin(_DME_RUN_ID_RE, run_id) || throw(
        _DmeCliUsageError(
            "run id must match $(_DME_RUN_ID_RE.pattern) (from $run_id_source): $run_id",
        ),
    )

    source_commit, source_commit_origin = _dme_source_commit(env)
    image_version = get(env, _DME_IMAGE_VERSION_ENV, "")
    platform = isempty(get(env, _DME_ECS_METADATA_ENV, "")) ? "local" : "ecs"
    return _DmeRunContext(
        run_id,
        run_id_source,
        source_commit,
        source_commit_origin,
        isempty(image_version) ? nothing : image_version,
        ecs,
        platform,
    )
end

function _dme_ecs_manifest_fields(ecs::Union{Nothing, _DmeEcsTaskMetadata})
    ecs === nothing && return nothing
    return Dict{String, Any}(
        "task_arn" => ecs.task_arn,
        "cluster" => ecs.cluster,
        "task_definition_family" => ecs.task_definition_family,
        "task_definition_revision" => ecs.task_definition_revision,
        "container_name" => ecs.container_name,
        "log_group" => ecs.log_group,
        "log_stream" => ecs.log_stream,
    )
end

"""
    _dme_run_manifest(; context, command, arguments, publication, artifacts,
                      output_dir, exit_code, started_at, finished_at) -> Dict

Build a `dme-run-manifest/v1` document. `artifacts` must already exist under
`output_dir`; their SHA-256 and size are read from disk so the manifest describes
the bytes that a sink will publish. Paths are relative to `output_dir`: the
manifest never records a host path.
"""
function _dme_run_manifest(;
    context::_DmeRunContext,
    command::Dict{String, Any},
    publication::Dict{String, Any},
    artifacts::Vector{_DmeRunArtifact},
    output_dir::String,
    exit_code::Int,
    started_at::String,
    finished_at::String,
)::Dict{String, Any}
    status = exit_code == 0 ? "succeeded" : "failed"
    artifact_entries = map(artifacts) do artifact
        bytes = read(joinpath(output_dir, artifact.path))
        Dict{String, Any}(
            "path" => artifact.path,
            "schema" => artifact.schema,
            "sha256" => bytes2hex(sha256(bytes)),
            "bytes" => length(bytes),
        )
    end
    failure =
        exit_code == 0 ? nothing :
        Dict{String, Any}(
            "category" => get(_DME_RUN_FAILURE_CATEGORIES, exit_code, "unexpected_error"),
        )
    image_digest = context.ecs === nothing ? nothing : context.ecs.image_digest
    return Dict{String, Any}(
        "manifest_schema" => DME_RUN_MANIFEST_SCHEMA,
        "run_id" => context.run_id,
        "run_id_source" => context.run_id_source,
        "status" => status,
        "exit_code" => exit_code,
        "failure" => failure,
        "started_at" => started_at,
        "finished_at" => finished_at,
        "command" => command,
        "source" => Dict{String, Any}(
            "repository" => _DME_REPOSITORY_URL,
            "commit" => context.source_commit,
            "commit_origin" => context.source_commit_origin,
            "dme_version" => string(pkgversion(@__MODULE__)),
            "julia_version" => string(VERSION),
        ),
        "image" =>
            Dict{String, Any}("version" => context.image_version, "digest" => image_digest),
        "execution" => Dict{String, Any}(
            "platform" => context.platform,
            "ecs" => _dme_ecs_manifest_fields(context.ecs),
        ),
        "publication" => publication,
        "artifacts" => artifact_entries,
    )
end
