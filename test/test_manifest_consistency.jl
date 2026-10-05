using Test

# root / test / docs の Manifest.toml は別々に解決されるため、共有パッケージの
# entry が食い違うと Pkg.test() の sandbox 解決が root 側を採用して warning を出し、
# test/Manifest.toml の固定が効かなくなる（Issue #299）。この食い違いを検出する。
const _MANIFEST_ROOT = normpath(joinpath(@__DIR__, ".."))
const _MANIFEST_FILES = ["Manifest.toml", "test/Manifest.toml", "docs/Manifest.toml"]
# DME 自身は docs 環境で path 依存のため entry の形が異なる。
const _MANIFEST_SKIP = Set(["DME"])

function _manifest_entries(path::AbstractString)
    deps = get(Base.parsed_toml(path), "deps", Dict{String,Any}())
    return Dict{String,Any}(k => v[1] for (k, v) in deps if !(k in _MANIFEST_SKIP))
end

function _manifest_mismatches(a::AbstractString, b::AbstractString)
    ea, eb = _manifest_entries(a), _manifest_entries(b)
    out = String[]
    for k in sort!(collect(intersect(keys(ea), keys(eb))))
        x, y = ea[k], eb[k]
        if get(x, "version", nothing) != get(y, "version", nothing) ||
           get(x, "git-tree-sha1", nothing) != get(y, "git-tree-sha1", nothing)
            push!(out, "$k: $(get(x, "version", "?")) vs $(get(y, "version", "?"))")
        end
    end
    return out
end

@testset "Manifest consistency across root/test/docs" begin
    paths = [joinpath(_MANIFEST_ROOT, f) for f in _MANIFEST_FILES]
    present = filter(isfile, paths)
    @test length(present) >= 1
    for i in eachindex(present), j in (i + 1):length(present)
        @testset "$(relpath(present[i], _MANIFEST_ROOT)) vs $(relpath(present[j], _MANIFEST_ROOT))" begin
            mm = _manifest_mismatches(present[i], present[j])
            isempty(mm) || @info "Manifest entries differ" mismatches = mm
            @test isempty(mm)
        end
    end
end
