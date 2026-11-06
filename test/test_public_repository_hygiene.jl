using Test

# DME は public リポジトリで、tracked file はすべて公開物になる（ADR 0028、Issue #310）。
# 1. AWS アカウント ID は認証情報ではないが、不要に公開しない。ARN 形式・ECR 形式の
#    12桁の ID が tracked file に入ったら fail する。AWS ドキュメントの例 ID だけは許可する。
# 2. test/fixtures 直下の各ディレクトリは、test/fixtures/README.md の出典区分表に載っている。
const _HYGIENE_ROOT = normpath(joinpath(@__DIR__, ".."))
const _AWS_EXAMPLE_ACCOUNT_ID = "123456789012"
const _AWS_ACCOUNT_ID_PATTERNS =
    [r"\b(\d{12})\.dkr\.ecr\.", r"\barn:aws[a-z-]*:[a-z0-9-]*:[a-z0-9-]*:(\d{12}):"]

# git の無い環境（ソース tarball 等）では検査対象を決められないため nothing を返す。
function _hygiene_tracked_files(root::AbstractString)
    git = Sys.which("git")
    (git === nothing || !ispath(joinpath(root, ".git"))) && return nothing
    return filter!(!isempty, split(read(`$git -C $root ls-files -z`, String), '\0'))
end

function _aws_account_id_hits(root::AbstractString, files)
    hits = String[]
    for f in files
        path = joinpath(root, f)
        isfile(path) || continue
        bytes = read(path)
        0x00 in bytes && continue  # バイナリは対象外
        text = String(bytes)
        for pattern in _AWS_ACCOUNT_ID_PATTERNS, m in eachmatch(pattern, text)
            m.captures[1] == _AWS_EXAMPLE_ACCOUNT_ID || push!(hits, f)
        end
    end
    return unique!(hits)
end

@testset "public リポジトリの公開物（ADR 0028）" begin
    tracked = _hygiene_tracked_files(_HYGIENE_ROOT)

    @testset "tracked file に AWS アカウント ID が無い" begin
        if tracked === nothing
            @test_skip "git ls-files が使えないため検査しない"
        else
            hits = _aws_account_id_hits(_HYGIENE_ROOT, tracked)
            isempty(hits) ||
                @info "AWS account ID found; replace it with <pap-account-id>" files = hits
            @test isempty(hits)
        end
    end

    @testset "test/fixtures 直下の各ディレクトリに出典区分がある" begin
        fixtures = joinpath(_HYGIENE_ROOT, "test", "fixtures")
        readme = read(joinpath(fixtures, "README.md"), String)
        dirs = if tracked === nothing
            filter(d -> isdir(joinpath(fixtures, d)), readdir(fixtures))
        else
            prefix = "test/fixtures/"
            rel = [f[(length(prefix) + 1):end] for f in tracked if startswith(f, prefix)]
            unique!([first(split(r, '/')) for r in rel if occursin('/', r)])
        end
        @test !isempty(dirs)
        for d in sort!(dirs)
            @test occursin("| `$(d)/` |", readme)
        end
    end
end
