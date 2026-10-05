# Batch run bundle: run manifest, run identity, and the S3 artifact sink (Issue #252).
#
# The S3 sink is exercised through an in-memory transport that behaves like S3's
# conditional PUT, so no network or AWS account is needed. The SigV4 signer is pinned
# to AWS's published S3 example and to a request signed by botocore.

using Test
using DME

@isdefined(jf_schema_errors) ||
    include(joinpath(@__DIR__, "fixtures", "japan_fiscal", "json_schema_subset.jl"))

const _BATCH_MANIFEST_SCHEMA = jf_load_schema("dme-run-manifest-v1.schema.json")
const _BATCH_TASK_ID = "0123456789abcdef0123456789abcdef"
const _BATCH_TASK_ARN = "arn:aws:ecs:ap-northeast-1:123456789012:task/pap-shared/$(_BATCH_TASK_ID)"
const _BATCH_DIGEST = "sha256:" * "ab"^32
const _BATCH_COMMIT = "0123456789abcdef0123456789abcdef01234567"

_batch_plain(path) = DME._qe_to_plain(DME.json_read(read(path, String)))

"""
In-memory stand-in for S3 and the ECS endpoints. PUTs honor `If-None-Match: *`
like S3 (412 for an existing key); `fail_key` makes one key answer HTTP 500.
"""
function _batch_fake_aws(; fail_key = nothing, ecs_metadata = nothing)
    objects = Dict{String, Vector{UInt8}}()
    calls = NamedTuple[]
    transport = function (method, url, headers, body; timeout = 30)
        header_dict = Dict(lowercase(k) => v for (k, v) in headers)
        push!(calls, (; method, url, headers = header_dict))
        if method == "GET" && startswith(url, "http://169.254.170.2/creds")
            return (
                status = 200,
                body = Vector{UInt8}(
                    """{"AccessKeyId":"ASIATESTKEY","SecretAccessKey":"test-secret","Token":"test-token","Expiration":"2099-01-01T00:00:00Z"}""",
                ),
            )
        elseif method == "GET" && url == "http://169.254.170.2/v4/metadata"
            ecs_metadata === nothing && return (status = 404, body = UInt8[])
            return (status = 200, body = Vector{UInt8}(DME.json_write(ecs_metadata)))
        elseif method == "PUT"
            key = replace(url, r"^https?://[^/]+/" => "")
            key == fail_key && return (
                status = 500,
                body = Vector{UInt8}("<Error><Code>InternalError</Code></Error>"),
            )
            if get(header_dict, "if-none-match", "") == "*" && haskey(objects, key)
                return (
                    status = 412,
                    body = Vector{UInt8}("<Error><Code>PreconditionFailed</Code></Error>"),
                )
            end
            objects[key] = copy(body)
            return (status = 200, body = UInt8[])
        end
        return (status = 404, body = UInt8[])
    end
    return (; transport, objects, calls)
end

const _BATCH_ECS_METADATA = Dict(
    "ImageID" => _BATCH_DIGEST,
    "Labels" => Dict(
        "com.amazonaws.ecs.task-arn" => _BATCH_TASK_ARN,
        "com.amazonaws.ecs.cluster" => "pap-shared",
        "com.amazonaws.ecs.task-definition-family" => "pap-prod-dme-sim",
        "com.amazonaws.ecs.task-definition-version" => "3",
        "com.amazonaws.ecs.container-name" => "dme",
    ),
    "LogOptions" => Dict(
        "awslogs-group" => "/aws/ecs/pap-prod-dme-sim",
        "awslogs-stream" => "dme/dme/$(_BATCH_TASK_ID)",
    ),
)

_batch_ecs_env(extra = Dict{String, String}()) = merge(
    Dict(
        "ECS_CONTAINER_METADATA_URI_V4" => "http://169.254.170.2/v4/metadata",
        "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI" => "/creds/task-role",
        "AWS_REGION" => "ap-northeast-1",
        "DME_ARTIFACT_SINK" => "s3://pap-prod-dme-sim-artifacts/dme",
        "DME_SOURCE_COMMIT" => _BATCH_COMMIT,
        "DME_IMAGE_VERSION" => "0.1.0+$(_BATCH_COMMIT[1:12])",
    ),
    extra,
)

