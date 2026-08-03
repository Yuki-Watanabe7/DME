# モデル能力プロファイル・概念定義 metadata（#149 / Phase 5）のテスト

using Test
using DME

# 全 export 済みモデルの識別子。新モデル追加時はここへ追加すれば自動的に検証対象になる。
const _ALL_MODEL_SYMBOLS = (
    :ramsey,
    :rbc,
    :solow,
    :islm,
    :adas,
    :new_keynesian,
    :var,
    :mundell_fleming,
    :keen,
    :sim,
    :capex_credit_cycle,
)

# 各識別子に対応するインスタンス（インスタンス dispatch の検証用）
_capability_test_instances() = Dict{Symbol, AbstractMacroModel}(
    :ramsey => RamseyModel(0.3, 0.96, 0.1),
    :rbc => RBCModel(0.3, 0.99, 1, 0.025, 1, 0.9),
    :solow => SolowModel(0.3, 0.2, 0.1, 0.01, 0.02),
    :islm => ISLMModel(100.0, 0.8, 200.0, 50.0, 100.0, 100.0, 0.2, 100.0, 1000.0, 1.0),
    :adas => ADASModel(
        100.0,
        0.8,
        200.0,
        50.0,
        100.0,
        100.0,
        0.2,
        100.0,
        300.0,
        1500.0,
        500.0,
        1.0,
    ),
    :new_keynesian =>
        NewKeynesianModel(1.0, 0.02, 0.99, 0.1, 1.5, 0.5, 0.02, 0.8, 0.5, 0.5),
    :var => VARModel([:y1, :y2], [0.5 0.0; 0.0 0.5], [0.0, 0.0]),
    :mundell_fleming => MundellFlemingModel(
        100.0,
        0.8,
        200.0,
        50.0,
        100.0,
        100.0,
        0.2,
        100.0,
        1000.0,
        1.0,
        0.02,
        50.0,
        10.0,
    ),
    :keen => KeenModel(
        0.025,
        0.02,
        0.01,
        3.0,
        0.03,
        0.0400641,
        6.41e-5,
        -0.0065,
        exp(-5),
        20.0,
    ),
    :sim => SIMModel(; α1 = 0.6, α2 = 0.4, θ = 0.2, G = 20.0),
    :capex_credit_cycle =>
        capex_credit_cycle_model(capex_credit_cycle_default_targets()),
)

