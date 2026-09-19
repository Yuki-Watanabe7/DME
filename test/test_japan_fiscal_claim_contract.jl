# Japan Fiscal Scenario Lab の claim-level / coverage 契約（Issue #285）のテスト。
#
# #274 の findings が downstream（#275 の scenario schema・#276 の result artifact・
# Market Analyzer consumer）へ lossless に伝播することを機械的に検証する。
#   - `claim_level` ごとの主張可能な診断と数値意味づけが固定されている
#   - 現在の 55 セルに `:magnitude` が 0 件（日本較正済みモデルが無い）
#   - F1 の成長・F3 の JGB 吸収・F5 の sovereign leg が unsupported として残る
#   - serialization で `claim_level` と unsupported フィールドが消えない
#   - claim_level を超える主張が実行時に違反として返る

using Test
using DME

@testset "Japan fiscal claim-level / coverage 契約（Issue #285）" begin

    # ---- 契約 version と語彙 ------------------------------------------------
    @testset "契約 version と語彙" begin
        @test JAPAN_FISCAL_CLAIM_CONTRACT_VERSION == "japan-fiscal-claim-contract/1.0.0"
        @test JAPAN_FISCAL_NUMERIC_SEMANTICS ==
              (:none, :model_unit_relative, :normalized_deviation, :japan_magnitude)
        @test JAPAN_FISCAL_CALIBRATION_GEOGRAPHIES == (:jp, :us, :none)
        @test JAPAN_FISCAL_CHANNEL_STATUSES ==
              (:covered, :partially_covered, :unsupported)
        @test Set(keys(JAPAN_FISCAL_CLAIM_LEVEL_REGISTRY)) ==
              Set(JAPAN_FISCAL_CLAIM_LEVELS)
        @test Set(keys(JAPAN_FISCAL_FORBIDDEN_CLAIM_REASONS)) ==
              Set(JAPAN_FISCAL_FORBIDDEN_CLAIM_KINDS)
        @test length(japan_fiscal_forbidden_claims()) ==
              length(JAPAN_FISCAL_FORBIDDEN_CLAIM_KINDS)
    end

    # ---- claim_level の意味論 -----------------------------------------------
    @testset "claim_level ごとの主張可能な診断" begin
        @test isempty(japan_fiscal_claim_level_spec(:none).permitted_diagnostics)
        @test japan_fiscal_claim_level_spec(:none).numeric_semantics === :none

        # direction_only は符号のみ。時間形状を主張できない。
        @test japan_fiscal_claim_level_permits(:direction_only, :direction)
        @test japan_fiscal_claim_level_permits(:direction_only, :sign_of_delta)
        for d in (:peak, :onset, :duration, :recovery, :relative_delta, :absolute_delta)
            @test !japan_fiscal_claim_level_permits(:direction_only, d)
            @test d in japan_fiscal_forbidden_diagnostics(:direction_only)
        end

        # direction_and_relative_timing は時間形状まで。絶対差・水準経路は不可。
        for d in (:peak, :onset, :duration, :recovery, :relative_delta, :relative_ordering,
            :contribution_decomposition)
            @test japan_fiscal_claim_level_permits(:direction_and_relative_timing, d)
        end
        for d in (:absolute_delta, :level_path)
            @test !japan_fiscal_claim_level_permits(:direction_and_relative_timing, d)
        end

        # magnitude は全診断。
        for d in JAPAN_FISCAL_DIAGNOSTICS
            @test japan_fiscal_claim_level_permits(:magnitude, d)
        end
        @test isempty(japan_fiscal_forbidden_diagnostics(:magnitude))

        # 単調性: 上位段階は下位段階の診断を包含する
        order = (:none, :direction_only, :direction_and_relative_timing, :magnitude)
        for i in 2:length(order)
            lo = Set(japan_fiscal_claim_level_spec(order[i - 1]).permitted_diagnostics)
            hi = Set(japan_fiscal_claim_level_spec(order[i]).permitted_diagnostics)
            @test issubset(lo, hi)
            @test japan_fiscal_numeric_semantics_rank(
                japan_fiscal_claim_level_spec(order[i - 1]).numeric_semantics,
            ) < japan_fiscal_numeric_semantics_rank(
                japan_fiscal_claim_level_spec(order[i]).numeric_semantics,
            )
        end

        # 各段階が caveat と consumer rule を持つ
        for l in JAPAN_FISCAL_CLAIM_LEVELS
            s = japan_fiscal_claim_level_spec(l)
            @test !isempty(s.required_caveats)
            @test !isempty(s.consumer_rules)
        end

        @test_throws ArgumentError japan_fiscal_claim_level_spec(:unknown_level)
        @test_throws ArgumentError japan_fiscal_claim_level_permits(
            :direction_only,
            :unknown_diagnostic,
        )
    end

    # ---- 日本較正が無いことの invariant ------------------------------------
    @testset "現在の 55 セルに magnitude claim が 0 件" begin
        covs = japan_fiscal_coverages()
        @test length(covs) == 55
        @test count(c -> c.claim_level === :magnitude, covs) == 0
        @test count(c -> c.numeric_semantics === :japan_magnitude, covs) == 0
        @test count(c -> c.calibration_geography === :jp, covs) == 0
        # 較正地理は calibration_basis から一意に決まる
        for m in JAPAN_FISCAL_MODEL_MAPPINGS
            g = japan_fiscal_calibration_geography(m)
            @test g in JAPAN_FISCAL_CALIBRATION_GEOGRAPHIES
            @test (g === :us) == (m.calibration_basis === :non_japan_calibrated)
            @test (g === :jp) == (m.calibration_basis === :japan_calibrated)
        end
        @test any(c -> c.calibration_geography === :us, covs)
        # 昇格規則が存在し、consumer の暗黙昇格を禁じている
        r = JAPAN_FISCAL_CLAIM_UPGRADE_RULE
        @test !isempty(r.conditions)
        @test length(r.version_bumps) == 2
        @test any(f -> occursin("claim_level", f), r.forbidden)
    end

    # ---- coverage の導出整合 ------------------------------------------------
    @testset "coverage が #274 registry から導出される" begin
        for m in JAPAN_FISCAL_MODEL_MAPPINGS
            c = japan_fiscal_coverage(m.family, m.model)
            @test c.capability_contract_version ==
                  JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION
            @test c.claim_contract_version == JAPAN_FISCAL_CLAIM_CONTRACT_VERSION
            @test c.representability === m.representability
            @test c.adoption === m.adoption
            @test c.claim_level === m.claim_level
            @test c.accepted_concepts == japan_fiscal_accepted_concepts(m)
            @test c.unsupported_concepts ==
                  japan_fiscal_unsupported_concepts(m.family, m.model)
            @test c.unsupported_outputs ==
                  japan_fiscal_unsupported_outputs(m.family, m.model)
            @test c.required_concepts ==
                  japan_fiscal_family_spec(m.family).required_concepts
            @test c.produced_outputs == m.endogenous_outputs
            @test c.numeric_semantics ===
                  japan_fiscal_claim_level_spec(m.claim_level).numeric_semantics
            @test issubset(Set(m.gap_ids), Set(c.gap_ids))
            # 覆われたチャネルと覆われていないチャネルは family のチャネル全体を分割する
            all_ch =
                Set(ch.channel_id for ch in japan_fiscal_channels(; family = m.family))
            @test Set(c.covered_channels) ∪ Set(c.uncovered_channels) == all_ch
            @test isempty(intersect(Set(c.covered_channels), Set(c.uncovered_channels)))
        end
    end

    @testset "family 完全なセルが存在しない" begin
        # 全 family に :unsupported のチャネルが残るため、family_complete は全件 false。
        # これは未実装の placeholder ではなく #274 の監査結果そのものである。
        for c in japan_fiscal_coverages()
            @test c.family_complete == false
            @test !isempty(c.uncovered_channels)
        end
    end

    # ---- チャネル registry --------------------------------------------------
    @testset "因果チャネル registry" begin
        @test length(JAPAN_FISCAL_CHANNEL_REGISTRY) == 25
        for f in JAPAN_FISCAL_SCENARIO_FAMILIES
            chs = japan_fiscal_channels(; family = f)
            @test length(chs) == 5
            @test !isempty(japan_fiscal_channels(; family = f, status = :unsupported))
            adopted = Set(japan_fiscal_implementation_candidates(f))
            for c in chs
                @test c.family === f
                @test issubset(Set(c.covered_by), adopted)
                @test (c.status === :unsupported) == isempty(c.covered_by)
                if c.status !== :covered
                    @test !isempty(c.limitation)
                end
            end
        end
        known = Set(g.gap_id for g in JAPAN_FISCAL_GAP_REGISTER)
        for c in JAPAN_FISCAL_CHANNEL_REGISTRY
            @test issubset(Set(c.gap_ids), known)
        end
        @test_throws ArgumentError japan_fiscal_channel(:jgb_funding_cost, :unknown_channel)
    end

    @testset "F1 の成長チャネルが unsupported として残る" begin
        c = japan_fiscal_channel(:low_growth_high_rates, :growth_assumption_transmission)
        @test c.status === :unsupported
        @test isempty(c.covered_by)
        @test "G-03" in c.gap_ids
        # 主候補 CCC も growth path を受け取らない
        ccc = japan_fiscal_coverage(:low_growth_high_rates, :capex_credit_cycle)
        @test ccc.representability === :partial
        @test :growth_path in ccc.unsupported_concepts
        @test :growth_assumption_transmission in ccc.uncovered_channels
    end

    @testset "F3 の BOJ/JGB absorption が全モデルで unsupported" begin
        c = japan_fiscal_channel(:financial_repression, :cb_jgb_absorption)
        @test c.status === :unsupported
        @test isempty(c.covered_by)
        @test "G-04" in c.gap_ids
        for mo in JAPAN_FISCAL_CANDIDATE_MODELS
            cov = japan_fiscal_coverage(:financial_repression, mo)
            @test :cb_jgb_absorption in cov.unsupported_concepts
            @test :cb_jgb_absorption in cov.uncovered_channels
        end
    end

    @testset "F5 の sovereign leg が unsupported として残る" begin
        sov = japan_fiscal_channel(:jgb_funding_cost, :sovereign_funding_cost)
        @test sov.status === :unsupported
        @test isempty(sov.covered_by)
        @test "G-14" in sov.gap_ids
        @test "G-01" in sov.gap_ids
        burden =
            japan_fiscal_channel(:jgb_funding_cost, :interest_burden_to_fiscal_balance)
        @test burden.status === :unsupported
        # private pass-through leg は covered
        priv = japan_fiscal_channel(:jgb_funding_cost, :private_pass_through)
        @test priv.status === :covered
        @test Set(priv.covered_by) == Set([:capex_credit_cycle, :keen])
        # 主候補 CCC の coverage に sovereign leg が未被覆として現れる
        ccc = japan_fiscal_coverage(:jgb_funding_cost, :capex_credit_cycle)
        @test :sovereign_funding_cost in ccc.uncovered_channels
        @test :private_pass_through in ccc.covered_channels
        @test :government_balance in ccc.unsupported_outputs
    end

    # ---- claim 検証 ---------------------------------------------------------
    @testset "claim_level を超える主張が違反になる" begin
        # direction_only に peak / onset を要求
        v = japan_fiscal_validate_claims(
            :fiscal_consolidation,
            :islm;
            diagnostics = [:direction, :peak, :onset],
            disclosed_unsupported_concepts = Symbol[],
            disclosed_unsupported_outputs = [:government_balance],
        )
        @test length(v) == 2
        @test all(x -> x.code === :diagnostic_not_permitted, v)
        @test all(x -> !isempty(x.detail), v)

        # 適合ケース（違反なし）
        cov = japan_fiscal_coverage(:jgb_funding_cost, :capex_credit_cycle)
        @test isempty(
            japan_fiscal_validate_claims(
                :jgb_funding_cost,
                :capex_credit_cycle;
                diagnostics = [:direction, :peak, :onset, :duration],
                numeric_semantics = :normalized_deviation,
                disclosed_unsupported_concepts = cov.unsupported_concepts,
                disclosed_unsupported_outputs = cov.unsupported_outputs,
            ),
        )
    end

    @testset "未較正モデルの数値を日本の量として提示できない" begin
        v = japan_fiscal_validate_claims(
            :fiscal_consolidation,
            :sim;
            numeric_semantics = :japan_magnitude,
            disclosed_unsupported_concepts = Symbol[],
            disclosed_unsupported_outputs = Symbol[],
        )
        codes = Set(x.code for x in v)
        @test :numeric_semantics_exceeds_claim in codes
        @test :magnitude_without_japan_calibration in codes
    end

    @testset "unsupported を隠すと違反になる" begin
        v = japan_fiscal_validate_claims(
            :financial_repression,
            :new_keynesian;
            diagnostics = [:direction],
        )
        codes = Set(x.code for x in v)
        @test :unsupported_concept_hidden in codes
        v2 = japan_fiscal_validate_claims(
            :jgb_funding_cost,
            :capex_credit_cycle;
            disclosed_unsupported_concepts = Symbol[],
            disclosed_unsupported_outputs = Symbol[],
        )
        @test :unsupported_output_hidden in Set(x.code for x in v2)
    end

    @testset "禁止主張と family 完全提示が違反になる" begin
        v = japan_fiscal_validate_claims(
            :high_growth_productivity,
            :solow;
            disclosed_unsupported_concepts = Symbol[],
            disclosed_unsupported_outputs = Symbol[],
            claim_kinds = [:forecast, :crisis_probability, :debt_sustainability_judgment],
            presented_as_family_complete = true,
        )
        codes = [x.code for x in v]
        @test count(==(:forbidden_claim_kind), codes) == 3
        @test :family_presented_as_complete in Set(codes)
    end

    @testset "違反コード語彙" begin
        for c in JAPAN_FISCAL_CLAIM_VIOLATION_CODES
            @test JapanFiscalClaimViolation(c, "テスト").code === c
        end
        @test_throws ArgumentError JapanFiscalClaimViolation(:unknown_code, "テスト")
    end

    # ---- handoff requirements -----------------------------------------------
    @testset "downstream handoff requirements" begin
        rs = japan_fiscal_handoff_requirements()
        @test length(rs) == 22
        ids = [r.requirement_id for r in rs]
        @test length(unique(ids)) == length(ids)
        for r in rs
            @test occursin(r"^H-\d{2}$", r.requirement_id)
            @test !isempty(r.requirement)
            @test !isempty(r.rationale)
            @test !isempty(r.verification)
        end
        for a in JAPAN_FISCAL_HANDOFF_AUDIENCES
            @test !isempty(japan_fiscal_handoff_requirements(; audience = a))
        end
        # #275 / #276 / #277 / consumer のそれぞれに要件がある
        @test length(japan_fiscal_handoff_requirements(; audience = :dme_scenario_schema)) ==
              5
        @test length(japan_fiscal_handoff_requirements(; audience = :dme_result_artifact)) ==
              7
        @test length(japan_fiscal_handoff_requirements(; audience = :dme_e2e_fixture)) == 4
        @test length(japan_fiscal_handoff_requirements(; audience = :consumer)) == 6
        known = Set(g.gap_id for g in JAPAN_FISCAL_GAP_REGISTER)
        for r in rs
            @test issubset(Set(r.gap_ids), known)
        end
        @test_throws ArgumentError japan_fiscal_handoff_requirements(;
            audience = :unknown_audience,
        )
    end

    # ---- serialization ------------------------------------------------------
    @testset "serialization で claim_level と unsupported が消えない" begin
        cov = japan_fiscal_coverage(:financial_repression, :new_keynesian)
        d = to_dict(cov)
        for k in (
            "claim_level",
            "numeric_semantics",
            "permitted_diagnostics",
            "forbidden_diagnostics",
            "unsupported_concepts",
            "unsupported_outputs",
            "uncovered_channels",
            "family_complete",
            "calibration_geography",
            "cannot_state",
            "major_caveats",
            "gap_ids",
        )
            @test haskey(d, k)
        end
        @test d["claim_level"] == "direction_and_relative_timing"
        @test "cb_jgb_absorption" in d["unsupported_concepts"]
        @test d["family_complete"] == false

        back = DME.JSON3.read(to_json(cov))
        @test back["claim_level"] == "direction_and_relative_timing"
        @test "cb_jgb_absorption" in back["unsupported_concepts"]
        @test back["family_complete"] == false
        @test !isempty(back["uncovered_channels"])
        @test !isempty(back["cannot_state"])
    end

    @testset "downstream contract の機械可読 export" begin
        c = japan_fiscal_downstream_contract()
        @test c["claim_contract_version"] == JAPAN_FISCAL_CLAIM_CONTRACT_VERSION
        @test c["capability_contract_version"] ==
              JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION
        @test length(c["coverages"]) == 55
        @test length(c["channels"]) == 25
        @test length(c["claim_levels"]) == 4
        @test length(c["handoff_requirements"]) == 22
        @test length(c["forbidden_claims"]) == length(JAPAN_FISCAL_FORBIDDEN_CLAIM_KINDS)
        inv = c["invariants"]
        @test inv["magnitude_claim_count"] == 0
        @test inv["japan_calibrated_model_count"] == 0
        @test inv["family_complete_count"] == 0
        @test inv["unsupported_channel_count"] > 0

        # 決定的
        @test japan_fiscal_downstream_contract() == c
        s1 = DME.JSON3.write(c)
        @test DME.JSON3.write(japan_fiscal_downstream_contract()) == s1

        # Julia 内部型なしで decode できる
        back = DME.JSON3.read(s1)
        @test back["claim_contract_version"] == JAPAN_FISCAL_CLAIM_CONTRACT_VERSION
        @test length(back["coverages"]) == 55
        @test back["invariants"]["magnitude_claim_count"] == 0
        # F5 の sovereign leg が contract から読める
        sov = only(
            ch for ch in back["channels"] if
            ch["family"] == "jgb_funding_cost" && ch["channel_id"] == "sovereign_funding_cost"
        )
        @test sov["status"] == "unsupported"
        @test isempty(sov["covered_by"])
    end

    # ---- コンストラクタの契約強制 -------------------------------------------
    @testset "コンストラクタが契約違反を拒否する" begin
        # :none が診断を主張する
        @test_throws ArgumentError JapanFiscalClaimLevelSpec(;
            claim_level = :none,
            display_name = "テスト",
            definition = "テスト",
            numeric_semantics = :none,
            permitted_diagnostics = [:direction],
        )
        # japan_magnitude を magnitude 以外で名乗る
        @test_throws ArgumentError JapanFiscalClaimLevelSpec(;
            claim_level = :direction_only,
            display_name = "テスト",
            definition = "テスト",
            numeric_semantics = :japan_magnitude,
            permitted_diagnostics = [:direction],
        )
        # unsupported なのに covered_by を持つ
        @test_throws ArgumentError JapanFiscalChannel(;
            channel_id = :test_channel,
            family = :jgb_funding_cost,
            display_name = "テスト",
            description = "テスト",
            status = :unsupported,
            covered_by = [:capex_credit_cycle],
            limitation = "テスト",
        )
        # unsupported なのに limitation が無い
        @test_throws ArgumentError JapanFiscalChannel(;
            channel_id = :test_channel,
            family = :jgb_funding_cost,
            display_name = "テスト",
            description = "テスト",
            status = :unsupported,
        )
        # covered なのに covered_by が空
        @test_throws ArgumentError JapanFiscalChannel(;
            channel_id = :test_channel,
            family = :jgb_funding_cost,
            display_name = "テスト",
            description = "テスト",
            status = :covered,
        )
        # requirement_id の形式違反
        @test_throws ArgumentError JapanFiscalHandoffRequirement(;
            requirement_id = "H1",
            audience = :consumer,
            requirement = "テスト",
            rationale = "テスト",
            verification = "テスト",
        )
    end
end