@testset "Batch run bundle (Issue #252)" begin
    @testset "SigV4 signer matches AWS and botocore" begin
        # AWS S3 documentation, "Example: PUT Object" (Signature Version 4, single chunk).
        credentials = DME._DmeAwsCredentials(
            "AKIAIOSFODNN7EXAMPLE",
            "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            nothing,
        )
        payload = bytes2hex(DME.SHA.sha256(Vector{UInt8}("Welcome to Amazon S3.")))
        @test payload == "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"
        authorization = DME._dme_sigv4_authorization(;
            method = "PUT",
            canonical_uri = "/" * DME._dme_sigv4_uri_encode("test\$file.text"),
            headers = [
                "Date" => "Fri, 24 May 2013 00:00:00 GMT",
                "Host" => "examplebucket.s3.amazonaws.com",
                "x-amz-date" => "20130524T000000Z",
                "x-amz-storage-class" => "REDUCED_REDUNDANCY",
                "x-amz-content-sha256" => payload,
            ],
            payload_sha256 = payload,
            credentials,
            region = "us-east-1",
            amz_date = "20130524T000000Z",
        )
        @test authorization ==
              "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, " *
              "SignedHeaders=date;host;x-amz-content-sha256;x-amz-date;x-amz-storage-class, " *
              "Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"

        # The request shape DME sends (session token, If-None-Match), signed by
        # botocore's S3SigV4Auth with the same inputs.
        authorization = DME._dme_sigv4_authorization(;
            method = "PUT",
            canonical_uri = "/dme/runs/r-1/simulation/solow/simulation.json",
            headers = [
                "host" => "pap-dme.s3.ap-northeast-1.amazonaws.com",
                "content-type" => "application/json",
                "if-none-match" => "*",
                "x-amz-content-sha256" => payload,
                "x-amz-date" => "20260929T222306Z",
                "x-amz-security-token" => "TOKEN123",
            ],
            payload_sha256 = payload,
            credentials = DME._DmeAwsCredentials(
                "AKIDEXAMPLE",
                "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
                "TOKEN123",
            ),
            region = "ap-northeast-1",
            amz_date = "20260929T222306Z",
        )
        @test endswith(
            authorization,
            "Signature=29b027d3a0e9dd49c5027c09e180e3e218754347dbc1a8be2647118d0df77769",
        )
        @test DME._dme_sigv4_uri_encode("a b/c~d") == "a%20b/c~d"
        @test DME._dme_sigv4_uri_encode("a/b"; keep_slash = false) == "a%2Fb"
    end

    @testset "Sink configuration is validated before a run" begin
        env = Dict("AWS_REGION" => "ap-northeast-1")
        @test DME._dme_artifact_sink(nothing, Dict{String, String}()) === nothing
        sink = DME._dme_artifact_sink("s3://pap-dme/a/b/", env)
        @test (sink.bucket, sink.prefix, sink.region, sink.endpoint) ==
              ("pap-dme", "a/b", "ap-northeast-1", nothing)
        @test DME._dme_sink_location(sink, "r1") == "s3://pap-dme/a/b/runs/r1/"
        @test DME._dme_sink_location(DME._dme_artifact_sink("s3://pap-dme", env), "r1") ==
              "s3://pap-dme/runs/r1/"
        @test DME._dme_artifact_sink(
            nothing,
            Dict(
                "DME_ARTIFACT_SINK" => "s3://pap-dme",
                "AWS_DEFAULT_REGION" => "us-east-1",
                "DME_ARTIFACT_SINK_ENDPOINT" => "http://127.0.0.1:7070/",
            ),
        ).endpoint == "http://127.0.0.1:7070"
        for (uri, sink_env) in [
            ("file:///tmp/x", env),
            ("s3://Bad_Bucket", env),
            ("s3://a.b.c", env),
            ("s3://pap-dme/../x", env),
            ("s3://pap-dme", Dict{String, String}()),
            ("s3://pap-dme", merge(env, Dict("DME_ARTIFACT_SINK_ENDPOINT" => "ftp://x"))),
        ]
            @test_throws DME._DmeCliUsageError DME._dme_artifact_sink(uri, sink_env)
        end
    end

    @testset "Credentials: environment, then the ECS task role; never printed" begin
        fake = _batch_fake_aws()
        static = DME._dme_aws_credentials(
            Dict("AWS_ACCESS_KEY_ID" => "AKIDSTATIC", "AWS_SECRET_ACCESS_KEY" => "s3cret"),
            fake.transport,
        )
        @test static.access_key_id == "AKIDSTATIC" && static.session_token === nothing
        @test isempty(fake.calls)

        role = DME._dme_aws_credentials(
            Dict("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI" => "/creds/task-role"),
            fake.transport,
        )
        @test (role.access_key_id, role.session_token) == ("ASIATESTKEY", "test-token")
        @test !occursin("test-secret", sprint(show, role))
        @test_throws DME._DmeCliIOError DME._dme_aws_credentials(
            Dict{String, String}(),
            fake.transport,
        )
    end

    @testset "Run identity precedence and ECS correlation" begin
        fake = _batch_fake_aws(; ecs_metadata = _BATCH_ECS_METADATA)
        ecs_env = _batch_ecs_env()

        context = DME._dme_run_context(nothing, ecs_env, fake.transport)
        @test (context.run_id, context.run_id_source) == (_BATCH_TASK_ID, "ecs_task")
        @test context.platform == "ecs"
        @test context.ecs.image_digest == _BATCH_DIGEST
        @test context.ecs.log_stream == "dme/dme/$(_BATCH_TASK_ID)"
        @test (context.source_commit, context.source_commit_origin) ==
              (_BATCH_COMMIT, "environment")

        @test DME._dme_run_context(
            nothing,
            merge(ecs_env, Dict("DME_RUN_ID" => "env-run")),
            fake.transport,
        ).run_id_source == "environment"
        @test DME._dme_run_context("cli-run", ecs_env, fake.transport).run_id == "cli-run"
        @test_throws DME._DmeCliUsageError DME._dme_run_context(
            "../escape",
            ecs_env,
            fake.transport,
        )

        # Outside ECS, or when the endpoint misbehaves, the id is generated and the
        # correlation fields stay empty instead of failing the run.
        local_context = DME._dme_run_context(nothing, Dict{String, String}(), fake.transport)
        @test local_context.run_id_source == "generated"
        @test occursin(r"^local-\d{8}T\d{6}Z-[0-9a-f]{12}$", local_context.run_id)
        @test local_context.platform == "local" && local_context.ecs === nothing
        broken = _batch_fake_aws()
        warnings = IOBuffer()
        @test DME._dme_run_context(nothing, ecs_env, broken.transport, warnings).run_id_source ==
              "generated"
        @test occursin("dme: warning: ECS task metadata endpoint returned HTTP 404", String(take!(warnings)))
        failing_transport = (args...; kwargs...) -> error("mktemp: Read-only file system")
        DME._dme_run_context(nothing, ecs_env, failing_transport, warnings)
        @test occursin("could not be read", String(take!(warnings)))
    end

    @testset "A published run: artifacts first, manifest last, If-None-Match on every PUT" begin
        mktempdir() do dir
            fake = _batch_fake_aws(; ecs_metadata = _BATCH_ECS_METADATA)
            stdout = IOBuffer()
            code = dme_main(
                ["simulate", "solow", "--periods", "12", "--out", dir];
                stdout,
                stderr = IOBuffer(),
                env = _batch_ecs_env(),
                transport = fake.transport,
            )
            @test code == 0
            prefix = "dme/runs/$(_BATCH_TASK_ID)"
            puts = [call for call in fake.calls if call.method == "PUT"]
            @test [replace(call.url, r"^https://[^/]+/" => "") for call in puts] == [
                "$prefix/simulation/solow/simulation.json",
                "$prefix/simulation/solow/run-manifest.json",
            ]
            @test all(call.headers["if-none-match"] == "*" for call in puts)
            @test all(
                startswith(
                    call.url,
                    "https://pap-prod-dme-sim-artifacts.s3.ap-northeast-1.amazonaws.com/",
                ) for call in puts
            )
            @test all(call.headers["x-amz-security-token"] == "test-token" for call in puts)
            @test occursin(
                "published: s3://pap-prod-dme-sim-artifacts/$prefix/",
                String(take!(stdout)),
            )

            # The sink is a byte-for-byte mirror of the local bundle.
            for path in ("simulation/solow/simulation.json", "simulation/solow/run-manifest.json")
                @test fake.objects["$prefix/$path"] == read(joinpath(dir, path))
            end

            manifest = _batch_plain(joinpath(dir, "simulation", "solow", "run-manifest.json"))
            @test isempty(jf_schema_errors(_BATCH_MANIFEST_SCHEMA, manifest))
            @test manifest["status"] == "succeeded" && manifest["failure"] === nothing
            @test manifest["run_id"] == _BATCH_TASK_ID
            @test manifest["source"]["commit"] == _BATCH_COMMIT
            @test manifest["image"]["digest"] == _BATCH_DIGEST
            @test manifest["execution"]["ecs"]["task_arn"] == _BATCH_TASK_ARN
            @test manifest["publication"] == Dict(
                "sink" => "s3",
                "location" => "s3://pap-prod-dme-sim-artifacts/$prefix/",
            )
            @test manifest["command"]["arguments"]["periods"] == 12
            artifact = only(manifest["artifacts"])
            @test artifact["path"] == "simulation/solow/simulation.json"
            @test artifact["sha256"] ==
                  bytes2hex(DME.SHA.sha256(read(joinpath(dir, "simulation", "solow", "simulation.json"))))

            # No host path, credential or signature reaches the published bytes.
            published = String(copy(fake.objects["$prefix/simulation/solow/run-manifest.json"]))
            for secret_or_path in (dir, "test-secret", "test-token", "ASIATESTKEY", "/creds/")
                @test !occursin(secret_or_path, published)
            end
        end
    end

    @testset "A reused run id never overwrites a published run" begin
        mktempdir() do dir
            fake = _batch_fake_aws()
            env = _batch_ecs_env(Dict("DME_RUN_ID" => "fixed-run"))
            @test dme_main(
                ["quality-export", "--out", dir];
                stdout = IOBuffer(),
                stderr = IOBuffer(),
                env,
                transport = fake.transport,
            ) == 0
            snapshot = deepcopy(fake.objects)
            stderr = IOBuffer()
            @test dme_main(
                ["quality-export", "--out", dir];
                stdout = IOBuffer(),
                stderr,
                env,
                transport = fake.transport,
            ) == 4
            message = String(take!(stderr))
            @test occursin("refusing to overwrite", message)
            @test occursin("was not published", message)
            @test fake.objects == snapshot
        end
    end

    @testset "A sink failure is exit code 4 and leaves the prefix without a manifest" begin
        mktempdir() do dir
            prefix = "dme/runs/sink-fail"
            fake = _batch_fake_aws(; fail_key = "$prefix/quality/run-manifest.json")
            code = dme_main(
                ["quality-export", "--out", dir, "--run-id", "sink-fail"];
                stdout = IOBuffer(),
                stderr = IOBuffer(),
                env = _batch_ecs_env(),
                transport = fake.transport,
            )
            @test code == 4
            @test haskey(fake.objects, "$prefix/quality/quality-export.json")
            @test !haskey(fake.objects, "$prefix/quality/run-manifest.json")
        end
    end

    @testset "A failed command records and publishes a failed manifest" begin
        mktempdir() do dir
            fake = _batch_fake_aws()
            env = _batch_ecs_env()
            run = DME._dme_begin_run(Dict("run-id" => "model-fail"), env, fake.transport, devnull)
            stderr = IOBuffer()
            @test_throws DME._DmeCliModelError DME._dme_execute_run(
                run,
                Dict{String, Any}(
                    "name" => "simulate",
                    "model" => "solow",
                    "arguments" => Dict{String, Any}(),
                ),
                dir,
                "simulation/solow",
                stderr,
                env,
                fake.transport,
            ) do
                throw(DME._DmeCliModelError("diverged at /home/runner/secret-path"))
            end
            manifest = _batch_plain(joinpath(dir, "simulation", "solow", "run-manifest.json"))
            @test isempty(jf_schema_errors(_BATCH_MANIFEST_SCHEMA, manifest))
            @test (manifest["status"], manifest["exit_code"]) == ("failed", 3)
            @test manifest["failure"] == Dict("category" => "model_error")
            @test isempty(manifest["artifacts"])
            # The error text stays on stderr; the manifest records only its category.
            @test !occursin("secret-path", read(joinpath(dir, "simulation", "solow", "run-manifest.json"), String))
            @test collect(keys(fake.objects)) ==
                  ["dme/runs/model-fail/simulation/solow/run-manifest.json"]
            @test occursin("recorded as failed", String(take!(stderr)))
        end
    end

    @testset "Local runs keep the filesystem contract and record no host path" begin
        mktempdir() do dir
            env = Dict("DME_SOURCE_COMMIT" => _BATCH_COMMIT)
            @test dme_main(
                ["quality-export", "--out", dir];
                stdout = IOBuffer(),
                stderr = IOBuffer(),
                env,
            ) == 0
            manifest_text = read(joinpath(dir, "quality", "run-manifest.json"), String)
            manifest = _batch_plain(joinpath(dir, "quality", "run-manifest.json"))
            @test isempty(jf_schema_errors(_BATCH_MANIFEST_SCHEMA, manifest))
            @test manifest["publication"] == Dict("sink" => "filesystem", "location" => nothing)
            @test manifest["execution"] == Dict("platform" => "local", "ecs" => nothing)
            @test !occursin(dir, manifest_text)
            # Inside an image there is no git checkout; the quality export takes the
            # commit from the image's DME_SOURCE_COMMIT.
            @test load_quality_export(joinpath(dir, "quality", "quality-export.json")).commit ==
                  _BATCH_COMMIT
        end
    end
end
