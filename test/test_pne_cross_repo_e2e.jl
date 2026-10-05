# PNE → DME の cross-repository contract fixture・provenance・replay E2E（Issue #283 / `PN-3`）。
#
#   - PNE の実 producer 経路（CLI）で生成した synthetic fixture（fixtures/pne/producer/）が、commit
#     された DME 所有の入力から導出されたものであること（手編集の fixture を正本にしない）
#   - compatible な架空 fixture + 明示 mapping で X1（受理）→ X7（保存・replay）を完走する
#     （hypothetical_override。fixture の geography を CCC の経済圏へ偽装しない）
#   - official Japan IO 由来 bridge artifact の identity（fixtures/pne/official_jp/）を US CCC へ
#     入れる 3 mode が、それぞれ別のコードで拒否される（negative golden、設計 §6.5）
#   - contract drift の検出（vendor schema の contract surface golden・語彙・schema 駆動の
#     mutation probe・canonical fixture hash・mapping hash）
#   - 保存済み成果物だけから DME 結果 → AppliedModelInput → mapping → PNE bridge → PNE dynamic
#     artifact / scenario まで provenance を辿る
#   - 保存済み入力からの replay（別ディレクトリ・PNE bytes なし・絶対パス非依存・再保存のバイト一致）
#   - failure fixture（schema version・geography・classification・period semantics・unmapped
#     sector・ratio・hash chain・target variable）の fail closed
#   - PNE / Python への runtime 依存が無いこと
#
# 本テストは PNE・EDP・Python・ネットワークを必要としない。fixture の再生成と PNE 側との drift 検査は
# fixtures/pne/regenerate_cross_repo.jl（手動実行）が行う。
#
# 設計: docs/architecture/pne_sector_output_integration.md §6.5・§12・§15・§16.3・§21

using Test
using DME
using Dates
const json_read = DME.json_read
const json_write = DME.json_write
const json_pretty = DME.json_pretty

@isdefined(synthetic_quarterly_dict) ||
    include(joinpath(@__DIR__, "fixtures", "pne", "pne_fixture_builders.jl"))
@isdefined(pne_contract_surface) ||
    include(joinpath(@__DIR__, "fixtures", "pne", "pne_contract_surface.jl"))

const XREPO_ROOT = joinpath(@__DIR__, "fixtures", "pne")
const XREPO_DME_ROOT = normpath(joinpath(@__DIR__, ".."))
const XREPO_CASES = (
    (id = "quarterly_supplier_disruption", mapping = "ccc_producer_hypothetical_quarterly.json"),
    (id = "monthly_supplier_disruption", mapping = "ccc_producer_hypothetical_monthly.json"),
)
const XREPO_OFFICIAL_MODES = (
    ("same_economy", :geography_mismatch),
    ("explicit_cross_economy", :cross_economy_transmission_unavailable),
    ("hypothetical_override", :hypothetical_override_requires_synthetic_source),
)

_xrepo_json(path) = DME._scenario_json_to_plain(json_read(read(path, String)))
_xrepo_golden(name) = read(joinpath(XREPO_ROOT, "golden", name), String)
_xrepo_mapping(name) = load_cross_model_mapping(joinpath(XREPO_ROOT, "mappings", name))
_xrepo_codes(v) = [x.code for x in v]
_xrepo_sha(path) = "sha256:" * bytes2hex(DME.SHA.sha256(read(path)))

function _xrepo_error(f)
    try
        f()
    catch e
        e isa ArgumentError || rethrow()
        return e.msg
    end
    return nothing
end

_xrepo_scenario(; kwargs...) =
    Scenario(; id = :xrepo_e2e, model = :capex_credit_cycle, period_zero = CalendarQuarter(2025, 1), kwargs...)

"producer fixture を X1–X4 まで通す（ファイルから読む）。"
function _xrepo_pipeline(case)
    a = load_pne_sector_output_path(pne_producer_path(case.id))
    mp = _xrepo_mapping(case.mapping)
    r = check_cross_model_compatibility(a, mp)
    xs = build_model_derived_inputs(a, mp, r; timing_basis = :calendar)
    return (a = a, mapping = mp, report = r, xs = xs)
end

"artifact・mapping を 1 事実だけ変えて互換性判定する。"
function _xrepo_check(; artifact! = identity, mapping! = identity, case = XREPO_CASES[1])
    d = pne_producer_dict(case.id)
    artifact!(d)
    md = cross_model_mapping_to_dict(_xrepo_mapping(case.mapping))
    mapping!(md)
    a = pne_sector_output_path_from_dict(d)
    mp = cross_model_mapping_from_dict(md)
    return a, mp, check_cross_model_compatibility(a, mp)
end

"保存ディレクトリを複製し、1 ファイルの JSON を書き換える。"
function _xrepo_tampered(dir, file, f!)
    d = mktempdir()
    for p in readdir(dir)
        cp(joinpath(dir, p), joinpath(d, p))
    end
    doc = _xrepo_json(joinpath(d, file))
    f!(doc)
    write(joinpath(d, file), canonical_json_string(doc))
    return d
end

