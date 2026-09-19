# Japan Fiscal Scenario Lab の scenario family × model capability / mapping contract
# （Issue #274 / Phase 3）のテスト。
#
# 契約が「宣言だけの文書」にならないよう、次を機械的に検証する。
#   - 5 family × 11 model の 55 セルに漏れなく representability 判定がある
#   - representability が family 仕様（required_concepts / required_outputs）と整合する
#   - mapping が参照するモデル側変数が実在する（架空の変数名で契約を書いていない）
#   - FRE の affinity / share / confidence を magnitude へ変換する経路が存在しない
#   - 金融抑圧を単一 rate shock へ縮約していない
#   - 日本較正済みモデルが無いことと `claim_level` の上限が整合する

using Test
using DME

# 能力 metadata のテストと同じインスタンス集合（モデル側変数の実在確認に使う）
_jf_test_instances() = Dict{Symbol, AbstractMacroModel}(
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
    :keen =>
        KeenModel(0.025, 0.02, 0.01, 3.0, 0.03, 0.0400641, 6.41e-5, -0.0065, exp(-5), 20.0),
    :sim => SIMModel(; α1 = 0.6, α2 = 0.4, θ = 0.2, G = 20.0),
    :capex_credit_cycle =>
        capex_credit_cycle_model(capex_credit_cycle_default_targets()),
)

# モデル側で「名前として実在する」記号の集合（パラメータ・状態・操作・外生変数）
function _jf_known_names(model::Symbol, inst::AbstractMacroModel)
    names = Set{Symbol}()
    for k in keys(parameters(inst))
        push!(names, k)
    end
    union!(names, Set(state_variables(inst)))
    union!(names, Set(control_variables(inst)))
    if model === :capex_credit_cycle
        union!(names, Set(exogenous_variables(inst)))
    end
    return names
end

