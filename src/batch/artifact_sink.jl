# Artifact sinks for run bundles (Issue #252, ADR 0026).
#
# The filesystem under `--out` is always the first and canonical write. A sink
# copies that finished bundle to durable storage that outlives the process: for an
# ECS Fargate task, whose ephemeral storage disappears when the task stops, the
# sink is an S3 prefix owned by the platform.
#
# S3 publication rules (ADR 0026 §2):
#
#   - keys are `<prefix>/runs/<run-id>/<path relative to --out>`, so a sink is a
#     byte-for-byte mirror of the local bundle and two runs never share a key;
#   - every PUT carries `If-None-Match: *`: S3 refuses to overwrite an existing
#     object, so a reused run id fails (exit code 4) instead of replacing a
#     published run;
#   - artifacts are uploaded first and `run-manifest.json` last. A run prefix
#     without a manifest is an incomplete publication and is never canonical.
#
# This file is the only AWS-specific code in DME. It signs requests with AWS
# Signature Version 4 using the SHA and Downloads standard libraries, reads
# credentials from the standard environment variables or the ECS container
# credentials endpoint, and never logs a credential or a signed header.

const _DME_ARTIFACT_SINK_ENV = "DME_ARTIFACT_SINK"
const _DME_ARTIFACT_SINK_ENDPOINT_ENV = "DME_ARTIFACT_SINK_ENDPOINT"
const _DME_ECS_CREDENTIALS_HOST = "http://169.254.170.2"

# Virtual-hosted-style HTTPS requires a bucket name without dots.
const _DME_S3_BUCKET_RE = r"^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$"
const _DME_S3_PREFIX_SEGMENT_RE = r"^[A-Za-z0-9][A-Za-z0-9._-]*$"
const _DME_AWS_REGION_RE = r"^[a-z]{2}(-[a-z]+)+-[0-9]+$"
const _DME_SINK_ENDPOINT_RE = r"^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$"

"""An S3 destination for run bundles: `s3://<bucket>[/<prefix>]`."""
struct _DmeS3Sink
    bucket::String
    prefix::String
    region::String
    # An S3-compatible endpoint (for local verification) switches to path-style
    # addressing. `nothing` means the AWS regional endpoint.
    endpoint::Union{Nothing, String}
end

struct _DmeAwsCredentials
    access_key_id::String
    secret_access_key::String
    session_token::Union{Nothing, String}
end

Base.show(io::IO, ::_DmeAwsCredentials) = print(io, "_DmeAwsCredentials(<redacted>)")

"""
    _dme_artifact_sink(option, env) -> Union{_DmeS3Sink, Nothing}

Resolve `--artifact-sink` (or `DME_ARTIFACT_SINK`). No sink means the run bundle
stays in the output directory only, which is the pre-existing CLI behavior. A
malformed sink or a missing region is an input error (exit code 2) detected
before the command runs.
"""
function _dme_artifact_sink(option::Union{Nothing, String}, env)::Union{Nothing, _DmeS3Sink}
    configured = option === nothing ? get(env, _DME_ARTIFACT_SINK_ENV, "") : option
    isempty(configured) && return nothing
    startswith(configured, "s3://") || throw(
        _DmeCliUsageError(
            "unsupported artifact sink (only s3://<bucket>[/<prefix>] is supported): $configured",
        ),
    )
    location = rstrip(configured[6:end], '/')
    bucket, prefix =
        occursin('/', location) ? split(location, '/'; limit = 2) : (location, "")
    occursin(_DME_S3_BUCKET_RE, bucket) || throw(
        _DmeCliUsageError(
            "artifact sink bucket must be 3-63 lowercase letters, digits or hyphens: $bucket",
        ),
    )
    if !isempty(prefix)
        all(segment -> occursin(_DME_S3_PREFIX_SEGMENT_RE, segment), split(prefix, '/')) ||
            throw(
                _DmeCliUsageError(
                    "artifact sink prefix segments must match $(_DME_S3_PREFIX_SEGMENT_RE.pattern): $prefix",
                ),
            )
    end

    region = get(env, "AWS_REGION", "")
    isempty(region) && (region = get(env, "AWS_DEFAULT_REGION", ""))
    occursin(_DME_AWS_REGION_RE, region) || throw(
        _DmeCliUsageError(
            "an s3:// artifact sink requires AWS_REGION or AWS_DEFAULT_REGION (got \"$region\")",
        ),
    )

    endpoint = get(env, _DME_ARTIFACT_SINK_ENDPOINT_ENV, "")
    if !isempty(endpoint)
        endpoint = rstrip(endpoint, '/')
        occursin(_DME_SINK_ENDPOINT_RE, endpoint) || throw(
            _DmeCliUsageError(
                "$(_DME_ARTIFACT_SINK_ENDPOINT_ENV) must be http(s)://host[:port]: $endpoint",
            ),
        )
    end
    return _DmeS3Sink(
        String(bucket),
        String(prefix),
        region,
        isempty(endpoint) ? nothing : String(endpoint),
    )
