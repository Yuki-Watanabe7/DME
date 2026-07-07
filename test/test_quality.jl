using Aqua
using JuliaFormatter

@testset "Aqua.jl package quality" begin
    # recursive=false: 依存パッケージのメソッドとの曖昧性は対象外（誤検知が多いため）
    # persistent_tasks=false: このチェックは DME 一式（JuMP・Ipopt・Plots 等）を
    # 独立した一時プロジェクトで再解決・再プリコンパイルするサブプロセスを spawn する。
    # 既にこれらを読み込み済みのメインテストプロセスと同時実行されるため、
    # CI ランナーのメモリ/CPU 制約でサブプロセスが完了前に落ちることがあり、
    # DME 側の実際の persistent task 有無とは無関係に不安定化する
    # （ローカルでは数十秒で安定して成功するが、CI では数分かけてクラッシュする）。
    Aqua.test_all(DME; ambiguities = (recursive = false,), persistent_tasks = false)
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
