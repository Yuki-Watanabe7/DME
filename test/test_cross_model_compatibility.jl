# PNE sector-output-path の受理・cross-model mapping artifact・互換性判定と mapping 適用
# （Issue #281 / `PN-1`）のテスト。
#
#   - PNE v1 artifact の decode（schema 制約と x-semantic-invariants の Julia 再実装、UM-8）
#   - vendor した PNE contract fixture の hash 固定（drift 検出）
#   - geography の fail closed（Japan-PNE → US-CCC を 3 mode すべてで拒否）
#   - classification・sector 割当・weight・DD-6・時間軸の構造化拒否（全件列挙）
#   - many-to-one 集約の決定性・再正規化しないこと・unmapped を 0 にしないこと
#   - month → quarter の厳密な集約・anchor・部分四半期・horizon 末の回復
#   - compatibility report / mapped path の golden と hash の決定性
#
# 設計: docs/architecture/pne_sector_output_integration.md・docs/adr/0024-*.md

using Test
using DME
using Dates
const json_read = DME.json_read
const json_write = DME.json_write
const json_pretty = DME.json_pretty

include(joinpath(@__DIR__, "fixtures", "pne", "pne_fixture_builders.jl"))

const PNE_TEST_ROOT = joinpath(@__DIR__, "fixtures", "pne")
const PNE_REPO_ROOT = normpath(joinpath(@__DIR__, ".."))

_pne_mapping(name) = load_cross_model_mapping(joinpath(PNE_TEST_ROOT, "mappings", name))
_pne_mapping_dict(name) = cross_model_mapping_to_dict(_pne_mapping(name))
_codes(r) = [x.code for x in r.rejections]
_warning_codes(r) = [w.code for w in r.warnings]
_artifact(d) = pne_sector_output_path_from_dict(d)
_check(d::AbstractDict, m) = check_cross_model_compatibility(_artifact(d), m)

function _decode_error(f)
    try
        f()
    catch e
        e isa ArgumentError || rethrow()
        return e.msg
    end
    return nothing
end

