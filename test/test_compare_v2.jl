@testset "compare_results_v2" begin
    Q = DME.Quarterly
    dts = ["2020-Q1", "2020-Q2", "2020-Q3", "2020-Q4"]

    # 日付付きデータ系列 → SimulationResult
    mk(id, dates, vals; unit = "level", freq = Q) = to_simulation_result(
        DataSeries(;
            id = id,
            name = id,
            source = "s",
            frequency = freq,
            unit = unit,
            dates = dates,
            values = vals,
        ),
    )
    # 日付なし（モデル）結果
    mkmodel(id, vals) =
        SimulationResult("Model", "sim", Dict{String, Vector{Float64}}(id => vals))

    single(mv, dv; kw...) =
        [VariableComparisonMapping(; model_variable = mv, data_variable = dv, kw...)]

    @testset "型・構築とバリデーション" begin
        vm = VariableComparisonMapping(; model_variable = "Y", data_variable = "GDP")
        @test vm.mapping_type === :equivalent
        @test vm.transform === nothing

        @test_throws ArgumentError VariableComparisonMapping(;
            model_variable = "Y",
            data_variable = "GDP",
            mapping_type = :bogus,
        )
        @test_throws ArgumentError ComparisonSpec(; mode = :bogus)
        # mechanism 以外で mapping 空はエラー
        @test_throws ArgumentError ComparisonSpec(; mode = :trajectory)
        # mechanism は mapping 空を許容
        @test ComparisonSpec(; mode = :mechanism) isa ComparisonSpec
    end

    @testset "日付順序の入替え（位置でなく日付で整列）" begin
        data = mk("GDP", dts, [1.1, 2.1, 2.9, 4.2])
        # モデル側は日付が逆順
        model = mk("Y", reverse(dts), [4.0, 3.0, 2.0, 1.0])
        spec = ComparisonSpec(; mode = :trajectory, mappings = single("Y", "GDP"))
        r = compare_results_v2(model, data; spec = spec)

        @test r isa ComparisonResultV2
        @test r.assessment.level === :comparable
        al = r.alignment["Y"]
        # left（モデル）順で整列: Q4,Q3,Q2,Q1
        @test al.common_dates == reverse(dts)
        # 日付整列なので Y(Q1)=1.0 は GDP(Q1)=1.1 と対応（位置切詰なら 1.0 vs 4.2 になる）
        @test !al.used_period_index
        @test r.metrics["Y"].level_diff[end] ≈ 1.0 - 1.1
    end

    @testset "期間の部分重複（intersection）" begin
        data = mk("GDP", dts, [1.1, 2.1, 2.9, 4.2])
        model = mk("Y", ["2020-Q3", "2020-Q4", "2021-Q1"], [3.0, 4.0, 5.0])
        spec = ComparisonSpec(; mode = :trajectory, mappings = single("Y", "GDP"))
        r = compare_results_v2(model, data; spec = spec)
        al = r.alignment["Y"]
        @test Set(al.common_dates) == Set(["2020-Q3", "2020-Q4"])
        @test "2021-Q1" in al.excluded_dates
        @test "2020-Q1" in al.excluded_dates
        @test r.metrics["Y"].n_periods == 2
    end

    @testset "spec.period による期間指定" begin
        data = mk("GDP", dts, [1.1, 2.1, 2.9, 4.2])
        model = mk("Y", dts, [1.0, 2.0, 3.0, 4.0])
        spec = ComparisonSpec(;
            mode = :trajectory,
            period = ("2020-Q2", "2020-Q3"),
            mappings = single("Y", "GDP"),
        )
        r = compare_results_v2(model, data; spec = spec)
        @test r.alignment["Y"].common_dates == ["2020-Q2", "2020-Q3"]
    end

    @testset "比較期間0件 → insufficient" begin
        data = mk("GDP", dts, [1.1, 2.1, 2.9, 4.2])
        model = mk("Y", ["2019-Q1", "2019-Q2"], [9.0, 9.0])
        spec = ComparisonSpec(; mode = :trajectory, mappings = single("Y", "GDP"))
        r = compare_results_v2(model, data; spec = spec)
        @test r.assessment.level === :insufficient
        @test !haskey(r.metrics, "Y")
        @test !isempty(r.assessment.required_transforms)
    end

    @testset "period index の明示許可・拒否" begin
        model = mkmodel("Y", [1.0, 2.0, 3.0])
        data = mkmodel("GDP", [1.1, 2.1, 3.1])
        # 拒否（既定）: 日付なし同士は insufficient
        spec_deny = ComparisonSpec(; mode = :trajectory, mappings = single("Y", "GDP"))
        r_deny = compare_results_v2(model, data; spec = spec_deny)
        @test r_deny.assessment.level === :insufficient
        @test !haskey(r_deny.metrics, "Y")
        @test !r_deny.alignment["Y"].used_period_index

        # 許可: 配列位置で比較（警告付き）
        spec_allow = ComparisonSpec(;
            mode = :trajectory,
            allow_period_index = true,
            mappings = single("Y", "GDP"),
        )
        r_allow = compare_results_v2(model, data; spec = spec_allow)
        @test r_allow.assessment.level === :comparable
        @test haskey(r_allow.metrics, "Y")
        @test r_allow.alignment["Y"].used_period_index
        @test !isempty(r_allow.warnings)
    end

    @testset "単位差は自動同一視しない" begin
        # concept id 由来の単位差（同一 kind=flow, 単位 level(real) vs wage units）
        model = mk("Y", dts, [1.0, 2.0, 3.0, 4.0])
        data = mk("K", dts, [1.0, 2.0, 3.0, 4.0])
        spec = ComparisonSpec(;
            mode = :trajectory,
            mappings = single(
                "Y",
                "K";
                model_concept_id = :rbc_output_Y,
                data_concept_id = :sim_output_Y,
            ),
        )
        r = compare_results_v2(model, data; spec = spec)
        @test r.assessment.level === :insufficient
        @test !haskey(r.metrics, "Y")
        @test any(occursin("単位換算", s) for s in r.assessment.required_transforms)

        # metadata 由来の単位差でも降格する
        m2 = mk("Y", dts, [1.0, 2.0, 3.0, 4.0]; unit = "thousands")
        d2 = mk("K", dts, [1.0, 2.0, 3.0, 4.0]; unit = "millions")
        r2 = compare_results_v2(
            m2,
            d2;
            spec = ComparisonSpec(; mode = :trajectory, mappings = single("Y", "K")),
        )
        @test r2.assessment.level === :insufficient
    end

    @testset "頻度差は自動変換しない" begin
        model = mk("Y", ["2020", "2021"], [1.0, 2.0]; freq = DME.Annual)
        data = mk("K", ["2020", "2021"], [1.0, 2.0]; freq = Q)
        r = compare_results_v2(
            model,
            data;
            spec = ComparisonSpec(; mode = :trajectory, mappings = single("Y", "K")),
        )
        @test r.assessment.level === :insufficient
        @test any(occursin("頻度変換", s) for s in r.assessment.required_transforms)
    end

    @testset "stock/flow 差 → incompatible" begin
        model = mk("Y", dts, [1.0, 2.0, 3.0, 4.0])
        data = mk("K", dts, [1.0, 2.0, 3.0, 4.0])
        # sim_money_stock_H は stock、ramsey_consumption_C は flow
        spec = ComparisonSpec(;
            mode = :trajectory,
            mappings = single(
                "Y",
                "K";
                model_concept_id = :sim_money_stock_H,
                data_concept_id = :ramsey_consumption_C,
            ),
        )
        r = compare_results_v2(model, data; spec = spec)
        @test r.assessment.level === :incompatible
        @test !haskey(r.metrics, "Y")
    end

    @testset "同名変数だが concept id が異なる → equivalent にしない" begin
        model = mk("Y", dts, [1.0, 2.0, 3.0, 4.0])
        data = mk("Y", dts, [1.0, 2.0, 3.0, 4.0])
        # islm_output_Y と mf_output_Y は同 kind(flow)・同単位(level)・同 timing(static) だが
        # 定義（definition_key）が異なる（需要決定の閉/開経済）。equivalent 宣言でも同一視しない。
        spec = ComparisonSpec(;
            mode = :trajectory,
            mappings = single(
                "Y",
                "Y";
                mapping_type = :equivalent,
                model_concept_id = :islm_output_Y,
                data_concept_id = :mf_output_Y,
            ),
        )
        r = compare_results_v2(model, data; spec = spec)
        @test r.assessment.level === :partial
        @test r.assessment.per_variable["Y"] === :partial
        # partial でも metric は計算する（警告付き）
        @test haskey(r.metrics, "Y")
        @test !isempty(r.warnings)
    end

    @testset "明示変換後のみ比較可能になる" begin
        model = mk("Y", dts, [1000.0, 2000.0, 3000.0, 4000.0]; unit = "thousands")
        data = mk("K", dts, [1.0, 2.0, 3.0, 4.0]; unit = "millions")
        # 変換なし: 単位差で insufficient
        r0 = compare_results_v2(
            model,
            data;
            spec = ComparisonSpec(; mode = :trajectory, mappings = single("Y", "K")),
        )
        @test r0.assessment.level === :insufficient

        # 明示変換で比較可能に
        spec = ComparisonSpec(;
            mode = :trajectory,
            mappings = single(
                "Y",
                "K";
                transform = x -> x / 1000.0,
                transform_label = "thousands→millions",
            ),
        )
        r = compare_results_v2(model, data; spec = spec)
        @test r.assessment.level === :comparable
        @test haskey(r.metrics, "Y")
        @test r.metrics["Y"].rmse ≈ 0.0 atol = 1e-9
        @test !isempty(r.alignment["Y"].transform_history)
    end

    @testset "mapping_type=incompatible → 数値比較しない" begin
        model = mk("Y", dts, [1.0, 2.0, 3.0, 4.0])
        data = mk("K", dts, [1.0, 2.0, 3.0, 4.0])
        r = compare_results_v2(
            model,
            data;
            spec = ComparisonSpec(;
                mode = :trajectory,
                mappings = single("Y", "K"; mapping_type = :incompatible),
            ),
        )
        @test r.assessment.level === :incompatible
        @test !haskey(r.metrics, "Y")
    end

    @testset "NaN・欠損・定数系列の頑健性" begin
        sm = to_simulation_result(
            DataSeries(;
                id = "Y",
                name = "Y",
                source = "s",
                frequency = Q,
                unit = "level",
                dates = dts,
                values = [1.0, missing, 3.0, 4.0],
            ),
        )
        sd = mk("K", dts, [1.0, 2.0, 3.0, 4.0])
        r = compare_results_v2(
            sm,
            sd;
            spec = ComparisonSpec(; mode = :trajectory, mappings = single("Y", "K")),
        )
        @test r.alignment["Y"].n_missing == 1
        @test isfinite(r.metrics["Y"].rmse)

        # 定数系列 → correlation は NaN だがクラッシュしない
        sc1 = mk("Y", dts, [2.0, 2.0, 2.0, 2.0])
        sc2 = mk("K", dts, [1.0, 2.0, 3.0, 4.0])
        rc = compare_results_v2(
            sc1,
            sc2;
            spec = ComparisonSpec(; mode = :trajectory, mappings = single("Y", "K")),
        )
        @test isnan(rc.metrics["Y"].correlation)

        # 0系列
        sz1 = mk("Y", dts, [0.0, 0.0, 0.0, 0.0])
        sz2 = mk("K", dts, [0.0, 0.0, 0.0, 0.0])
        rz = compare_results_v2(
            sz1,
            sz2;
            spec = ComparisonSpec(; mode = :trajectory, mappings = single("Y", "K")),
        )
        @test rz.metrics["Y"].rmse ≈ 0.0
    end

    @testset "shock_response モード" begin
        model = mkmodel("Y", [0.0, 1.0, 0.5, -0.2])
        data = mkmodel("K", [0.0, 0.8, 0.4, -0.1])
        spec = ComparisonSpec(;
            mode = :shock_response,
            allow_period_index = true,
            mappings = single("Y", "K"),
        )
        r = compare_results_v2(model, data; spec = spec)
        m = r.metrics["Y"]
        @test m.same_direction == true
        @test m.model_argmax == 2
        @test isfinite(m.peak_ratio)
    end

    @testset "mechanism モード（能力 metadata 差分）" begin
        model = mkmodel("Y", [1.0, 2.0])
        data = mkmodel("K", [1.0, 2.0])
        r = compare_results_v2(
            model,
            data;
            spec = ComparisonSpec(;
                mode = :mechanism,
                left_model = :keen,
                right_model = :rbc,
            ),
        )
        @test r.assessment.level === :comparable
        @test r.mechanism_diff !== nothing
        @test isempty(r.metrics)  # 数値 metric を返さない
        @test r.mechanism_diff["endogenous_credit"]["differs"] == true
        @test haskey(r.mechanism_diff, "sectors")

        # モデル識別子未指定 → insufficient（例外ではない）
        r2 = compare_results_v2(model, data; spec = ComparisonSpec(; mode = :mechanism))
        @test r2.assessment.level === :insufficient
        @test !isempty(r2.assessment.required_transforms)
    end

    @testset "存在しない変数は ArgumentError" begin
        model = mk("Y", dts, [1.0, 2.0, 3.0, 4.0])
        data = mk("K", dts, [1.0, 2.0, 3.0, 4.0])
        @test_throws ArgumentError compare_results_v2(
            model,
            data;
            spec = ComparisonSpec(; mode = :trajectory, mappings = single("ZZZ", "K")),
        )
        @test_throws ArgumentError compare_results_v2(
            model,
            data;
            spec = ComparisonSpec(; mode = :trajectory, mappings = single("Y", "ZZZ")),
        )
    end

    @testset "provenance と契約 version" begin
        model = mk("Y", dts, [1.0, 2.0, 3.0, 4.0])
        data = mk("K", dts, [1.0, 2.0, 3.0, 4.0])
        r = compare_results_v2(
            model,
            data;
            spec = ComparisonSpec(; mode = :trajectory, mappings = single("Y", "K")),
        )
        @test r.provenance["contract_version"] == DME.COMPARISON_V2_CONTRACT_VERSION
        @test r.provenance["mode"] == "trajectory"
        @test length(r.provenance["mappings"]) == 1
    end
end