@testset "Japan fiscal scenario capability contract（Issue #274）" begin

    # ---- 契約 version と語彙 ------------------------------------------------
    @testset "契約 version と語彙" begin
        @test JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION ==
              "japan-fiscal-scenario-capability/1.0.0"
        @test length(JAPAN_FISCAL_SCENARIO_FAMILIES) == 5
        @test Set(JAPAN_FISCAL_SCENARIO_FAMILIES) == Set([
            :low_growth_high_rates,
            :fiscal_consolidation,
            :financial_repression,
            :high_growth_productivity,
            :jgb_funding_cost,
        ])
        @test length(JAPAN_FISCAL_ASSUMPTION_CONCEPTS) == 9
        @test JAPAN_FISCAL_REPRESENTABILITY ==
              (:representable, :partial, :not_representable)
        # 候補モデル集合は能力 metadata registry と一致する（監査漏れの防止）
        @test Set(JAPAN_FISCAL_CANDIDATE_MODELS) == Set(keys(MODEL_CAPABILITY_REGISTRY))
    end

    # ---- 55 セルの網羅性 ----------------------------------------------------
    @testset "5 family × 11 model の全セルに判定がある" begin
        @test length(JAPAN_FISCAL_MODEL_MAPPINGS) == 55
        cells = Set((m.family, m.model) for m in JAPAN_FISCAL_MODEL_MAPPINGS)
        @test length(cells) == 55
        for f in JAPAN_FISCAL_SCENARIO_FAMILIES, mo in JAPAN_FISCAL_CANDIDATE_MODELS
            @test (f, mo) in cells
            @test japan_fiscal_representability(f, mo) in JAPAN_FISCAL_REPRESENTABILITY
        end
    end

    @testset "全セルが具体的な理由を持つ" begin
        for m in JAPAN_FISCAL_MODEL_MAPPINGS
            @test !isempty(m.reason)
            # 「表現できない」で終わらせず、どの入力・どの概念が無いかを書く
            @test length(m.reason) >= 30
        end
    end

    # ---- representability の導出整合 ---------------------------------------
    @testset "representability が family 仕様から導かれる値と一致する" begin
        for m in JAPAN_FISCAL_MODEL_MAPPINGS
            spec = japan_fiscal_family_spec(m.family)
            accepted = Set(japan_fiscal_accepted_concepts(m))
            required = Set(spec.required_concepts)
            derived = if isempty(intersect(required, accepted))
                :not_representable
            elseif issubset(required, accepted) &&
                   issubset(Set(spec.required_outputs), Set(m.endogenous_outputs))
                :representable
            else
                :partial
            end
            @test m.representability === derived
        end
    end

    @testset "not_representable のセルは採用されず claim を持たない" begin
        for m in japan_fiscal_model_mappings(; representability = :not_representable)
            @test m.adoption === :not_adopted
            @test m.claim_level === :none
            @test isempty(japan_fiscal_accepted_concepts(m)) ||
                  isempty(intersect(
                Set(japan_fiscal_accepted_concepts(m)),
                Set(japan_fiscal_family_spec(m.family).required_concepts),
            ))
        end
    end

    # ---- 実装候補 -----------------------------------------------------------
    @testset "family ごとに実装候補が 1 つ以上ある" begin
        for f in JAPAN_FISCAL_SCENARIO_FAMILIES
            cands = japan_fiscal_implementation_candidates(f)
            @test !isempty(cands)
            @test count(
                m -> m.adoption === :primary,
                japan_fiscal_model_mappings(; family = f),
            ) == 1
        end
        @test japan_fiscal_implementation_candidates(:fiscal_consolidation)[1] === :sim
        @test japan_fiscal_implementation_candidates(:financial_repression)[1] ===
              :new_keynesian
        @test japan_fiscal_implementation_candidates(:high_growth_productivity)[1] ===
              :solow
        @test japan_fiscal_implementation_candidates(:low_growth_high_rates)[1] ===
              :capex_credit_cycle
        @test japan_fiscal_implementation_candidates(:jgb_funding_cost)[1] ===
              :capex_credit_cycle
    end

    # ---- 日本較正が無いことと claim_level の整合 ----------------------------
    @testset "日本較正済みモデルが無いため magnitude を名乗るセルが無い" begin
        for m in JAPAN_FISCAL_MODEL_MAPPINGS
            @test m.claim_level !== :magnitude
            @test m.calibration_basis !== :japan_calibrated
        end
        @test any(m -> m.calibration_basis === :non_japan_calibrated,
            JAPAN_FISCAL_MODEL_MAPPINGS)
    end

    # ---- モデル側変数の実在確認 --------------------------------------------
    @testset "mapping が参照するモデル側変数が実在する" begin
        inst = _jf_test_instances()
        checked = 0
        for m in JAPAN_FISCAL_MODEL_MAPPINGS
            known = _jf_known_names(m.model, inst[m.model])
            for i in m.inputs
                i.input_kind === :not_accepted && continue
                @test i.variable in known
                @test !isempty(i.unit)
                checked += 1
            end
        end
        @test checked >= 20
    end

    @testset "not_accepted の行は変数名を持たず理由を持つ" begin
        for m in JAPAN_FISCAL_MODEL_MAPPINGS, i in m.inputs
            if i.input_kind === :not_accepted
                @test i.variable === :none
                @test !isempty(i.notes)
            end
        end
    end

    # ---- FRE context contract ----------------------------------------------
    @testset "FRE snapshot は observed context に限定される" begin
        @test JAPAN_FISCAL_FRE_CONTEXT_ROLE === :observed_context_only
        @test :external_belief in JAPAN_FISCAL_FORBIDDEN_MAGNITUDE_SOURCES
        @test !japan_fiscal_magnitude_source_allowed(:external_belief)
        @test japan_fiscal_magnitude_source_allowed(:observed)
        @test japan_fiscal_magnitude_source_allowed(:disclosed)
        @test japan_fiscal_magnitude_source_allowed(:assumed_default)
        @test_throws ArgumentError japan_fiscal_magnitude_source_allowed(:regime_affinity)
        # 禁止フィールドはいずれも MACRO_EVENT_MAGNITUDE_SOURCES の部分集合である
        @test issubset(
            Set(JAPAN_FISCAL_FORBIDDEN_MAGNITUDE_SOURCES),
            Set(DME.MACRO_EVENT_MAGNITUDE_SOURCES),
        )
    end

    @testset "FRE のスコアをモデル入力に取っている mapping が無い" begin
        forbidden = Set(Symbol(f) for f in JAPAN_FISCAL_FORBIDDEN_MAGNITUDE_INPUT_FIELDS)
        @test !isempty(forbidden)
        for m in JAPAN_FISCAL_MODEL_MAPPINGS, i in m.inputs
            @test !(i.variable in forbidden)
        end
        # FRE 由来の概念は assumption 概念語彙にも存在しない
        @test isempty(intersect(forbidden, Set(JAPAN_FISCAL_ASSUMPTION_CONCEPTS)))
    end

    # ---- 分解規則（#274 確認事項 1〜5） ------------------------------------
    @testset "financial repression を単一 rate shock へ縮約しない" begin
        spec = japan_fiscal_family_spec(:financial_repression)
        @test Set(spec.required_concepts) ==
              Set([:policy_rate, :inflation, :cb_jgb_absorption])
        @test occursin("縮約", spec.decomposition_rule)
        @test !isempty(spec.forbidden_proxies)
        # 中央銀行の JGB 吸収はどのモデルも受け取らない（G-04）
        for mo in JAPAN_FISCAL_CANDIDATE_MODELS
            @test :cb_jgb_absorption in
                  japan_fiscal_unsupported_concepts(:financial_repression, mo)
        end
        # AD-AS は「インフレと名目金利を独立に置けない」ことを理由に not_representable
        adas = japan_fiscal_model_mapping(:financial_repression, :adas)
        @test adas.representability === :not_representable
        @test occursin("独立", adas.reason)
        # 主候補 New Keynesian は政策金利とインフレを別入力として受け取る
        nk = japan_fiscal_model_mapping(:financial_repression, :new_keynesian)
        @test Set(japan_fiscal_accepted_concepts(nk)) == Set([:policy_rate, :inflation])
        @test length(unique(i.variable for i in nk.inputs if i.input_kind !== :not_accepted)) ==
              2
    end

    @testset "fiscal consolidation は税・支出を受け取り PB は変換が要る" begin
        spec = japan_fiscal_family_spec(:fiscal_consolidation)
        @test Set(spec.required_concepts) == Set([:government_spending, :tax])
        @test :primary_balance in spec.optional_concepts
        sim = japan_fiscal_model_mapping(:fiscal_consolidation, :sim)
        @test sim.representability === :representable
        @test :government_balance in sim.endogenous_outputs
        pb = only(i for i in sim.inputs if i.concept === :primary_balance)
        @test pb.input_kind === :requires_structural_conversion
        @test occursin("一意", pb.conversion)
        # 政府部門を持たないモデルは財政 family を表現しない
        for mo in (:ramsey, :rbc, :solow, :keen, :capex_credit_cycle, :new_keynesian)
            @test japan_fiscal_representability(:fiscal_consolidation, mo) ===
                  :not_representable
        end
    end

    @testset "low growth + high rates は金利と成長を別入力として保持する" begin
        spec = japan_fiscal_family_spec(:low_growth_high_rates)
        @test Set(spec.required_concepts) ==
              Set([:growth_path, :policy_rate, :long_rate_funding_condition])
        ccc = japan_fiscal_model_mapping(:low_growth_high_rates, :capex_credit_cycle)
        accepted = Set(japan_fiscal_accepted_concepts(ccc))
        @test :policy_rate in accepted
        @test :long_rate_funding_condition in accepted
        # 政策金利と長期金利は別々のモデル変数へ入る
        pr = only(i for i in ccc.inputs if i.concept === :policy_rate)
        lr = only(i for i in ccc.inputs if i.concept === :long_rate_funding_condition)
        @test pr.variable !== lr.variable
        @test pr.variable === :policy_rate
        @test lr.variable === :spread_shock_ex
    end

    @testset "GDP 成長率パスはどのモデルも直接受け取らない（G-03）" begin
        for m in JAPAN_FISCAL_MODEL_MAPPINGS
            @test !(:growth_path in japan_fiscal_accepted_concepts(m))
        end
        g = japan_fiscal_gap("G-03")
        @test :low_growth_high_rates in g.affected_families
        @test :high_growth_productivity in g.affected_families
    end

    @testset "生産性ショックと GDP パス assumption を区別する" begin
        spec = japan_fiscal_family_spec(:high_growth_productivity)
        @test spec.required_concepts == [:productivity_growth]
        @test :growth_path in spec.optional_concepts
        solow = japan_fiscal_model_mapping(:high_growth_productivity, :solow)
        @test solow.representability === :representable
        @test only(i for i in solow.inputs if i.concept === :productivity_growth).variable ===
              :g
        # AD-AS は「水準」でしか受け取れないため変換が要る
        adas = japan_fiscal_model_mapping(:high_growth_productivity, :adas)
        adas_in = only(i for i in adas.inputs if i.concept === :productivity_growth)
        @test adas_in.input_kind === :requires_structural_conversion
        @test adas_in.variable === :Y_n
        # CCC は成長 regime を表現できない
        @test japan_fiscal_representability(
            :high_growth_productivity,
            :capex_credit_cycle,
        ) === :not_representable
    end

    @testset "JGB funding-cost は #260 契約の再利用範囲と sovereign leg を分離する" begin
        spec = japan_fiscal_family_spec(:jgb_funding_cost)
        @test spec.required_concepts == [:long_rate_funding_condition]
        @test :government_balance in spec.required_outputs
        # assumption 概念はイベント層の target concept と同一概念として宣言されている
        c = japan_fiscal_assumption_concept(:long_rate_funding_condition)
        @test c.event_target_concept === :long_rate_funding_condition
        @test c.event_target_concept in DME.MACRO_EVENT_TARGET_CONCEPTS
        @test c.unit == "bp"
        # sovereign leg（財政収支・利払費）はどのモデルも返さない
        for mo in JAPAN_FISCAL_CANDIDATE_MODELS
            @test :government_balance in
                  japan_fiscal_unsupported_outputs(:jgb_funding_cost, mo)
        end
        ccc = japan_fiscal_model_mapping(:jgb_funding_cost, :capex_credit_cycle)
        @test ccc.representability === :partial
        @test ccc.adoption === :primary
        @test "G-14" in ccc.gap_ids
        @test :spread_shock_ex in
              exogenous_variables(_jf_test_instances()[:capex_credit_cycle])
    end

    # ---- gap register -------------------------------------------------------
    @testset "gap register" begin
        @test length(JAPAN_FISCAL_GAP_REGISTER) == 15
        ids = [g.gap_id for g in JAPAN_FISCAL_GAP_REGISTER]
        @test length(unique(ids)) == length(ids)
        for g in JAPAN_FISCAL_GAP_REGISTER
            @test occursin(r"^G-\d{2}$", g.gap_id)
            @test !isempty(g.consequence)
            @test !isempty(g.affected_families)
            @test !isempty(g.affected_models)
            @test g.resolution in JAPAN_FISCAL_GAP_RESOLUTIONS
        end
        known = Set(ids)
        for m in JAPAN_FISCAL_MODEL_MAPPINGS
            @test issubset(Set(m.gap_ids), known)
        end
        for f in JAPAN_FISCAL_SCENARIO_FAMILIES
            @test issubset(Set(japan_fiscal_family_spec(f).gap_ids), known)
            @test !isempty(japan_fiscal_gaps(; family = f))
        end
        # 利付き政府債務が無いことは全 family に効く最重要ギャップ
        g1 = japan_fiscal_gap("G-01")
        @test Set(g1.affected_families) == Set(JAPAN_FISCAL_SCENARIO_FAMILIES)
        @test g1.resolution === :hold_as_limitation
        @test_throws ArgumentError japan_fiscal_gap("G-99")
    end

    # ---- 機械可読 export ----------------------------------------------------
    @testset "capability matrix の機械可読 export" begin
        mx = japan_fiscal_capability_matrix()
        @test mx["contract_version"] == JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION
        @test mx["fre_context_role"] == "observed_context_only"
        @test length(mx["mappings"]) == 55
        @test length(mx["families"]) == 5
        @test length(mx["gaps"]) == 15
        @test length(mx["assumption_concepts"]) == 9
        # 同一入力から同一の matrix（決定的）
        @test japan_fiscal_capability_matrix() == mx
        s1 = DME.JSON3.write(mx)
        @test DME.JSON3.write(japan_fiscal_capability_matrix()) == s1
        # JSON として読み戻せる
        back = DME.JSON3.read(s1)
        @test back["contract_version"] == JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION
        @test length(back["mappings"]) == 55
        # 各 mapping の dict に必須キーが揃う
        row = first(mx["mappings"])
        for k in (
            "family",
            "model",
            "representability",
            "adoption",
            "accepted_concepts",
            "unsupported_concepts",
            "unsupported_outputs",
            "inputs",
            "calibration_basis",
            "claim_level",
            "reason",
            "gap_ids",
        )
            @test haskey(row, k)
        end
        @test !isempty(to_json(japan_fiscal_family_spec(:fiscal_consolidation)))
        @test !isempty(to_json(japan_fiscal_gap("G-01")))
        @test !isempty(to_json(japan_fiscal_assumption_concept(:policy_rate)))
    end

    # ---- 照会 API -----------------------------------------------------------
    @testset "照会 API" begin
        @test length(japan_fiscal_model_mappings()) == 55
        @test length(japan_fiscal_model_mappings(; family = :jgb_funding_cost)) == 11
        @test length(japan_fiscal_model_mappings(; model = :sim)) == 5
        @test all(
            m -> m.adoption === :primary,
            japan_fiscal_model_mappings(; adoption = :primary),
        )
        @test length(japan_fiscal_model_mappings(; adoption = :primary)) == 5
        @test japan_fiscal_scenario_families() == collect(JAPAN_FISCAL_SCENARIO_FAMILIES)
        @test_throws ArgumentError japan_fiscal_model_mapping(:unknown_family, :sim)
        @test_throws ArgumentError japan_fiscal_model_mapping(:jgb_funding_cost, :unknown)
        @test_throws ArgumentError japan_fiscal_family_spec(:unknown_family)
        @test_throws ArgumentError japan_fiscal_assumption_concept(:unknown_concept)
    end

    # ---- コンストラクタの契約強制 -------------------------------------------
    @testset "コンストラクタが契約違反を拒否する" begin
        # representability の宣言と導出値の不一致
        @test_throws ArgumentError JapanFiscalModelMapping(;
            family = :fiscal_consolidation,
            model = :ramsey,
            representability = :representable,
            reason = "テスト用の誤った宣言。政府部門を持たないモデルを representable と宣言する。",
        )
        # not_accepted なのに変数名を持つ
        @test_throws ArgumentError JapanFiscalInputMapping(;
            concept = :policy_rate,
            input_kind = :not_accepted,
            variable = :r,
            notes = "テスト",
        )
        # not_accepted なのに理由が無い
        @test_throws ArgumentError JapanFiscalInputMapping(;
            concept = :policy_rate,
            input_kind = :not_accepted,
        )
        # 受け取る行なのに変数名が無い
        @test_throws ArgumentError JapanFiscalInputMapping(;
            concept = :policy_rate,
            input_kind = :exogenous_path,
        )
        # 未知の語彙
        @test_throws ArgumentError JapanFiscalInputMapping(;
            concept = :unknown_concept,
            input_kind = :exogenous_path,
            variable = :x,
        )
        # 日本較正でないのに magnitude を名乗る
        @test_throws ArgumentError JapanFiscalModelMapping(;
            family = :fiscal_consolidation,
            model = :sim,
            representability = :representable,
            adoption = :primary,
            calibration_basis = :structural_illustrative,
            claim_level = :magnitude,
            reason = "テスト用。日本較正でないのに magnitude を名乗るセル。",
            inputs = [
                JapanFiscalInputMapping(;
                    concept = :government_spending,
                    variable = :G,
                    input_kind = :exogenous_path,
                    unit = "level",
                ),
                JapanFiscalInputMapping(;
                    concept = :tax,
                    variable = :θ,
                    input_kind = :exogenous_path,
                    unit = "ratio",
                ),
            ],
            endogenous_outputs = [:output, :government_balance],
        )
        # forbidden_proxies が空の family 仕様
        @test_throws ArgumentError JapanFiscalScenarioFamilySpec(;
            family = :fiscal_consolidation,
            display_name = "テスト",
            economic_meaning = "テスト",
            required_concepts = [:tax],
            decomposition_rule = "テスト",
        )
        # gap_id の形式違反
        @test_throws ArgumentError JapanFiscalGap(;
            gap_id = "GAP1",
            title = "テスト",
            description = "テスト",
            consequence = "テスト",
            resolution = :hold_as_limitation,
        )
    end
end
