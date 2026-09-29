# Japan Fiscal Scenario Lab の deterministic E2E・fixture・artifact validation・Market Analyzer handoff
# （Issue #277）のテスト。
#
#   - representative fixture（test/fixtures/japan_fiscal/inputs/）で public API から artifact まで完走する
#   - 5 family を representable / partial / not_representable のいずれかとして明示的に検証する
#   - 決定論（同一入力 2 回で canonical artifact が一致・入力順 / Dict 挿入順に非依存）
#   - canonical serialization round-trip・保存済み bundle からの replay
#   - semantic guardrails（FRE score を magnitude に使わない・missing/unavailable を 0 にしない・
#     observed / assumed / model_implied を混ぜない・forecast / probability と呼ばない・
#     not_representable を成功結果に見せない）
#   - consumer fixture（test/fixtures/japan_fiscal/handoff/v1/）が versioned に公開され、schemas/ の
#     JSON Schema だけで decode でき、再生成結果と一致し、fail closed で読めること
#   - claim-level 契約の #277 向け handoff requirements（H-13–H-16）
#   - 入力エラー（未対応の unit / horizon ほか）が artifact を生成しないこと
#
# 本テストは FRE・Market Analyzer・Python・ネットワークを必要としない。fixture の再生成は
# test/fixtures/japan_fiscal/regenerate.jl（手動実行）が行う。
#
# 設計: docs/architecture/japan_fiscal_scenario_handoff.md・ADR 0025

using Test
using DME
using Dates
const JSON3 = DME.JSON3

@isdefined(jf_fixture_cases) ||
    include(joinpath(@__DIR__, "fixtures", "japan_fiscal", "japan_fiscal_fixture_cases.jl"))
@isdefined(jf_schema_errors) ||
    include(joinpath(@__DIR__, "fixtures", "japan_fiscal", "json_schema_subset.jl"))

_jfe_plain(x) = DME._jf_json_to_plain(JSON3.read(String(canonical_json_bytes(x))))
_jfe_read(path) = DME._jf_json_to_plain(JSON3.read(read(path, String)))
_jfe_bytes(x) = canonical_json_bytes(x)

"JSON 木を辿り、各キーの位置（`\$.a.b[1].c`）を返す。"
function _jfe_key_paths(x, path = "\$", out = Tuple{String, String}[])
    if x isa AbstractDict
        for (k, v) in x
            push!(out, (path, String(k)))
            _jfe_key_paths(v, "$(path).$(k)", out)
        end
    elseif x isa AbstractVector
        for (i, v) in enumerate(x)
            _jfe_key_paths(v, "$(path)[$(i)]", out)
        end
    end
    return out
end

"プラットフォーム差（BLAS 等による浮動小数点の最終桁）で変わりうる hash フィールドを再帰的に除く。"
function _jfe_strip_float_hashes(x)
    platform_keys = ("sha256", "result_content_hash", "artifact_content_hash", "bundle_content_hash")
    x isa AbstractDict && return Dict{String, Any}(
        k => _jfe_strip_float_hashes(v) for (k, v) in x if !(k in platform_keys)
    )
    x isa AbstractVector && return Any[_jfe_strip_float_hashes(v) for v in x]
    return x
end

function _jfe_tolerance_mismatches(a, b; rtol = 1e-9, atol = 1e-12)
    mismatches = String[]
    DME._jf_compare_json!(a, b, "\$", rtol, atol, mismatches, Ref(0.0))
    return mismatches
end

function _jfe_error_msg(f)
    try
        f()
    catch e
        e isa ArgumentError || rethrow()
        return e.msg
    end
    return nothing
end

"committed bundle を index の bundle hash を再計算しながら書き換えるためのヘルパ。"
function _jfe_rewrite_index!(dir, f!)
    idx = _jfe_read(joinpath(dir, "index.json"))
    f!(idx)
    idx["bundle_content_hash"] = DME._japan_fiscal_artifact_content_hash(idx, "bundle_content_hash")
    write(joinpath(dir, "index.json"), _jfe_bytes(idx))
    return nothing
end

function _jfe_copy_bundle()
    dst = joinpath(mktempdir(), "relocated", "bundle")
    mkpath(dirname(dst))
    cp(JF_HANDOFF_DIR, dst)
    return dst
end

const _JFE_CASES = jf_fixture_cases()
const _JFE_GENERATED_AT = jf_fixture_generated_at()
const _JFE_NEGATIVE_SOURCE = jf_fixture_negative_source_case_id()
const _JFE_BUILT = build_japan_fiscal_handoff(
    _JFE_CASES;
    generated_at = _JFE_GENERATED_AT,
    negative_source_case_id = _JFE_NEGATIVE_SOURCE,
)
_jfe_artifact(case_id) = _jfe_plain(_JFE_BUILT["artifacts/$(case_id).json"])
_jfe_case(case_id) = only(c for c in _JFE_CASES if c.case_id == case_id)

const _JFE_RESULT_SCHEMA = jf_load_schema("japan-fiscal-scenario-result-v2.schema.json")
const _JFE_SCENARIO_SCHEMA = jf_load_schema("japan-fiscal-scenario-v1.schema.json")
const _JFE_HANDOFF_SCHEMA = jf_load_schema("japan-fiscal-scenario-handoff-v1.schema.json")

