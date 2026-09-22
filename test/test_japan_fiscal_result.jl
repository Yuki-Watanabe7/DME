# Japan Fiscal Scenario Lab の model adapter・scenario runner・result artifact 契約
# （Issue #276）のテスト。
#
#   - #274 で採用（adoption=:primary/:supporting）した14セルすべてが実行でき、
#     JapanFiscalScenarioResult を返す
#   - adoption=:not_adopted のセルはモデルを実行せず JapanFiscalScenarioRejection を返す
#   - unsupported_concepts/unsupported_outputs が silent ignore されない（coverage 経由で開示）
#   - assumption → applied input の traceability（conversion が空でない）
#   - claim_level が diagnostics を厳密にゲートする（:direction_only では peak 等が存在しない）
#   - F5（jgb_funding_cost）で sovereign leg が :unsupported として分離される（H-11）
#   - 決定論（同一 scenario の同一 result_content_hash）・FRE context だけの変化は
#     model_implied/diagnostics に影響しない
#   - serialization round trip・改変検出・機械可読 contract export

using Test
using DME
using Dates
const JSON3 = DME.JSON3

function _jf_result_test_scenario(
    family::Symbol,
    assumptions::Vector{JapanFiscalScenarioAssumption};
    fre_context::Union{JapanFiscalFREContext, Nothing} = nothing,
    scenario_id::AbstractString = "test-$(family)",
)
    return JapanFiscalScenario(;
        scenario_id = scenario_id,
        family = family,
        fre_context = fre_context,
        provenance = JapanFiscalScenarioProvenance(; assumption_source = :user),
        assumptions = assumptions,
    )
end

const _JF_RESULT_TEST_SCENARIOS = Dict{Symbol, JapanFiscalScenario}(
    :low_growth_high_rates => _jf_result_test_scenario(
        :low_growth_high_rates,
        [
            JapanFiscalScenarioAssumption(;
                assumption_id = "a1",
                concept = :policy_rate,
                magnitude = 0.5,
                magnitude_source = :derived,
            ),
            JapanFiscalScenarioAssumption(;
                assumption_id = "a2",
                concept = :long_rate_funding_condition,
                magnitude = 30.0,
                magnitude_source = :derived,
            ),
        ],
    ),
    :fiscal_consolidation => _jf_result_test_scenario(
        :fiscal_consolidation,
        [
            JapanFiscalScenarioAssumption(;
                assumption_id = "a1",
                concept = :government_spending,
                magnitude = -10.0,
                magnitude_source = :derived,
            ),
            JapanFiscalScenarioAssumption(;
                assumption_id = "a2",
                concept = :tax,
                magnitude = 0.02,
                magnitude_source = :derived,
            ),
        ],
    ),
    :financial_repression => _jf_result_test_scenario(
        :financial_repression,
        [
            JapanFiscalScenarioAssumption(;
                assumption_id = "a1",
                concept = :policy_rate,
                magnitude = -0.5,
                magnitude_source = :derived,
            ),
            JapanFiscalScenarioAssumption(;
                assumption_id = "a2",
                concept = :inflation,
                magnitude = 1.0,
                magnitude_source = :derived,
            ),
        ],
    ),
    :high_growth_productivity => _jf_result_test_scenario(
        :high_growth_productivity,
        [
            JapanFiscalScenarioAssumption(;
                assumption_id = "a1",
                concept = :productivity_growth,
                magnitude = 1.0,
                magnitude_source = :derived,
            ),
        ],
    ),
    :jgb_funding_cost => _jf_result_test_scenario(
        :jgb_funding_cost,
        [
            JapanFiscalScenarioAssumption(;
                assumption_id = "a1",
                concept = :policy_rate,
                magnitude = 0.25,
                magnitude_source = :derived,
            ),
            JapanFiscalScenarioAssumption(;
                assumption_id = "a2",
                concept = :long_rate_funding_condition,
                magnitude = 40.0,
                magnitude_source = :derived,
            ),
        ],
    ),
)

_jf_result_adopted_mappings() =
    filter(m -> m.adoption !== :not_adopted, DME.JAPAN_FISCAL_MODEL_MAPPINGS)

