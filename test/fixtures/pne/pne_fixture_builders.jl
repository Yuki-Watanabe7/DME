# pne_fixture_builders.jl: PNE `production-network-sector-output-path/v1` 形式の**テスト用**
# artifact を決定的に組み立てるヘルパ（Issue #281）。
#
# test/test_cross_model_compatibility.jl・test/test_pne_cross_repo_e2e.jl と
# test/fixtures/pne/regenerate.jl が include する。
#
# ここで作る文書は PNE の producer 経路で生成したものではない。PNE が生成した fixture
# （`sector_output_path/v1/`、vendor コピー）を**基にして**、DME 側の互換性判定の規則
# （geography・classification・時間軸・部門割当）を 1 事実ずつ検査するために DME 側で派生させた
# テスト入力である。値はすべて架空であり、実在の経済・部門・企業・公式統計を表さない。
# PNE の producer 経路で生成した cross-repository fixture（`producer/`・`official_jp/`、Issue #283）を
# 読むヘルパは末尾にある。

const PNE_FIXTURE_DIR = joinpath(@__DIR__, "sector_output_path", "v1")
const PNE_PRODUCER_DIR = joinpath(@__DIR__, "producer")
const PNE_OFFICIAL_JP_DIR = joinpath(@__DIR__, "official_jp")

"vendor した PNE の representative fixture を plain `Dict` として読む。"
function pne_representative_dict()
    raw = DME.JSON3.read(read(joinpath(PNE_FIXTURE_DIR, "representative.json"), String))
    return DME._scenario_json_to_plain(raw)
end

_pne_points(ratios) = Any[
    Dict{String, Any}(
        "period_index" => i - 1,
        "realized_output_ratio" => r,
        "output_loss_ratio" => 1.0 - r,
    ) for (i, r) in enumerate(ratios)
]

