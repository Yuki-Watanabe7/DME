# Japan Fiscal Scenario Lab の scenario catalog・explicit assumption schema・FRE context
# 契約（Issue #275）のテスト。
#
#   - catalog が #274 の family spec からそのまま導出され、独自に再定義していない（H-01）
#   - FRE context と Scenario Assumption が別構造であり、FRE context だけを変えても
#     assumption 集合の identity は変わらない（H-05）
#   - magnitude の 0 と missing が construction・serialization を通じて区別される（H-03）
#   - magnitude_source = :external_belief が construction 時に拒否される（H-04）
#   - scenario identity（content hash）が #274/#285 の両 version を含み、決定論的である（H-02）
#   - family の required/optional concepts に無い assumption concept が黙って無視されず拒否される

using Test
using DME
using Dates
using JSON3

@testset "Japan fiscal scenario catalog / assumption schema / FRE context 契約（Issue #275）" begin

    # ---- 契約 version と語彙 ------------------------------------------------
    @testset "契約 version と語彙" begin
        @test JAPAN_FISCAL_SCENARIO_SCHEMA_VERSION == "japan-fiscal-scenario-schema/1.0.0"
        @test JAPAN_FISCAL_FRE_REGIME_DETERMINATIONS == (:primary, :ambiguous, :unavailable)
        @test JAPAN_FISCAL_ASSUMPTION_SOURCES == (:user, :preset, :fixture, :analysis)
    end

    # ---- catalog は #274 の family spec から導出する（H-01） ----------------
    @testset "scenario catalog が #274 registry から導出される（H-01）" begin
        catalog = japan_fiscal_scenario_catalog()
        @test length(catalog) == length(JAPAN_FISCAL_SCENARIO_FAMILIES)
        for f in JAPAN_FISCAL_SCENARIO_FAMILIES
            entry = japan_fiscal_scenario_catalog_entry(f)
            spec = japan_fiscal_family_spec(f)
            @test entry.required_concepts == spec.required_concepts
            @test entry.optional_concepts == spec.optional_concepts
            @test entry.guardrails == spec.guardrails
            @test entry.display_name == spec.display_name
            @test entry.doc_ref == spec.doc_ref
            @test entry.compatible_models == japan_fiscal_implementation_candidates(f)
            @test entry.capability_contract_version == JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION
            @test entry.claim_contract_version == JAPAN_FISCAL_CLAIM_CONTRACT_VERSION
            # concept_units は #274 の assumption concept registry から引く
            for c in vcat(entry.required_concepts, entry.optional_concepts)
                @test entry.concept_units[String(c)] == japan_fiscal_assumption_concept(c).unit
            end
            # horizons は :not_accepted を除く入力から導出され、空にならない
            @test !isempty(entry.horizons)
            @test issubset(Set(entry.horizons), Set(JAPAN_FISCAL_HORIZONS))
            # unsupported_channel_ids は #285 の channel registry の :unsupported と一致する
            expected_unsupported = Set(
                c.channel_id for
                c in japan_fiscal_channels(; family = f, status = :unsupported)
            )
            @test Set(entry.unsupported_channel_ids) == expected_unsupported
            @test to_dict(entry) == to_dict(catalog[f])
        end
        @test_throws ArgumentError japan_fiscal_scenario_catalog_entry(:unknown_family)
    end

    # ---- FRE context contract ------------------------------------------------
    @testset "JapanFiscalFREContext: identity・決定論・primary/ambiguous/unavailable" begin
        ctx_primary = JapanFiscalFREContext(;
            snapshot_id = "fre-2026-09-01",
            as_of = Date(2026, 9, 1),
            vintage_basis = "fre-vintage-1",
            regime_determination = :primary,
            primary_regime = "fiscal_dominance_lite",
            regime_affinity = Dict("fiscal_dominance_lite" => 0.7, "orthodox" => 0.3),
            regime_share = Dict("fiscal_dominance_lite" => 0.55),
            regime_confidence = 0.6,
            dimension_score = Dict("d1" => 0.1, "d2" => 0.4, "d3" => 0.2, "d4" => 0.5, "d5" => 0.3),
            constraint_pressure = 0.42,
            dominant_drivers = ["jgb_yield", "boj_balance_sheet"],
            data_quality_score = 0.9,
            methodology_version = "fre-methodology/1.2.0",
            policy_version = "fre-policy/1.0.0",
        )
        @test ctx_primary.primary_regime == "fiscal_dominance_lite"

        # regime_determination = :primary は primary_regime を要求する
        @test_throws ArgumentError JapanFiscalFREContext(;
            snapshot_id = "s", as_of = Date(2026, 1, 1), vintage_basis = "v",
            regime_determination = :primary,
        )
        # :ambiguous / :unavailable は primary_regime を持てない
        @test_throws ArgumentError JapanFiscalFREContext(;
            snapshot_id = "s", as_of = Date(2026, 1, 1), vintage_basis = "v",
            regime_determination = :ambiguous, primary_regime = "x",
        )
        ctx_unavailable = JapanFiscalFREContext(;
            snapshot_id = "fre-none", as_of = Date(2026, 1, 1), vintage_basis = "v0",
            regime_determination = :unavailable,
        )
        @test ctx_unavailable.primary_regime === nothing

        # 未知の regime_determination は拒否される
        @test_throws ArgumentError JapanFiscalFREContext(;
            snapshot_id = "s", as_of = Date(2026, 1, 1), vintage_basis = "v",
            regime_determination = :unknown,
        )
        # 空文字列 ID は拒否される
        @test_throws ArgumentError JapanFiscalFREContext(;
            snapshot_id = "", as_of = Date(2026, 1, 1), vintage_basis = "v",
            regime_determination = :unavailable,
        )
        # 非有限値は拒否される
        @test_throws ArgumentError JapanFiscalFREContext(;
            snapshot_id = "s", as_of = Date(2026, 1, 1), vintage_basis = "v",
            regime_determination = :unavailable, constraint_pressure = NaN,
        )

        # identity は同一内容から同一値・並び順に依存しない（dominant_drivers を逆順にしても同一）
        ctx_reordered = JapanFiscalFREContext(;
            snapshot_id = ctx_primary.snapshot_id, as_of = ctx_primary.as_of,
            vintage_basis = ctx_primary.vintage_basis,
            regime_determination = ctx_primary.regime_determination,
            primary_regime = ctx_primary.primary_regime,
            regime_affinity = ctx_primary.regime_affinity,
            regime_share = ctx_primary.regime_share,
            regime_confidence = ctx_primary.regime_confidence,
            dimension_score = ctx_primary.dimension_score,
            constraint_pressure = ctx_primary.constraint_pressure,
            dominant_drivers = reverse(ctx_primary.dominant_drivers),
            data_quality_score = ctx_primary.data_quality_score,
            methodology_version = ctx_primary.methodology_version,
            policy_version = ctx_primary.policy_version,
        )
        @test japan_fiscal_fre_context_identity(ctx_primary) ==
              japan_fiscal_fre_context_identity(ctx_reordered)

        # notes を変えても identity は変わらない（表示専用）
        ctx_noted = JapanFiscalFREContext(;
            snapshot_id = ctx_primary.snapshot_id, as_of = ctx_primary.as_of,
            vintage_basis = ctx_primary.vintage_basis,
            regime_determination = ctx_primary.regime_determination,
            primary_regime = ctx_primary.primary_regime,
            regime_affinity = ctx_primary.regime_affinity,
            regime_share = ctx_primary.regime_share,
            regime_confidence = ctx_primary.regime_confidence,
            dimension_score = ctx_primary.dimension_score,
            constraint_pressure = ctx_primary.constraint_pressure,
            dominant_drivers = ctx_primary.dominant_drivers,
            data_quality_score = ctx_primary.data_quality_score,
            methodology_version = ctx_primary.methodology_version,
            policy_version = ctx_primary.policy_version,
            notes = "unrelated commentary",
        )
        @test japan_fiscal_fre_context_identity(ctx_primary) ==
              japan_fiscal_fre_context_identity(ctx_noted)

        # snapshot_id を変えると identity は変わる
        ctx_diff = JapanFiscalFREContext(;
            snapshot_id = "fre-2026-10-01", as_of = ctx_primary.as_of,
            vintage_basis = ctx_primary.vintage_basis,
            regime_determination = ctx_primary.regime_determination,
            primary_regime = ctx_primary.primary_regime,
        )
        @test japan_fiscal_fre_context_identity(ctx_primary) !=
              japan_fiscal_fre_context_identity(ctx_diff)
    end

    # ---- explicit assumption schema ------------------------------------------
    @testset "JapanFiscalScenarioAssumption: magnitude_source・unit/direction 導出" begin
        a_up = JapanFiscalScenarioAssumption(;
            assumption_id = "a-up", concept = :policy_rate, magnitude = 1.5,
            magnitude_source = :assumed_default,
        )
        a_down = JapanFiscalScenarioAssumption(;
            assumption_id = "a-down", concept = :policy_rate, magnitude = -1.5,
            magnitude_source = :assumed_default,
        )
        a_zero = JapanFiscalScenarioAssumption(;
            assumption_id = "a-zero", concept = :policy_rate, magnitude = 0.0,
            magnitude_source = :assumed_default,
        )
        @test japan_fiscal_assumption_direction(a_up) === :up
        @test japan_fiscal_assumption_direction(a_down) === :down
        @test japan_fiscal_assumption_direction(a_zero) === :none
        @test japan_fiscal_assumption_unit(a_up) ==
              japan_fiscal_assumption_concept(:policy_rate).unit

        # magnitude_source = :external_belief は #274 の禁止リストにより拒否される（H-04）
        @test :external_belief in JAPAN_FISCAL_FORBIDDEN_MAGNITUDE_SOURCES
        @test_throws ArgumentError JapanFiscalScenarioAssumption(;
            assumption_id = "bad", concept = :policy_rate, magnitude = 1.0,
            magnitude_source = :external_belief,
        )
        # 未知の concept・magnitude_source は拒否される
        @test_throws ArgumentError JapanFiscalScenarioAssumption(;
            assumption_id = "bad2", concept = :unknown_concept, magnitude = 1.0,
            magnitude_source = :assumed_default,
        )
        @test_throws ArgumentError JapanFiscalScenarioAssumption(;
            assumption_id = "bad3", concept = :policy_rate, magnitude = 1.0,
            magnitude_source = :unknown_source,
        )
        # 非有限 magnitude は拒否される
        @test_throws ArgumentError JapanFiscalScenarioAssumption(;
            assumption_id = "bad4", concept = :policy_rate, magnitude = NaN,
            magnitude_source = :assumed_default,
        )
        @test_throws ArgumentError JapanFiscalScenarioAssumption(;
            assumption_id = "bad5", concept = :policy_rate, magnitude = Inf,
            magnitude_source = :assumed_default,
        )
        # 空の assumption_id は拒否される
        @test_throws ArgumentError JapanFiscalScenarioAssumption(;
            assumption_id = "", concept = :policy_rate, magnitude = 1.0,
            magnitude_source = :assumed_default,
        )
    end

    # ---- JapanFiscalScenario: family 整合性・重複拒否 -------------------------
    @testset "JapanFiscalScenario: family の required/optional concepts のみ許容する" begin
        prov = JapanFiscalScenarioProvenance(; assumption_source = :fixture)

        # F2 (fiscal_consolidation) の required concepts に無い :cb_jgb_absorption は拒否される
        bad_assumption = JapanFiscalScenarioAssumption(;
            assumption_id = "x", concept = :cb_jgb_absorption, magnitude = 1.0,
            magnitude_source = :assumed_default,
        )
        @test_throws ArgumentError JapanFiscalScenario(;
            scenario_id = "sc-bad", family = :fiscal_consolidation, provenance = prov,
            assumptions = [bad_assumption],
        )

        # 同一 concept の重複主張は拒否される
        g1 = JapanFiscalScenarioAssumption(;
            assumption_id = "g1", concept = :government_spending, magnitude = -1.0,
            magnitude_source = :assumed_default,
        )
        g2 = JapanFiscalScenarioAssumption(;
            assumption_id = "g2", concept = :government_spending, magnitude = -2.0,
            magnitude_source = :assumed_default,
        )
        @test_throws ArgumentError JapanFiscalScenario(;
            scenario_id = "sc-dup", family = :fiscal_consolidation, provenance = prov,
            assumptions = [g1, g2],
        )

        # 空の scenario_id は拒否される
        @test_throws ArgumentError JapanFiscalScenario(;
            scenario_id = "", family = :fiscal_consolidation, provenance = prov,
        )

        # assumptions が空でも正当な scenario（baseline 相当）
        empty_sc = JapanFiscalScenario(;
            scenario_id = "sc-empty", family = :fiscal_consolidation, provenance = prov,
        )
        @test isempty(empty_sc.assumptions)
        @test empty_sc.fre_context === nothing
    end

    # ---- 0 と missing の区別（H-03） ------------------------------------------
    @testset "magnitude の 0 と missing の区別（H-03）" begin
        prov = JapanFiscalScenarioProvenance(; assumption_source = :fixture)
        tax_zero = JapanFiscalScenarioAssumption(;
            assumption_id = "tax-zero", concept = :tax, magnitude = 0.0,
            magnitude_source = :assumed_default,
        )
        # :government_spending は明示的に置かない（= missing）
        sc = JapanFiscalScenario(;
            scenario_id = "sc-zero-vs-missing", family = :fiscal_consolidation,
            provenance = prov, assumptions = [tax_zero],
        )
        concepts_present = Set(a.concept for a in sc.assumptions)
        @test :tax in concepts_present
        @test !(:government_spending in concepts_present)

        d = to_dict(sc)
        present_in_json = Set(a["concept"] for a in d["assumptions"])
        @test "tax" in present_in_json
        @test !("government_spending" in present_in_json)
        @test length(d["assumptions"]) == 1
        @test d["assumptions"][1]["magnitude"] == 0.0

        # round trip でも欠測は補完されない
        back = japan_fiscal_scenario_from_dict(JSON3.read(to_json(sc)))
        back_concepts = Set(a.concept for a in back.assumptions)
        @test back_concepts == concepts_present
    end

    # ---- FRE context と assumption 集合の分離（H-05） --------------------------
    @testset "FRE context だけを変えても applied model input の identity は不変（H-05）" begin
        prov = JapanFiscalScenarioProvenance(; assumption_source = :analysis)
        a = JapanFiscalScenarioAssumption(;
            assumption_id = "a", concept = :tax, magnitude = 1.0,
            magnitude_source = :assumed_default,
        )
        ctx1 = JapanFiscalFREContext(;
            snapshot_id = "fre-1", as_of = Date(2026, 1, 1), vintage_basis = "v1",
            regime_determination = :unavailable,
        )
        ctx2 = JapanFiscalFREContext(;
            snapshot_id = "fre-2", as_of = Date(2026, 6, 1), vintage_basis = "v2",
            regime_determination = :primary, primary_regime = "orthodox",
            constraint_pressure = 0.9,
        )
        sc_no_ctx = JapanFiscalScenario(;
            scenario_id = "sc", family = :fiscal_consolidation, provenance = prov,
            assumptions = [a],
        )
        sc_ctx1 = JapanFiscalScenario(;
            scenario_id = "sc", family = :fiscal_consolidation, provenance = prov,
            fre_context = ctx1, assumptions = [a],
        )
        sc_ctx2 = JapanFiscalScenario(;
            scenario_id = "sc", family = :fiscal_consolidation, provenance = prov,
            fre_context = ctx2, assumptions = [a],
        )

        # assumption_set_hash（applied model input の identity）は context に依存しない
        @test japan_fiscal_assumption_set_hash(sc_no_ctx) ==
              japan_fiscal_assumption_set_hash(sc_ctx1) ==
              japan_fiscal_assumption_set_hash(sc_ctx2)

        # scenario の全体 identity（content hash）は context の有無・内容で変わる
        hashes = Set([
            japan_fiscal_scenario_content_hash(sc_no_ctx),
            japan_fiscal_scenario_content_hash(sc_ctx1),
            japan_fiscal_scenario_content_hash(sc_ctx2),
        ])
        @test length(hashes) == 3
    end

    # ---- content hash の決定論性（H-02・順序非依存） --------------------------
    @testset "content hash の決定論性・両 contract version の包含（H-02）" begin
        prov = JapanFiscalScenarioProvenance(;
            assumption_source = :fixture, created_at = DateTime(2026, 9, 20, 3, 0, 0),
            created_by = "tester",
        )
        g = JapanFiscalScenarioAssumption(;
            assumption_id = "g", concept = :government_spending, magnitude = -1.0,
            magnitude_source = :assumed_default,
        )
        t = JapanFiscalScenarioAssumption(;
            assumption_id = "t", concept = :tax, magnitude = 0.5,
            magnitude_source = :assumed_default,
        )
        sc_gt = JapanFiscalScenario(;
            scenario_id = "sc-order", family = :fiscal_consolidation, provenance = prov,
            assumptions = [g, t],
        )
        sc_tg = JapanFiscalScenario(;
            scenario_id = "sc-order", family = :fiscal_consolidation, provenance = prov,
            assumptions = [t, g],
        )
        @test japan_fiscal_scenario_content_hash(sc_gt) ==
              japan_fiscal_scenario_content_hash(sc_tg)
        @test japan_fiscal_assumption_set_hash(sc_gt) ==
              japan_fiscal_assumption_set_hash(sc_tg)

        # created_at / created_by（volatile）を変えても content hash は変わらない
        prov_other_creator = JapanFiscalScenarioProvenance(;
            assumption_source = :fixture, created_at = DateTime(2030, 1, 1),
            created_by = "someone-else",
        )
        sc_other_creator = JapanFiscalScenario(;
            scenario_id = "sc-order", family = :fiscal_consolidation,
            provenance = prov_other_creator, assumptions = [g, t],
        )
        @test japan_fiscal_scenario_content_hash(sc_gt) ==
              japan_fiscal_scenario_content_hash(sc_other_creator)

        # 両 contract version が identity 対象 provenance に含まれる（H-02）
        d = to_dict(sc_gt)
        @test d["provenance"]["capability_contract_version"] ==
              JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION
        @test d["provenance"]["claim_contract_version"] == JAPAN_FISCAL_CLAIM_CONTRACT_VERSION

        # assumption_source を変えると content hash は変わる（identity 対象）
        prov_user = JapanFiscalScenarioProvenance(; assumption_source = :user)
        sc_user = JapanFiscalScenario(;
            scenario_id = "sc-order", family = :fiscal_consolidation, provenance = prov_user,
            assumptions = [g, t],
        )
        @test japan_fiscal_scenario_content_hash(sc_gt) !=
              japan_fiscal_scenario_content_hash(sc_user)
    end

    # ---- serialization round trip・改変検出 ------------------------------------
    @testset "serialization round trip と改変検出" begin
        prov = JapanFiscalScenarioProvenance(;
            assumption_source = :preset, created_at = DateTime(2026, 9, 20, 12, 0, 0),
            created_by = "preset-loader",
        )
        ctx = JapanFiscalFREContext(;
            snapshot_id = "fre-rt", as_of = Date(2026, 9, 1), vintage_basis = "v-rt",
            regime_determination = :primary, primary_regime = "fiscal_dominance_lite",
        )
        a = JapanFiscalScenarioAssumption(;
            assumption_id = "a", concept = :government_spending, magnitude = -3.0,
            magnitude_source = :assumed_default, notes = "10% cut over 3 years",
        )
        sc = JapanFiscalScenario(;
            scenario_id = "sc-rt", family = :fiscal_consolidation, provenance = prov,
            fre_context = ctx, assumptions = [a], name = "F2 round trip fixture",
            notes = "test fixture",
        )

        json_str = to_json(sc)
        back = japan_fiscal_scenario_from_dict(JSON3.read(json_str))
        @test back.scenario_id == sc.scenario_id
        @test back.family == sc.family
        @test back.name == sc.name
        @test back.notes == sc.notes
        @test length(back.assumptions) == 1
        @test back.assumptions[1].concept == :government_spending
        @test back.assumptions[1].magnitude == -3.0
        @test back.assumptions[1].notes == "10% cut over 3 years"
        @test back.fre_context !== nothing
        @test back.fre_context.snapshot_id == "fre-rt"
        @test back.provenance.assumption_source === :preset
        @test back.provenance.created_by == "preset-loader"
        @test japan_fiscal_scenario_content_hash(back) == japan_fiscal_scenario_content_hash(sc)

        # content_hash の改変は検出される
        d = DME._jf_json_to_plain(JSON3.read(json_str))
        d["content_hash"] = "sha256:" * "0"^64
        @test_throws ArgumentError japan_fiscal_scenario_from_dict(d)

        # assumption_set_hash の改変は検出される
        d2 = DME._jf_json_to_plain(JSON3.read(json_str))
        d2["assumption_set_hash"] = "sha256:" * "1"^64
        @test_throws ArgumentError japan_fiscal_scenario_from_dict(d2)

        # 未知キーの混入は拒否される（fail closed decode）
        d3 = DME._jf_json_to_plain(JSON3.read(json_str))
        d3["unexpected_field"] = "surprise"
        @test_throws ArgumentError japan_fiscal_scenario_from_dict(d3)

        # 必須キーの欠落は拒否される
        d4 = DME._jf_json_to_plain(JSON3.read(json_str))
        delete!(d4, "assumption_set_hash")
        @test_throws ArgumentError japan_fiscal_scenario_from_dict(d4)

        # assumptions が空の scenario も round trip する
        empty_sc = JapanFiscalScenario(;
            scenario_id = "sc-empty-rt", family = :high_growth_productivity,
            provenance = JapanFiscalScenarioProvenance(; assumption_source = :fixture),
        )
        empty_back = japan_fiscal_scenario_from_dict(JSON3.read(to_json(empty_sc)))
        @test isempty(empty_back.assumptions)
        @test empty_back.fre_context === nothing
    end

    # ---- schema contract export ------------------------------------------------
    @testset "japan_fiscal_scenario_schema_contract の export" begin
        contract = japan_fiscal_scenario_schema_contract()
        @test contract["schema_version"] == JAPAN_FISCAL_SCENARIO_SCHEMA_VERSION
        @test contract["capability_contract_version"] == JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION
        @test contract["claim_contract_version"] == JAPAN_FISCAL_CLAIM_CONTRACT_VERSION
        @test contract["fre_context_role"] == "observed_context_only"
        @test Set(contract["forbidden_magnitude_sources"]) == Set(["external_belief"])
        @test Set(contract["forbidden_magnitude_input_fields"]) ==
              Set(collect(JAPAN_FISCAL_FORBIDDEN_MAGNITUDE_INPUT_FIELDS))
        @test length(contract["assumption_concepts"]) == length(JAPAN_FISCAL_ASSUMPTION_CONCEPTS)
        @test length(contract["catalog"]) == length(JAPAN_FISCAL_SCENARIO_FAMILIES)
        # JSON3 で round trip できる（Julia 内部型を含まない）
        parsed = JSON3.read(JSON3.write(contract))
        @test parsed.schema_version == JAPAN_FISCAL_SCENARIO_SCHEMA_VERSION
    end

    # ---- FRE のスコアが magnitude 入力へ混入しないことの構造的検査 ----------------
    @testset "FRE context のフィールドは JapanFiscalScenarioAssumption の入力に現れない" begin
        # `JapanFiscalScenarioAssumption` の keyword constructor は
        # assumption_id/concept/magnitude/magnitude_source/notes の5つのみを取り、
        # JapanFiscalFREContext 型の引数を一切取らない（fieldnames で確認する）。
        @test fieldnames(JapanFiscalScenarioAssumption) ==
              (:assumption_id, :concept, :magnitude, :magnitude_source, :notes)
        forbidden_fields = Set(String.(collect(JAPAN_FISCAL_FORBIDDEN_MAGNITUDE_INPUT_FIELDS)))
        fre_fields = Set(String.(collect(fieldnames(JapanFiscalFREContext))))
        # #274 が禁止する6フィールドはすべて JapanFiscalFREContext 側に存在する
        # （= observed context としてのみ保持され、assumption 側には存在しない）
        @test issubset(forbidden_fields, fre_fields)
        @test isempty(intersect(forbidden_fields, Set(String.(collect(fieldnames(JapanFiscalScenarioAssumption))))))
    end
end
