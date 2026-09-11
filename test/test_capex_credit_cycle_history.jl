# CCC 履歴再生候補選定層の契約テスト（Issue #247 / P-7）。
# 受け入れ条件は docs/architecture/capex_credit_cycle_empirical_integration.md §12.6
# （項目 50–51）と Issue #247 本文の受け入れ条件。

using DME:
    assess_capex_episodes,
    CapexHistoricalEpisodeSpec,
    CapexEpisodeAssessment,
    CAPEX_CC_HISTORY_VERSION,
    CAPEX_CC_EPISODE_IDS,
    CAPEX_CC_EPISODE_STATUSES,
    CAPEX_CC_NC_IDS,
    CAPEX_CC_SPECIAL_FACTOR_KINDS,
    CAPEX_CC_EXPECTED_DIAGNOSTIC_LABELS,
    CAPEX_CC_EPISODE_REQUIRED_MODEL_VARS,
    CAPEX_CC_NC2_SERIES,
    CAPEX_CC_EPISODE_SPECS,
    capex_episode_spec_to_dict,
    capex_episode_assessment_to_dict,
    save_capex_episode_assessment,
    build_capex_empirical_dataset,
    CapexSeriesSpec,
    CapexRawObservation,
    CapexRawDataset,
    DataSeries,
    Quarterly,
    CalendarQuarter,
    ObservedEvent,
    ScenarioAssumption,
    EventSource,
    EventProvenance,
    EventTiming,
    PersistenceSpec,
    CAPEX_CC_EMPIRICAL_INTEGRATION_VERSION

using Dates: Date

const JSON3 = DME.JSON3

# ---------------------------------------------------------------------------
# fixture: 合成 observation dataset（test_capex_credit_cycle_calibration.jl と同じ規約）
# ---------------------------------------------------------------------------

function _histq_dates(start_label::String, n::Int)
    y0, q0 =
        parse(Int, split(start_label, "-Q")[1]), parse(Int, split(start_label, "-Q")[2])
    base = y0 * 4 + (q0 - 1)
    return [string(idx ÷ 4, "-Q", idx % 4 + 1) for idx in base:(base + n - 1)]
end

function _hist_spec(
    key::Symbol;
    model_vars::Vector{Symbol} = [key],
    methodology::Symbol = :direct,
    role::Symbol = :calibration_required,
    observability::Symbol = :D,
)
    return CapexSeriesSpec(
        key = key,
        model_vars = model_vars,
        provider_series_id = uppercase(string(key)),
        provider = "TEST",
        source_kind = :official_statistic,
        role = role,
        observability = observability,
        methodology = methodology,
        declared_unit = "unit",
        declared_frequency = Quarterly,
        declared_seasonal_adjustment = "SA",
        declared_real_nominal = :real,
        declared_base_year = nothing,
        annualized = false,
        level_form = :level,
        anchor = nothing,
        sector_scope = "test scope",
        scope_bias = :none,
        aggregation = :sum,
        model_timing = :SUM,
        allocation_key = nothing,
        availability_start = "1990-Q1",
        notes = "history fixture entry",
    )
end

function _hist_series(key::Symbol, values::AbstractVector, dates::Vector{String})
    return DataSeries(
        uppercase(string(key)),
        string(key),
        "TEST",
        Quarterly,
        "unit",
        dates,
        Vector{Union{Float64, Missing}}(values),
    )
end

function _hist_obs(spec::CapexSeriesSpec, series::Union{DataSeries, Nothing})
    return CapexRawObservation(
        spec.key,
        spec,
        :ok,
        series,
        series === nothing ? missing : "unit",
        series === nothing ? missing : Quarterly,
        "SA",
        missing,
        String[],
        nothing,
        :fixture,
        "",
    )
end