@testset "PNE sector-output-path 受理・cross-model 互換性判定（Issue #281）" begin

    # ---- 契約 version と語彙 --------------------------------------------------
    @testset "契約 version と語彙" begin
        @test CROSS_MODEL_INPUT_CONTRACT_VERSION == "cross-model-input/1.0.0"
        @test PNE_SECTOR_OUTPUT_PATH_ACCEPTED_SCHEMA_VERSIONS ==
              ("production-network-sector-output-path/v1",)
        @test CROSS_MODEL_MAPPING_SCHEMA_VERSION == "dme.cross-model-mapping/1.0.0"
        @test CROSS_MODEL_COMPATIBILITY_REPORT_SCHEMA_VERSION ==
              "dme.cross-model-compatibility-report/1.0.0"
        @test length(CROSS_MODEL_REJECTION_CODES) == 30
        @test length(unique(CROSS_MODEL_REJECTION_CODES)) == 30
        @test length(CROSS_MODEL_WARNING_CODES) == 10
        # event 層の語彙とは独立（ADR 0024 決定 15。MACRO_EVENT_* を変更しない）
        @test isempty(intersect(CROSS_MODEL_REJECTION_CODES, MACRO_EVENT_REJECTION_CODES))
        @test isempty(intersect(CROSS_MODEL_WARNING_CODES, MACRO_EVENT_WARNING_CODES))
        @test length(MACRO_EVENT_REJECTION_CODES) == 12
        @test length(MACRO_EVENT_WARNING_CODES) == 12
        @test CROSS_MODEL_TRANSMISSION_MODES ==
              (:same_economy, :explicit_cross_economy, :hypothetical_override)
        @test ACCEPTED_CROSS_ECONOMY_TRANSMISSION_CONTRACTS == ()
    end

    # ---- vendor fixture の drift 検出 ----------------------------------------
    @testset "vendor した PNE contract fixture が MANIFEST の hash と一致する" begin
        manifest = json_read(
            read(joinpath(PNE_TEST_ROOT, "sector_output_path", "v1", "MANIFEST.json"), String),
        )
        @test manifest["upstream_repository"] == "Yuki-Watanabe7/production-network-engine"
        @test manifest["upstream_contract"] == PNE_SECTOR_OUTPUT_PATH_CONTRACT
        @test length(manifest["upstream_commit"]) == 40
        @test length(manifest["files"]) == 10
        for f in manifest["files"]
            path = joinpath(PNE_REPO_ROOT, f["path"])
            @test isfile(path)
            @test "sha256:" * bytes2hex(DME.SHA.sha256(read(path))) == f["sha256"]
        end
        schema = json_read(
            read(
                joinpath(
                    PNE_REPO_ROOT,
                    "docs",
                    "contract",
                    "pne",
                    "production-network-sector-output-path-v1.schema.json",
                ),
                String,
            ),
        )
        @test schema["x-contract-version"] == PNE_SECTOR_OUTPUT_PATH_CONTRACT
        @test length(schema["required"]) == 21
    end

    # ---- X1: 受理 ----------------------------------------------------------
    @testset "X1: representative fixture を受理し identity を保持する" begin
        path = joinpath(PNE_TEST_ROOT, "sector_output_path", "v1", "representative.json")
        a = load_pne_sector_output_path(path)
        @test a isa PNESectorOutputPath
        @test a.schema_version == PNE_SECTOR_OUTPUT_PATH_CONTRACT
        @test a.artifact_id == "sop-719504be22aa5ec3f41907f8"
        @test a.status === :complete
        @test a.time.period_unit === :year
        @test a.time.calendar_anchor == "2025-01-01"
        @test pne_sector_ids(a) == ["assembly", "component", "final_good", "raw_material"]
        @test pne_sector(a, "assembly").realized_output_ratio == [0.1, 0.4, 0.4, 1.0, 1.0]
        @test pne_sector(a, "missing") === nothing
        @test pne_is_synthetic_source(a)
        @test occursin(r"^sha256:[0-9a-f]{64}$", a.content_hash)
        @test a.source_bytes_sha256 == "sha256:" * bytes2hex(DME.SHA.sha256(read(path)))

        # content_hash は空白・キー順・整数/浮動小数の表記に依存しない
        d = pne_representative_dict()
        a2 = pne_sector_output_path_from_dict(d)
        @test a2.content_hash == a.content_hash
        @test a2.source_bytes_sha256 === nothing
        compact = json_write(d)
        a3 = pne_sector_output_path_from_dict(
            DME._scenario_json_to_plain(json_read(compact)),
        )
        @test a3.content_hash == a.content_hash

        # UpstreamModelArtifactRef は PNE の source hash を再計算せずに写す
        ref = upstream_artifact_ref(a)
        @test ref.content_hash == a.content_hash
        @test ref.dynamic_artifact_hash == a.source.dynamic_artifact_hash
        @test ref.scenario_hash == a.source.scenario_hash
        @test ref.source_input_hash == a.source.source_input_hash
        @test ref.export_config_hash == a.source.export_config_hash
        @test ref.result_role === UPSTREAM_MODEL_DERIVED_RESULT_ROLE
        @test ref.geography_economy_id == "TEST-ECONOMY-A"
        dref = upstream_artifact_ref_to_dict(ref)
        @test dref["source_bytes_sha256"] == a.source_bytes_sha256
        @test !haskey(upstream_artifact_ref_to_dict(ref; include_audit = false), "source_bytes_sha256")

        # aggregate_path は検証して保持する（v1 ではモデル入力に用いない）
        @test a.aggregate_realized_output_ratio[1] ≈ 0.162376237624 atol = 1e-12
    end

    @testset "X1: PNE の rejected fixture 6 件をすべて decode 時に拒否する" begin
        expected = Dict(
            "classification_missing.json" => "upstream_schema_violation",
            "geography_missing.json" => "upstream_schema_violation",
            "inconsistent_output_ratio.json" => "upstream_semantic_invariant_violation",
            "infinite_output_ratio.json" => "upstream_schema_violation",
            "not_a_number_output_ratio.json" => "upstream_schema_violation",
            "unsupported_period_semantics.json" => "upstream_schema_violation",
        )
        dir = joinpath(PNE_TEST_ROOT, "sector_output_path", "v1", "rejected")
        @test sort(readdir(dir)) == sort(collect(keys(expected)))
        for (file, code) in expected
            msg = _decode_error(() -> load_pne_sector_output_path(joinpath(dir, file)))
            @test msg !== nothing
            @test startswith(msg, code)
        end
    end

    @testset "X1: schema・意味論的不変条件の個別の違反" begin
        base = synthetic_quarterly_dict()
        @test _artifact(base) isa PNESectorOutputPath

        cases = Pair{String, Function}[
            "unsupported_upstream_schema_version" =>
                d -> (d["schema_version"] = "production-network-sector-output-path/v2"),
            "upstream_schema_violation" => d -> (d["unexpected_key"] = 1),
            "upstream_schema_violation" => d -> (d["time"]["frequency"] = 2),
            "upstream_schema_violation" => d -> (d["time"]["rescaled_by_exporter"] = true),
            "upstream_schema_violation" => d -> (d["aggregation"]["status"] = "dme_mapped"),
            "upstream_schema_violation" => d -> (d["aggregation"]["mapping_artifact_hash"] = "sha256:" * repeat("a", 64)),
            "upstream_schema_violation" =>
                d -> (d["geography_compatibility"]["explicitly_modeled_cross_economy"] = true),
            "upstream_schema_violation" =>
                d -> (d["result_type_boundary"]["output_path"] = "observed_output"),
            "upstream_schema_violation" => d -> (d["sectors"][1]["source_data_status"] = "measured"),
            "upstream_schema_violation" =>
                d -> (d["sectors"][1]["periods"][1]["realized_output_ratio"] = true),
            "upstream_schema_violation" =>
                d -> (d["sectors"][1]["periods"][2]["realized_output_ratio"] = 1.2;
                d["sectors"][1]["periods"][2]["output_loss_ratio"] = -0.2),
            "upstream_schema_violation" => d -> (d["source"]["scenario_hash"] = "md5:abc"),
            "upstream_schema_violation" => d -> (d["sectors"][1]["sector_id"] = "bad id"),
            "upstream_semantic_invariant_violation" =>
                d -> (d["geography_compatibility"]["compatible_economy_ids"] = Any["OTHER"]),
            "upstream_semantic_invariant_violation" =>
                d -> (d["sectors"] = reverse(d["sectors"])),
            "upstream_semantic_invariant_violation" =>
                d -> (d["sectors"][1]["periods"][2]["period_index"] = 5),
            "upstream_semantic_invariant_violation" =>
                d -> (pop!(d["sectors"][1]["periods"])),
            "upstream_semantic_invariant_violation" =>
                d -> (d["unsupported_reasons"] = Any[Dict{String, Any}("code" => "x", "message" => "y")]),
            "upstream_semantic_invariant_violation" =>
                d -> (d["status"] = "unsupported"),
        ]
        for (code, mutate!) in cases
            d = deepcopy(base)
            mutate!(d)
            msg = _decode_error(() -> _artifact(d))
            @test msg !== nothing && startswith(msg, code)
        end
        not_json = _decode_error(() -> load_pne_sector_output_path(@__FILE__))
        @test not_json !== nothing && startswith(not_json, "upstream_schema_violation")
    end

    # ---- target profile registry -----------------------------------------
    @testset "target profile は registry からのみ引き、差し替える経路を持たない" begin
        @test CROSS_MODEL_TARGET_PROFILES isa Tuple
        @test length(CROSS_MODEL_TARGET_PROFILES) == 1
        p = cross_model_target_profile(:capex_credit_cycle)
        @test p.geography == CrossModelGeographyRef("ISO 3166-1 alpha-2", "US")
        @test p.frequency === :quarter
        @test p.model_mapping_version == CCC_CROSS_MODEL_MAPPING_VERSION
        @test cross_model_accepted_concepts(p) == (:derived_out_of_model_demand,)
        @test Set(first.(p.target_groups)) == Set([:ext_demand_s2_customers, :ext_demand_s3_customers])
        for model in (:rbc, :solow, :ramsey, :new_keynesian, :sim, :var, :keen)
            @test cross_model_target_profile(model) === nothing
        end
        # check_cross_model_compatibility は (artifact, mapping) の 2 引数のみ・keyword なし
        ms = collect(methods(check_cross_model_compatibility))
        @test length(ms) == 1
        @test ms[1].nargs == 3
        @test isempty(Base.kwarg_decl(ms[1]))
    end

    # ---- geography（設計 §6） ------------------------------------------------
    @testset "geography: hypothetical_override は synthetic source で受理される" begin
        r = _check(synthetic_quarterly_dict(), _pne_mapping("ccc_hypothetical_quarterly.json"))
        @test r.decision === :accepted
        @test r.geography_status === :accepted
        @test r.claim_scope === :hypothetical_fictional
        @test r.transmission_mode === :hypothetical_override
        @test :hypothetical_transmission in _warning_codes(r)
        @test :synthetic_upstream_source in _warning_codes(r)
    end

    @testset "geography: identity が完全一致する same_economy は受理される" begin
        # 同一 identity の受理規則だけを検査するためのテスト入力（synthetic）。実在の米国データを
        # 表すものではない。
        d = synthetic_quarterly_dict()
        d["geography"]["system"] = "ISO 3166-1 alpha-2"
        d["geography"]["economy_id"] = "US"
        d["geography"]["name"] = "test-only identity match"
        d["geography_compatibility"]["compatible_economy_ids"] = Any["US"]
        md = _pne_mapping_dict("ccc_hypothetical_quarterly.json")
        md["source_geography"] = Dict{String, Any}("system" => "ISO 3166-1 alpha-2", "economy_id" => "US")
        md["transmission"] = Dict{String, Any}("mode" => "same_economy", "justification" => "", "transmission_ref" => nothing)
        r = _check(d, cross_model_mapping_from_dict(md))
        @test r.decision === :accepted
        @test r.claim_scope === :same_economy_model_derived
        @test !(:hypothetical_transmission in _warning_codes(r))

        # 同一経済圏に override / cross-economy を宣言すると mode 不整合
        md["transmission"] = Dict{String, Any}("mode" => "hypothetical_override", "justification" => "x", "transmission_ref" => nothing)
        r2 = _check(d, cross_model_mapping_from_dict(md))
        @test _codes(r2) == [:transmission_mode_inconsistent]
        @test r2.claim_scope === nothing

        # economy_id の大文字小文字・名前は正規化しない（完全一致のみ）
        d2 = deepcopy(d)
        d2["geography"]["economy_id"] = "us"
        d2["geography_compatibility"]["compatible_economy_ids"] = Any["us"]
        md["transmission"] = Dict{String, Any}("mode" => "same_economy", "justification" => "", "transmission_ref" => nothing)
        md["source_geography"]["economy_id"] = "us"
        r3 = _check(d2, cross_model_mapping_from_dict(md))
        @test _codes(r3) == [:geography_mismatch]
    end

    @testset "geography: Japan-PNE → US-CCC は 3 mode すべてで別コードで拒否される（§6.5）" begin
        jp = jp_like_dict()
        r_same = _check(jp, _pne_mapping("ccc_same_economy_jp_like.json"))
        @test _codes(r_same) == [:geography_mismatch]
        @test r_same.geography_status === :rejected
        @test r_same.claim_scope === nothing

        r_cross = _check(jp, _pne_mapping("ccc_explicit_cross_economy_jp_like.json"))
        @test _codes(r_cross) == [:cross_economy_transmission_unavailable]

        md = _pne_mapping_dict("ccc_same_economy_jp_like.json")
        md["transmission"] = Dict{String, Any}(
            "mode" => "hypothetical_override",
            "justification" => "test",
            "transmission_ref" => nothing,
        )
        r_hyp = _check(jp, cross_model_mapping_from_dict(md))
        @test _codes(r_hyp) == [:hypothetical_override_requires_synthetic_source]

        # 部門ラベル・経済圏名を揃えても通らない（ラベルは presentation only）
        jp2 = deepcopy(jp)
        jp2["geography"]["name"] = "United States"
        @test _codes(_check(jp2, _pne_mapping("ccc_same_economy_jp_like.json"))) ==
              [:geography_mismatch]
    end

    @testset "geography: 宣言と実体の不一致・mode の必須フィールド" begin
        base_md = _pne_mapping_dict("ccc_hypothetical_quarterly.json")
        d = synthetic_quarterly_dict()

        md = deepcopy(base_md)
        md["source_geography"]["economy_id"] = "TEST-ECONOMY-B"
        @test _codes(_check(d, cross_model_mapping_from_dict(md))) ==
              [:geography_declaration_inconsistent]

        md = deepcopy(base_md)
        md["target_geography"]["economy_id"] = "JP"
        @test _codes(_check(d, cross_model_mapping_from_dict(md))) ==
              [:geography_declaration_inconsistent]

        md = deepcopy(base_md)
        md["transmission"]["justification"] = "   "
        @test _codes(_check(d, cross_model_mapping_from_dict(md))) ==
              [:transmission_mode_inconsistent]

        md = deepcopy(base_md)
        md["transmission"] = Dict{String, Any}("mode" => "explicit_cross_economy", "justification" => "", "transmission_ref" => nothing)
        @test _codes(_check(d, cross_model_mapping_from_dict(md))) ==
              [:transmission_mode_inconsistent]

        # transmission_ref の economy が実体と食い違えば宣言不整合も併せて報告する
        cross = _pne_mapping_dict("ccc_explicit_cross_economy_jp_like.json")
        cross["transmission"]["transmission_ref"]["target_economy"]["economy_id"] = "GB"
        @test Set(_codes(_check(jp_like_dict(), cross_model_mapping_from_dict(cross)))) == Set([
            :geography_declaration_inconsistent,
            :cross_economy_transmission_unavailable,
        ])

        # transmission_ref を explicit 以外の mode で宣言できない
        md = deepcopy(base_md)
        md["transmission"]["transmission_ref"] = cross["transmission"]["transmission_ref"]
        @test :transmission_mode_inconsistent in _codes(_check(d, cross_model_mapping_from_dict(md)))
    end

    # ---- target model・classification ------------------------------------
    @testset "target model: profile の無いモデル・registry version の不一致" begin
        d = synthetic_quarterly_dict()
        md = _pne_mapping_dict("ccc_hypothetical_quarterly.json")
        md["target_model"] = "rbc"
        r = _check(d, cross_model_mapping_from_dict(md))
        @test _codes(r) == [:unsupported_target_model]
        @test r.geography_status === :not_evaluated
        @test r.target_profile_version === nothing

        md = _pne_mapping_dict("ccc_hypothetical_quarterly.json")
        md["target_model_mapping_version"] = "ccc-cross-model-mapping/9.9.9"
        @test _codes(_check(d, cross_model_mapping_from_dict(md))) == [:unsupported_target_model]
    end

    @testset "classification: (system, version, level) の完全一致" begin
        d = synthetic_quarterly_dict()
        for (k, v) in (("system", "other"), ("version", "2"), ("level", "aggregated"))
            md = _pne_mapping_dict("ccc_hypothetical_quarterly.json")
            md["source_classification"][k] = v
            r = _check(d, cross_model_mapping_from_dict(md))
            @test _codes(r) == [:classification_mismatch]
            @test r.classification_status === :rejected
        end
    end

    # ---- sector 割当（設計 §8.4） ---------------------------------------------
    @testset "sector: 未知 sector・重複割当・unmapped の宣言" begin
        d = synthetic_quarterly_dict()
        base_md = _pne_mapping_dict("ccc_hypothetical_quarterly.json")

        md = deepcopy(base_md)
        push!(md["groups"][1]["members"], Dict{String, Any}("sector_id" => "ghost_sector", "weight" => 0.1))
        @test _codes(_check(d, cross_model_mapping_from_dict(md))) == [:unknown_source_sector]

        # phone_assembly を member と producer set の両方へ割り当てる。producer set 側では
        # phone_assembly の産出低下が DD-6 違反にもなるため、両方を同時に報告する（全件列挙）
        md = deepcopy(base_md)
        md["groups"][1]["producer_set"] = Any["chip_fab", "phone_assembly"]
        r_dup = _check(d, cross_model_mapping_from_dict(md))
        @test Set(_codes(r_dup)) == Set([:duplicate_sector_assignment, :own_supply_constraint_present])
        @test only(filter(x -> x.code === :duplicate_sector_assignment, r_dup.rejections)).subject_ids ==
              ["phone_assembly"]

        md = deepcopy(base_md)
        md["declared_unmapped_source_sectors"] = Any[]
        r = _check(d, cross_model_mapping_from_dict(md))
        @test _codes(r) == [:unmapped_sector_undeclared]
        @test r.rejections[1].subject_ids == ["raw_material"]

        md = deepcopy(base_md)
        md["declared_unmapped_source_sectors"] = Any["raw_material", "chip_fab"]
        @test _codes(_check(d, cross_model_mapping_from_dict(md))) == [:unmapped_sector_undeclared]

        r_ok = _check(d, _pne_mapping("ccc_hypothetical_quarterly.json"))
        @test r_ok.unmapped_source_sectors == ["raw_material"]
        @test :unmapped_source_sectors_present in _warning_codes(r_ok)
        @test r_ok.source_sectors_total == 4
        @test r_ok.member_sectors == ["auto_assembly", "phone_assembly"]
        @test r_ok.producer_set_sectors == ["chip_fab"]
    end

    @testset "sector: unmapped 部門は 0 としても 1 としても入力に使わない" begin
        m = _pne_mapping("ccc_hypothetical_quarterly.json")
        d1 = synthetic_quarterly_dict()
        d2 = deepcopy(d1)
        raw = only(filter(s -> s["sector_id"] == "raw_material", d2["sectors"]))
        raw["periods"] = _pne_points([0.1, 0.2, 0.3, 0.4, 0.9, 1.0])
        a1, a2 = _artifact(d1), _artifact(d2)
        p1 = apply_cross_model_mapping(a1, m, check_cross_model_compatibility(a1, m))
        p2 = apply_cross_model_mapping(a2, m, check_cross_model_compatibility(a2, m))
        @test p1[1].values == p2[1].values
    end

    # ---- weight・集約（設計 §8.3） ------------------------------------------
    @testset "many-to-one 集約: −Σ w_j (1 − r_j)、再正規化しない" begin
        a = _artifact(synthetic_quarterly_dict())
        m = _pne_mapping("ccc_hypothetical_quarterly.json")
        r = check_cross_model_compatibility(a, m)
        paths = apply_cross_model_mapping(a, m, r)
        @test length(paths) == 1
        p = paths[1]
        @test p.target_group === :ext_demand_s2_customers
        @test p.value_semantics === :target_relative_change
        @test p.members == ["auto_assembly", "phone_assembly"]
        @test p.effective_weights == [0.15, 0.25]
        auto = [1.0, 0.6, 0.7, 0.9, 1.0, 1.0]
        phone = [1.0, 0.8, 0.8, 1.0, 1.0, 1.0]
        expected = [(0.0 - 0.15 * (1.0 - auto[k])) - 0.25 * (1.0 - phone[k]) for k in 1:6]
        @test p.values == expected
        @test all(<=(0.0), p.values)
        # Σw = 0.4 で割っていない（再正規化しない）
        @test p.values[2] ≈ -0.11 atol = 1e-15
        @test p.covered_share == 0.4
        @test p.uncovered_share ≈ 0.6
        cov = only(r.group_coverage)
        @test cov.covered_share == 0.4
        @test :partial_target_coverage in _warning_codes(r)
        # members の宣言順に依存しない
        md = _pne_mapping_dict("ccc_hypothetical_quarterly.json")
        reverse!(md["groups"][1]["members"])
        m2 = cross_model_mapping_from_dict(md)
        @test cross_model_mapping_hash(m2) == cross_model_mapping_hash(m)
        @test apply_cross_model_mapping(a, m2, check_cross_model_compatibility(a, m2))[1].values ==
              p.values
    end

    @testset "weight: 欠落・非正・Σw > 1・provenance 欠落は invalid_weights" begin
        d = synthetic_quarterly_dict()
        base_md = _pne_mapping_dict("ccc_hypothetical_quarterly.json")
        mutations = [
            md -> (md["groups"][1]["members"][1]["weight"] = nothing),
            md -> (md["groups"][1]["members"][1]["weight"] = 0.0),
            md -> (md["groups"][1]["members"][1]["weight"] = -0.1),
            md -> (md["groups"][1]["members"][1]["weight"] = 0.9),
            md -> (md["groups"][1]["weight_provenance"] = nothing),
            md -> (md["groups"][1]["weight_provenance"]["method"] = ""),
        ]
        for mutate! in mutations
            md = deepcopy(base_md)
            mutate!(md)
            @test _codes(_check(d, cross_model_mapping_from_dict(md))) == [:invalid_weights]
        end
        # 非有限の weight は JSON で表せず hash も計算できないため、Julia から直接構築しようと
        # しても member の構築時に拒否される（層(1)）
        @test_throws ArgumentError CrossModelGroupMember("auto_assembly", NaN)
        @test_throws ArgumentError CrossModelGroupMember("auto_assembly", Inf)
        @test_throws ArgumentError CrossModelGroupMember("auto_assembly", true)
        @test CrossModelGroupMember("auto_assembly", 1).weight === 1.0
    end

    @testset "weight basis と target concept: CCC が受理しない概念・basis" begin
        d = synthetic_quarterly_dict()
        # 派生需要に source_baseline_output は使えない
        md = _pne_mapping_dict("ccc_hypothetical_quarterly.json")
        md["groups"][1]["weight_basis"] = "source_baseline_output"
        for mem in md["groups"][1]["members"]
            mem["weight"] = nothing
        end
        @test _codes(_check(d, cross_model_mapping_from_dict(md))) == [:weight_basis_not_allowed]

        # 供給能力・総産出の概念は CCC が構造上表現しない（近い変数へ寄せない）
        for concept in ("sector_supply_capacity", "aggregate_realized_output")
            md = _pne_mapping_dict("ccc_hypothetical_quarterly.json")
            g = md["groups"][1]
            g["target_group"] = "ext_demand_s2_customers"
            g["target_concept"] = concept
            g["weight_basis"] = "source_baseline_output"
            g["producer_set"] = Any[]
            g["customer_scope"] = nothing
            for mem in g["members"]
                mem["weight"] = nothing
            end
            md["declared_unmapped_source_sectors"] = Any["chip_fab", "raw_material"]
            r = _check(d, cross_model_mapping_from_dict(md))
            @test _codes(r) == [:unmapped_target_concept]
            @test occursin("構造上表現しません", r.rejections[1].detail)
        end

        # 受理される概念でも profile に無い target group は表現しない
        md = _pne_mapping_dict("ccc_hypothetical_quarterly.json")
        md["groups"][1]["target_group"] = "price_s1_customers"
        r = _check(d, cross_model_mapping_from_dict(md))
        @test _codes(r) == [:unmapped_target_concept]
        @test r.target_groups_without_source == [:ext_demand_s2_customers, :ext_demand_s3_customers]
    end

    @testset "source_baseline_output: baseline 欠落・単位不一致を非加重平均へ落とさない" begin
        mk(concept_basis_members) = begin
            md = _pne_mapping_dict("ccc_hypothetical_quarterly.json")
            g = md["groups"][1]
            g["target_concept"] = "aggregate_realized_output"
            g["weight_basis"] = concept_basis_members[1]
            g["members"] = concept_basis_members[2]
            g["producer_set"] = Any[]
            g["customer_scope"] = nothing
            md["declared_unmapped_source_sectors"] = concept_basis_members[3]
            cross_model_mapping_from_dict(md)
        end
        members2 = Any[
            Dict{String, Any}("sector_id" => "auto_assembly", "weight" => nothing),
            Dict{String, Any}("sector_id" => "phone_assembly", "weight" => nothing),
        ]
        unm = Any["chip_fab", "raw_material"]
        d = synthetic_quarterly_dict()
        only(filter(s -> s["sector_id"] == "auto_assembly", d["sectors"]))["baseline_output"] = nothing
        r = _check(d, mk(("source_baseline_output", members2, unm)))
        @test Set(_codes(r)) == Set([:unmapped_target_concept, :baseline_output_missing])

        d = synthetic_quarterly_dict()
        only(filter(s -> s["sector_id"] == "auto_assembly", d["sectors"]))["baseline_output"]["unit"] = "JPY billion"
        r = _check(d, mk(("source_baseline_output", members2, unm)))
        @test Set(_codes(r)) == Set([:unmapped_target_concept, :baseline_output_unit_mismatch])

        d = synthetic_quarterly_dict()
        r = _check(d, mk(("direct_one_to_one", members2, unm)))
        @test Set(_codes(r)) == Set([:unmapped_target_concept, :invalid_weights])
    end

    @testset "集約 helper: baseline 加重は PNE の aggregate_path と一致する" begin
        a = load_pne_sector_output_path(
            joinpath(PNE_TEST_ROOT, "sector_output_path", "v1", "representative.json"),
        )
        ratios = [s.realized_output_ratio for s in a.sectors]
        weights = DME._cross_model_baseline_weights([s.baseline_output.value for s in a.sectors])
        values, semantics = DME._cross_model_group_values(:source_baseline_output, ratios, weights)
        @test semantics === :group_realized_output_ratio
        @test all(abs.(values .- a.aggregate_realized_output_ratio) .<= 1e-12)
        v1, s1 = DME._cross_model_group_values(:direct_one_to_one, [ratios[1]], [1.0])
        @test v1 == ratios[1] && s1 === :group_realized_output_ratio
        vd, sd = DME._cross_model_group_values(:declared_target_share, ratios[1:2], [0.5, 0.25])
        @test sd === :target_relative_change
        @test vd == [(0.0 - 0.5 * (1 - ratios[1][k])) - 0.25 * (1 - ratios[2][k]) for k in 1:5]
        @test_throws ArgumentError DME._cross_model_baseline_weights([0.0, 0.0])
    end

    # ---- DD-6（producer set）------------------------------------------------
    @testset "DD-6: producer set が制約されていれば派生需要として読まない" begin
        d = synthetic_quarterly_dict()
        chip = only(filter(s -> s["sector_id"] == "chip_fab", d["sectors"]))
        chip["periods"] = _pne_points([1.0, 0.7, 1.0, 1.0, 1.0, 1.0])
        r = _check(d, _pne_mapping("ccc_hypothetical_quarterly.json"))
        @test _codes(r) == [:own_supply_constraint_present]
        @test r.rejections[1].subject_ids == ["chip_fab"]

        md = _pne_mapping_dict("ccc_hypothetical_quarterly.json")
        md["groups"][1]["producer_set"] = Any[]
        md["declared_unmapped_source_sectors"] = Any["chip_fab", "raw_material"]
        @test _codes(_check(synthetic_quarterly_dict(), cross_model_mapping_from_dict(md))) ==
              [:producer_set_undeclared]

        md["groups"][1]["producer_set_absent_reason"] = "target 製品の生産部門は架空 network に含まれない"
        r = _check(synthetic_quarterly_dict(), cross_model_mapping_from_dict(md))
        @test r.decision === :accepted
        @test :producer_set_absent in _warning_codes(r)
    end

    # ---- 時間軸（設計 §9） ---------------------------------------------------
    @testset "時間: quarter は恒等、month は 3 か月の算術平均" begin
        r = _check(synthetic_quarterly_dict(), _pne_mapping("ccc_hypothetical_quarterly.json"))
        @test r.aggregation_rule === :identity
        @test r.timing_quarters == 6
        @test r.calendar_anchor == Date(2025, 1, 1)

        md = _pne_mapping_dict("ccc_hypothetical_quarterly.json")
        md["time"]["expected_source_period_unit"] = "month"
        md["time"]["aggregation_rule"] = "mean_of_three_months"
        m = cross_model_mapping_from_dict(md)
        a = _artifact(synthetic_monthly_dict())
        r = check_cross_model_compatibility(a, m)
        @test r.decision === :accepted
        @test r.aggregation_rule === :mean_of_three_months
        @test r.timing_quarters == 2
        p = only(apply_cross_model_mapping(a, m, r))
        @test p.anchor_quarter == CalendarQuarter(2025, 2)
        auto_q = [(0.4 + 0.7 + 0.8) / 3, 1.0]
        phone_q = [(0.7 + 0.7 + 1.0) / 3, 1.0]
        @test p.values == [(0.0 - 0.15 * (1.0 - auto_q[k])) - 0.25 * (1.0 - phone_q[k]) for k in 1:2]
        @test DME._cross_model_quarterly_ratios([0.3, 0.6, 0.9, 1.0, 1.0, 1.0], :month) ==
              [(0.3 + 0.6 + 0.9) / 3, 1.0]

        # mapping が month を想定し artifact が quarter なら拒否
        @test _codes(check_cross_model_compatibility(_artifact(synthetic_quarterly_dict()), m)) ==
              [:unsupported_source_period_unit]
    end

    @testset "時間: 受理しない period_unit・anchor・部分四半期・未回復" begin
        m_q = _pne_mapping("ccc_hypothetical_quarterly.json")
        for unit in ("year", "week", "day")
            d = synthetic_quarterly_dict()
            d["time"]["period_unit"] = unit
            @test _codes(_check(d, m_q)) == [:unsupported_source_period_unit]
        end
        d = synthetic_quarterly_dict()
        d["time"]["period_unit"] = "baseline_period"
        @test _codes(_check(d, m_q)) == [:ambiguous_source_period_unit]

        # vendor した representative（year）は CCC へ入らない
        rep = load_pne_sector_output_path(
            joinpath(PNE_TEST_ROOT, "sector_output_path", "v1", "representative.json"),
        )
        @test :unsupported_source_period_unit in _codes(check_cross_model_compatibility(rep, m_q))

        for (anchor, code) in (
            ("2025/01/01", :calendar_anchor_invalid),
            ("2025-01-01T00:00:00Z", :calendar_anchor_invalid),
            ("2025-13-01", :calendar_anchor_invalid),
            ("2025-02-01", :calendar_anchor_misaligned),
            ("2025-04-15", :calendar_anchor_misaligned),
        )
            d = synthetic_quarterly_dict()
            d["time"]["calendar_anchor"] = anchor
            @test _codes(_check(d, m_q)) == [code]
        end
        # quarter source は anchor 無しでも X2 は受理する（配置の要否は #282 が Scenario 基準で決める）
        d = synthetic_quarterly_dict()
        d["time"]["calendar_anchor"] = nothing
        r = _check(d, m_q)
        @test r.decision === :accepted
        @test r.calendar_anchor === nothing
        @test only(apply_cross_model_mapping(_artifact(d), m_q, r)).anchor_quarter === nothing

        md = _pne_mapping_dict("ccc_hypothetical_quarterly.json")
        md["time"]["expected_source_period_unit"] = "month"
        md["time"]["aggregation_rule"] = "mean_of_three_months"
        m_m = cross_model_mapping_from_dict(md)
        @test _codes(_check(synthetic_monthly_dict(; calendar_anchor = nothing), m_m)) ==
              [:calendar_anchor_required]
        @test _codes(_check(synthetic_monthly_dict(; n_months = 7), m_m)) == [:partial_quarter]
        @test _codes(_check(synthetic_monthly_dict(; calendar_anchor = "2025-05-01"), m_m)) ==
              [:calendar_anchor_misaligned]

        # horizon 末の四半期で member が回復していなければ拒否（horizon 後を仮定しない）
        d = synthetic_quarterly_dict()
        auto = only(filter(s -> s["sector_id"] == "auto_assembly", d["sectors"]))
        auto["periods"] = _pne_points([1.0, 0.6, 0.7, 0.9, 1.0, 0.95])
        r = _check(d, m_q)
        @test _codes(r) == [:upstream_path_unrecovered_at_horizon_end]
        @test r.rejections[1].subject_ids == ["auto_assembly"]
        @test r.timing_quarters === nothing
    end

    # ---- 上流の状態 -------------------------------------------------------
    @testset "上流の状態: unsupported・error 警告は拒否、その他の警告は転記" begin
        m = _pne_mapping("ccc_hypothetical_quarterly.json")
        d = synthetic_quarterly_dict()
        d["status"] = "unsupported"
        d["time"]["horizon_periods"] = 8
        d["unsupported_reasons"] = Any[Dict{String, Any}("code" => "horizon_incomplete", "message" => "stopped early")]
        @test :upstream_status_unsupported in _codes(_check(d, m))

        warn(sev) = Dict{String, Any}(
            "code" => "w_$(sev)",
            "message" => "fabricated $(sev)",
            "severity" => sev,
            "source" => "source_dynamic_artifact",
        )
        d = synthetic_quarterly_dict()
        d["warnings"] = Any[warn("error"), warn("info")]
        r = _check(d, m)
        @test _codes(r) == [:upstream_error_warning]
        @test :upstream_warning_carried in _warning_codes(r)

        d = synthetic_quarterly_dict()
        d["source_provenance"]["edge_estimation_status_counts"] = Dict{String, Any}("estimated" => 3)
        @test :upstream_estimated_inputs in _warning_codes(_check(d, m))
    end

    # ---- report ------------------------------------------------------------
    @testset "report: 1 回の判定で全件を列挙する" begin
        md = _pne_mapping_dict("ccc_same_economy_jp_like.json")
        md["source_classification"]["version"] = "2015"
        md["groups"][1]["members"][1]["weight"] = 2.0
        push!(md["groups"][1]["members"], Dict{String, Any}("sector_id" => "JP-TEST-999", "weight" => 0.1))
        d = jp_like_dict()
        d["time"]["calendar_anchor"] = "2025-02-01"
        r = _check(d, cross_model_mapping_from_dict(md))
        @test r.decision === :rejected
        @test Set(_codes(r)) == Set([
            :geography_mismatch,
            :classification_mismatch,
            :unknown_source_sector,
            :invalid_weights,
            :calendar_anchor_misaligned,
        ])
        dd = cross_model_compatibility_report_to_dict(r)
        @test dd["decision"] == "rejected"
        @test length(dd["rejections"]) == 5
        @test all(x -> x["stage"] == "compatibility", dd["rejections"])
    end

    @testset "report: hash の決定性と監査属性の除外・golden" begin
        m = _pne_mapping("ccc_hypothetical_quarterly.json")
        r1 = _check(synthetic_quarterly_dict(), m)
        r2 = _check(synthetic_quarterly_dict(), m)
        @test cross_model_compatibility_report_hash(r1) == cross_model_compatibility_report_hash(r2)
        @test occursin(r"^sha256:[0-9a-f]{64}$", cross_model_compatibility_report_hash(r1))

        # 同じ内容を別のバイト列（ファイル）から受理しても report hash は同じ
        path = joinpath(mktempdir(), "artifact.json")
        write(path, json_write(synthetic_quarterly_dict()))
        r_file = check_cross_model_compatibility(load_pne_sector_output_path(path), m)
        @test r_file.upstream.source_bytes_sha256 !== nothing
        @test cross_model_compatibility_report_hash(r_file) == cross_model_compatibility_report_hash(r1)

        golden(name) = read(joinpath(PNE_TEST_ROOT, "golden", name), String)
        @test canonical_json_string(cross_model_compatibility_report_to_dict(r1; include_audit = false)) ==
              golden("report_ccc_hypothetical_quarterly.json")
        r_jp = _check(jp_like_dict(), _pne_mapping("ccc_same_economy_jp_like.json"))
        @test canonical_json_string(cross_model_compatibility_report_to_dict(r_jp; include_audit = false)) ==
              golden("report_jp_like_same_economy.json")
        a = _artifact(synthetic_quarterly_dict())
        paths = apply_cross_model_mapping(a, m, check_cross_model_compatibility(a, m))
        @test canonical_json_string(Dict{String, Any}("paths" => Any[mapped_group_path_to_dict(p) for p in paths])) ==
              golden("mapped_ccc_hypothetical_quarterly.json")

        # decision と rejections の不整合な report は構築できない
        args = [getfield(r_jp, f) for f in fieldnames(CrossModelCompatibilityReport)]
        args[1] = :accepted
        @test_throws ArgumentError CrossModelCompatibilityReport(args...)
    end

    # ---- X3: 適用の前提 ------------------------------------------------------
    @testset "X3: accepted かつ同じ入力から再計算した report でなければ適用しない" begin
        m = _pne_mapping("ccc_hypothetical_quarterly.json")
        a = _artifact(synthetic_quarterly_dict())
        r = check_cross_model_compatibility(a, m)

        jp = _artifact(jp_like_dict())
        m_jp = _pne_mapping("ccc_same_economy_jp_like.json")
        r_jp = check_cross_model_compatibility(jp, m_jp)
        msg = _decode_error(() -> apply_cross_model_mapping(jp, m_jp, r_jp))
        @test startswith(msg, "cross_model_mapping_rejected")

        # 別の artifact の report を流用できない
        d2 = synthetic_quarterly_dict()
        only(filter(s -> s["sector_id"] == "phone_assembly", d2["sectors"]))["periods"] =
            _pne_points([1.0, 0.5, 0.8, 1.0, 1.0, 1.0])
        a2 = _artifact(d2)
        msg = _decode_error(() -> apply_cross_model_mapping(a2, m, r))
        @test startswith(msg, "provenance_chain_broken")

        p = only(apply_cross_model_mapping(a, m, r))
        @test p.upstream_content_hash == a.content_hash
        @test p.mapping_hash == cross_model_mapping_hash(m)
        @test p.compatibility_report_hash == cross_model_compatibility_report_hash(r)
        @test p.claim_scope === :hypothetical_fictional
        @test p.transmission_mode === :hypothetical_override
        @test p.target_model === :capex_credit_cycle
        dp = mapped_group_path_to_dict(p)
        @test dp["uncovered_share_treatment"] == "not_covered_by_upstream_input"
        @test dp["anchor_quarter"] == "2025Q1"
    end

    # ---- mapping artifact（設計 §8.2） -------------------------------------
    @testset "mapping artifact: round-trip・hash・fail closed decode" begin
        m = _pne_mapping("ccc_hypothetical_quarterly.json")
        d = cross_model_mapping_to_dict(m)
        @test cross_model_mapping_to_dict(cross_model_mapping_from_dict(d)) == d
        h = cross_model_mapping_hash(m)
        @test occursin(r"^sha256:[0-9a-f]{64}$", h)
        d2 = deepcopy(d)
        d2["notes"] = "changed notes"
        @test cross_model_mapping_hash(cross_model_mapping_from_dict(d2)) == h
        d3 = deepcopy(d)
        d3["assumptions"] = Any["changed assumption"]
        @test cross_model_mapping_hash(cross_model_mapping_from_dict(d3)) != h

        fail(mutate!) = begin
            dd = deepcopy(d)
            mutate!(dd)
            _decode_error(() -> cross_model_mapping_from_dict(dd))
        end
        @test startswith(fail(dd -> (dd["schema_version"] = "dme.cross-model-mapping/2.0.0")), "unsupported_cross_model_mapping_schema_version")
        @test startswith(fail(dd -> (dd["extra"] = 1)), "invalid_cross_model_mapping")
        @test startswith(fail(dd -> delete!(dd, "declared_unmapped_source_sectors")), "invalid_cross_model_mapping")
        @test startswith(fail(dd -> (dd["transmission"]["mode"] = "auto")), "invalid_cross_model_mapping")
        @test startswith(fail(dd -> delete!(dd["transmission"], "mode")), "invalid_cross_model_mapping")
        @test startswith(fail(dd -> (dd["source_contract"] = "production-network-sector-output-path/v2")), "invalid_cross_model_mapping")
        @test startswith(fail(dd -> (dd["groups"][1]["customer_scope"] = nothing)), "invalid_cross_model_mapping")
        @test startswith(fail(dd -> (dd["groups"][1]["identifying_assumptions"] = Any[])), "invalid_cross_model_mapping")
        @test startswith(fail(dd -> (dd["groups"][1]["members"] = Any[])), "invalid_cross_model_mapping")
        @test startswith(fail(dd -> (dd["groups"][1]["members"][1]["weight"] = "0.2")), "invalid_cross_model_mapping")
        @test startswith(fail(dd -> push!(dd["groups"], deepcopy(dd["groups"][1]))), "invalid_cross_model_mapping")
        @test startswith(fail(dd -> (dd["time"]["aggregation_rule"] = "mean_of_three_months")), "invalid_cross_model_mapping")
        @test startswith(fail(dd -> (dd["time"]["expected_source_period_unit"] = "year")), "invalid_cross_model_mapping")
        @test startswith(fail(dd -> (dd["time"]["partial_quarter"] = "drop")), "invalid_cross_model_mapping")
        @test startswith(fail(dd -> (dd["time"]["post_horizon"] = "hold_last")), "invalid_cross_model_mapping")
        @test startswith(fail(dd -> (dd["declared_unmapped_source_sectors"] = Any["raw_material", "raw_material"])), "invalid_cross_model_mapping")
        @test startswith(
            fail(dd -> begin
                g = dd["groups"][1]
                g["target_concept"] = "aggregate_realized_output"
                g["customer_scope"] = nothing
            end),
            "invalid_cross_model_mapping",
        )
    end

    @testset "拒否・警告の型: 語彙と detail の規律" begin
        @test_throws ArgumentError CrossModelRejection(; code = :not_a_code, detail = "x")
        @test_throws ArgumentError CrossModelRejection(; code = :geography_mismatch, detail = "x", stage = :other)
        @test_throws ArgumentError CrossModelRejection(; code = :geography_mismatch, detail = "")
        @test_throws ArgumentError CrossModelRejection(; code = :geography_mismatch, detail = "影響が無いため")
        @test_throws ArgumentError CrossModelRejection(; code = :unmapped_target_concept, detail = "対応が無い")
        @test CrossModelRejection(; code = :unmapped_target_concept, detail = "構造上表現しない").code ===
              :unmapped_target_concept
        @test_throws ArgumentError CrossModelWarning(; code = :geography_mismatch, detail = "x")
        @test CrossModelWarning(; code = :partial_target_coverage, detail = "x", subject_ids = ["b", "a"]).subject_ids ==
              ["a", "b"]
    end
end