@testset "Japan fiscal scenario adapter / runner / result artifact 契約（Issue #276）" begin

    # ---- 契約 version ---------------------------------------------------
    @testset "契約 version" begin
        @test JAPAN_FISCAL_ADAPTER_CONTRACT_VERSION == "japan-fiscal-scenario-adapter/1.0.0"
        @test JAPAN_FISCAL_RESULT_ARTIFACT_SCHEMA_VERSION == "japan-fiscal-scenario-result/1.0.0"
        @test JAPAN_FISCAL_DEFAULT_HORIZON >= 1
    end

    # ---- 採用した14セルすべてが実行できる ----------------------------------
    @testset "adoption=:primary/:supporting の全セルが実行できる" begin
        adopted = _jf_result_adopted_mappings()
        @test length(adopted) == 14
        for m in adopted
            @test haskey(JAPAN_FISCAL_MODEL_ADAPTERS, m.model)
            sc = _JF_RESULT_TEST_SCENARIOS[m.family]
            r = japan_fiscal_run(m.model, sc; horizon = 8)
            @test r isa JapanFiscalScenarioResult
            @test r.family == m.family
            @test r.model == m.model
            @test r.result_shape in (:time_path, :static_point)
            @test !isempty(r.diagnostics.variables)
        end
    end

    # ---- adoption=:not_adopted はモデルを実行せず拒否を返す ------------------
    @testset "not_representable / partial-not_adopted は機械可読な拒否を返す" begin
        not_adopted = filter(
            m -> m.adoption === :not_adopted,
            DME.JAPAN_FISCAL_MODEL_MAPPINGS,
        )
        @test length(not_adopted) == 41  # not_representable 40 + partial-not_adopted 1

        # 代表的な not_representable セル
        m1 = first(filter(m -> m.representability === :not_representable, not_adopted))
        sc1 = _JF_RESULT_TEST_SCENARIOS[m1.family]
        rej1 = japan_fiscal_run(m1.model, sc1)
        @test rej1 isa JapanFiscalScenarioRejection
        @test rej1.status == :not_executed
        @test rej1.representability == :not_representable
        @test rej1.adoption == :not_adopted
        @test !isempty(rej1.reason)

        # partial だが not_adopted の1セル
        m2 = first(filter(m -> m.representability === :partial, not_adopted))
        sc2 = _JF_RESULT_TEST_SCENARIOS[m2.family]
        rej2 = japan_fiscal_run(m2.model, sc2)
        @test rej2 isa JapanFiscalScenarioRejection
        @test rej2.representability == :partial
        @test rej2.adoption == :not_adopted
    end

    # ---- unsupported concepts/outputs は coverage 経由で常に開示される -------
    @testset "unsupported_concepts / unsupported_outputs が silent ignore されない" begin
        # NK/F1: growth_path と long_rate_funding_condition は受け付けない
        r = japan_fiscal_run(:new_keynesian, _JF_RESULT_TEST_SCENARIOS[:low_growth_high_rates]; horizon = 6)
        @test :growth_path in r.coverage.unsupported_concepts
        @test :long_rate_funding_condition in r.coverage.unsupported_concepts
        d = to_dict(r)
        @test d["coverage"]["unsupported_concepts"] != String[]
    end

    # ---- assumption → applied input の traceability -------------------------
    @testset "applied_inputs の traceability" begin
        r = japan_fiscal_run(:sim, _JF_RESULT_TEST_SCENARIOS[:fiscal_consolidation]; horizon = 6)
        @test length(r.applied_inputs) == 2
        ids = Set(ai.assumption_id for ai in r.applied_inputs)
        @test ids == Set(["a1", "a2"])
        for ai in r.applied_inputs
            @test !isempty(ai.conversion)
            @test isfinite(ai.magnitude_model_units)
        end
    end

    # ---- claim_level が diagnostics を厳密にゲートする -----------------------
    @testset "claim_level による diagnostics のゲート" begin
        # IS-LM（fiscal_consolidation）は :direction_only。peak/onset/duration/relative_delta
        # はフィールドとして存在しない（null で隠すのではなく、そもそも計算しない）。
        r_direction_only =
            japan_fiscal_run(:islm, _JF_RESULT_TEST_SCENARIOS[:fiscal_consolidation]; horizon = 6)
        @test r_direction_only.diagnostics.claim_level == :direction_only
        d1 = to_dict(r_direction_only.diagnostics)
        @test haskey(d1, "direction")
        @test haskey(d1, "sign_of_delta")
        @test !haskey(d1, "peak")
        @test !haskey(d1, "onset_period")
        @test !haskey(d1, "relative_delta")

        # RBC（high_growth_productivity）は :direction_and_relative_timing。
        r_timing =
            japan_fiscal_run(:rbc, _JF_RESULT_TEST_SCENARIOS[:high_growth_productivity]; horizon = 8)
        @test r_timing.diagnostics.claim_level == :direction_and_relative_timing
        d2 = to_dict(r_timing.diagnostics)
        @test haskey(d2, "peak")
        @test haskey(d2, "onset_period")
        @test haskey(d2, "relative_delta")

        # validate_claims が同じ規則で違反を検出する（H-07 の直接検証）
        v = japan_fiscal_validate_claims(
            :fiscal_consolidation,
            :islm;
            diagnostics = [:peak],
            numeric_semantics = :model_unit_relative,
            disclosed_unsupported_concepts = Symbol[],
            disclosed_unsupported_outputs = Symbol[],
        )
        @test :diagnostic_not_permitted in [x.code for x in v]
    end

    # ---- F5: sovereign leg / private pass-through leg の分離（H-11） ---------
    @testset "jgb_funding_cost の sovereign/private leg 分離" begin
        for model in (:capex_credit_cycle, :keen)
            r = japan_fiscal_run(model, _JF_RESULT_TEST_SCENARIOS[:jgb_funding_cost]; horizon = 6)
            @test r.funding_cost_legs !== nothing
            @test r.funding_cost_legs["sovereign"]["status"] == "unsupported"
            @test r.funding_cost_legs["private_pass_through"]["status"] == "modeled"
        end
        # jgb_funding_cost 以外では nothing
        r_other =
            japan_fiscal_run(:sim, _JF_RESULT_TEST_SCENARIOS[:fiscal_consolidation]; horizon = 6)
        @test r_other.funding_cost_legs === nothing
    end

    # ---- 決定論・FRE context の非影響 ----------------------------------------
    @testset "決定論性と FRE context の非影響（H-05 と同型の regression guard）" begin
        sc = _JF_RESULT_TEST_SCENARIOS[:fiscal_consolidation]
        r1 = japan_fiscal_run(:sim, sc; horizon = 6)
        r2 = japan_fiscal_run(:sim, sc; horizon = 6)
        @test r1.result_content_hash == r2.result_content_hash

        fre = JapanFiscalFREContext(;
            snapshot_id = "s1",
            as_of = Date(2026, 1, 1),
            vintage_basis = "v1",
            regime_determination = :unavailable,
            methodology_version = "m1",
            policy_version = "p1",
        )
        sc_fre = _jf_result_test_scenario(
            :fiscal_consolidation,
            sc.assumptions;
            fre_context = fre,
            scenario_id = "test-fiscal_consolidation-fre",
        )
        r_fre = japan_fiscal_run(:sim, sc_fre; horizon = 6)
        @test r_fre.model_implied == r1.model_implied
        @test to_dict(r_fre.diagnostics) == to_dict(r1.diagnostics)
        @test r_fre.fre_context_identity != r1.fre_context_identity
        @test r_fre.assumption_set_hash == r1.assumption_set_hash
        @test r_fre.result_content_hash != r1.result_content_hash

        # 異なる magnitude は異なる hash を生む
        sc_diff = _jf_result_test_scenario(
            :fiscal_consolidation,
            [
                JapanFiscalScenarioAssumption(;
                    assumption_id = "a1",
                    concept = :government_spending,
                    magnitude = -20.0,
                    magnitude_source = :derived,
                ),
            ];
            scenario_id = "test-fiscal_consolidation-diff",
        )
        r_diff = japan_fiscal_run(:sim, sc_diff; horizon = 6)
        @test r_diff.result_content_hash != r1.result_content_hash
    end

    # ---- no secrets / local paths in identity --------------------------------
    @testset "artifact に secrets・local path が含まれない" begin
        r = japan_fiscal_run(:sim, _JF_RESULT_TEST_SCENARIOS[:fiscal_consolidation]; horizon = 6)
        s = String(JSON3.write(to_dict(r)))
        @test !occursin(homedir(), s)
        @test !occursin("/Users/", s)
        @test !occursin("/home/", s)

        base_dir1 = mktempdir()
        base_dir2 = mktempdir()
        path1 = save_japan_fiscal_scenario_result(r, base_dir1)
        r2 = japan_fiscal_run(:sim, _JF_RESULT_TEST_SCENARIOS[:fiscal_consolidation]; horizon = 6)
        path2 = save_japan_fiscal_scenario_result(r2, base_dir2)
        @test r.result_content_hash == r2.result_content_hash
        @test isfile(path1)
        @test isfile(path2)
    end

    # ---- serialization round trip・改変検出 -----------------------------------
    @testset "serialization round trip と改変検出" begin
        for m in _jf_result_adopted_mappings()
            sc = _JF_RESULT_TEST_SCENARIOS[m.family]
            r = japan_fiscal_run(m.model, sc; horizon = 6)
            d = to_dict(r)
            r2 = japan_fiscal_scenario_result_from_dict(d)
            @test r2.result_content_hash == r.result_content_hash
            @test r2.diagnostics.claim_level == r.diagnostics.claim_level
            @test r2.coverage.unsupported_concepts == r.coverage.unsupported_concepts
        end

        r = japan_fiscal_run(:sim, _JF_RESULT_TEST_SCENARIOS[:fiscal_consolidation]; horizon = 6)
        d = to_dict(r)
        tampered = copy(d)
        tampered["warnings"] = vcat(tampered["warnings"], ["tampered"])
        @test_throws ArgumentError japan_fiscal_scenario_result_from_dict(tampered)

        missing_key = Dict{String, Any}(k => v for (k, v) in d if k != "horizon")
        @test_throws ArgumentError japan_fiscal_scenario_result_from_dict(missing_key)
    end

    # ---- rejection の JSON round trip ---------------------------------------
    @testset "JapanFiscalScenarioRejection の to_dict/to_json" begin
        not_representable =
            first(filter(m -> m.representability === :not_representable, DME.JAPAN_FISCAL_MODEL_MAPPINGS))
        sc = _JF_RESULT_TEST_SCENARIOS[not_representable.family]
        rej = japan_fiscal_run(not_representable.model, sc)
        d = to_dict(rej)
        @test d["status"] == "not_executed"
        @test d["adoption"] == "not_adopted"
        s = to_json(rej)
        @test s isa AbstractString
        @test !isempty(s)
    end

    # ---- 機械可読 contract export ---------------------------------------------
    @testset "japan_fiscal_result_artifact_contract() の機械可読 export" begin
        c = japan_fiscal_result_artifact_contract()
        @test c["schema_version"] == JAPAN_FISCAL_RESULT_ARTIFACT_SCHEMA_VERSION
        @test c["adapter_contract_version"] == JAPAN_FISCAL_ADAPTER_CONTRACT_VERSION
        @test length(c["adopted_models"]) == length(JAPAN_FISCAL_MODEL_ADAPTERS)
        s = JSON3.write(c)
        @test s isa AbstractString
    end

    # ---- coverage は #285 registry から丸ごと埋め込まれる（H-06） -------------
    @testset "coverage が japan_fiscal_coverage を丸ごと保持する（H-06）" begin
        r = japan_fiscal_run(:sim, _JF_RESULT_TEST_SCENARIOS[:fiscal_consolidation]; horizon = 6)
        expected = to_dict(japan_fiscal_coverage(:fiscal_consolidation, :sim))
        @test to_dict(r)["coverage"] == expected
        @test r.coverage.family_complete == false
        @test !isempty(r.coverage.gap_ids)
    end

end
