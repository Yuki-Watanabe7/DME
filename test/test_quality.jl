using Aqua
using JuliaFormatter

# Julia品質Export Contract v1（Issue #208）: `DME_QUALITY_EXPORT_ENABLED` が有効なときのみ
# test/quality_capture_runner.jl の `run_quality_capture` がこれらを読み出し、Aqua.jl/
# JuliaFormatter.jl セクションの `result` を組み立てる。無効時（既定）は誰も読み出さないため
# 無害（このファイル自体の検証内容・失敗判定は一切変わらない）。
#
# ここで `Ref` を定義するのは（quality_capture_runner.jl 側ではなく）このファイル: 通常経路
# （`DME_QUALITY_EXPORT_ENABLED` 未設定）では quality_capture_runner.jl は include すらされない
# ため、そちらで `const` 宣言すると通常経路でこのファイルの代入が `UndefVarError` になる。
const QUALITY_CAPTURE_AQUA = Ref{Any}(nothing)
const QUALITY_CAPTURE_FORMATTER = Ref{Any}(nothing)

let
    # recursive=false: 依存パッケージのメソッドとの曖昧性は対象外（誤検知が多いため）
    # persistent_tasks=false: このチェックは DME 一式（JuMP・Ipopt・Plots 等）を
    # 独立した一時プロジェクトで再解決・再プリコンパイルするサブプロセスを spawn する。
    # 既にこれらを読み込み済みのメインテストプロセスと同時実行されるため、
    # CI ランナーのメモリ/CPU 制約でサブプロセスが完了前に落ちることがあり、
    # DME 側の実際の persistent task 有無とは無関係に不安定化する
    # （ローカルでは数十秒で安定して成功するが、CI では数分かけてクラッシュする）。
    #
    # `ambiguities_kw`/`persistent_tasks_kw` を Aqua.test_all への引数と
    # QUALITY_CAPTURE_AQUA[].settings（Issue #208 の provenance）の両方で使い回すことで、
    # 2箇所が食い違う（設定を変えたのに provenance を更新し忘れる）事態を構造的に防ぐ。
    ambiguities_kw = (recursive = false,)
    persistent_tasks_kw = false

    ts = @testset "Aqua.jl package quality" begin
        Aqua.test_all(DME; ambiguities = ambiguities_kw, persistent_tasks = persistent_tasks_kw)
    end
    # `DME_QUALITY_EXPORT_ENABLED` 無効時（既定）はこの `@testset` 自体が深さ0のままであり、
    # 何らかの check が失敗すれば上の行で例外が投げられ、以下の代入には到達しない
    # （今までどおりの挙動。#208 はこの分岐を変えない）。
    QUALITY_CAPTURE_AQUA[] = (
        testset = ts,
        settings = Dict{String, Any}(
            "ambiguities" => Dict{String, Any}("recursive" => ambiguities_kw.recursive),
            "persistent_tasks" => persistent_tasks_kw,
        ),
    )
end

@testset "JuliaFormatter" begin
    # overwrite=false: ファイルを書き換えずに確認のみ。ファイル単位で呼ぶのは、
    # JuliaFormatter.format(dir) が「全体で1つの Bool」しか返さず、Issue #208 が要求する
    # 未フォーマットファイル一覧を取得できないため（`format` はディレクトリを渡された場合も
    # 内部で全ファイルに対して個別に `format` を呼ぶので、ここでの分割は追加のフルディレクトリ
    # 走査ではなく、同じ1回分の処理を明示的にファイル単位へ展開しているだけ）。
    src_dir = joinpath(@__DIR__, "..", "src")
    jl_files = sort(
        String[
            joinpath(root, f) for (root, _, files) in walkdir(src_dir) for
            f in files if endswith(f, ".jl")
        ],
    )
    unformatted_files = filter(f -> !JuliaFormatter.format(f; overwrite = false), jl_files)
    is_formatted = isempty(unformatted_files)
    QUALITY_CAPTURE_FORMATTER[] = (
        formatted = is_formatted,
        unformatted_files = [relpath(f, src_dir) for f in unformatted_files],
    )
    if !is_formatted
        @warn "src/ にフォーマット未適用のファイルがあります: $(join([relpath(f, src_dir) for f in unformatted_files], ", "))。`julia --project=. -e 'using JuliaFormatter; format(\"src/\")'` を実行してください。"
    end
    @test is_formatted
end
