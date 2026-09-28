# 上流モデル由来入力（ModelDerivedInput）・CCC cross-model adapter・cross-model 実行と
# 保存/replay（Issue #282 / `PN-2`）のテスト。
#
#   - CCC の cross-model registry が §7.3 表と一致し、適用先を exogenous_variables(m) の外へ
#     広げない（ext_demand_s2 / ext_demand_s3 のみ）・近い変数へ代理適用しない
#   - ModelDerivedInput の構築時不変条件（接頭辞・有限性・符号・配置基準・claim scope）
#   - PNE 由来パスが CCC の外生パスへ既存の固定順合成で適用される（event 入力との同時適用）
#   - fail closed（未対応 concept・model・配置基準の不一致・助走区間・ID 重複）。
#     on_unmapped = :warn でも cross-model の拒否は緩めない
#   - provenance chain・metadata 予約キー 10 個・要約・保存/replay（PNE bytes 不要・再導出検証）
#   - 入力が空のとき run_scenario と外生パス・系列が一致する（既存挙動を壊さない）
#
# 設計: docs/architecture/pne_sector_output_integration.md §7.3–§7.4・§9.5・§10・§12

using Test
using DME
using Dates
const JSON3 = DME.JSON3

@isdefined(synthetic_quarterly_dict) ||
    include(joinpath(@__DIR__, "fixtures", "pne", "pne_fixture_builders.jl"))

const XMR_MAPPINGS = joinpath(@__DIR__, "fixtures", "pne", "mappings")

_xmr_mapping_dict() = cross_model_mapping_to_dict(
    load_cross_model_mapping(joinpath(XMR_MAPPINGS, "ccc_hypothetical_quarterly.json")),
)

"s2 group（既存 fixture）に raw_material を member とする s3 group を足した 2 group の mapping。"
function _xmr_two_group_mapping()
    md = _xmr_mapping_dict()
    s3 = deepcopy(md["groups"][1])
    s3["target_group"] = "ext_demand_s3_customers"
    s3["members"] = Any[Dict{String, Any}("sector_id" => "raw_material", "weight" => 0.1)]
    s3["producer_set"] = Any[]
    s3["producer_set_absent_reason"] = "fictional S3 products are not part of the synthetic network"
    push!(md["groups"], s3)
    md["declared_unmapped_source_sectors"] = Any[]
    return cross_model_mapping_from_dict(md)
end

function _xmr_inputs(;
    mapping = load_cross_model_mapping(joinpath(XMR_MAPPINGS, "ccc_hypothetical_quarterly.json")),
    artifact_dict = synthetic_quarterly_dict(),
    timing_basis::Symbol = :calendar,
    t_start = nothing,
)
    a = pne_sector_output_path_from_dict(artifact_dict)
    r = check_cross_model_compatibility(a, mapping)
    xs = build_model_derived_inputs(a, mapping, r; timing_basis = timing_basis, t_start = t_start)
    return (a = a, mapping = mapping, report = r, xs = xs)
end

"`ModelDerivedInput` を keyword で差し替えて作り直す（構築時検査のテスト用）。"
function _xmr_with(x::ModelDerivedInput; kwargs...)
    base = Dict{Symbol, Any}(
        :input_id => x.input_id,
        :upstream => x.upstream,
        :mapping_id => x.mapping_id,
        :mapping_version => x.mapping_version,
        :mapping_hash => x.mapping_hash,
        :compatibility_report_hash => x.compatibility_report_hash,
        :target_model => x.target_model,
        :target_concept => x.target_concept,
        :target_group => x.target_group,
        :value_semantics => x.value_semantics,
        :values => x.values,
        :timing_basis => x.timing_basis,
        :anchor_quarter => x.anchor_quarter,
        :t_start => x.t_start,
        :transmission_mode => x.transmission_mode,
        :claim_scope => x.claim_scope,
        :coverage => x.coverage,
    )
    for (k, v) in kwargs
        base[k] = v
    end
    return ModelDerivedInput(; base...)
end