"""
    pne_test_artifact_dict(; sectors, period_unit, calendar_anchor, geography, classification,
                           is_synthetic, status, warnings, unsupported_reasons) -> Dict

PNE v1 の shape を満たすテスト用 artifact を組み立てる。`sectors` は
`(sector_id, ratios, baseline_value_or_nothing, source_data_status)` の配列で、`sector_id`
昇順に整列して書き出す。source の hash は固定のダミー値（`sha256:` + 64 桁）。
"""
function pne_test_artifact_dict(;
    sectors,
    period_unit::String = "quarter",
    calendar_anchor = "2025-01-01",
    geography = ("pne-synthetic-economy/v1", "TEST-ECONOMY-A", "Fabricated economy A"),
    classification = ("pne-synthetic-industries", "1", "native-node"),
    is_synthetic::Bool = true,
    status::String = "complete",
    warnings = Any[],
    unsupported_reasons = Any[],
    artifact_id::String = "sop-dme-test-0000000000000001",
    baseline_unit::String = "index_units",
)
    sorted = sort(collect(sectors); by = first)
    n = length(sorted[1][2])
    horizon = status == "complete" ? n : n + 1
    counts = Dict{String, Any}()
    for s in sorted
        counts[s[4]] = get(counts, s[4], 0) + 1
    end
    dummy(c) = "sha256:" * repeat(c, 64)
    return Dict{String, Any}(
        "schema_version" => "production-network-sector-output-path/v1",
        "artifact_id" => artifact_id,
        "status" => status,
        "source" => Dict{String, Any}(
            "network_id" => "dme-test-network",
            "source_input_hash" => dummy("1"),
            "dynamic_artifact_id" => "dyn-dme-test-000000000001",
            "dynamic_artifact_hash" => dummy("2"),
            "scenario_hash" => dummy("3"),
            "scenario_policy_hash" => dummy("4"),
            "scenario_config_hash" => dummy("5"),
            "export_config_hash" => dummy("6"),
        ),
        "producer" => Dict{String, Any}(
            "engine" => "production-network-engine",
            "engine_version" => "0.1.0",
            "exporter_version" => "1.0.0",
            "algorithm_versions" => Dict{String, Any}("dynamic.multi_period_propagation" => "1.4.0"),
        ),
        "result_type_boundary" => Dict{String, Any}(
            "source_network_data" => "source_data_with_declared_estimation_status",
            "pne_scenario" => "pne_scenario_assumption",
            "output_path" => "pne_model_derived_endogenous_result",
            "downstream_application" => "not_present",
        ),
        "geography" => Dict{String, Any}(
            "system" => geography[1],
            "economy_id" => geography[2],
            "name" => geography[3],
        ),
        "geography_compatibility" => Dict{String, Any}(
            "mode" => "same_economy_only",
            "compatible_economy_ids" => Any[geography[2]],
            "explicitly_modeled_cross_economy" => false,
            "model_reference" => nothing,
        ),
        "classification" => Dict{String, Any}(
            "system" => classification[1],
            "version" => classification[2],
            "level" => classification[3],
            "sector_id_semantics" => "opaque",
        ),
        "aggregation" => Dict{String, Any}(
            "status" => "native_sector_path",
            "mapping_artifact_hash" => nothing,
            "weighted_aggregation_rule" => nothing,
            "baseline_output_weighting" => nothing,
            "unmapped_sector_treatment" => nothing,
            "coverage" => 1.0,
        ),
        "time" => Dict{String, Any}(
            "period_unit" => period_unit,
            "frequency" => 1,
            "period_index_origin" => 0,
            "horizon_periods" => horizon,
            "available_periods" => n,
            "calendar_anchor" => calendar_anchor,
            "interval_semantics" => "start_inclusive_end_exclusive",
            "value_semantics" => "period_total_realized_output_ratio",
            "rescaled_by_exporter" => false,
        ),
        "source_provenance" => Dict{String, Any}(
            "network_as_of" => "2024-12-31",
            "is_synthetic" => is_synthetic,
            "node_estimation_status_counts" => counts,
            "edge_estimation_status_counts" => Dict{String, Any}(),
            "note" => "Fabricated DME test input derived for compatibility-rule tests. It describes no real economy, sector, company, or official statistic.",
            "references" => Any[],
        ),
        "scenario_assumptions" => Any["Fabricated capacity path for DME rule tests."],
        "model_assumptions" => Any["No DME-side meaning is implied by this fixture."],
        "export_assumptions" => Any["No sector aggregation or calendar-frequency conversion was performed."],
        "sectors" => Any[
            Dict{String, Any}(
                "sector_id" => s[1],
                "source_label" => uppercasefirst(replace(s[1], "_" => " ")),
                "source_label_semantics" => "presentation_only",
                "source_data_status" => s[4],
                "baseline_output" =>
                    s[3] === nothing ? nothing :
                    Dict{String, Any}("value" => s[3], "unit" => baseline_unit),
                "periods" => _pne_points(s[2]),
            ) for s in sorted
        ],
        "aggregate_path_definition" => Dict{String, Any}(
            "weighting" => "source_baseline_output",
            "ratio_semantics" => "baseline_output_weighted_mean_of_sector_realized_output_ratio",
            "loss_semantics" => "one_minus_aggregate_output_ratio",
            "missing_baseline_treatment" => "aggregate_path_absent",
        ),
        "aggregate_path" => nothing,
        "warnings" => warnings,
        "unsupported_reasons" => unsupported_reasons,
        "result_semantics" => "Fabricated PNE-shaped test artifact; model-derived by construction, not observed output or a forecast.",
    )
end

"""
    synthetic_quarterly_dict()

架空経済 TEST-ECONOMY-A・四半期 6 期の synthetic artifact。顧客部門 `auto_assembly`・
`phone_assembly` の産出が落ちて回復し、target 製品の生産部門 `chip_fab` は全期 1.0
（供給制約なし）。`raw_material` はどの group にも属さない。
"""
synthetic_quarterly_dict() = pne_test_artifact_dict(;
    sectors = [
        ("auto_assembly", [1.0, 0.6, 0.7, 0.9, 1.0, 1.0], 60.0, "synthetic"),
        ("chip_fab", [1.0, 1.0, 1.0, 1.0, 1.0, 1.0], 30.0, "synthetic"),
        ("phone_assembly", [1.0, 0.8, 0.8, 1.0, 1.0, 1.0], 40.0, "synthetic"),
        ("raw_material", [0.5, 0.5, 1.0, 1.0, 1.0, 1.0], 12.0, "synthetic"),
    ],
)