end

_dme_sink_run_prefix(sink::_DmeS3Sink, run_id::AbstractString)::String =
    join(filter(!isempty, [sink.prefix, "runs", run_id]), "/")

"""`s3://` location of a run's bundle, recorded in its manifest."""
_dme_sink_location(
    sink::_DmeS3Sink,
    run_id::AbstractString,
)::String = "s3://$(sink.bucket)/$(_dme_sink_run_prefix(sink, run_id))/"

_dme_publication_fields(::Nothing, ::AbstractString) =
    Dict{String, Any}("sink" => "filesystem", "location" => nothing)

_dme_publication_fields(sink::_DmeS3Sink, run_id::AbstractString) =
    Dict{String, Any}("sink" => "s3", "location" => _dme_sink_location(sink, run_id))

"""
    _dme_aws_credentials(env, transport) -> _DmeAwsCredentials

Credential precedence follows the AWS SDKs for the two sources a DME task uses:
static environment variables (local S3-compatible verification), then the ECS
container credentials endpoint (`AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`, which
Fargate sets for the task role). Shared config files, SSO and instance metadata
are deliberately unsupported.
"""
function _dme_aws_credentials(env, transport)::_DmeAwsCredentials
    access_key_id = get(env, "AWS_ACCESS_KEY_ID", "")
    secret_access_key = get(env, "AWS_SECRET_ACCESS_KEY", "")
    if !isempty(access_key_id) && !isempty(secret_access_key)
        token = get(env, "AWS_SESSION_TOKEN", "")
        return _DmeAwsCredentials(
            access_key_id,
            secret_access_key,
            isempty(token) ? nothing : token,
        )
    end

    relative_uri = get(env, "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI", "")
    isempty(relative_uri) && throw(
        _DmeCliIOError(
            "no AWS credentials for the artifact sink: set AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY " *
            "or run with an ECS task role",
        ),
    )
    startswith(relative_uri, "/") ||
        throw(_DmeCliIOError("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI must start with '/'"))
    response = transport(
        "GET",
        _DME_ECS_CREDENTIALS_HOST * relative_uri,
        Pair{String, String}[],
        nothing;
        timeout = 5,
    )
    response.status == 200 || throw(
        _DmeCliIOError(
            "ECS container credentials endpoint returned HTTP $(response.status)",
        ),
    )
    document = try
        json_read(response.body)
    catch
        throw(_DmeCliIOError("ECS container credentials endpoint returned invalid JSON"))
    end
    access_key_id = _dme_optional_string(document, :AccessKeyId)
    secret_access_key = _dme_optional_string(document, :SecretAccessKey)
    (access_key_id === nothing || secret_access_key === nothing) &&
        throw(_DmeCliIOError("ECS container credentials endpoint returned no access key"))
    return _DmeAwsCredentials(
        access_key_id,
        secret_access_key,
        _dme_optional_string(document, :Token),
    )
end

"""RFC 3986 percent-encoding as SigV4 defines it; `/` is kept when `keep_slash`."""
function _dme_sigv4_uri_encode(value::AbstractString; keep_slash::Bool = true)::String
    io = IOBuffer()
    for byte in codeunits(value)
        char = Char(byte)
        if ('A' <= char <= 'Z') ||
           ('a' <= char <= 'z') ||
           ('0' <= char <= '9') ||
           char in ('-', '_', '.', '~') ||
           (keep_slash && char == '/')
            write(io, byte)
        else
            print(io, '%', uppercase(string(byte; base = 16, pad = 2)))
        end
    end
    return String(take!(io))
end