_xmr_calendar_scenario(; kwargs...) = Scenario(;
    id = :xm_test,
    model = :capex_credit_cycle,
    period_zero = CalendarQuarter(2025, 1),
    kwargs...,
)

_xmr_provenance() = EventProvenance(;
    layer = :assumption,
    rule_id = "test-cross-model-runner",
    rule_version = "1.0.0",
    generator = "test_cross_model_runner.jl",
    derived_from = ["fictional-source-xm"],
)

function _xmr_event(;
    id,
    event_type,
    sector,
    magnitude,
    unit,
    application_mode,
    target_concepts,
    effective_from = Date(2025, 4, 15),
)
    return scenario_assumption(;
        assumption_id = id,
        event_type = event_type,
        sector = sector,
        direction = magnitude >= 0 ? :up : :down,
        magnitude = magnitude,
        unit = unit,
        magnitude_source = :assumed_default,
        application_mode = application_mode,
        timing = EventTiming(; basis = :calendar, rule = :same_quarter, effective_from = effective_from),
        persistence = PersistenceSpec(; shape = :step, duration = nothing),
        target_concepts = target_concepts,
        provenance = _xmr_provenance(),
    )
end

_xmr_codes(v) = [x.code for x in v]

@testset "上流モデル由来入力・CCC cross-model adapter・実行と replay（Issue #282）" begin
    m = capex_credit_cycle_model(capex_credit_cycle_default_targets())

    # ---- registry（設計 §7.3） ------------------------------------------------
    @testset "CCC cross-model registry は §7.3 表と一致し、適用先を 7 変数の外へ広げない" begin
        @test CCC_CROSS_MODEL_MAPPING_VERSION == "ccc-cross-model-mapping/1.0.0"
        accepted = [r.target_variable for r in CCC_CROSS_MODEL_MAPPING_RULES if r.target_variable !== nothing]
        @test Set(accepted) == Set([:ext_demand_s2, :ext_demand_s3])
        @test all(v -> v in exogenous_variables(m), accepted)
        @test collect(keys(CCC_CROSS_MODEL_EXOGENOUS_COVERAGE)) == exogenous_variables(m)
        @test Set(k for (k, v) in pairs(CCC_CROSS_MODEL_EXOGENOUS_COVERAGE) if v === :accepted) ==
              Set(accepted)
        for r in CCC_CROSS_MODEL_MAPPING_RULES
            if r.target_variable === nothing
                @test r.unsupported_reason !== nothing
                @test !isempty(r.forbidden_proxies)
            else
                @test r.application_mode === :multiplicative
                @test r.unit == "%"
                @test r.value_semantics === :target_relative_change
                @test r.sign_convention === :non_positive
                @test r.baseline_reference === :ccc_steady_state_exog
                @test r.frequency === :quarter
            end
        end
        supply = only(filter(r -> r.target_concept === :sector_supply_capacity, CCC_CROSS_MODEL_MAPPING_RULES))
        @test supply.target_variable === nothing
        @test Set(supply.forbidden_proxies) ⊇ Set([:ext_demand_s2, :ext_demand_s3, :capex_plan_shock_ex])
        @test_throws ArgumentError CrossModelMappingRule(;
            rule_id = "bad",
            target_concept = :derived_out_of_model_demand,
            value_semantics = :target_relative_change,
            contract_row = "test",
            target_variable = :y_s2,
        )
        @test_throws ArgumentError CrossModelMappingRule(;
            rule_id = "bad",
            target_concept = :sector_supply_capacity,
            value_semantics = :group_realized_output_ratio,
            contract_row = "test",
        )
        @test length(CROSS_MODEL_METADATA_KEYS) == 10
    end

    # ---- ModelDerivedInput（X4） -------------------------------------------
    @testset "X4: accepted report から ModelDerivedInput を構築する" begin
        f = _xmr_inputs()
        @test length(f.xs) == 1
        x = only(f.xs)
        @test !(x isa AbstractMacroEvent)
        @test x.input_id == "xm-dme-test-ccc-hypothetical-quarterly:ext_demand_s2_customers"
        @test x.input_origin === MODEL_DERIVED_INPUT_ORIGIN
        @test x.target_model === :capex_credit_cycle
        @test x.target_group === :ext_demand_s2_customers
        @test x.value_semantics === :target_relative_change
        @test x.timing_basis === :calendar
        @test x.anchor_quarter == CalendarQuarter(2025, 1)
        @test x.t_start === nothing
        @test x.claim_scope === :hypothetical_fictional
        @test x.upstream.content_hash == f.a.content_hash
        @test x.mapping_hash == cross_model_mapping_hash(f.mapping)
        @test x.compatibility_report_hash == cross_model_compatibility_report_hash(f.report)
        @test x.values == only(apply_cross_model_mapping(f.a, f.mapping, f.report)).values
        @test x.coverage["members"] == ["auto_assembly", "phone_assembly"]
        @test x.coverage["producer_set"] == ["chip_fab"]
        @test x.coverage["unmapped_source_sectors"] == ["raw_material"]
        @test x.coverage["covered_share"] == 0.4
        @test x.coverage["uncovered_share_treatment"] == "not_covered_by_upstream_input"

        xp = only(_xmr_inputs(; timing_basis = :period, t_start = 3).xs)
        @test xp.timing_basis === :period && xp.t_start == 3

        # rejected な report からは構築できない
        jp = pne_sector_output_path_from_dict(jp_like_dict())
        m_jp = load_cross_model_mapping(joinpath(XMR_MAPPINGS, "ccc_same_economy_jp_like.json"))
        r_jp = check_cross_model_compatibility(jp, m_jp)
        err = try
            build_model_derived_inputs(jp, m_jp, r_jp; timing_basis = :calendar)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError && startswith(err.msg, "cross_model_mapping_rejected")

        # anchor の無い artifact を暦日基準で構築しようとすると拒否
        d = synthetic_quarterly_dict()
        d["time"]["calendar_anchor"] = nothing
        err = try
            _xmr_inputs(; artifact_dict = d)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError && startswith(err.msg, "calendar_anchor_required")
        @test only(_xmr_inputs(; artifact_dict = d, timing_basis = :period, t_start = 0).xs).anchor_quarter ===
              nothing
    end

    @testset "X4: ModelDerivedInput の構築時不変条件" begin
        x = only(_xmr_inputs().xs)
        bad = [
            (input_id = "pne-no-prefix",),
            (input_id = "xm-",),
            (values = Float64[],),
            (values = [0.0, NaN],),
            (values = [0.0, Inf],),
            (values = [0.0, 0.1],),
            (values = [-1.5],),
            (value_semantics = :group_realized_output_ratio,),
            (target_concept = :not_a_concept,),
            (timing_basis = :calendar, anchor_quarter = nothing),
            (timing_basis = :calendar, t_start = 1),
            (timing_basis = :period, t_start = nothing),
            (timing_basis = :as_of,),
            (transmission_mode = :explicit_cross_economy,),
            (claim_scope = :same_economy_model_derived,),
            (mapping_hash = "md5:abc",),
        ]
        for kw in bad
            @test_throws ArgumentError _xmr_with(x; pairs(kw)...)
        end
        @test _xmr_with(x; timing_basis = :period, t_start = 0) isa ModelDerivedInput
        @test _xmr_with(x; transmission_mode = :same_economy, claim_scope = :same_economy_model_derived) isa
              ModelDerivedInput
    end

    @testset "X4: シリアライズ・set hash" begin
        f = _xmr_inputs(; mapping = _xmr_two_group_mapping())
        @test length(f.xs) == 2
        for x in f.xs
            y = model_derived_input_from_dict(model_derived_input_to_dict(x))
            @test model_derived_input_to_dict(y) == model_derived_input_to_dict(x)
            @test y.values == x.values
            j = DME._scenario_json_to_plain(JSON3.read(canonical_json_string(model_derived_input_to_dict(x))))
            @test cross_model_input_set_hash([model_derived_input_from_dict(j)]) == cross_model_input_set_hash([x])
        end
        h = cross_model_input_set_hash(f.xs)
        @test cross_model_input_set_hash(reverse(f.xs)) == h
        x1 = f.xs[1]
        noted = ModelDerivedInput(;
            input_id = x1.input_id,
            upstream = x1.upstream,
            mapping_id = x1.mapping_id,
            mapping_version = x1.mapping_version,
            mapping_hash = x1.mapping_hash,
            compatibility_report_hash = x1.compatibility_report_hash,
            target_model = x1.target_model,
            target_concept = x1.target_concept,
            target_group = x1.target_group,
            value_semantics = x1.value_semantics,
            values = x1.values,
            timing_basis = x1.timing_basis,
            anchor_quarter = x1.anchor_quarter,
            transmission_mode = x1.transmission_mode,
            claim_scope = x1.claim_scope,
            coverage = x1.coverage,
            notes = "changed notes",
        )
        @test cross_model_input_set_hash([noted, f.xs[2]]) == h
        shifted = _xmr_with(x1; values = [v * 0.5 for v in x1.values])
        @test cross_model_input_set_hash([shifted, f.xs[2]]) != h
        @test_throws ArgumentError model_derived_input_from_dict(
            merge(model_derived_input_to_dict(x1), Dict{String, Any}("extra" => 1)),
        )
    end

    # ---- X5 / X6: 適用 --------------------------------------------------------
    @testset "X5/X6: 派生需要パスが ext_demand_s2 へ適用される（暦日基準）" begin
        f = _xmr_inputs()
        x = only(f.xs)
        run = run_cross_model_scenario(m, _xmr_calendar_scenario(), f.xs)
        @test run.status === :completed
        @test run.result isa SimulationResult
        @test isempty(run.cross_model_rejections)
        base = run_scenario(m, _xmr_calendar_scenario())
        periods = collect(-8:19)
        for (i, t) in enumerate(periods)
            b = base.exog[:ext_demand_s2][i]
            expected = (0 <= t < length(x.values)) ? b * (1 + (100.0 * x.values[t + 1]) / 100) : b
            @test run.exog[:ext_demand_s2][i] == expected
        end
        # 他の外生変数は変えない（適用先を広げない）
        for v in exogenous_variables(m)
            v === :ext_demand_s2 && continue
            @test run.exog[v] == base.exog[v]
        end
        # 上流由来の L4 は ext_demand_s2 / ext_demand_s3 以外を対象にしない
        ups = filter(i -> i.input_id in run.upstream_applied_input_ids, run.applied_inputs)
        @test length(ups) == 1
        u = only(ups)
        @test u.input_id == x.input_id * "/ext_demand_s2"
        @test u.assumption_id == x.input_id
        @test u.application_mode === :multiplicative && u.unit == "%"
        @test u.t_apply == 0
        @test u.provenance.layer === :applied
        @test u.provenance.derived_from == [x.input_id]
        @test u.mapping_version == CCC_CROSS_MODEL_MAPPING_VERSION
        @test u.persistence.shape === :path
        @test u.magnitude == maximum(abs, 100.0 .* x.values)
        @test all(w -> w in MACRO_EVENT_WARNING_CODES, u.warnings)

        md = run.result.metadata
        for k in CROSS_MODEL_METADATA_KEYS
            @test haskey(md, k)
        end
        for k in ("event_set_hash", "scenario_content_hash", "event_log", "event_execution_status", "params_hash")
            @test haskey(md, k)
        end
        @test md["cross_model_claim_scope"] == "hypothetical_fictional"
        @test md["cross_model_input_set_hash"] == cross_model_input_set_hash(f.xs)
        @test md["cross_model_compatibility_report_hashes"] == [x.compatibility_report_hash]
        @test only(md["cross_model_upstream_artifacts"])["content_hash"] == f.a.content_hash
        @test only(md["cross_model_mapping_refs"])["mapping_hash"] == x.mapping_hash
        entry = only(md["cross_model_inputs"])
        @test entry["target_variable"] == "ext_demand_s2"
        @test entry["t0"] == 0
        @test entry["placed_periods"] == collect(0:5)
        @test entry["applied_periods"] == [1, 2, 3]
        @test entry["timing_basis"] == "calendar"
        @test entry["anchor_quarter"] == "2025Q1"
        @test entry["period_zero"] == "2025Q1"
        @test entry["path_min_percent"] ≈ -11.0 atol = 1e-12
    end

    @testset "X5/X6: モデル期基準の配置・anchor の不使用警告・horizon 超過の切り捨て" begin
        f = _xmr_inputs(; timing_basis = :period, t_start = 2)
        sc = Scenario(; id = :xm_period, model = :capex_credit_cycle)
        run = run_cross_model_scenario(m, sc, f.xs)
        @test run.status === :completed
        @test :upstream_calendar_anchor_unused in _xmr_codes(run.cross_model_warnings)
        @test only(run.input_log)["t0"] == 2
        @test only(run.input_log)["applied_periods"] == [3, 4, 5]

        f2 = _xmr_inputs()
        sc2 = _xmr_calendar_scenario(; horizon_eval = 4)
        run2 = run_cross_model_scenario(m, sc2, f2.xs)
        @test run2.status === :completed
        @test :upstream_path_truncated in _xmr_codes(run2.cross_model_warnings)
        @test only(run2.input_log)["truncated_quarters"] == 2
        @test only(run2.input_log)["placed_periods"] == collect(0:3)
    end

    @testset "fail closed: 配置基準の不一致・助走区間" begin
        cal = _xmr_inputs().xs
        run = run_cross_model_scenario(m, Scenario(; id = :xm_p, model = :capex_credit_cycle), cal)
        @test run.status === :rejected_validation
        @test _xmr_codes(run.cross_model_rejections) == [:timing_basis_conflict]
        @test run.result === nothing && run.exog === nothing

        per = _xmr_inputs(; timing_basis = :period, t_start = 0).xs
        run = run_cross_model_scenario(m, _xmr_calendar_scenario(), per)
        @test _xmr_codes(run.cross_model_rejections) == [:timing_basis_conflict]

        # period_zero が anchor より後 → PNE 期 0 が助走区間（t0 = -2）に置かれる
        sc = Scenario(; id = :xm_late, model = :capex_credit_cycle, period_zero = CalendarQuarter(2025, 3))
        run = run_cross_model_scenario(m, sc, cal)
        @test run.status === :rejected_validation
        @test _xmr_codes(run.cross_model_rejections) == [:upstream_path_in_runup]

        per_neg = [_xmr_with(only(per); t_start = -1)]
        run = run_cross_model_scenario(m, Scenario(; id = :xm_p2, model = :capex_credit_cycle), per_neg)
        @test _xmr_codes(run.cross_model_rejections) == [:upstream_path_in_runup]
    end

    @testset "fail closed: CCC が表現しない概念・group・モデル（近い変数へ寄せない）" begin
        x = only(_xmr_inputs().xs)
        supply = _xmr_with(
            x;
            target_concept = :sector_supply_capacity,
            target_group = :s2_supply,
            value_semantics = :group_realized_output_ratio,
            values = [1.0, 0.6, 0.7, 1.0],
        )
        for opts in (ScenarioRunOptions(), ScenarioRunOptions(; on_unmapped = :warn))
            run = run_cross_model_scenario(m, _xmr_calendar_scenario(), [supply]; options = opts)
            @test run.status === :rejected_mapping
            @test _xmr_codes(run.cross_model_rejections) == [:unmapped_target_concept]
            @test occursin("構造上表現しません", only(run.cross_model_rejections).detail)
            @test occursin("PG-01", only(run.cross_model_rejections).detail)
            @test run.result === nothing && run.exog === nothing
            @test isempty(run.upstream_applied_input_ids)
        end
        other_group = _xmr_with(x; target_group = :price_s1_customers)
        run = run_cross_model_scenario(m, _xmr_calendar_scenario(), [other_group])
        @test _xmr_codes(run.cross_model_rejections) == [:unmapped_target_concept]

        # 既定メソッド: registry を持たないモデルは unsupported_target_model
        rbc = RBCModel(0.3, 0.99, 1, 0.025, 1, 0.9)
        res, ws = map_model_derived_input(rbc, x)
        @test res isa CrossModelRejection && res.code === :unsupported_target_model
        @test isempty(ws)
        # 実行前検証: target_model が実行対象と異なる
        run = run_cross_model_scenario(m, _xmr_calendar_scenario(), [_xmr_with(x; target_model = :rbc)])
        @test run.status === :rejected_validation
        @test _xmr_codes(run.cross_model_rejections) == [:unsupported_target_model]
    end

    @testset "fail closed: input_id の重複・assumption_id との衝突" begin
        x = only(_xmr_inputs().xs)
        run = run_cross_model_scenario(m, _xmr_calendar_scenario(), [x, x])
        @test run.status === :rejected_validation
        @test _xmr_codes(run.cross_model_rejections) == [:duplicate_input_id]

        clash = _xmr_event(;
            id = x.input_id,
            event_type = :DemandOutlookRevision,
            sector = :s2,
            magnitude = -5.0,
            unit = "%",
            application_mode = :multiplicative,
            target_concepts = [:demand_expectation],
        )
        run = run_cross_model_scenario(m, _xmr_calendar_scenario(; assumptions = [clash]), [x])
        @test _xmr_codes(run.cross_model_rejections) == [:duplicate_input_id]
    end

    @testset "複数の PNE パス + 既存 event の同時適用（固定順合成）" begin
        f = _xmr_inputs(; mapping = _xmr_two_group_mapping())
        @test [x.target_group for x in f.xs] == [:ext_demand_s2_customers, :ext_demand_s3_customers]
        demand = _xmr_event(;
            id = "event-demand-s2",
            event_type = :DemandOutlookRevision,
            sector = :s2,
            magnitude = -5.0,
            unit = "%",
            application_mode = :multiplicative,
            target_concepts = [:demand_expectation],
        )
        cancel = _xmr_event(;
            id = "event-cancel-s2",
            event_type = :OrderCancellation,
            sector = :s2,
            magnitude = -3.0,
            unit = "bn USD (2017 chained)",
            application_mode = :additive,
            target_concepts = [:order_flow],
        )
        sc = _xmr_calendar_scenario(; assumptions = [demand, cancel])
        run = run_cross_model_scenario(m, sc, f.xs)
        @test run.status === :completed
        @test :upstream_event_same_target in _xmr_codes(run.cross_model_warnings)
        @test length(run.upstream_applied_input_ids) == 2
        base = run_scenario(m, _xmr_calendar_scenario())
        x2 = f.xs[1]
        x3 = f.xs[2]
        periods = collect(-8:19)
        for (i, t) in enumerate(periods)
            # ext_demand_s2: multiplicative は order_key 昇順（上流 t_apply=0 → event t_apply=1）、
            # その後 additive
            b = base.exog[:ext_demand_s2][i]
            a_up = (0 <= t < length(x2.values)) ? 100.0 * x2.values[t + 1] : 0.0
            a_ev = t >= 1 ? -5.0 : 0.0
            expected = b
            a_up != 0.0 && (expected *= 1 + a_up / 100)
            a_ev != 0.0 && (expected *= 1 + a_ev / 100)
            t >= 1 && (expected += -3.0)
            @test run.exog[:ext_demand_s2][i] == expected
            # ext_demand_s3: 上流入力のみ
            b3 = base.exog[:ext_demand_s3][i]
            a3 = (0 <= t < length(x3.values)) ? 100.0 * x3.values[t + 1] : 0.0
            @test run.exog[:ext_demand_s3][i] == (a3 == 0.0 ? b3 : b3 * (1 + a3 / 100))
        end
        # event 由来と上流由来の拒否・警告は別の配列
        @test all(w -> w isa ScenarioWarning, run.event_warnings)
        @test all(w -> w isa CrossModelWarning, run.cross_model_warnings)
        @test run.result.metadata["cross_model_transmission_modes"] ==
              Dict{String, Any}(x.input_id => "hypothetical_override" for x in f.xs)
    end

    @testset "入力が空のとき run_scenario と外生パス・系列が一致する" begin
        demand = _xmr_event(;
            id = "event-demand-s1",
            event_type = :DemandOutlookRevision,
            sector = :s1,
            magnitude = 5.0,
            unit = "%",
            application_mode = :multiplicative,
            target_concepts = [:demand_expectation],
        )
        sc = _xmr_calendar_scenario(; assumptions = [demand])
        r1 = run_scenario(m, sc)
        r2 = run_cross_model_scenario(m, sc, ModelDerivedInput[])
        @test r1.status === r2.status === :completed
        @test r1.exog == r2.exog
        @test r1.result.variables == r2.result.variables
        @test r2.result.metadata["cross_model_claim_scope"] === nothing
        for (k, v) in r1.result.metadata
            k in ("event_log",) && continue
            @test r2.result.metadata[k] == v
        end
    end

    # ---- 要約・保存・replay（X7） ----------------------------------------------
    @testset "要約: PNE shock がどの入力へ変換されたか" begin
        f = _xmr_inputs()
        run = run_cross_model_scenario(m, _xmr_calendar_scenario(), f.xs)
        s = cross_model_input_summary(run)
        @test s["status"] == "completed"
        @test s["claim_scope"] == "hypothetical_fictional"
        e = only(s["inputs"])
        @test e["coverage"]["members"] == ["auto_assembly", "phone_assembly"]
        @test e["coverage"]["unmapped_source_sectors"] == ["raw_material"]
        @test e["coverage"]["covered_share"] == 0.4
        chain = only(s["provenance_chain"])
        @test chain["applied_input_ids"] == [only(f.xs).input_id * "/ext_demand_s2"]
        @test chain["upstream_content_hash"] == f.a.content_hash
        @test chain["dynamic_artifact_hash"] == f.a.source.dynamic_artifact_hash
        @test chain["scenario_hash"] == f.a.source.scenario_hash
        @test chain["source_input_hash"] == f.a.source.source_input_hash
        @test chain["mapping_hash"] == cross_model_mapping_hash(f.mapping)
        @test isempty(s["cross_model_rejections"])
    end

    @testset "保存・replay: PNE bytes 不要・再導出検証・改ざん検出" begin
        f = _xmr_inputs()
        run = run_cross_model_scenario(m, _xmr_calendar_scenario(), f.xs)
        dir = mktempdir()
        paths = save_cross_model_scenario_artifact(dir, run; mappings = [f.mapping], reports = [f.report])
        @test Set(basename.(paths)) == Set([
            "cross_model_scenario.json",
            "mappings.json",
            "compatibility_reports.json",
            "event_log.json",
            "cross_model_input_log.json",
            "manifest.json",
            "result_summary.json",
            "report.md",
        ])
        # 既存の scenario.json は書かない（既存 replay_scenario が上流入力を欠いて再実行しない）
        @test !isfile(joinpath(dir, "scenario.json"))
        @test_throws ArgumentError load_scenario(joinpath(dir, "cross_model_scenario.json"))
        report = read(joinpath(dir, "report.md"), String)
        @test occursin("観測・実績・予測ではない", report)
        @test occursin("hypothetical_fictional", report)
        manifest = JSON3.read(read(joinpath(dir, "manifest.json"), String))
        @test manifest["run_kind"] == "cross_model"

        sc2, xs2 = load_cross_model_scenario(joinpath(dir, "cross_model_scenario.json"))
        @test sc2.id === :xm_test
        @test cross_model_input_set_hash(xs2) == cross_model_input_set_hash(f.xs)

        replayed = replay_cross_model_scenario(m, dir)
        @test replayed.exog == run.exog
        @test replayed.result.variables == run.result.variables
        @test replayed.result.metadata["cross_model_input_set_hash"] ==
              run.result.metadata["cross_model_input_set_hash"]

        artifact_path = joinpath(mktempdir(), "pne.json")
        write(artifact_path, JSON3.write(synthetic_quarterly_dict()))
        rederived = replay_cross_model_scenario(
            m,
            dir;
            upstream_artifacts = Dict(f.a.content_hash => artifact_path),
        )
        @test rederived.exog == run.exog

        # 別の値の PNE artifact を渡すと content_hash で検出する
        d2 = synthetic_quarterly_dict()
        only(filter(s -> s["sector_id"] == "phone_assembly", d2["sectors"]))["periods"] =
            _pne_points([1.0, 0.5, 0.8, 1.0, 1.0, 1.0])
        wrong_path = joinpath(mktempdir(), "pne_wrong.json")
        write(wrong_path, JSON3.write(d2))
        err = try
            replay_cross_model_scenario(m, dir; upstream_artifacts = Dict(f.a.content_hash => wrong_path))
            nothing
        catch e
            e
        end
        @test err isa ArgumentError && startswith(err.msg, "provenance_chain_broken")

        # 改ざん: 入力の値 → set hash 不一致
        function tampered_copy(mutate!)
            d = mktempdir()
            for p in readdir(dir)
                cp(joinpath(dir, p), joinpath(d, p))
            end
            mutate!(d)
            return d
        end
        rewrite(path, f!) = begin
            doc = DME._scenario_json_to_plain(JSON3.read(read(path, String)))
            f!(doc)
            write(path, canonical_json_string(doc))
        end
        d_vals = tampered_copy(
            d -> rewrite(
                joinpath(d, "cross_model_scenario.json"),
                doc -> (doc["model_derived_inputs"][1]["values"][2] = -0.5),
            ),
        )
        err = try
            replay_cross_model_scenario(m, d_vals)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError && startswith(err.msg, "provenance_chain_broken")

        # 改ざん: mapping の weight → mapping hash 不一致
        d_map = tampered_copy(
            d -> rewrite(
                joinpath(d, "mappings.json"),
                doc -> (doc["mappings"][1]["groups"][1]["members"][1]["weight"] = 0.2),
            ),
        )
        err = try
            replay_cross_model_scenario(m, d_map)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError && startswith(err.msg, "provenance_chain_broken")

        # 改ざん: report の decision
        d_rep = tampered_copy(
            d -> rewrite(
                joinpath(d, "compatibility_reports.json"),
                doc -> (doc["reports"][1]["geography"]["claim_scope"] = "same_economy_model_derived"),
            ),
        )
        err = try
            replay_cross_model_scenario(m, d_rep)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError && startswith(err.msg, "provenance_chain_broken")

        # manifest の params_hash 不一致
        d_man = tampered_copy(
            d -> rewrite(joinpath(d, "manifest.json"), doc -> (doc["params_hash"] = "sha256:" * repeat("0", 64))),
        )
        err = try
            replay_cross_model_scenario(m, d_man)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError && startswith(err.msg, "params_identity_mismatch")

        # 参照する mapping / report を渡さずに保存できない
        @test_throws ArgumentError save_cross_model_scenario_artifact(
            mktempdir(),
            run;
            mappings = CrossModelMapping[],
            reports = [f.report],
        )
    end

    @testset "拒否された実行も保存でき、result を持たない" begin
        f = _xmr_inputs()
        run = run_cross_model_scenario(m, Scenario(; id = :xm_p, model = :capex_credit_cycle), f.xs)
        @test run.status === :rejected_validation
        dir = mktempdir()
        save_cross_model_scenario_artifact(dir, run; mappings = [f.mapping], reports = [f.report])
        summary = JSON3.read(read(joinpath(dir, "result_summary.json"), String))
        @test summary["status"] == "rejected_validation"
        @test summary["variables"] === nothing
        @test occursin("timing_basis_conflict", read(joinpath(dir, "report.md"), String))
    end
end