# key => 定数（全期一定）または key => Vector（missing混在可）。
function _hist_dataset(
    values::AbstractDict;
    n_quarters::Int = 40,
    start::String = "2000-Q1",
    specs_override::AbstractDict = Dict{Symbol, CapexSeriesSpec}(),
)
    dates = _histq_dates(start, n_quarters)
    obs = CapexRawObservation[]
    for (k, v) in values
        spec = get(specs_override, k, _hist_spec(k))
        series =
            v isa AbstractVector ? _hist_series(k, v, dates) :
            _hist_series(k, fill(Float64(v), n_quarters), dates)
        push!(obs, _hist_obs(spec, series))
    end
    raw = CapexRawDataset(
        Dict(o.key => o for o in obs),
        "test-catalog-v1",
        CAPEX_CC_EMPIRICAL_INTEGRATION_VERSION,
        "",
        Dict{String, Any}(),
        Dict{String, Any}(),
    )
    return build_capex_empirical_dataset(raw; min_valid_obs = 8)
end

# NC-1 の17必須model varすべて + NC-6用2キーを一定値で満たすbaseline values。
function _hist_full_values()
    d = Dict{Symbol, Float64}()
    for mv in CAPEX_CC_EPISODE_REQUIRED_MODEL_VARS
        d[mv] = 100.0
    end
    d[:spread] = 5.0
    d[:y_s1_proxy] = 20.0
    d[:equity_val_sector] = 300.0
    return d
end

_hist_specs_override() = Dict{Symbol, CapexSeriesSpec}(
    :y_s1_proxy => _hist_spec(:y_s1_proxy; role = :validation_only, observability = :P),
    :equity_val_sector =>
        _hist_spec(:equity_val_sector; role = :validation_only, observability = :P),
    :wage => _hist_spec(:wage; role = :estimation_input),
    :emp_s1 => _hist_spec(:emp_s1; role = :estimation_input),
    :emp_s2 => _hist_spec(:emp_s2; role = :estimation_input),
    :emp_s3 => _hist_spec(:emp_s3; role = :estimation_input),
    :cons => _hist_spec(:cons; role = :validation_only, observability = :P),
    :hh_income => _hist_spec(:hh_income; role = :validation_only, observability = :P),
)

# NC-2 の4系列に、評価区間内で閾値を超える悪化を注入する。
function _hist_inject_nc2_breach!(values::Dict{Symbol, Float64}, dates::Vector{String}, eval_hit_idx::Int)
    n = length(dates)
    values2 = Dict{Symbol, Any}(values)
    order = fill(100.0, n)
    order[eval_hit_idx] = 88.0  # -12% <= di_sector(-8%)
    values2[:order_s2] = order
    capex = fill(100.0, n)
    capex[eval_hit_idx] = 85.0  # -15% <= di_sector(-8%)
    values2[:capex_exec_s1] = capex
    emp = fill(100.0, n)
    emp[eval_hit_idx] = 99.0  # -1.0% <= dl(-0.5%)
    values2[:emp_tot] = emp
    spread = fill(5.0, n)
    spread[eval_hit_idx] = 6.5  # +150bp >= spread_bp(100bp)
    values2[:spread] = spread
    return values2
end

# ---------------------------------------------------------------------------
# イベント層ヘルパ（4層型の smoke 構築、test_macro_event_types.jl と同じ規約）
# ---------------------------------------------------------------------------

_hist_source() = EventSource(publisher = "fictional wire", document_id = "doc-1")
_hist_prov(layer::Symbol; derived_from::Vector{String} = String[]) =
    EventProvenance(;
        layer = layer,
        rule_id = "test-rule",
        rule_version = "1.0.0",
        generator = "human",
        derived_from = derived_from,
    )