@testset "PNE → DME cross-repository fixture・provenance・replay E2E（Issue #283）" begin
    m = capex_credit_cycle_model(capex_credit_cycle_default_targets())
    manifest = pne_producer_manifest()
    records = Dict(c["case_id"] => c for c in manifest["cases"])

    # ---- 1. producer fixture ------------------------------------------------
    @testset "producer fixture: PNE の実 producer 経路で commit 済みの入力から生成されている" begin
        @test manifest["schema_version"] == "dme.pne-producer-fixture-manifest/1.0.0"
        @test manifest["upstream_repository"] == "Yuki-Watanabe7/production-network-engine"
        @test occursin(r"^[0-9a-f]{40}$", manifest["upstream_commit"])
        @test manifest["upstream_tree_dirty"] === false
        @test manifest["upstream_contract"] == PNE_SECTOR_OUTPUT_PATH_CONTRACT
        @test any(c -> occursin("export-sector-output-path", c), manifest["producer_commands"])
        # MANIFEST とファイルのバイト列が一致する（黙った手編集・差し替えの検出）
        for f in manifest["inputs"]
            @test _xrepo_sha(joinpath(XREPO_DME_ROOT, f["path"])) == f["sha256"]
        end
        @test Set(keys(records)) == Set(c.id for c in XREPO_CASES)

        for case in XREPO_CASES
            rec = records[case.id]
            path = joinpath(XREPO_DME_ROOT, rec["output"]["path"])
            @test path == pne_producer_path(case.id)
            @test _xrepo_sha(path) == rec["output"]["sha256"]
            a = load_pne_sector_output_path(path)
            @test a.content_hash == rec["dme_content_hash"]
            @test a.source_bytes_sha256 == rec["output"]["sha256"]

            # 出力は commit 済みの入力（network・scenario・export config）から導出されている
            net = _xrepo_json(joinpath(XREPO_DME_ROOT, rec["network"]))
            sc = _xrepo_json(joinpath(XREPO_DME_ROOT, rec["scenario"]))
            cfg = _xrepo_json(joinpath(XREPO_DME_ROOT, rec["export_config"]))
            pr = rec["producer_record"]
            @test a.source.network_id == net["network_id"] == sc["network_id"] == pr["network_id"]
            @test a.source.dynamic_artifact_id == pr["dynamic_artifact_id"]
            @test a.source.dynamic_artifact_hash == pr["dynamic_artifact_hash"]
            @test a.source.scenario_hash == pr["scenario_hash"]
            @test a.source.source_input_hash == pr["source_input_hash"]
            @test a.producer.engine_version == pr["engine_version"]
            @test a.producer.algorithm_versions == pr["algorithm_versions"]
            @test pr["completed_periods"] == pr["horizon_periods"] == sc["horizon_periods"]
            @test a.time.period_unit === Symbol(sc["calendar"]["unit"])
            @test a.time.calendar_anchor == sc["calendar"]["start"]
            @test a.time.available_periods == a.time.horizon_periods == sc["horizon_periods"]
            @test (a.geography.system, a.geography.economy_id, a.geography.name) ==
                  (cfg["geography"]["system"], cfg["geography"]["economy_id"], cfg["geography"]["name"])
            @test (a.classification.system, a.classification.version, a.classification.level) ==
                  (cfg["classification"]["system"], cfg["classification"]["version"], cfg["classification"]["level"])
            @test a.source_provenance.note == cfg["provenance_note"]
            nodes = sort(net["nodes"]; by = n -> n["node_id"])
            @test pne_sector_ids(a) == [n["node_id"] for n in nodes]
            for (s, n) in zip(a.sectors, nodes)
                @test s.source_label == n["label"]
                @test s.source_data_status === Symbol(n["estimation_status"])
                @test s.baseline_output.value == n["baseline_output"]["value"]
                @test s.baseline_output.unit == n["baseline_output"]["unit"]
            end

            # Issue #283 Scope 1 の最低限の内容
            @test a.status === :complete
            @test pne_is_synthetic_source(a)
            @test length(a.sectors) >= 4
            @test a.time.available_periods >= 6
            dropped = [s for s in a.sectors if any(<(1.0), s.realized_output_ratio)]
            @test !isempty(dropped)
            @test all(s -> s.realized_output_ratio[end] == 1.0, a.sectors)   # 回復
            @test all(==(1.0), pne_sector(a, "chip_fab").realized_output_ratio)   # producer set は制約されない
            for h in (
                a.source.source_input_hash,
                a.source.dynamic_artifact_hash,
                a.source.scenario_hash,
                a.source.scenario_policy_hash,
                a.source.scenario_config_hash,
                a.source.export_config_hash,
            )
                @test occursin(r"^sha256:[0-9a-f]{64}$", h)
            end
        end
    end

    # ---- 2. positive E2E ----------------------------------------------------
    @testset "positive E2E（四半期）: producer fixture → compatibility → mapping → CCC 実行" begin
        f = _xrepo_pipeline(XREPO_CASES[1])
        a, r = f.a, f.report
        @test r.decision === :accepted
        @test r.claim_scope === :hypothetical_fictional
        @test r.transmission_mode === :hypothetical_override
        @test Set(_xrepo_codes(r.warnings)) ⊇ Set([
            :hypothetical_transmission,
            :synthetic_upstream_source,
            :unmapped_source_sectors_present,
            :partial_target_coverage,
            :upstream_warning_carried,
        ])
        @test r.unmapped_source_sectors == ["harness_maker", "metal_supply", "panel_maker"]

        # X3: 顧客部門の実現産出の低下 → 派生需要（−Σ w_j (1 − r_j)、sector_id 昇順の逐次加算）
        p = only(apply_cross_model_mapping(a, f.mapping, r))
        h = pne_sector(a, "handset_assembly").realized_output_ratio
        v = pne_sector(a, "vehicle_assembly").realized_output_ratio
        @test p.members == ["handset_assembly", "vehicle_assembly"]
        @test p.values == [(0.0 - 0.15 * (1.0 - h[k])) - 0.2 * (1.0 - v[k]) for k in eachindex(h)]
        @test minimum(p.values) < 0.0 && p.values[end] == 0.0
        @test p.covered_share ≈ 0.35

        # X4
        x = only(f.xs)
        @test x.values == p.values
        @test x.anchor_quarter == CalendarQuarter(2025, 1)
        @test x.upstream.content_hash == a.content_hash
        @test x.claim_scope === :hypothetical_fictional

        # X5 / X6
        sc = _xrepo_scenario()
        run = run_cross_model_scenario(m, sc, f.xs)
        @test run.status === :completed
        @test run.result isa SimulationResult
        @test run.accounting !== nothing && run.diagnostics !== nothing
        @test isempty(run.cross_model_rejections) && isempty(run.event_rejections)
        base = run_scenario(m, sc)
        for (i, t) in enumerate(collect(-8:(length(run.exog[:ext_demand_s2]) - 9)))
            b = base.exog[:ext_demand_s2][i]
            expected = (0 <= t < length(x.values) && x.values[t + 1] != 0.0) ?
                       b * (1 + (100.0 * x.values[t + 1]) / 100) : b
            @test run.exog[:ext_demand_s2][i] == expected
        end
        for var in exogenous_variables(m)
            var === :ext_demand_s2 && continue
            @test run.exog[var] == base.exog[var]
        end
        # 上流入力は CCC の内生系列まで伝わる
        @test any(k -> run.result.variables[k] != base.result.variables[k], keys(run.result.variables))
        u = only(filter(i -> i.input_id in run.upstream_applied_input_ids, run.applied_inputs))
        @test u.target_variable === :ext_demand_s2
        @test u.provenance.derived_from == [x.input_id]
        md = run.result.metadata
        @test all(k -> haskey(md, k), CROSS_MODEL_METADATA_KEYS)
        @test md["cross_model_claim_scope"] == "hypothetical_fictional"
        @test md["cross_model_transmission_modes"] == Dict{String, Any}(x.input_id => "hypothetical_override")
    end

    @testset "positive E2E（月次）: 3 か月平均で四半期へ集約して CCC 実行まで完走する" begin
        f = _xrepo_pipeline(XREPO_CASES[2])
        a, r = f.a, f.report
        @test a.time.period_unit === :month
        @test r.decision === :accepted
        @test r.aggregation_rule === :mean_of_three_months
        @test r.timing_quarters == 4
        x = only(f.xs)
        @test x.anchor_quarter == CalendarQuarter(2025, 2)
        q(s) = [sum(s[(3k + 1):(3k + 3)]) / 3 for k in 0:3]
        h = q(pne_sector(a, "handset_assembly").realized_output_ratio)
        v = q(pne_sector(a, "vehicle_assembly").realized_output_ratio)
        @test x.values == [(0.0 - 0.15 * (1.0 - h[k])) - 0.2 * (1.0 - v[k]) for k in 1:4]
        run = run_cross_model_scenario(m, _xrepo_scenario(), f.xs)
        @test run.status === :completed
        @test only(run.input_log)["t0"] == 1   # 2025-04-01 は period_zero=2025Q1 から 1 四半期後
    end

    @testset "geography guard を弱めていない: positive path は synthetic source の hypothetical_override に限る" begin
        profile = cross_model_target_profile(:capex_credit_cycle)
        @test profile.geography == CrossModelGeographyRef("ISO 3166-1 alpha-2", "US")
        for case in XREPO_CASES
            a = load_pne_sector_output_path(pne_producer_path(case.id))
            # fixture の geography を CCC の経済圏へ偽装していない
            @test (a.geography.system, a.geography.economy_id) != ("ISO 3166-1 alpha-2", "US")
            @test _xrepo_mapping(case.mapping).transmission.mode === :hypothetical_override
        end
        # 同じ producer fixture を same_economy で入れると geography_mismatch
        _, _, r = _xrepo_check(;
            mapping! = md -> (md["transmission"] = Dict{String, Any}("mode" => "same_economy", "justification" => "", "transmission_ref" => nothing)),
        )
        @test _xrepo_codes(r.rejections) == [:geography_mismatch]
        # synthetic でない source は同じ mapping でも override できない
        _, _, r = _xrepo_check(; artifact! = d -> (d["source_provenance"]["is_synthetic"] = false))
        @test _xrepo_codes(r.rejections) == [:hypothetical_override_requires_synthetic_source]
        _, _, r = _xrepo_check(; artifact! = d -> (d["sectors"][1]["source_data_status"] = "observed"))
        @test _xrepo_codes(r.rejections) == [:hypothetical_override_requires_synthetic_source]
    end

    # ---- 3. official Japan → US negative -------------------------------------
    @testset "official Japan → US CCC: 3 mode がそれぞれ別のコードで拒否される（negative golden）" begin
        ident = pne_official_jp_identity()
        text = read(joinpath(PNE_OFFICIAL_JP_DIR, "bridge_identity.json"), String)
        # license 未確認の official data（部門 ID・ラベル・baseline・パス）を commit していない
        @test ident["schema_version"] == "dme.pne-bridge-identity/1.0.0"
        @test ident["withheld_members"] == ["aggregate_path", "sectors"]
        @test !haskey(ident["bridge"], "sectors") && !haskey(ident["bridge"], "aggregate_path")
        for key in ("\"sector_id\"", "\"source_label\"", "\"periods\"", "\"baseline_output\"", "\"realized_output_ratio\"")
            @test !occursin(key, text)
        end
        @test !occursin("jp-io:2020:", text)   # EDP が official 部門に付ける node id の形式
        @test isempty([f for (_, _, fs) in walkdir(XREPO_ROOT) for f in fs if endswith(f, ".xlsx")])

        # identity は official 実行（EDP → PNE）の値そのもの
        b = ident["bridge"]
        gen = ident["generation"]
        @test (b["geography"]["system"], b["geography"]["economy_id"]) == ("ISO 3166-1 alpha-2", "JP")
        @test (b["classification"]["system"], b["classification"]["version"], b["classification"]["level"]) ==
              ("Japan 2020 IO sector classification", "2020", "integrated-middle")
        @test b["source_provenance"]["is_synthetic"] === false
        @test b["source_provenance"]["node_estimation_status_counts"] == Dict{String, Any}("observed" => 108)
        @test ident["sector_summary"]["count"] == gen["network"]["node_count"] == 108
        @test b["source"]["network_id"] == gen["network"]["network_id"]
        @test occursin(gen["official_source"]["workbook_sha256"][8:23], b["source"]["network_id"])
        @test occursin("estat:" * gen["official_source"]["estat_table_id"], only(b["source_provenance"]["references"])["source_version"])
        @test b["source"]["dynamic_artifact_id"] == gen["dynamic_record"]["dynamic_artifact_id"]
        @test b["source"]["dynamic_artifact_hash"] == gen["dynamic_record"]["dynamic_artifact_hash"]
        @test b["source"]["scenario_hash"] == gen["dynamic_record"]["scenario_hash"]
        @test gen["export_config"]["sha256"] == _xrepo_sha(joinpath(XREPO_DME_ROOT, gen["export_config"]["path"]))
        @test b["time"]["period_unit"] == "year"   # 年次 IO の 1 期間

        # identity + placeholder 部門で decode 可能な文書に戻す（部門の値は架空）
        a = pne_sector_output_path_from_dict(official_jp_reconstructed_dict())
        @test !pne_is_synthetic_source(a)
        golden = _xrepo_json(joinpath(XREPO_ROOT, "golden", "report_official_jp_ccc.json"))
        observed = ident["dme_observation"]["modes"]
        for (mode, geo_code) in XREPO_OFFICIAL_MODES
            mp = _xrepo_mapping("ccc_official_jp_$(mode).json")
            @test mp.transmission.mode === Symbol(mode)
            r = check_cross_model_compatibility(a, mp)
            @test r.decision === :rejected
            @test r.geography_status === :rejected
            @test r.claim_scope === nothing
            codes = _xrepo_codes(r.rejections)
            @test geo_code in codes
            # geography の判定コードはこの mode のものだけ（mode ごとに別コード）
            @test intersect(codes, last.(XREPO_OFFICIAL_MODES)) == [geo_code]
            # 実データの full artifact に対して DME が出した判定と一致する
            @test String.(codes) == observed[mode]["rejection_codes"]
            @test observed[mode]["decision"] == "rejected" && observed[mode]["geography_status"] == "rejected"
            dd = cross_model_compatibility_report_to_dict(r; include_audit = false)
            @test canonical_json_string(dd) == canonical_json_string(golden[mode])
            @test dd["geography"]["status"] == "rejected"
            msg = _xrepo_error(() -> build_model_derived_inputs(a, mp, r; timing_basis = :period, t_start = 0))
            @test msg !== nothing && startswith(msg, "cross_model_mapping_rejected")
        end
        @test length(unique(last.(XREPO_OFFICIAL_MODES))) == 3
    end

    # ---- 4. contract drift ---------------------------------------------------
    @testset "contract drift: vendor schema の contract surface golden と DME の語彙" begin
        surface = pne_contract_surface(pne_vendored_schema())
        @test canonical_json_string(surface) == _xrepo_golden("pne_contract_surface_v1.json")
        n = surface["nodes"]
        @test surface["contract_version"] == PNE_SECTOR_OUTPUT_PATH_CONTRACT
        @test Set(Symbol.(n["\$.time.period_unit"]["enum"])) == Set(PNE_PERIOD_UNITS)
        @test Set(Symbol.(n["\$.sectors[].source_data_status"]["enum"])) == Set(PNE_ESTIMATION_STATUSES)
        @test Set(Symbol.(n["\$.status"]["enum"])) == Set(PNE_ARTIFACT_STATUSES)
        @test Set(Symbol.(n["\$.warnings[].severity"]["enum"])) == Set(PNE_WARNING_SEVERITIES)
        @test Set(n["\$.warnings[].source"]["enum"]) == Set(DME._PNE_WARNING_SOURCES)
        @test Set(Symbol.(n["\$.source_provenance.node_estimation_status_counts"]["property_names_enum"])) ==
              Set(PNE_ESTIMATION_STATUSES)
        @test Set(n["\$"]["properties"]) == Set(n["\$"]["required"]) == Set(DME._PNE_TOP_LEVEL_KEYS)
        @test Set(n["\$.source"]["required"]) == Set(DME._PNE_SOURCE_KEYS)
        # geography / classification / time / output ratio の意味論
        @test n["\$.geography"]["required"] == ["economy_id", "name", "system"]
        @test n["\$.geography_compatibility.mode"]["const"] == "same_economy_only"
        @test n["\$.geography_compatibility.explicitly_modeled_cross_economy"]["const"] === false
        @test n["\$.classification"]["required"] == ["level", "sector_id_semantics", "system", "version"]
        @test n["\$.classification.sector_id_semantics"]["const"] == "opaque"
        @test n["\$.time.value_semantics"]["const"] == "period_total_realized_output_ratio"
        @test n["\$.time.interval_semantics"]["const"] == "start_inclusive_end_exclusive"
        @test n["\$.time.rescaled_by_exporter"]["const"] === false
        @test n["\$.time.frequency"]["const"] == 1
        @test n["\$.time.period_index_origin"]["const"] == 0
        @test n["\$.aggregation.status"]["const"] == "native_sector_path"
        for k in ("realized_output_ratio", "output_loss_ratio")
            @test (n["\$.sectors[].periods[].$(k)"]["minimum"], n["\$.sectors[].periods[].$(k)"]["maximum"]) == (0, 1)
        end
        @test "output_loss_ratio equals 1 - realized_output_ratio" in surface["semantic_invariants"]
        @test length(surface["semantic_invariants"]) == 6
    end

    @testset "contract drift: schema の各制約を 1 つだけ破った文書を DME の decoder がすべて拒否する" begin
        surface = pne_contract_surface(pne_vendored_schema())
        doc = pne_producer_dict("quarterly_supplier_disruption")
        # complete artifact に存在しない unsupported_reasons[] の要素は unsupported の派生文書で検査する
        unsupported = deepcopy(doc)
        unsupported["status"] = "unsupported"
        unsupported["time"]["horizon_periods"] = unsupported["time"]["available_periods"] + 1
        unsupported["unsupported_reasons"] =
            Any[Dict{String, Any}("code" => "horizon_incomplete", "message" => "fabricated for a drift probe")]
        @test pne_sector_output_path_from_dict(doc) isa PNESectorOutputPath
        @test pne_sector_output_path_from_dict(unsupported) isa PNESectorOutputPath
        probes = vcat(
            [(doc, mu) for mu in pne_contract_mutations(surface, doc)],
            [
                (unsupported, mu) for
                mu in pne_contract_mutations(surface, unsupported) if startswith(mu.name, "\$.unsupported_reasons[]")
            ],
        )
        @test length(probes) >= 300
        located = Set(first(split(mu.name, ":")) for (_, mu) in probes)
        @test located == Set(keys(surface["nodes"]))   # surface のすべての位置を少なくとも 1 回検査する
        for (base, mu) in probes
            d = deepcopy(base)
            mu.mutate!(d)
            msg = _xrepo_error(() -> pne_sector_output_path_from_dict(d))
            ok = msg !== nothing && any(c -> startswith(msg, String(c)), PNE_DECODE_ERROR_CODES) &&
                 occursin(mu.fragment, msg)
            ok || @info "drift probe が拒否されなかった" mu.name msg
            @test ok
        end
    end

    @testset "contract drift: canonical fixture hash・mapping hash・report hash の golden" begin
        chain = _xrepo_json(joinpath(XREPO_ROOT, "golden", "e2e_producer_inputs.json"))
        for (case, report_file) in zip(XREPO_CASES, ("report_ccc_producer_quarterly.json", "report_ccc_producer_monthly.json"))
            f = _xrepo_pipeline(case)
            g = chain[case.id]
            @test f.a.content_hash == g["content_hash"] == records[case.id]["dme_content_hash"]
            @test f.a.source_bytes_sha256 == g["source_bytes_sha256"]
            @test f.mapping.mapping_id == g["mapping_id"]
            @test cross_model_mapping_hash(f.mapping) == g["mapping_hash"]
            @test cross_model_compatibility_report_hash(f.report) == g["compatibility_report_hash"]
            @test cross_model_input_set_hash(f.xs) == g["cross_model_input_set_hash"]
            @test canonical_json_string(Any[model_derived_input_to_dict(x) for x in f.xs]) ==
                  canonical_json_string(g["model_derived_inputs"])
            @test canonical_json_string(cross_model_compatibility_report_to_dict(f.report; include_audit = false)) ==
                  _xrepo_golden(report_file)
        end
    end

    # ---- 5. provenance ------------------------------------------------------
    @testset "provenance: 保存済み成果物だけから DME 結果 → PNE source artifact まで辿る" begin
        case = XREPO_CASES[1]
        f = _xrepo_pipeline(case)
        run = run_cross_model_scenario(m, _xrepo_scenario(), f.xs)
        dir = mktempdir()
        save_cross_model_scenario_artifact(dir, run; mappings = [f.mapping], reports = [f.report])

        # DME 結果と DME model / version
        summary = _xrepo_json(joinpath(dir, "result_summary.json"))
        man = _xrepo_json(joinpath(dir, "manifest.json"))
        @test summary["status"] == "completed"
        @test man["run_kind"] == "cross_model"
        @test man["model_version"] == run.provenance.model_version
        @test man["contract_versions"]["cross_model_input_contract_version"] == CROSS_MODEL_INPUT_CONTRACT_VERSION
        @test man["model_mapping_version"] == CCC_CROSS_MODEL_MAPPING_VERSION
        @test man["params_hash"] == run.provenance.params_hash
        md = summary["metadata"]
        entry = only(md["cross_model_inputs"])
        input_id = entry["input_id"]
        # CCC では 1 つの ModelDerivedInput が 1 つの AppliedModelInput になる（設計 §21）
        applied = [entry["applied_input_id"]]
        @test applied == [input_id * "/ext_demand_s2"]
        @test entry["upstream_content_hash"] == f.a.content_hash
        @test entry["mapping_hash"] == cross_model_mapping_hash(f.mapping)

        # AppliedModelInput（実行ログ）
        log = _xrepo_json(joinpath(dir, "event_log.json"))["event_log"]
        l4 = filter(e -> e["input_id"] in applied, log)
        @test !isempty(l4)
        @test all(e -> e["target_variable"] == "ext_demand_s2" && e["derived_from"] == [input_id], l4)
        @test all(e -> e["mapping_version"] == CCC_CROSS_MODEL_MAPPING_VERSION, l4)

        # ModelDerivedInput → mapping artifact → compatibility report
        xd = only(filter(x -> x["input_id"] == input_id, _xrepo_json(joinpath(dir, "cross_model_scenario.json"))["model_derived_inputs"]))
        mps = _xrepo_json(joinpath(dir, "mappings.json"))["mappings"]
        mpd = only(filter(d -> cross_model_mapping_hash(cross_model_mapping_from_dict(d)) == xd["mapping_hash"], mps))
        @test mpd["mapping_id"] == f.mapping.mapping_id
        @test only(md["cross_model_mapping_refs"])["mapping_hash"] == xd["mapping_hash"]
        reps = _xrepo_json(joinpath(dir, "compatibility_reports.json"))["reports"]
        rd = only(filter(d -> DME._cross_model_report_dict_hash(d) == xd["compatibility_report_hash"], reps))
        @test rd["decision"] == "accepted"
        @test rd["mapping"]["mapping_hash"] == xd["mapping_hash"]
        @test md["cross_model_compatibility_report_hashes"] == [xd["compatibility_report_hash"]]

        # PNE bridge artifact
        up = xd["upstream"]
        @test rd["upstream"]["content_hash"] == up["content_hash"]
        bridge = load_pne_sector_output_path(pne_producer_path(case.id))
        @test bridge.content_hash == up["content_hash"]
        @test bridge.artifact_id == up["artifact_id"]
        @test only(md["cross_model_upstream_artifacts"])["content_hash"] == up["content_hash"]

        # PNE dynamic artifact・scenario / config（producer 側で PNE が計算した記録と一致）
        pr = records[case.id]["producer_record"]
        for (k, v) in (
            "dynamic_artifact_id" => pr["dynamic_artifact_id"],
            "dynamic_artifact_hash" => pr["dynamic_artifact_hash"],
            "scenario_hash" => pr["scenario_hash"],
            "source_input_hash" => pr["source_input_hash"],
            "network_id" => pr["network_id"],
            "scenario_policy_hash" => bridge.source.scenario_policy_hash,
            "scenario_config_hash" => bridge.source.scenario_config_hash,
            "export_config_hash" => bridge.source.export_config_hash,
        )
            @test up[k] == v
            @test only(md["cross_model_upstream_artifacts"])[k] == v
        end
        chain = only(cross_model_input_summary(run)["provenance_chain"])
        @test chain["dynamic_artifact_hash"] == pr["dynamic_artifact_hash"]
        @test chain["upstream_content_hash"] == bridge.content_hash
    end

    # ---- 6. replay ----------------------------------------------------------
    @testset "replay: 保存済み入力だけから同一の結果・hash を再現する（環境非依存）" begin
        case = XREPO_CASES[1]
        f = _xrepo_pipeline(case)
        run = run_cross_model_scenario(m, _xrepo_scenario(), f.xs)
        dir = mktempdir()
        save_cross_model_scenario_artifact(dir, run; mappings = [f.mapping], reports = [f.report])

        # 成果物は絶対パス・ホームディレクトリ・作業ディレクトリを含まない
        for p in readdir(dir)
            text = read(joinpath(dir, p), String)
            for s in (dir, realpath(dir), homedir(), XREPO_DME_ROOT, "/Users/", "/home/", "/private/", "/tmp/")
                @test !occursin(s, text)
            end
        end

        # 別の場所へ移し、PNE bytes・API key なしで replay する
        moved = joinpath(mktempdir(), "moved-artifact")
        cp(dir, moved)
        replayed = withenv("FRED_API_KEY" => nothing, "ESTAT_APP_ID" => nothing, "OPENAI_API_KEY" => nothing) do
            replay_cross_model_scenario(m, moved)
        end
        @test replayed.status === :completed
        @test replayed.exog == run.exog
        @test replayed.result.variables == run.result.variables
        @test replayed.cross_model_provenance.cross_model_input_set_hash ==
              run.cross_model_provenance.cross_model_input_set_hash
        @test replayed.provenance.params_hash == run.provenance.params_hash

        # 再保存した成果物は元の成果物とバイト単位で一致する（canonical result の決定性）
        again = mktempdir()
        save_cross_model_scenario_artifact(again, replayed; mappings = [f.mapping], reports = [f.report])
        @test sort(readdir(again)) == sort(readdir(dir))
        for p in readdir(dir)
            @test read(joinpath(again, p)) == read(joinpath(dir, p))
        end

        # PNE bytes を与えた場合に限り X1–X3 を再導出して値を照合する
        rederived = replay_cross_model_scenario(
            m,
            moved;
            upstream_artifacts = Dict(f.a.content_hash => pne_producer_path(case.id)),
        )
        @test rederived.exog == run.exog
    end

    # ---- 7. failure fixtures ----------------------------------------------
    @testset "failure: decode 不能な上流 artifact は X1 で拒否する（schema version・period semantics・ratio）" begin
        cases = [
            ("unsupported schema version", d -> (d["schema_version"] = "production-network-sector-output-path/v2"), :unsupported_upstream_schema_version),
            ("missing period semantics: period_unit", d -> delete!(d["time"], "period_unit"), :upstream_schema_violation),
            ("missing period semantics: value_semantics", d -> delete!(d["time"], "value_semantics"), :upstream_schema_violation),
            ("undeclared period unit", d -> (d["time"]["period_unit"] = "fortnight"), :upstream_schema_violation),
            ("rescaled by exporter", d -> (d["time"]["rescaled_by_exporter"] = true), :upstream_schema_violation),
            ("missing geography", d -> delete!(d, "geography"), :upstream_schema_violation),
            ("missing classification", d -> delete!(d, "classification"), :upstream_schema_violation),
            ("invalid ratio: above 1", d -> (p = d["sectors"][2]["periods"][2]; p["realized_output_ratio"] = 1.2; p["output_loss_ratio"] = -0.2), :upstream_schema_violation),
            ("invalid ratio: NaN", d -> (d["sectors"][2]["periods"][2]["realized_output_ratio"] = "NaN"), :upstream_schema_violation),
            ("invalid ratio: Infinity", d -> (d["sectors"][2]["periods"][2]["realized_output_ratio"] = "Infinity"), :upstream_schema_violation),
            ("invalid ratio: loss inconsistent", d -> (d["sectors"][2]["periods"][2]["output_loss_ratio"] = 0.123), :upstream_semantic_invariant_violation),
            ("missing period", d -> pop!(d["sectors"][2]["periods"]), :upstream_semantic_invariant_violation),
        ]
        for (name, mutate!, code) in cases
            d = pne_producer_dict("quarterly_supplier_disruption")
            mutate!(d)
            msg = _xrepo_error(() -> pne_sector_output_path_from_dict(d))
            ok = msg !== nothing && startswith(msg, String(code))
            ok || @info "failure fixture" name msg
            @test ok
        end
    end

    @testset "failure: 互換性判定で拒否し、ModelDerivedInput を作らない（geography・classification・sector・target）" begin
        same_economy = md -> (md["transmission"] = Dict{String, Any}("mode" => "same_economy", "justification" => "", "transmission_ref" => nothing))
        cases = [
            ("geography mismatch", identity, same_economy, [:geography_mismatch]),
            ("geography declaration", identity, md -> (md["source_geography"]["economy_id"] = "DME-FICTIONAL-B"), [:geography_declaration_inconsistent]),
            ("classification mismatch", d -> (d["classification"]["version"] = "2"), identity, [:classification_mismatch]),
            ("classification level mismatch", d -> (d["classification"]["level"] = "aggregated"), identity, [:classification_mismatch]),
            ("ambiguous period unit", d -> (d["time"]["period_unit"] = "baseline_period"), identity, [:ambiguous_source_period_unit]),
            ("unsupported period unit", d -> (d["time"]["period_unit"] = "year"), identity, [:unsupported_source_period_unit]),
            ("unmapped sector undeclared", identity, md -> (md["declared_unmapped_source_sectors"] = Any["harness_maker", "metal_supply"]), [:unmapped_sector_undeclared]),
            ("unknown source sector", identity, md -> push!(md["groups"][1]["members"], Dict{String, Any}("sector_id" => "ghost_sector", "weight" => 0.05)), [:unknown_source_sector]),
            ("own supply constrained (DD-6)", d -> (p = d["sectors"][1]["periods"][2]; p["realized_output_ratio"] = 0.9; p["output_loss_ratio"] = 0.09999999999999998), identity, [:own_supply_constraint_present]),
            ("unrecovered at horizon end", d -> (p = d["sectors"][6]["periods"][end]; p["realized_output_ratio"] = 0.9; p["output_loss_ratio"] = 0.09999999999999998), identity, [:upstream_path_unrecovered_at_horizon_end]),
            ("unsupported target variable: supply capacity", identity, md -> begin
                g = md["groups"][1]
                g["target_concept"] = "sector_supply_capacity"
                g["weight_basis"] = "source_baseline_output"
                g["producer_set"] = Any[]
                g["customer_scope"] = nothing
                foreach(mem -> (mem["weight"] = nothing), g["members"])
                md["declared_unmapped_source_sectors"] = Any["chip_fab", "harness_maker", "metal_supply", "panel_maker"]
            end, [:unmapped_target_concept]),
            ("unsupported target variable: price group", identity, md -> (md["groups"][1]["target_group"] = "price_s1_customers"), [:unmapped_target_concept]),
            ("unsupported target model", identity, md -> (md["target_model"] = "rbc"), [:unsupported_target_model]),
            ("upstream status unsupported", d -> begin
                d["status"] = "unsupported"
                d["time"]["horizon_periods"] = 9
                d["unsupported_reasons"] = Any[Dict{String, Any}("code" => "horizon_incomplete", "message" => "fabricated")]
            end, identity, [:upstream_status_unsupported]),
        ]
        # sectors は sector_id 昇順: [1] = chip_fab（producer set）・[6] = vehicle_assembly（member）
        @test [s["sector_id"] for s in pne_producer_dict("quarterly_supplier_disruption")["sectors"][[1, 6]]] ==
              ["chip_fab", "vehicle_assembly"]
        for (name, art!, map!, expected) in cases
            a, mp, r = _xrepo_check(; artifact! = art!, mapping! = map!)
            codes = _xrepo_codes(r.rejections)
            ok = r.decision === :rejected && issubset(expected, codes) &&
                 (name == "upstream status unsupported" || codes == expected)
            ok || @info "failure fixture" name codes
            @test ok
            msg = _xrepo_error(() -> build_model_derived_inputs(a, mp, r; timing_basis = :calendar))
            @test msg !== nothing && startswith(msg, "cross_model_mapping_rejected")
        end
        # 月次: anchor が無い・部分四半期
        month = XREPO_CASES[2]
        _, _, r = _xrepo_check(; case = month, artifact! = d -> (d["time"]["calendar_anchor"] = nothing))
        @test _xrepo_codes(r.rejections) == [:calendar_anchor_required]
        _, _, r = _xrepo_check(;
            case = month,
            artifact! = d -> begin
                foreach(s -> resize!(s["periods"], 10), d["sectors"])
                resize!(d["aggregate_path"], 10)
                d["time"]["available_periods"] = d["time"]["horizon_periods"] = 10
            end,
        )
        @test _xrepo_codes(r.rejections) == [:partial_quarter]
    end

    @testset "failure: target model が表現しない入力は実行前に拒否し、近い変数へ寄せない" begin
        x = only(_xrepo_pipeline(XREPO_CASES[1]).xs)
        supply = ModelDerivedInput(;
            input_id = x.input_id,
            upstream = x.upstream,
            mapping_id = x.mapping_id,
            mapping_version = x.mapping_version,
            mapping_hash = x.mapping_hash,
            compatibility_report_hash = x.compatibility_report_hash,
            target_model = x.target_model,
            target_concept = :sector_supply_capacity,
            target_group = :s2_supply,
            value_semantics = :group_realized_output_ratio,
            values = [1.0, 0.5, 0.5, 0.75, 1.0],
            timing_basis = x.timing_basis,
            anchor_quarter = x.anchor_quarter,
            transmission_mode = x.transmission_mode,
            claim_scope = x.claim_scope,
            coverage = x.coverage,
        )
        for opts in (ScenarioRunOptions(), ScenarioRunOptions(; on_unmapped = :warn))
            run = run_cross_model_scenario(m, _xrepo_scenario(), [supply]; options = opts)
            @test run.status === :rejected_mapping
            @test _xrepo_codes(run.cross_model_rejections) == [:unmapped_target_concept]
            @test run.result === nothing && run.exog === nothing
        end
    end

    @testset "failure: hash chain が壊れた入力は拒否する" begin
        case = XREPO_CASES[1]
        f = _xrepo_pipeline(case)
        # 別の artifact の report を流用できない（X3）
        d2 = pne_producer_dict(case.id)
        p = d2["sectors"][2]["periods"][3]
        p["realized_output_ratio"] = 0.6
        p["output_loss_ratio"] = 0.4
        msg = _xrepo_error(() -> apply_cross_model_mapping(pne_sector_output_path_from_dict(d2), f.mapping, f.report))
        @test msg !== nothing && startswith(msg, "provenance_chain_broken")

        run = run_cross_model_scenario(m, _xrepo_scenario(), f.xs)
        dir = mktempdir()
        save_cross_model_scenario_artifact(dir, run; mappings = [f.mapping], reports = [f.report])
        tampers = [
            ("cross_model_scenario.json", doc -> (doc["model_derived_inputs"][1]["values"][2] = -0.5)),
            ("cross_model_scenario.json", doc -> (doc["model_derived_inputs"][1]["upstream"]["content_hash"] = "sha256:" * repeat("0", 64))),
            ("mappings.json", doc -> (doc["mappings"][1]["groups"][1]["members"][1]["weight"] = 0.3)),
            ("compatibility_reports.json", doc -> (doc["reports"][1]["upstream"]["dynamic_artifact_hash"] = "sha256:" * repeat("0", 64))),
            ("manifest.json", doc -> (doc["cross_model_input_set_hash"] = "sha256:" * repeat("0", 64))),
        ]
        for (file, f!) in tampers
            msg = _xrepo_error(() -> replay_cross_model_scenario(m, _xrepo_tampered(dir, file, f!)))
            ok = msg !== nothing && startswith(msg, "provenance_chain_broken")
            ok || @info "hash chain tamper" file msg
            @test ok
        end
        # 再導出検証: content hash の異なる PNE bytes を与えると検出する
        wrong = joinpath(mktempdir(), "wrong.json")
        write(wrong, json_write(d2))
        msg = _xrepo_error(
            () -> replay_cross_model_scenario(m, dir; upstream_artifacts = Dict(f.a.content_hash => wrong)),
        )
        @test msg !== nothing && startswith(msg, "provenance_chain_broken")
        # 参照する mapping を同梱せずに保存できない
        @test_throws ArgumentError save_cross_model_scenario_artifact(
            mktempdir(),
            run;
            mappings = CrossModelMapping[],
            reports = [f.report],
        )
    end

    # ---- 8. runtime 依存 ----------------------------------------------------
    @testset "cross-repository runtime 依存が無い（PNE / Python を実行時に使わない）" begin
        project = read(joinpath(XREPO_DME_ROOT, "Project.toml"), String)
        for dep in ("PyCall", "PythonCall", "CondaPkg", "production_network_engine", "production-network-engine")
            @test !occursin(dep, project)
        end
        for (root, _, files) in walkdir(joinpath(XREPO_DME_ROOT, "src"))
            for file in filter(endswith(".jl"), files)
                text = read(joinpath(root, file), String)
                @test !occursin("import production_network_engine", text)
                @test !occursin("from production_network_engine", text)
                @test !occursin("uv run", text)
                @test !occursin("PyCall", text) && !occursin("PythonCall", text)
            end
        end
        # 生成スクリプトはテストから呼ばれない
        runtests = read(joinpath(@__DIR__, "runtests.jl"), String)
        @test !occursin("regenerate_cross_repo", runtests)
    end
end