@testset "モデル能力・概念定義 metadata（#149 / Phase 5）" begin

    # ---- 全 export 済みモデルが profile を返す -----------------------------
    @testset "全モデルが ModelCapabilityProfile を返す" begin
        for s in _ALL_MODEL_SYMBOLS
            p = model_capabilities(s)
            @test p isa ModelCapabilityProfile
            @test p.model === s
            @test haskey(MODEL_CAPABILITY_REGISTRY, s)
            # 語彙整合（コンストラクタで検証済みだが registry の値も確認）
            @test p.time_representation in CAPABILITY_TIME_REPRESENTATIONS
            @test all(a -> a in CAPABILITY_APIS, p.apis)
            @test all(sec -> sec in CAPABILITY_SECTORS, p.sectors)
            @test all(i -> i in CAPABILITY_INSTRUMENTS, p.instruments)
            @test p.accounting_closure in CAPABILITY_ACCOUNTING_CLOSURES
            @test p.equilibrium_concept in CAPABILITY_EQUILIBRIUM_CONCEPTS
        end
        # registry には過不足なく 11 モデル
        @test Set(keys(MODEL_CAPABILITY_REGISTRY)) == Set(_ALL_MODEL_SYMBOLS)
    end

    # ---- インスタンス dispatch ---------------------------------------------
    @testset "インスタンスからの dispatch" begin
        insts = _capability_test_instances()
        for s in _ALL_MODEL_SYMBOLS
            m = insts[s]
            @test model_symbol(m) === s
            @test model_capabilities(m) === model_capabilities(s)
            @test !isempty(concept_definitions(m))
            @test concept_definitions(m) == concept_definitions(s)
        end
    end

    # ---- stable concept id が重複しない ------------------------------------
    @testset "stable concept id が重複しない" begin
        ids = [d.concept_id for d in MODEL_CONCEPT_DEFINITION_REGISTRY]
        @test length(ids) == length(unique(ids))
        # 各モデルが少なくとも 1 概念定義を持つ
        for s in _ALL_MODEL_SYMBOLS
            @test !isempty(concept_definitions(s))
        end
        # 概念定義の model は全て登録済み識別子
        @test all(d -> d.model in _ALL_MODEL_SYMBOLS, MODEL_CONCEPT_DEFINITION_REGISTRY)
    end

    # ---- 対応 API の符号化が実装と整合（既知の true/false） ----------------
    @testset "対応 API の保守的符号化" begin
        # Ramsey: transition_path/simulate はあるが impulse_response はない
        @test supports_api(model_capabilities(:ramsey), :steady_state)
        @test supports_api(model_capabilities(:ramsey), :transition_path)
        @test !supports_api(model_capabilities(:ramsey), :impulse_response)
        # RBC: impulse_response はあるが simulate はない
        @test supports_api(model_capabilities(:rbc), :impulse_response)
        @test !supports_api(model_capabilities(:rbc), :simulate)
        # 静学モデルは transition_path/impulse_response を持たない
        for s in (:islm, :adas, :mundell_fleming)
            @test !supports_api(model_capabilities(s), :transition_path)
            @test !supports_api(model_capabilities(s), :impulse_response)
        end
        # calibration/validation は Keen のみ
        for s in _ALL_MODEL_SYMBOLS
            expected = (s === :keen)
            @test supports_api(model_capabilities(s), :calibration) == expected
            @test supports_api(model_capabilities(s), :validation) == expected
        end
    end

    # ---- 部門・金融・会計の保守的符号化 ------------------------------------
    @testset "部門・金融・会計の符号化" begin
        # SIM のみ stock-flow-consistent、CCC のみ partial、他は none
        for s in _ALL_MODEL_SYMBOLS
            expected = if s === :sim
                :stock_flow_consistent
            elseif s === :capex_credit_cycle
                :partial
            else
                :none
            end
            @test model_capabilities(s).accounting_closure == expected
        end
        # 内生信用は Keen と CCC（借り手側のみ内生）
        for s in _ALL_MODEL_SYMBOLS
            @test model_capabilities(s).endogenous_credit ==
                  (s in (:keen, :capex_credit_cycle))
        end
        # 対外部門を内生化するのは Mundell-Fleming のみ
        @test has_sector(model_capabilities(:mundell_fleming), :external)
        @test model_capabilities(:mundell_fleming).external_sector === :endogenous
        for s in (
            :ramsey,
            :rbc,
            :solow,
            :islm,
            :adas,
            :new_keynesian,
            :keen,
            :sim,
            :capex_credit_cycle,
        )
            @test !has_sector(model_capabilities(s), :external)
        end
        # 銀行部門は Keen と CCC（S4 金融・信用部門）
        for s in _ALL_MODEL_SYMBOLS
            @test has_sector(model_capabilities(s), :bank) ==
                  (s in (:keen, :capex_credit_cycle))
        end
    end

    # ---- 実証能力（推定・OOS は Keen のみ） --------------------------------
    @testset "実証能力の符号化" begin
        for s in _ALL_MODEL_SYMBOLS
            p = model_capabilities(s)
            @test p.data_connection            # 汎用 compare_with_data で全モデル true
            @test p.estimation == (s === :keen)
            @test p.out_of_sample_validation == (s === :keen)
        end
    end

    # ---- 同名だが定義の異なる概念を equivalent 判定しない -------------------
    @testset "同名変数の非同一性（equivalence）" begin
        rbc_r = only(filter(d -> d.variable === :r, concept_definitions(:rbc)))
        islm_r = only(filter(d -> d.variable === :r, concept_definitions(:islm)))
        # 同じ変数名 :r でも定義が異なる（実質資本収益率 vs 名目貨幣市場金利）
        @test rbc_r.variable === islm_r.variable
        @test rbc_r.definition_key !== islm_r.definition_key
        @test !concept_definitions_equivalent(rbc_r, islm_r)
        # 反射律: 自分自身とは等価
        @test concept_definitions_equivalent(rbc_r, rbc_r)
        @test concept_definitions_equivalent(islm_r, islm_r)

        # 同名 :Y も各モデルで別定義（別 definition_key）→ 相互に非等価
        y_defs = [
            only(filter(d -> d.variable === :Y, concept_definitions(s))) for
            s in (:rbc, :islm, :adas, :mundell_fleming, :sim)
        ]
        for i in eachindex(y_defs), j in eachindex(y_defs)
            if i != j
                @test !concept_definitions_equivalent(y_defs[i], y_defs[j])
            end
        end
    end

    # ---- JSON round-trip ---------------------------------------------------
    @testset "JSON round-trip: ModelCapabilityProfile" begin
        for s in _ALL_MODEL_SYMBOLS
            p = model_capabilities(s)
            d = to_dict(p)
            @test d isa Dict{String, Any}
            @test d["contract_version"] == MODEL_CAPABILITY_CONTRACT_VERSION
            # dict → 復元 → 再 dict が一致
            @test to_dict(model_capability_profile_from_dict(d)) == d
            # json → 復元 → 再 dict が一致
            @test to_dict(model_capability_profile_from_json(to_json(p))) == d
            # to_json は決定的（同一入力で同一出力）
            @test to_json(p) == to_json(p)
        end
    end

    @testset "JSON round-trip: ModelConceptDefinition" begin
        for c in MODEL_CONCEPT_DEFINITION_REGISTRY
            d = to_dict(c)
            @test d isa Dict{String, Any}
            @test to_dict(model_concept_definition_from_dict(d)) == d
            @test to_dict(model_concept_definition_from_json(to_json(c))) == d
        end
    end

    # ---- 語彙違反はコンストラクタで ArgumentError --------------------------
    @testset "語彙検証（ArgumentError）" begin
        @test_throws ArgumentError ModelCapabilityProfile(;
            model = :x,
            model_type = :X,
            display_name = "X",
            time_representation = :weekly,  # 無効
        )
        @test_throws ArgumentError ModelCapabilityProfile(;
            model = :x,
            model_type = :X,
            display_name = "X",
            time_representation = :discrete,
            apis = [:steady_state, :bogus_api],  # 無効
        )
        @test_throws ArgumentError ModelConceptDefinition(;
            concept_id = :x_v,
            model = :x,
            variable = :v,
            definition = "d",
            definition_key = :dk,
            kind = :flow,
            timing = :static,
            endogeneity = :endogenous,
            observability = :cloudy,  # 無効
        )
        # 未登録モデル
        @test_throws ArgumentError model_capabilities(:not_a_model)
    end

    # ---- Phase 4 registry との橋渡し ---------------------------------------
    @testset "coverage_concept_definitions（Phase 4 との接続）" begin
        cov = only(model_concept_coverage(model = :keen, concept = :private_debt_credit))
        defs = coverage_concept_definitions(cov)
        @test !isempty(defs)
        @test all(d -> d.model === :keen, defs)
        @test :keen_debt_ratio_d in [d.concept_id for d in defs]
        # variables が空の coverage は空を返す（例: out_of_scope の RBC private_debt_credit）
        cov_empty =
            only(model_concept_coverage(model = :rbc, concept = :private_debt_credit))
        @test isempty(cov_empty.variables)
        @test isempty(coverage_concept_definitions(cov_empty))
    end
end