@testset "CCC 履歴再生候補選定層（Issue #247 / P-7）" begin
    @testset "smoke test（CLAUDE.md）" begin
        ds = _hist_dataset(_hist_full_values(); specs_override = _hist_specs_override())
        @test ds isa DME.CapexEmpiricalDataset
        results = assess_capex_episodes(ds; specs = CAPEX_CC_EPISODE_SPECS)
        @test length(results) == length(CAPEX_CC_EPISODE_IDS)
        @test Set(r.id for r in results) == Set(CAPEX_CC_EPISODE_IDS)
        @test all(r.status in CAPEX_CC_EPISODE_STATUSES for r in results)
    end

    @testset "語彙定数" begin
        @test startswith(CAPEX_CC_HISTORY_VERSION, "capex-credit-cycle-history/")
        @test CAPEX_CC_SPECIAL_FACTOR_KINDS == (
            :financial_crisis,
            :supply_shock,
            :policy_regime_shift,
            :statistical_definition_change,
        )
        @test CAPEX_CC_EXPECTED_DIAGNOSTIC_LABELS == (
            :broad_downturn,
            :sectoral_downturn,
            :contained_adjustment,
            :indeterminate,
        )
        @test CAPEX_CC_EPISODE_IDS == (:H1, :H2, :H3, :H4, :H5, :H6)
        @test :other ∉ CAPEX_CC_EPISODE_IDS  # 2026-09 現在局面を後付けしない
        @test length(CAPEX_CC_EPISODE_SPECS) == 6
        @test [ep.id for ep in CAPEX_CC_EPISODE_SPECS] == collect(CAPEX_CC_EPISODE_IDS)
        @test CAPEX_CC_EPISODE_STATUSES == (:selected, :excluded, :insufficient_data)
        @test length(CAPEX_CC_NC_IDS) == 7
        @test length(CAPEX_CC_EPISODE_REQUIRED_MODEL_VARS) == 17
        @test CAPEX_CC_NC2_SERIES == (:order_s2, :capex_exec_s1, :spread, :emp_tot)
    end

    @testset "CapexHistoricalEpisodeSpec のバリデーション" begin
        @test_throws ArgumentError CapexHistoricalEpisodeSpec(
            id = :H7,
            label = "invalid",
            period_zero = CalendarQuarter(2020, 1),
        )
        @test_throws ArgumentError CapexHistoricalEpisodeSpec(
            id = :H1,
            label = "invalid",
            period_zero = CalendarQuarter(2020, 1),
            runup_quarters = 0,
        )
        @test_throws ArgumentError CapexHistoricalEpisodeSpec(
            id = :H1,
            label = "invalid",
            period_zero = CalendarQuarter(2020, 1),
            eval_quarters = -1,
        )
        @test_throws ArgumentError CapexHistoricalEpisodeSpec(
            id = :H1,
            label = "invalid",
            period_zero = CalendarQuarter(2020, 1),
            special_factors = [:not_a_real_factor],
        )
        @test_throws ArgumentError CapexHistoricalEpisodeSpec(
            id = :H1,
            label = "invalid",
            period_zero = CalendarQuarter(2020, 1),
            expected_diagnostic_label = :not_a_real_label,
        )
        ep = CapexHistoricalEpisodeSpec(
            id = :H1,
            label = "valid",
            period_zero = CalendarQuarter(2020, 1),
        )
        @test ep.runup_quarters == 8
        @test ep.eval_quarters == 20
        @test isempty(ep.observed_events)
        @test isempty(ep.assumptions)
        @test ep.data_definition_break_resolved == true
        @test ep.expected_diagnostic_label === :indeterminate
    end

    @testset "observed_events / assumptions のフィールド保持（L1/L3の型分離）" begin
        oe = ObservedEvent(;
            event_id = "T-OE1",
            event_type = :DemandOutlookRevision,
            announced_at = Date(2005, 1, 15),
            observed_at = Date(2005, 1, 15),
            known_at = Date(2005, 1, 16),
            source = _hist_source(),
            provenance = _hist_prov(:observed),
            sector = :s2,
            direction = :down,
        )
        sa = ScenarioAssumption(;
            assumption_id = "T-SA1",
            event_type = :DemandOutlookRevision,
            sector = :s2,
            direction = :down,
            magnitude = -5.0,
            unit = "%",
            magnitude_source = :assumed_default,
            application_mode = :multiplicative,
            timing = EventTiming(; basis = :period, rule = :explicit_period, t_apply = 0),
            persistence = PersistenceSpec(; shape = :step, duration = nothing, params = NamedTuple()),
            target_concepts = [:demand_expectation],
            provenance = _hist_prov(:assumption; derived_from = ["T-OE1"]),
        )
        ep = CapexHistoricalEpisodeSpec(;
            id = :H1,
            label = "field retention",
            period_zero = CalendarQuarter(2020, 1),
            observed_events = [oe],
            assumptions = [sa],
        )
        @test only(ep.observed_events) === oe
        @test only(ep.assumptions) === sa
        @test only(ep.observed_events).magnitude === missing
        @test only(ep.assumptions).magnitude_source === :assumed_default
    end

    dates40 = _histq_dates("2000-Q1", 40)
    # period_zero を dataset の中ほど（2005-Q1、abs index基準でrunup4+eval8=12Qが
    # 2004-Q1..2006-Q4に収まる）に置く小さな窓で機械判定を検証する。
    zero_q = CalendarQuarter(2005, 1)

    function _hist_ep(
        id::Symbol;
        expected_diagnostic_label::Symbol = :broad_downturn,
        special_factors::Vector{Symbol} = Symbol[],
        data_definition_break_resolved::Bool = true,
        runup_quarters::Int = 4,
        eval_quarters::Int = 8,
    )
        return CapexHistoricalEpisodeSpec(;
            id = id,
            label = "test episode $(id)",
            period_zero = zero_q,
            runup_quarters = runup_quarters,
            eval_quarters = eval_quarters,
            special_factors = special_factors,
            data_definition_break_resolved = data_definition_break_resolved,
            expected_diagnostic_label = expected_diagnostic_label,
        )
    end

    @testset "NC-1: 必須系列の可用性" begin
        ds_full = _hist_dataset(_hist_full_values(); specs_override = _hist_specs_override())
        ep = _hist_ep(:H1)
        [a] = assess_capex_episodes(ds_full; specs = [ep])
        @test a.nc_results[:NC1] == true
        @test isempty(a.missing_keys)

        # wage を全期欠損にする（catalog上 estimation_input のまま）。
        v = Dict{Symbol, Any}(_hist_full_values())
        v[:wage] = fill(missing, 40)
        ds_gap = _hist_dataset(v; specs_override = _hist_specs_override())
        [a2] = assess_capex_episodes(ds_gap; specs = [ep])
        @test a2.nc_results[:NC1] == false
        @test :wage in a2.missing_keys
        @test a2.status == :insufficient_data
    end

    @testset "NC-2: 悪化開始時点の識別（G1–G4相当の深さ閾値）" begin
        ds_flat = _hist_dataset(_hist_full_values(); specs_override = _hist_specs_override())
        ep = _hist_ep(:H1)
        [a_flat] = assess_capex_episodes(ds_flat; specs = [ep])
        @test a_flat.nc_results[:NC2] == false  # 変動なしなら不成立

        v = _hist_full_values()
        v2 = _hist_inject_nc2_breach!(v, dates40, 24)  # eval窓(position 21..28)内、2005-Q4相当
        ds_breach = _hist_dataset(v2; specs_override = _hist_specs_override())
        [a_breach] = assess_capex_episodes(ds_breach; specs = [ep])
        @test a_breach.nc_results[:NC2] == true
    end

    @testset "NC-3: 単一の特殊要因だけで説明されない" begin
        ds_full = _hist_dataset(_hist_full_values(); specs_override = _hist_specs_override())
        ep0 = _hist_ep(:H1; special_factors = Symbol[])
        ep1 = _hist_ep(:H2; special_factors = [:financial_crisis])
        ep2 = _hist_ep(:H3; special_factors = [:financial_crisis, :policy_regime_shift])
        results = assess_capex_episodes(ds_full; specs = [ep0, ep1, ep2])
        by_id = Dict(r.id => r for r in results)
        @test by_id[:H1].nc_results[:NC3] == true
        @test by_id[:H2].nc_results[:NC3] == true
        @test by_id[:H3].nc_results[:NC3] == false
        @test by_id[:H3].status == :excluded
    end

    @testset "NC-4: データ定義変更の接続可否" begin
        ds_full = _hist_dataset(_hist_full_values(); specs_override = _hist_specs_override())
        ep_ok = _hist_ep(:H1; data_definition_break_resolved = true)
        ep_bad = _hist_ep(:H2; data_definition_break_resolved = false)
        results = assess_capex_episodes(ds_full; specs = [ep_ok, ep_bad])
        by_id = Dict(r.id => r for r in results)
        @test by_id[:H1].nc_results[:NC4] == true
        @test by_id[:H2].nc_results[:NC4] == false
        @test by_id[:H2].status == :excluded
    end

    @testset "NC-5: 助走・評価ウィンドウのデータ可用性（`Z-30`）" begin
        # dataset は 2000-Q1..2009-Q4（40Q）。評価終端が届かない period_zero を置く。
        ds_full = _hist_dataset(_hist_full_values(); specs_override = _hist_specs_override())
        ep_late = CapexHistoricalEpisodeSpec(;
            id = :H6,
            label = "tail exceeds dataset",
            period_zero = CalendarQuarter(2009, 3),
            runup_quarters = 4,
            eval_quarters = 20,
        )
        [a] = assess_capex_episodes(ds_full; specs = [ep_late])
        @test a.nc_results[:NC5] == false
        @test a.status == :insufficient_data
    end

    @testset "NC-6: ai_exp の代替構成（実証戦略 §8.2 ID-1）" begin
        ds_full = _hist_dataset(_hist_full_values(); specs_override = _hist_specs_override())
        ep = _hist_ep(:H1)
        [a_full] = assess_capex_episodes(ds_full; specs = [ep])
        @test a_full.nc_results[:NC6] == true

        v = _hist_full_values()
        delete!(v, :y_s1_proxy)
        delete!(v, :equity_val_sector)
        ds_no_alt = _hist_dataset(v; specs_override = _hist_specs_override())
        [a_no_alt] = assess_capex_episodes(ds_no_alt; specs = [ep])
        @test a_no_alt.nc_results[:NC6] == false
        @test a_no_alt.status == :insufficient_data
    end

    @testset "NC-7: 集合レベルの識別力条件" begin
        v = _hist_full_values()
        v2 = _hist_inject_nc2_breach!(v, dates40, 24)
        ds_breach = _hist_dataset(v2; specs_override = _hist_specs_override())

        ep_broad = _hist_ep(:H1; expected_diagnostic_label = :broad_downturn)
        ep_contained = _hist_ep(:H2; expected_diagnostic_label = :contained_adjustment)
        results_ok = assess_capex_episodes(ds_breach; specs = [ep_broad, ep_contained])
        @test all(r.nc_results[:NC7] for r in results_ok)
        @test all(r.status == :selected for r in results_ok)

        ep_broad2 = _hist_ep(:H1; expected_diagnostic_label = :broad_downturn)
        ep_broad3 = _hist_ep(:H2; expected_diagnostic_label = :broad_downturn)
        results_fail = assess_capex_episodes(ds_breach; specs = [ep_broad2, ep_broad3])
        @test all(!r.nc_results[:NC7] for r in results_fail)
        @test all(r.status == :excluded for r in results_fail)  # NC1-6は満たすがNC7で落ちる
    end

    @testset "選定・除外の両方に理由が記録される" begin
        ds_full = _hist_dataset(_hist_full_values(); specs_override = _hist_specs_override())
        ep_bad = _hist_ep(:H1; data_definition_break_resolved = false)
        [a] = assess_capex_episodes(ds_full; specs = [ep_bad])
        @test a.status != :selected
        @test !isempty(a.exclusion_reason)
        @test occursin("NC4", a.exclusion_reason)
    end

    @testset "episode_hash: 決定性と identity" begin
        ds = _hist_dataset(_hist_full_values(); specs_override = _hist_specs_override())
        r1 = assess_capex_episodes(ds; specs = CAPEX_CC_EPISODE_SPECS)
        r2 = assess_capex_episodes(ds; specs = CAPEX_CC_EPISODE_SPECS)
        for (a1, a2) in zip(r1, r2)
            @test a1.id == a2.id
            @test a1.episode_hash == a2.episode_hash
            @test startswith(a1.episode_hash, "sha256:")
        end

        ep_a = _hist_ep(:H1)
        ep_b = _hist_ep(:H1; special_factors = [:supply_shock])
        [ra] = assess_capex_episodes(ds; specs = [ep_a])
        [rb] = assess_capex_episodes(ds; specs = [ep_b])
        @test ra.episode_hash != rb.episode_hash

        [ra_again] = assess_capex_episodes(ds; specs = [ep_a])
        @test ra.episode_hash == ra_again.episode_hash
    end

    @testset "L1/L3 の分離（`Z-20`。#247 受け入れ条件・§12.6 項目51）" begin
        # magnitude 無しの L1 を持つ episode（H6-OE2）に対応する L3
        # （H6-SA1）が magnitude_source=:assumed_default であり、L1へ書き戻されていない。
        h6 = only(ep for ep in CAPEX_CC_EPISODE_SPECS if ep.id === :H6)
        oe2 = only(e for e in h6.observed_events if e.event_id == "H6-OE2")
        @test oe2.magnitude === missing

        sa1 = only(a for a in h6.assumptions if a.assumption_id == "H6-SA1")
        @test sa1.magnitude_source === :assumed_default
        @test "H6-OE2" in sa1.provenance.derived_from

        # L1へ数値が書き戻されていないことを再確認する（構築後も不変）。
        oe2_again = only(e for e in h6.observed_events if e.event_id == "H6-OE2")
        @test oe2_again.magnitude === missing

        # 全 episode で observed_events は ObservedEvent、assumptions は ScenarioAssumption
        # のみを保持する（型で強制されるが、内容としても確認する）。
        for ep in CAPEX_CC_EPISODE_SPECS
            @test all(e isa ObservedEvent for e in ep.observed_events)
            @test all(a isa ScenarioAssumption for a in ep.assumptions)
        end
    end

    @testset "改定後データによる履歴再生であることの明示（`Z-21`）" begin
        ds = _hist_dataset(_hist_full_values(); specs_override = _hist_specs_override())
        results = assess_capex_episodes(ds; specs = CAPEX_CC_EPISODE_SPECS)
        for a in results
            @test a.metadata["replay_kind"] == "revised_data_historical_replay"
        end
    end

    @testset "シリアライズ" begin
        h1 = only(ep for ep in CAPEX_CC_EPISODE_SPECS if ep.id === :H1)
        d = capex_episode_spec_to_dict(h1)
        @test d["id"] == "H1"
        @test haskey(d, "observed_events")
        @test haskey(d, "assumptions")

        ds = _hist_dataset(_hist_full_values(); specs_override = _hist_specs_override())
        [a] = assess_capex_episodes(ds; specs = [_hist_ep(:H1)])
        ad = capex_episode_assessment_to_dict(a)
        @test ad["id"] == "H1"
        @test haskey(ad, "nc_results")

        mktempdir() do dir
            path = joinpath(dir, "h1_assessment.json")
            save_capex_episode_assessment(path, a)
            @test isfile(path)
            loaded = JSON3.read(read(path, String))
            @test String(loaded["id"]) == "H1"
        end
    end

    @testset "H1–H6全候補にNC-1–NC-7の判定と採否理由がある（§12.6 項目50）" begin
        ds = _hist_dataset(_hist_full_values(); specs_override = _hist_specs_override())
        results = assess_capex_episodes(ds; specs = CAPEX_CC_EPISODE_SPECS)
        @test length(results) == 6
        for a in results
            @test Set(keys(a.nc_results)) == Set(CAPEX_CC_NC_IDS)
            @test Set(keys(a.nc_details)) == Set(CAPEX_CC_NC_IDS)
            @test all(!isempty(a.nc_details[k]) for k in CAPEX_CC_NC_IDS)
            a.status === :selected || @test !isempty(a.exclusion_reason)
        end
    end

    @testset "2026-09 現在局面が候補に混入していない" begin
        for ep in CAPEX_CC_EPISODE_SPECS
            @test ep.period_zero.year <= 2023
        end
    end
end
