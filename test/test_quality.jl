using Aqua
using JuliaFormatter

@testset "Aqua.jl package quality" begin
    # recursive=false: 依存パッケージのメソッドとの曖昧性は対象外（Phase 1 安定化のため）
    Aqua.test_all(DME; ambiguities = (recursive = false,))
end

@testset "JuliaFormatter" begin
    # overwrite=false: ファイルを書き換えずに確認のみ。format() は変更不要なら true を返す
    src_dir = joinpath(@__DIR__, "..", "src")
    is_formatted = JuliaFormatter.format(src_dir; overwrite = false)
    if !is_formatted
        @warn "src/ にフォーマット未適用のファイルがあります。`julia --project=. -e 'using JuliaFormatter; format(\"src/\")' を実行してください。"
    end
    @test is_formatted
end