"""
    _dme_sigv4_authorization(; method, canonical_uri, canonical_query = "", headers,
                             payload_sha256, credentials, region, service = "s3",
                             amz_date) -> String

Compute the `Authorization` header of AWS Signature Version 4. `headers` must
contain every header to be signed (at least `host`, `x-amz-date`, and for S3
`x-amz-content-sha256`), and `canonical_uri` must already be URI-encoded.
"""
function _dme_sigv4_authorization(;
    method::AbstractString,
    canonical_uri::AbstractString,
    canonical_query::AbstractString = "",
    headers::Vector{Pair{String, String}},
    payload_sha256::AbstractString,
    credentials::_DmeAwsCredentials,
    region::AbstractString,
    service::AbstractString = "s3",
    amz_date::AbstractString,
)::String
    normalized = sort!(
        [
            lowercase(name) => replace(strip(value), r"\s+" => " ") for
            (name, value) in headers
        ];
        by = first,
    )
    canonical_headers = join(["$name:$value\n" for (name, value) in normalized])
    signed_headers = join(first.(normalized), ";")
    canonical_request = join(
        [
            method,
            canonical_uri,
            canonical_query,
            canonical_headers,
            signed_headers,
            payload_sha256,
        ],
        "\n",
    )
    date = amz_date[1:8]
    scope = "$date/$region/$service/aws4_request"
    string_to_sign = join(
        [
            "AWS4-HMAC-SHA256",
            amz_date,
            scope,
            bytes2hex(sha256(Vector{UInt8}(canonical_request))),
        ],
        "\n",
    )
    key = Vector{UInt8}("AWS4" * credentials.secret_access_key)
    for part in (date, region, service, "aws4_request")
        key = hmac_sha256(key, Vector{UInt8}(part))
    end
    signature = bytes2hex(hmac_sha256(key, Vector{UInt8}(string_to_sign)))
    return "AWS4-HMAC-SHA256 Credential=$(credentials.access_key_id)/$scope, " *
           "SignedHeaders=$signed_headers, Signature=$signature"
end

function _dme_s3_error_code(body::Vector{UInt8})::String
    match_ = match(r"<Code>([A-Za-z0-9.]+)</Code>", String(copy(body)))
    return match_ === nothing ? "unknown" : match_.captures[1]
end

"""
    _dme_s3_put_if_absent(sink, credentials, key, body, transport; amz_date)

Upload one object with `If-None-Match: *`. S3 answers `412 Precondition Failed`
(or `409` for a concurrent conditional write) when the key already exists; both
are reported as an artifact error and nothing is overwritten.
"""
function _dme_s3_put_if_absent(
    sink::_DmeS3Sink,
    credentials::_DmeAwsCredentials,
    key::AbstractString,
    body::Vector{UInt8},
    transport;
    amz_date::AbstractString = Dates.format(
        Dates.unix2datetime(time()),
        dateformat"yyyymmddTHHMMSS",
    ) * "Z",
)
    encoded_key = _dme_sigv4_uri_encode(key)
    host, url, canonical_uri = if sink.endpoint === nothing
        host = "$(sink.bucket).s3.$(sink.region).amazonaws.com"
        (host, "https://$host/$encoded_key", "/$encoded_key")
    else
        host = replace(sink.endpoint, r"^https?://" => "")
        (
            host,
            "$(sink.endpoint)/$(sink.bucket)/$encoded_key",
            "/$(sink.bucket)/$encoded_key",
        )
    end
    payload_sha256 = bytes2hex(sha256(body))
    headers = Pair{String, String}[
        "host" => host,
        "content-type" => "application/json",
        "if-none-match" => "*",
        "x-amz-content-sha256" => payload_sha256,
        "x-amz-date" => amz_date,
    ]
    credentials.session_token === nothing ||
        push!(headers, "x-amz-security-token" => credentials.session_token)
    authorization = _dme_sigv4_authorization(;
        method = "PUT",
        canonical_uri,
        headers,
        payload_sha256,
        credentials,
        region = sink.region,
        amz_date,
    )
    response = transport("PUT", url, [headers; "authorization" => authorization], body)
    target = "s3://$(sink.bucket)/$key"
    response.status in (200, 201) && return target
    if response.status in (409, 412)
        throw(
            _DmeCliIOError(
                "refusing to overwrite $target (HTTP $(response.status), " *
                "$(_dme_s3_error_code(response.body))): run ids are single-use",
            ),
        )
    end
    throw(
        _DmeCliIOError(
            "S3 PUT $target failed: HTTP $(response.status) $(_dme_s3_error_code(response.body))",
        ),
    )
end

"""
    _dme_publish_run_bundle(sink, run_id, output_dir, artifact_paths, manifest_path,
                            env, transport) -> String

Copy a finished run bundle to the sink: each artifact, then the manifest. Returns
the run's `s3://` location. Any failure throws `_DmeCliIOError`; objects that were
already uploaded stay in place without a manifest, which marks the prefix as an
incomplete publication.
"""
function _dme_publish_run_bundle(
    sink::_DmeS3Sink,
    run_id::AbstractString,
    output_dir::AbstractString,
    artifact_paths::Vector{String},
    manifest_path::AbstractString,
    env,
    transport,
)::String
    credentials = _dme_aws_credentials(env, transport)
    run_prefix = _dme_sink_run_prefix(sink, run_id)
    for path in [artifact_paths; manifest_path]
        body = read(joinpath(output_dir, path))
        _dme_s3_put_if_absent(sink, credentials, "$run_prefix/$path", body, transport)
    end
    return _dme_sink_location(sink, run_id)
end