"""
    synthetic_monthly_dict(; n_months = 6, calendar_anchor = "2025-04-01")

synthetic_quarterly_dict と同じ部門構成の月次版（`n_months` か月）。
"""
function synthetic_monthly_dict(; n_months::Int = 6, calendar_anchor = "2025-04-01")
    auto = [0.4, 0.7, 0.8, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
    phone = [0.7, 0.7, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]
    return pne_test_artifact_dict(;
        period_unit = "month",
        calendar_anchor = calendar_anchor,
        sectors = [
            ("auto_assembly", auto[1:n_months], 60.0, "synthetic"),
            ("chip_fab", fill(1.0, n_months), 30.0, "synthetic"),
            ("phone_assembly", phone[1:n_months], 40.0, "synthetic"),
            ("raw_material", fill(1.0, n_months), 12.0, "synthetic"),
        ],
    )
end

"""
    jp_like_dict()

現行の PNE real profile（日本 2020 IO・統合中分類・実データ）と**同じ identity の形**を持つ
DME 側のテスト入力（Japan → US negative 用）。公式データは含まない: sector_id と値は架空であり、
公式の部門コード・取引額を表さない。`is_synthetic = false`・`source_data_status = observed` は
「実データ由来の artifact」として扱われることを検査するための設定である。
"""
jp_like_dict() = pne_test_artifact_dict(;
    geography = ("ISO 3166-1 alpha-2", "JP", "Japan"),
    classification = ("Japan 2020 IO sector classification", "2020", "integrated-middle"),
    is_synthetic = false,
    artifact_id = "sop-dme-test-jp-like-000001",
    baseline_unit = "JPY billion",
    sectors = [
        ("JP-TEST-001", [1.0, 0.6, 0.7, 0.9, 1.0, 1.0], 600.0, "observed"),
        ("JP-TEST-002", [1.0, 1.0, 1.0, 1.0, 1.0, 1.0], 300.0, "observed"),
        ("JP-TEST-003", [1.0, 0.8, 0.8, 1.0, 1.0, 1.0], 400.0, "observed"),
    ],
)

# ---------------------------------------------------------------------------
# cross-repository fixture（Issue #283）
# ---------------------------------------------------------------------------

"producer fixture の MANIFEST（`producer/MANIFEST.json`）を plain `Dict` として読む。"
pne_producer_manifest() =
    DME._scenario_json_to_plain(DME.JSON3.read(read(joinpath(PNE_PRODUCER_DIR, "MANIFEST.json"), String)))

"PNE の実 producer 経路で生成した artifact（`producer/v1/<case_id>.json`）のパス。"
pne_producer_path(case_id::AbstractString) = joinpath(PNE_PRODUCER_DIR, "v1", "$(case_id).json")

"PNE の実 producer 経路で生成した artifact を plain `Dict` として読む。"
pne_producer_dict(case_id::AbstractString) =
    DME._scenario_json_to_plain(DME.JSON3.read(read(pne_producer_path(case_id), String)))

"official Japan 由来 bridge artifact の identity metadata（`official_jp/bridge_identity.json`）。"
pne_official_jp_identity() = DME._scenario_json_to_plain(
    DME.JSON3.read(read(joinpath(PNE_OFFICIAL_JP_DIR, "bridge_identity.json"), String)),
)

"""
    official_jp_reconstructed_dict(; n_sectors = 3)

official Japan 由来 bridge artifact の identity（geography・classification・time・source・
source_provenance・producer・warnings 等は**実データの実行から得た値そのまま**）に、架空の
placeholder 部門（`DME-WITHHELD-001` …）を付けて decode 可能な文書に戻す。公式の部門 ID・
ラベル・baseline・産出パスは commit していないため、部門の値はすべて架空であり、実在の部門を
表さない。placeholder 部門の `source_data_status` は実データの部門構成（`sector_summary`）の
最頻値、パスは低下して horizon 末までに回復する架空の値である。
"""
function official_jp_reconstructed_dict(; n_sectors::Int = 3)
    identity = pne_official_jp_identity()
    d = deepcopy(identity["bridge"])
    summary = identity["sector_summary"]
    counts = summary["source_data_status_counts"]
    status = first(sort(collect(keys(counts)); by = k -> (-counts[k], k)))
    unit = first(summary["baseline_output_units"])
    n = d["time"]["available_periods"]
    ratios = [k == 1 ? 0.8 : k == 2 ? 0.9 : 1.0 for k in 1:n]
    d["sectors"] = Any[
        Dict{String, Any}(
            "sector_id" => "DME-WITHHELD-" * lpad(i, 3, '0'),
            "source_label" => "Withheld official sector placeholder $(i)",
            "source_label_semantics" => "presentation_only",
            "source_data_status" => status,
            "baseline_output" => Dict{String, Any}("value" => 100.0, "unit" => unit),
            "periods" => _pne_points(ratios),
        ) for i in 1:n_sectors
    ]
    d["aggregate_path"] = nothing
    return d
end