@testset "Japan fiscal scenario deterministic E2E・consumer handoff（Issue #277）" begin

    # ---- representative fixture: public API → artifact ---------------------------
    @testset "representative fixture が public API から artifact まで完走する" begin
        @test length(_JFE_CASES) == length(jf_fixture_manifest()["cases"])
        for c in _JFE_CASES
            d = _jfe_artifact(c.case_id)
            a = japan_fiscal_artifact_from_dict(d)
            executed = :representable in c.tags || :partial in c.tags
            @test (a isa JapanFiscalScenarioResult) == executed
            @test a.family === c.scenario.family
            @test a.model === c.model
            @test a.scenario_id == c.scenario.scenario_id
            for code in (:missing_required_assumption, :conversion_not_implemented)
                code in c.tags && @test a isa JapanFiscalScenarioRejection && a.rejection_code === code
            end
            (:not_representable in c.tags || :partial_not_adopted in c.tags) &&
                @test a isa JapanFiscalScenarioRejection && a.rejection_code === :not_adopted
        end
    end

    # ---- 5 family の representability を明示的に検証する ---------------------------
    @testset "5 family が representable / partial / not_representable として明示検証される" begin
        for f in JAPAN_FISCAL_SCENARIO_FAMILIES
            fam = [c for c in _JFE_CASES if c.scenario.family === f]
            @test !isempty(fam)
            reprs = Set{Symbol}()
            for c in fam
                a = japan_fiscal_artifact_from_dict(_jfe_artifact(c.case_id))
                @test a.coverage.representability === japan_fiscal_representability(f, c.model)
                push!(reprs, a.coverage.representability)
            end
            # 各 family に実行された result と not_representable の拒否が少なくとも 1 つずつある
            @test any(c -> _jfe_artifact(c.case_id)["artifact_kind"] == "result", fam)
            @test :not_representable in reprs
            @test length(reprs) >= 2
            # 各 family に必須概念の未指定（missing explicit assumption）の拒否がある
            @test any(c -> :missing_required_assumption in c.tags, fam)
        end
        # representable セルを持つ family（財政再建・高成長）は representable の通常ケースを持つ
        for f in (:fiscal_consolidation, :high_growth_productivity)
            @test any(
                c -> c.scenario.family === f && :representable in c.tags,
                _JFE_CASES,
            )
        end
        # 採用 14 セルがすべて実行されている
        adopted = Set(
            (m.family, m.model) for m in DME.JAPAN_FISCAL_MODEL_MAPPINGS if m.adoption !== :not_adopted
        )
        executed = Set(
            (c.scenario.family, c.model) for
            c in _JFE_CASES if _jfe_artifact(c.case_id)["artifact_kind"] == "result"
        )
        @test adopted == executed
    end

    # ---- 決定論 -------------------------------------------------------------------
    @testset "同一入力 2 回で canonical artifact が一致する" begin
        again = build_japan_fiscal_handoff(
            jf_fixture_cases();
            generated_at = _JFE_GENERATED_AT,
            negative_source_case_id = _JFE_NEGATIVE_SOURCE,
        )
        @test Set(keys(again)) == Set(keys(_JFE_BUILT))
        for k in keys(_JFE_BUILT)
            @test _jfe_bytes(again[k]) == _jfe_bytes(_JFE_BUILT[k])
        end

        # generated_at を固定しなくても content hash は一致する（generated_at は hash 対象外）
        sc = _jfe_case("f5-ccc").scenario
        r1 = japan_fiscal_run(:capex_credit_cycle, sc)
        r2 = japan_fiscal_run(:capex_credit_cycle, sc; generated_at = DateTime(2031, 1, 1))
        @test r1.result_content_hash == r2.result_content_hash
        @test r2.generated_at == "2031-01-01T00:00:00Z"
    end

    @testset "入力順・Dict 挿入順に依存しない" begin
        base = _jfe_case("f1-ccc").scenario
        fre = base.fre_context
        rev(d) = Dict{String, Float64}(k => d[k] for k in reverse(sort(collect(keys(d)))))
        fre_reordered = JapanFiscalFREContext(;
            snapshot_id = fre.snapshot_id,
            as_of = fre.as_of,
            vintage_basis = fre.vintage_basis,
            regime_determination = fre.regime_determination,
            primary_regime = fre.primary_regime,
            regime_affinity = rev(fre.regime_affinity),
            regime_share = rev(fre.regime_share),
            regime_confidence = fre.regime_confidence,
            dimension_score = rev(fre.dimension_score),
            constraint_pressure = fre.constraint_pressure,
            dominant_drivers = reverse(fre.dominant_drivers),
            data_quality_score = fre.data_quality_score,
            methodology_version = fre.methodology_version,
            policy_version = fre.policy_version,
            notes = fre.notes,
        )
        reordered = JapanFiscalScenario(;
            scenario_id = base.scenario_id,
            family = base.family,
            name = base.name,
            notes = base.notes,
            fre_context = fre_reordered,
            assumptions = reverse(base.assumptions),
            provenance = base.provenance,
        )
        @test japan_fiscal_scenario_content_hash(reordered) == japan_fiscal_scenario_content_hash(base)
        for model in (:capex_credit_cycle, :new_keynesian, :keen)
            a = japan_fiscal_run(model, base; generated_at = _JFE_GENERATED_AT)
            b = japan_fiscal_run(model, reordered; generated_at = _JFE_GENERATED_AT)
            @test _jfe_bytes(to_dict(a)) == _jfe_bytes(to_dict(b))
        end

        # scenario を JSON 経由で読み戻してから実行しても同一 artifact
        sc = _jfe_case("f2-sim").scenario
        back = japan_fiscal_scenario_from_dict(_jfe_plain(to_dict(sc)))
        @test _jfe_bytes(to_dict(japan_fiscal_run(:sim, back; generated_at = _JFE_GENERATED_AT))) ==
              _jfe_bytes(_JFE_BUILT["artifacts/f2-sim.json"])
    end

    # ---- canonical serialization round-trip ------------------------------------------
    @testset "canonical serialization round-trip（H-14）" begin
        for c in _JFE_CASES
            d = _jfe_artifact(c.case_id)
            a = japan_fiscal_artifact_from_dict(d)
            @test _jfe_bytes(to_dict(a)) == _jfe_bytes(d)
            # claim_level と unsupported 一覧が round-trip で消えない（H-14）
            @test a.coverage.claim_level === Symbol(d["coverage"]["claim_level"])
            @test String.(a.coverage.unsupported_concepts) == d["coverage"]["unsupported_concepts"]
            @test String.(a.coverage.unsupported_outputs) == d["coverage"]["unsupported_outputs"]
            @test String.(a.coverage.uncovered_channels) == d["coverage"]["uncovered_channels"]
            if a isa JapanFiscalScenarioResult
                @test a.diagnostics.claim_level === a.coverage.claim_level
            end
        end
        for (sid, _) in jf_fixture_scenarios()
            d = _jfe_plain(_JFE_BUILT["scenarios/$(sid).json"])
            @test _jfe_bytes(to_dict(japan_fiscal_scenario_from_dict(d))) == _jfe_bytes(d)
        end
    end

    # ---- replay -------------------------------------------------------------------------
    @testset "保存済み artifact から主要 result を再構築できる（replay）" begin
        # 同一プロセスで書いた bundle: 別ディレクトリへ移しても hash まで完全一致で replay できる
        dir = joinpath(mktempdir(), "written")
        write_japan_fiscal_handoff(
            dir,
            _JFE_CASES;
            generated_at = _JFE_GENERATED_AT,
            negative_source_case_id = _JFE_NEGATIVE_SOURCE,
        )
        moved = joinpath(mktempdir(), "moved")
        mv(dir, moved)
        bundle = load_japan_fiscal_handoff(moved)
        for c in _JFE_CASES
            rep = replay_japan_fiscal_handoff_case(bundle, c.case_id)
            @test rep.exact_match
            @test rep.within_tolerance
            @test isempty(rep.mismatches)
        end
        # 上書きしない
        @test_throws ArgumentError write_japan_fiscal_handoff(
            moved,
            _JFE_CASES;
            generated_at = _JFE_GENERATED_AT,
        )

        # commit 済み bundle（別プラットフォームで生成されうる）: 数値以外は完全一致、数値は許容誤差内
        committed = load_japan_fiscal_handoff(_jfe_copy_bundle())
        for c in _JFE_CASES
            rep = replay_japan_fiscal_handoff_case(committed, c.case_id)
            @test rep.within_tolerance
            isempty(rep.mismatches) || @info "replay mismatches" c.case_id rep.mismatches
            rep.artifact_kind === :rejection && @test rep.exact_match
        end
        @test_throws ArgumentError replay_japan_fiscal_handoff_case(committed, "no-such-case")
    end

    # ---- consumer fixture（handoff/v1）-----------------------------------------------------
    @testset "consumer fixture が versioned に公開され fail closed で読める" begin
        bundle = load_japan_fiscal_handoff(JF_HANDOFF_DIR)
        idx = bundle.index
        @test idx["schema_version"] == JAPAN_FISCAL_HANDOFF_SCHEMA_VERSION
        @test idx["contract_versions"]["result_artifact"] == JAPAN_FISCAL_RESULT_ARTIFACT_SCHEMA_VERSION
        @test length(bundle.artifacts) == length(_JFE_CASES)
        @test Set(keys(bundle.negative_errors)) == Set(String.(JAPAN_FISCAL_HANDOFF_NEGATIVE_KINDS))

        # 最低限の中身: catalog / scenario metadata・explicit assumptions・FRE context identity・
        # model / mapping versions・baseline + scenario・diagnostics・caveats / representability
        @test length(idx["families"]) == 5
        @test haskey(bundle.contracts["scenario_schema_contract"], "catalog")
        @test haskey(bundle.contracts["capability_matrix"], "mappings")
        r = bundle.artifact_dicts["f5-ccc"]
        for k in (
            "assumed",
            "observed",
            "fre_context_identity",
            "adapter_contract_version",
            "capability_contract_version",
            "parameter_identity_hash",
            "model_implied",
            "diagnostics",
            "coverage",
            "warnings",
        )
            @test haskey(r, k)
        end
        @test !isempty(r["coverage"]["major_caveats"])
        @test haskey(r["model_implied"], "baseline") && haskey(r["model_implied"], "scenario")

        # 再生成（in-memory）と commit 済みファイルが一致する（fixture の drift 検出）
        present = Set{String}()
        for (root, _, fs) in walkdir(JF_HANDOFF_DIR)
            for f in fs
                startswith(f, ".") && continue  # .DS_Store 等は bundle の内容ではない
                push!(present, join(splitpath(relpath(joinpath(root, f), JF_HANDOFF_DIR)), "/"))
            end
        end
        @test present == Set(keys(_JFE_BUILT))
        for (rel, content) in _JFE_BUILT
            committed = read(joinpath(JF_HANDOFF_DIR, split(rel, '/')...))
            if committed != _jfe_bytes(content)
                # 数値系列を含むファイルだけが、プラットフォーム差で最終桁が変わりうる
                d = _jfe_plain(content)
                has_floats = startswith(rel, "negative/") || rel == "index.json" ||
                             (haskey(d, "artifact_kind") && d["artifact_kind"] == "result")
                @test has_floats
                @test isempty(
                    _jfe_tolerance_mismatches(
                        _jfe_strip_float_hashes(DME._jf_json_to_plain(JSON3.read(String(committed)))),
                        _jfe_strip_float_hashes(d),
                    ),
                )
            end
        end

        # bundle に絶対パス・ローカルパスが含まれない
        for (root, _, fs) in walkdir(JF_HANDOFF_DIR)
            for f in fs
                startswith(f, ".") && continue
                s = read(joinpath(root, f), String)
                @test !occursin(homedir(), s)
                @test !occursin("/Users/", s)
                @test !occursin("/home/", s)
            end
        end
    end

    @testset "consumer fixture の改変・不整合を fail closed で拒否する" begin
        # 1. artifact のバイト改変（SHA-256 不一致）
        let dir = _jfe_copy_bundle()
            p = joinpath(dir, "artifacts", "f2-sim.json")
            write(p, replace(read(p, String), "\"horizon\":20" => "\"horizon\":21"))
            @test occursin("SHA-256", something(_jfe_error_msg(() -> load_japan_fiscal_handoff(dir)), ""))
        end
        # 2. index に列挙されていないファイル
        let dir = _jfe_copy_bundle()
            write(joinpath(dir, "artifacts", "extra.json"), "{}")
            @test occursin("列挙されていない", something(_jfe_error_msg(() -> load_japan_fiscal_handoff(dir)), ""))
        end
        # 3. index の要約を書き換える（bundle hash は再計算）
        let dir = _jfe_copy_bundle()
            _jfe_rewrite_index!(dir, idx -> begin
                c = only(x for x in idx["cases"] if x["case_id"] == "f2-islm")
                c["summary"]["claim_level"] = "direction_and_relative_timing"
            end)
            @test occursin("summary", something(_jfe_error_msg(() -> load_japan_fiscal_handoff(dir)), ""))
        end
        # 4. 内容と整合しない tag（not_representable の拒否を representable と称する）
        let dir = _jfe_copy_bundle()
            _jfe_rewrite_index!(dir, idx -> begin
                c = only(x for x in idx["cases"] if x["case_id"] == "f2-nk-not-representable")
                c["tags"] = ["representable"]
            end)
            @test occursin("tag", something(_jfe_error_msg(() -> load_japan_fiscal_handoff(dir)), ""))
        end
        # 5. bundle hash の改変
        let dir = _jfe_copy_bundle()
            idx = _jfe_read(joinpath(dir, "index.json"))
            idx["generated_at"] = "2030-01-01T00:00:00Z"  # hash 対象外
            idx["producer"]["component"] = "tampered"
            write(joinpath(dir, "index.json"), _jfe_bytes(idx))
            @test occursin(
                "bundle_content_hash",
                something(_jfe_error_msg(() -> load_japan_fiscal_handoff(dir)), ""),
            )
        end
        # 6. 未知の handoff schema version
        let dir = _jfe_copy_bundle()
            _jfe_rewrite_index!(dir, idx -> (idx["schema_version"] = "japan-fiscal-scenario-handoff/2.0.0"))
            @test occursin(
                "schema_version",
                something(_jfe_error_msg(() -> load_japan_fiscal_handoff(dir)), ""),
            )
        end
        # 7. negative artifact を正常 artifact に差し替えると「受理された」ことを検出する
        let dir = _jfe_copy_bundle()
            valid = read(joinpath(dir, "artifacts", "f2-sim.json"))
            write(joinpath(dir, "negative", "content_hash_mismatch.json"), valid)
            _jfe_rewrite_index!(dir, idx -> begin
                n = only(x for x in idx["negative_artifacts"] if x["name"] == "content_hash_mismatch")
                n["sha256"] = DME._jf_sha256_bytes(valid)
            end)
            @test occursin("受理されました", something(_jfe_error_msg(() -> load_japan_fiscal_handoff(dir)), ""))
        end
    end

    @testset "negative artifact が DME の decoder で拒否される" begin
        expected_fragment = Dict(
            "content_hash_mismatch" => "result_content_hash が再計算値と一致しません",
            "unsupported_schema_version" => "未対応の schema_version",
            "missing_required_field" => "必須フィールドが欠落しています",
            "claim_level_exceeds_contract" => "coverage が #285 registry",
            "not_representable_presented_as_result" => "adoption=:not_adopted",
            "missing_assumption_presented_as_zero" => "未指定のまま実行結果として扱われています",
        )
        @test Set(keys(expected_fragment)) == Set(String.(JAPAN_FISCAL_HANDOFF_NEGATIVE_KINDS))
        for (kind, fragment) in expected_fragment
            d = _jfe_plain(_JFE_BUILT["negative/$(kind).json"])
            msg = _jfe_error_msg(() -> japan_fiscal_artifact_from_dict(d))
            @test msg !== nothing && occursin(fragment, msg)
        end
    end

    # ---- JSON Schema（Julia 型なしで decode できる）--------------------------------------
    @testset "Market Analyzer が Julia 内部型なしで decode できる schema" begin
        for s in (_JFE_RESULT_SCHEMA, _JFE_SCENARIO_SCHEMA, _JFE_HANDOFF_SCHEMA)
            @test isempty(jf_schema_unsupported_keywords(s))
        end
        @test _JFE_RESULT_SCHEMA["x-contract-version"] == JAPAN_FISCAL_RESULT_ARTIFACT_SCHEMA_VERSION
        @test _JFE_SCENARIO_SCHEMA["x-contract-version"] == JAPAN_FISCAL_SCENARIO_SCHEMA_VERSION
        @test _JFE_HANDOFF_SCHEMA["x-contract-version"] == JAPAN_FISCAL_HANDOFF_SCHEMA_VERSION
        @test isfile(joinpath(JF_SCHEMA_DIR, "..", JAPAN_FISCAL_RESULT_ARTIFACT_JSON_SCHEMA))
        @test isfile(joinpath(JF_SCHEMA_DIR, "..", JAPAN_FISCAL_SCENARIO_JSON_SCHEMA))
        @test isfile(joinpath(JF_SCHEMA_DIR, "..", JAPAN_FISCAL_HANDOFF_JSON_SCHEMA))

        # 語彙の drift 検出（schema の enum が Julia 側の定数と一致する）
        defs = _JFE_RESULT_SCHEMA["\$defs"]
        @test defs["family"]["enum"] == String.(collect(JAPAN_FISCAL_SCENARIO_FAMILIES))
        @test defs["model"]["enum"] == String.(collect(JAPAN_FISCAL_CANDIDATE_MODELS))
        @test defs["assumptionConcept"]["enum"] == String.(collect(JAPAN_FISCAL_ASSUMPTION_CONCEPTS))
        @test defs["outputConcept"]["enum"] == String.(collect(JAPAN_FISCAL_OUTPUT_CONCEPTS))
        @test defs["diagnostic"]["enum"] == String.(collect(JAPAN_FISCAL_DIAGNOSTICS))
        @test defs["rejection"]["properties"]["rejection_code"]["enum"] ==
              String.(collect(JAPAN_FISCAL_REJECTION_CODES))
        @test Set(defs["assumption"]["properties"]["magnitude_source"]["enum"]) == Set(
            String(s) for s in DME.MACRO_EVENT_MAGNITUDE_SOURCES if
            japan_fiscal_magnitude_source_allowed(s)
        )
        hdefs = _JFE_HANDOFF_SCHEMA["\$defs"]
        @test hdefs["caseTag"]["enum"] == String.(collect(JAPAN_FISCAL_HANDOFF_CASE_TAGS))
        @test _JFE_HANDOFF_SCHEMA["properties"]["negative_artifacts"]["items"]["properties"]["name"]["enum"] ==
              String.(collect(JAPAN_FISCAL_HANDOFF_NEGATIVE_KINDS))
        # 共有 def（assumption・freContext）は 2 つの schema で同一
        for name in ("assumption", "freContext", "sha256", "family", "assumptionConcept")
            @test _jfe_bytes(defs[name]) == _jfe_bytes(_JFE_SCENARIO_SCHEMA["\$defs"][name])
        end

        # 全ファイルが schema に適合する（commit 済み fixture と再生成の両方）
        for (rel, content) in _JFE_BUILT
            d = _jfe_plain(content)
            errs = if startswith(rel, "artifacts/")
                jf_schema_errors(_JFE_RESULT_SCHEMA, d)
            elseif startswith(rel, "scenarios/")
                jf_schema_errors(_JFE_SCENARIO_SCHEMA, d)
            elseif rel == "index.json"
                jf_schema_errors(_JFE_HANDOFF_SCHEMA, d)
            else
                String[]
            end
            isempty(errs) || @info "schema 違反" rel errs
            @test isempty(errs)
        end
        committed_index = _jfe_read(joinpath(JF_HANDOFF_DIR, "index.json"))
        @test isempty(jf_schema_errors(_JFE_HANDOFF_SCHEMA, committed_index))

        # negative artifact は hash 改変以外は schema だけで拒否できる（hash は semantic invariant）
        for kind in JAPAN_FISCAL_HANDOFF_NEGATIVE_KINDS
            errs = jf_schema_errors(_JFE_RESULT_SCHEMA, _jfe_plain(_JFE_BUILT["negative/$(kind).json"]))
            if kind === :content_hash_mismatch
                @test isempty(errs)
            else
                @test !isempty(errs)
            end
        end

        # content hash の規則は DME 型なしで再現できる（generated_at と自身を除いた RFC 8785 正準 JSON）
        for c in _JFE_CASES
            d = _jfe_artifact(c.case_id)
            key = d["artifact_kind"] == "result" ? "result_content_hash" : "rejection_content_hash"
            identity = Dict{String, Any}(k => v for (k, v) in d if k != "generated_at" && k != key)
            @test d[key] == "sha256:" * bytes2hex(DME.SHA.sha256(canonical_json_bytes(identity)))
        end
    end

    # ---- semantic guardrails ------------------------------------------------------------
    @testset "FRE context 変更だけでは shock magnitude も結果も変わらない" begin
        groups = (
            ("f2-sim", "f2-sim-no-fre", "f2-sim-fre-unavailable", "f2-sim-fre-shifted"),
            ("f5-ccc", "f5-ccc-no-fre"),
        )
        invariant = ("applied_inputs", "assumption_disposition", "assumed", "model_implied", "diagnostics", "sensitivity", "coverage", "warnings", "assumption_set_hash", "parameter_identity_hash")
        for g in groups
            ref = _jfe_artifact(g[1])
            for cid in g[2:end]
                d = _jfe_artifact(cid)
                for k in invariant
                    @test _jfe_bytes(d[k]) == _jfe_bytes(ref[k])
                end
                @test d["fre_context_identity"] != ref["fre_context_identity"]
                @test d["result_content_hash"] != ref["result_content_hash"]
            end
        end
        # affinity / share / confidence / dimension score / constraint pressure を広く振っても
        # applied input の magnitude は assumption だけで決まる
        base = _jfe_case("f5-ccc").scenario
        magnitudes = Set{Vector{Float64}}()
        for x in (0.0, 0.25, 0.5, 0.99)
            ctx = JapanFiscalFREContext(;
                snapshot_id = "sweep-$(x)",
                as_of = Date(2026, 9, 30),
                vintage_basis = "fixture:sweep",
                regime_determination = :primary,
                primary_regime = "FISCAL_STRESS",
                regime_affinity = Dict("FISCAL_STRESS" => x, "FINANCIAL_REPRESSION" => 1 - x),
                regime_share = Dict("FISCAL_STRESS" => x),
                regime_confidence = x,
                dimension_score = Dict("interest_burden" => x, "jgb_absorption" => 1 - x),
                constraint_pressure = x,
                data_quality_score = x,
            )
            sc = JapanFiscalScenario(;
                scenario_id = "sweep",
                family = base.family,
                fre_context = ctx,
                assumptions = base.assumptions,
                provenance = base.provenance,
            )
            for model in (:capex_credit_cycle, :keen)
                r = japan_fiscal_run(model, sc; horizon = 8)
                push!(magnitudes, [ai.magnitude_model_units for ai in r.applied_inputs])
                @test r.assumption_set_hash == japan_fiscal_assumption_set_hash(base)
            end
        end
        @test magnitudes == Set([[50.0], [50.0 / 10000.0]])

        # FRE の score のフィールド名は observed の中にしか現れない
        forbidden = Set(JAPAN_FISCAL_FORBIDDEN_MAGNITUDE_INPUT_FIELDS)
        for c in _JFE_CASES
            for (path, key) in _jfe_key_paths(_jfe_artifact(c.case_id))
                key in forbidden && @test path == "\$.observed"
            end
        end
        # external_belief（FRE の score を外部 belief 経由で magnitude へ入れる経路）は構築時点で拒否
        @test_throws ArgumentError JapanFiscalScenarioAssumption(;
            assumption_id = "x",
            concept = :long_rate_funding_condition,
            magnitude = 68.0,
            magnitude_source = :external_belief,
        )
    end

    @testset "missing / unavailable を 0 に変換しない" begin
        # FRE context 無し: observed と identity は null（空 object や 0 ではない）
        d = _jfe_artifact("f2-sim-no-fre")
        @test d["observed"] === nothing
        @test d["fre_context_identity"] === nothing
        @test _jfe_artifact("f5-ccc-no-fre")["observed"] === nothing

        # FRE unavailable: null は null のまま、評価できない archetype / dimension はキーごと欠く
        o = _jfe_artifact("f2-sim-fre-unavailable")["observed"]
        @test o["regime_determination"] == "unavailable"
        for k in ("primary_regime", "regime_confidence", "constraint_pressure", "data_quality_score")
            @test o[k] === nothing
        end
        @test isempty(o["regime_affinity"])
        @test isempty(o["regime_share"])
        @test Set(keys(o["dimension_score"])) == Set(["debt_dynamics", "fiscal_space"])

        # 必須概念の未指定は実行されない（0 の assumption として結果を作らない）
        for c in _JFE_CASES
            :missing_required_assumption in c.tags || continue
            d = _jfe_artifact(c.case_id)
            @test d["artifact_kind"] == "rejection"
            @test d["rejection_code"] == "missing_required_assumption"
            @test !isempty(d["concepts"])
            for concept in d["concepts"]
                @test !any(a -> String(a.concept) == concept, c.scenario.assumptions)
                @test Symbol(concept) in japan_fiscal_family_spec(c.scenario.family).required_concepts
            end
            for k in ("model_implied", "diagnostics", "applied_inputs", "assumed")
                @test !haskey(d, k)
            end
        end
        # GDP 成長率パスを生産性成長率へ自動変換しない（G-03）
        @test _jfe_artifact("f4-solow-growth-path-only")["concepts"] == ["productivity_growth"]

        # magnitude = 0.0 の明示（変化なし）は未指定と区別され、実行される
        zero = _jfe_artifact("f2-sim-explicit-zero-tax")
        @test zero["artifact_kind"] == "result"
        tax = only(x for x in zero["assumption_disposition"] if x["concept"] == "tax")
        @test tax["assumption_state"] == "explicit" && tax["model_input"] == "applied"
        @test only(x for x in zero["applied_inputs"] if x["concept"] == "tax")["magnitude_model_units"] == 0
        @test _jfe_artifact("f2-sim-missing-tax")["artifact_kind"] == "rejection"

        # 未指定の任意概念は baseline 保持として開示され、0 の applied input を作らない
        ccc = _jfe_artifact("f5-ccc")
        pr = only(x for x in ccc["assumption_disposition"] if x["concept"] == "policy_rate")
        @test pr["assumption_state"] == "not_specified"
        @test pr["model_input"] == "held_at_baseline"
        @test pr["assumption_id"] === nothing
        @test !any(x -> x["concept"] == "policy_rate", ccc["applied_inputs"])
        @test !any(x -> x["concept"] == "policy_rate", ccc["assumed"])

        # 分母が閾値未満の relative_delta は null（0 で埋めない）。RBC の baseline は定常状態からの偏差 0
        rbc = _jfe_artifact("f4-rbc")
        @test all(x === nothing for v in values(rbc["diagnostics"]["relative_delta"]) for x in v)

        # PB 目標の explicit assumption は変換未実装のため黙って無視せず拒否する
        pb = _jfe_artifact("f2-sim-primary-balance")
        @test pb["rejection_code"] == "conversion_not_implemented"
        @test pb["concepts"] == ["primary_balance"]
    end

    @testset "observed / assumed / model_implied が混ざらない（H-10）" begin
        fre_keys = Set(keys(_jfe_plain(to_dict(_jfe_case("f2-sim").scenario.fre_context))))
        assumption_keys = Set(["assumption_id", "concept", "unit", "magnitude", "direction", "magnitude_source", "notes"])
        for c in _JFE_CASES
            d = _jfe_artifact(c.case_id)
            d["artifact_kind"] == "result" || continue
            d["observed"] === nothing || @test Set(keys(d["observed"])) == fre_keys
            for a in d["assumed"]
                @test Set(keys(a)) == assumption_keys
            end
            @test issorted([a["assumption_id"] for a in d["assumed"]])
            @test Set(keys(d["model_implied"])) == Set(["baseline", "scenario"])
            for side in ("baseline", "scenario")
                @test Set(keys(d["model_implied"][side])) == Set(["numeric_semantics", "series"])
            end
            # assumption の id は observed に現れず、FRE の snapshot は assumed に現れない
            @test !occursin("snapshot_id", String(_jfe_bytes(d["assumed"])))
            d["observed"] === nothing ||
                @test !any(a -> occursin(a["assumption_id"], String(_jfe_bytes(d["observed"]))), d["assumed"])
        end
    end

    @testset "model-implied を forecast / probability と呼ばない（H-22 の producer 側）" begin
        word = r"forecast|probabilit|predict"i
        for (rel, content) in _JFE_BUILT
            startswith(rel, "contracts/") && continue
            for (_, key) in _jfe_key_paths(_jfe_plain(content))
                @test !occursin(word, key)
            end
        end
        for c in _JFE_CASES
            d = _jfe_artifact(c.case_id)
            cov = d["coverage"]
            @test cov["claim_level"] != "magnitude"
            @test cov["numeric_semantics"] != "japan_magnitude"
            if d["artifact_kind"] == "result"
                spec = japan_fiscal_claim_level_spec(Symbol(cov["claim_level"]))
                @test all(x -> x in cov["major_caveats"], spec.required_caveats)
                @test d["model_implied"]["scenario"]["numeric_semantics"] == cov["numeric_semantics"]
                # forecast / probability / 危機確率 / 投資推奨として主張すれば違反になる
                v = japan_fiscal_validate_claims(
                    Symbol(d["family"]),
                    Symbol(d["model"]);
                    claim_kinds = [:forecast, :probability, :crisis_probability, :investment_recommendation],
                    disclosed_unsupported_concepts = Symbol[Symbol(x) for x in cov["unsupported_concepts"]],
                    disclosed_unsupported_outputs = Symbol[Symbol(x) for x in cov["unsupported_outputs"]],
                )
                @test count(x -> x.code === :forbidden_claim_kind, v) == 4
                v2 = japan_fiscal_validate_claims(
                    Symbol(d["family"]),
                    Symbol(d["model"]);
                    numeric_semantics = :japan_magnitude,
                    disclosed_unsupported_concepts = Symbol[Symbol(x) for x in cov["unsupported_concepts"]],
                    disclosed_unsupported_outputs = Symbol[Symbol(x) for x in cov["unsupported_outputs"]],
                )
                @test :magnitude_without_japan_calibration in [x.code for x in v2]
            end
        end
    end

    @testset "not_representable を成功 scenario に見せない" begin
        for c in _JFE_CASES
            d = _jfe_artifact(c.case_id)
            m = japan_fiscal_model_mapping(c.scenario.family, c.model)
            if m.adoption === :not_adopted
                @test d["artifact_kind"] == "rejection"
                @test d["status"] == "not_executed"
                @test d["rejection_code"] == "not_adopted"
                @test d["representability"] == String(m.representability)
                for k in ("model_implied", "diagnostics", "execution_status", "applied_inputs", "result_content_hash")
                    @test !haskey(d, k)
                end
                entry = only(x for x in _JFE_BUILT["index.json"]["cases"] if x["case_id"] == c.case_id)
                @test entry["summary"]["artifact_kind"] == "rejection"
            end
            d["artifact_kind"] == "result" && @test d["coverage"]["family_complete"] == false
        end
        # partial の result は unsupported を開示する（空配列へ落とさない。H-09）
        for c in _JFE_CASES
            :partial in c.tags || continue
            cov = _jfe_artifact(c.case_id)["coverage"]
            @test !isempty(cov["unsupported_concepts"]) || !isempty(cov["unsupported_outputs"])
            @test !isempty(cov["uncovered_channels"])
        end
    end

    # ---- claim-level 契約の #277 向け handoff requirements -------------------------------
    @testset "handoff requirements H-13–H-16" begin
        reqs = japan_fiscal_handoff_requirements(; audience = :dme_e2e_fixture)
        @test [r.requirement_id for r in reqs] == ["H-13", "H-14", "H-15", "H-16"]

        # H-13: E2E fixture の結果に :magnitude が現れない
        for c in _JFE_CASES
            @test _jfe_artifact(c.case_id)["coverage"]["claim_level"] != "magnitude"
        end
        dc = _jfe_plain(_JFE_BUILT["contracts/downstream_contract.json"])
        @test dc["invariants"]["magnitude_claim_count"] == 0

        # H-15: direction_only のセルに peak / onset / duration を要求すると違反
        direction_only = [
            c for c in _JFE_CASES if
            _jfe_artifact(c.case_id)["coverage"]["claim_level"] == "direction_only"
        ]
        @test !isempty(direction_only)
        for c in direction_only
            v = japan_fiscal_validate_claims(
                c.scenario.family,
                c.model;
                diagnostics = [:peak, :onset, :duration],
                disclosed_unsupported_concepts = japan_fiscal_unsupported_concepts(c.scenario.family, c.model),
                disclosed_unsupported_outputs = japan_fiscal_unsupported_outputs(c.scenario.family, c.model),
            )
            @test count(x -> x.code === :diagnostic_not_permitted, v) == 3
            @test !haskey(_jfe_artifact(c.case_id)["diagnostics"], "peak")
        end

        # H-16: consumer fixture に downstream contract を含め、JSON round-trip で全キーが読める
        committed_dc = load_japan_fiscal_handoff(JF_HANDOFF_DIR).contracts["downstream_contract"]
        @test Set(keys(committed_dc)) == Set(keys(japan_fiscal_downstream_contract()))
        @test _jfe_bytes(committed_dc) == _jfe_bytes(japan_fiscal_downstream_contract())
        @test length(committed_dc["handoff_requirements"]) == 22
    end

    # ---- 入力エラー（unsupported unit / horizon ほか）------------------------------------
    @testset "入力エラーは artifact を生成しない" begin
        entries = _jfe_read(joinpath(JF_INVALID_INPUTS_DIR, "index.json"))["invalid_inputs"]
        generated = jf_fixture_invalid_inputs()
        @test [e["name"] for e in entries] == [x.name for x in generated]
        for x in generated
            path = joinpath(JF_INVALID_INPUTS_DIR, "$(x.name).json")
            @test read(path) == _jfe_bytes(x.document)
            msg = _jfe_error_msg(() -> japan_fiscal_scenario_from_dict(_jfe_read(path)))
            @test msg !== nothing && occursin(x.expected_error, msg)
        end
        @test "scenario_unsupported_unit" in [x.name for x in generated]

        scenarios = jf_fixture_scenarios()
        errors = jf_fixture_run_argument_errors()
        @test !isempty(errors)
        for e in errors
            msg = _jfe_error_msg(
                () -> japan_fiscal_run(e.model, scenarios[e.scenario_id]; horizon = e.horizon),
            )
            @test msg !== nothing && occursin(e.expected_error, msg)
        end
    end

    # ---- assumption disposition / adapter registry の整合 --------------------------------
    @testset "assumption disposition と adapter の実装済み概念が一致する" begin
        prov = JapanFiscalScenarioProvenance(; assumption_source = :fixture)
        for m in DME.JAPAN_FISCAL_MODEL_MAPPINGS
            m.adoption === :not_adopted && continue
            implemented = JAPAN_FISCAL_ADAPTER_IMPLEMENTED_CONCEPTS[m.model]
            spec = japan_fiscal_family_spec(m.family)
            # family の全概念に 0.1 の explicit assumption を置く（変換未実装の概念は除く）
            concepts = [
                c for c in vcat(spec.required_concepts, spec.optional_concepts) if !(
                    c in japan_fiscal_accepted_concepts(m) && !(c in implemented)
                )
            ]
            sc = JapanFiscalScenario(;
                scenario_id = "disp",
                family = m.family,
                provenance = prov,
                assumptions = [
                    JapanFiscalScenarioAssumption(;
                        assumption_id = "a-$(c)",
                        concept = c,
                        magnitude = 0.1,
                        magnitude_source = :assumed_default,
                    ) for c in concepts
                ],
            )
            r = japan_fiscal_run(m.model, sc; horizon = 4)
            @test r isa JapanFiscalScenarioResult
            applied = Set(ai.concept for ai in r.applied_inputs)
            @test applied == Set(c for c in japan_fiscal_accepted_concepts(m) if c in implemented)
            @test [x.concept for x in r.assumption_disposition] ==
                  vcat(spec.required_concepts, spec.optional_concepts)
        end
        # 許されない組はコンストラクタが拒否する
        @test_throws ArgumentError JapanFiscalAssumptionDisposition(;
            concept = :tax,
            requirement = :required,
            assumption_state = :explicit,
            assumption_id = "a",
            model_input = :held_at_baseline,
            target = :T,
        )
        @test_throws ArgumentError JapanFiscalAssumptionDisposition(;
            concept = :tax,
            requirement = :optional,
            assumption_state = :not_specified,
            model_input = :applied,
            target = :T,
        )
    end
end
