# regenerate_cross_repo.jl: production-network-engine（PNE）と economic-data-provider（EDP）の
# **実 producer 経路**で DME の cross-repository fixture を生成・検査する（Issue #283 / `PN-3`）。
#
# 本スクリプトはテストから呼ばれない（DME のテストは PNE・EDP・Python・ネットワークに依存しない）。
# fixture を作り直すとき・PNE 側の変更（contract drift）を確かめるときに、uv と各リポジトリの
# checkout を用意して手動で実行する。
#
# 使い方（DME リポジトリルートから）:
#
#   # 1. synthetic producer fixture（producer/v1/*.json）と producer/MANIFEST.json を再生成する
#   julia --project=. test/fixtures/pne/regenerate_cross_repo.jl producer \
#       --pne-repo ../production-network-engine
#
#   # 2. drift 検査（書き込みなし）: PNE checkout で producer fixture を作り直して bytes を比較し、
#   #    vendor した PNE contract fixture（sector_output_path/v1/）と PNE 側のファイルを比較する
#   julia --project=. test/fixtures/pne/regenerate_cross_repo.jl check \
#       --pne-repo ../production-network-engine
#
#   # 3. official Japan IO 由来の bridge artifact の identity（metadata のみ）を再生成する。
#   #    e-Stat から公式 workbook を取得するため network access が必要。公式データと、それから
#   #    導出した network・scenario・bridge artifact はすべて --scratch（リポジトリの外）に置き、
#   #    リポジトリへは identity metadata（official_jp/bridge_identity.json）だけを書く
#   julia --project=. test/fixtures/pne/regenerate_cross_repo.jl official-jp \
#       --pne-repo ../production-network-engine --edp-repo ../economic-data-provider \
#       --scratch /path/outside/the/repository
#
# producer fixture の入力（producer/inputs/）は DME が所有する架空の network・PNE dynamic
# scenario・export config である。出力（producer/v1/*.json）は PNE CLI
# （`production-network dynamic-simulate` → `production-network export-sector-output-path`）が
# 書いたバイト列そのものであり、手で編集しない。PNE の dynamic artifact（runtime timestamp と
# PNE 内部 state を含む）は commit せず、その identity（id・PNE が計算した hash）だけを
# MANIFEST に記録する。DME は PNE の hash を再計算しない（設計 §5.3・`PG-09`）。ここでの
# `dynamic_artifact_hash` の記録は PNE 自身のコード（`hash_document`）による値である。

using DME

const json_read = DME.json_read
const json_write = DME.json_write
const json_pretty = DME.json_pretty
const HERE = @__DIR__
const DME_ROOT = normpath(joinpath(HERE, "..", "..", ".."))
const PRODUCER_DIR = joinpath(HERE, "producer")
const PRODUCER_INPUTS = joinpath(PRODUCER_DIR, "inputs")
const PRODUCER_OUTPUTS = joinpath(PRODUCER_DIR, "v1")
const PRODUCER_MANIFEST = joinpath(PRODUCER_DIR, "MANIFEST.json")
const OFFICIAL_DIR = joinpath(HERE, "official_jp")
const VENDOR_DIR = joinpath(HERE, "sector_output_path", "v1")
const MAPPINGS_DIR = joinpath(HERE, "mappings")

const PRODUCER_MANIFEST_SCHEMA_VERSION = "dme.pne-producer-fixture-manifest/1.0.0"
const BRIDGE_IDENTITY_SCHEMA_VERSION = "dme.pne-bridge-identity/1.0.0"
const PNE_REPOSITORY = "Yuki-Watanabe7/production-network-engine"
const EDP_REPOSITORY = "Yuki-Watanabe7/economic-data-provider"

const PRODUCER_NETWORK = "network_fictional_customer_chain.json"
const PRODUCER_EXPORT_CONFIG = "export_config.json"
const PRODUCER_CASES = (
    (case_id = "quarterly_supplier_disruption", scenario = "scenario_quarterly_supplier_disruption.json"),
    (case_id = "monthly_supplier_disruption", scenario = "scenario_monthly_supplier_disruption.json"),
)

"official Japan の negative golden で評価する transmission mode と、その mapping fixture。"
const OFFICIAL_MODES = (
    ("same_economy", "ccc_official_jp_same_economy.json"),
    ("explicit_cross_economy", "ccc_official_jp_explicit_cross_economy.json"),
    ("hypothetical_override", "ccc_official_jp_hypothetical_override.json"),
)

# PNE 自身のコードで dynamic artifact の hash（runtime block を除く canonical payload の
# hash_document）を計算する。PNE の export-sector-output-path が source.dynamic_artifact_hash に
# 書く値と同じ規則である。
const PNE_DYNAMIC_HASH_PY =
    "import sys; " *
    "from production_network_engine.io.json_loader import load_dynamic_simulation_artifact; " *
    "from production_network_engine.io.json_writer import hash_document; " *
    "print(hash_document(load_dynamic_simulation_artifact(sys.argv[1]).canonical_payload()))"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

_rel(path) = relpath(path, DME_ROOT)
_sha256_file(path) = "sha256:" * bytes2hex(DME.SHA.sha256(read(path)))
_read_plain(path) = DME._scenario_json_to_plain(json_read(read(path, String)))

function _write_pretty_json(path::AbstractString, d)
    mkpath(dirname(path))
    io = IOBuffer()
    json_pretty(io, json_read(canonical_json_string(d)))
    println(io)
    write(path, take!(io))
    println("wrote ", _rel(path))
end

function _parse_args(args)
    isempty(args) && error("usage: regenerate_cross_repo.jl (producer|check|official-jp) --pne-repo PATH [...]")
    cmd = args[1]
    opts = Dict{String, String}()
    flags = Set{String}()
    i = 2
    while i <= length(args)
        a = args[i]
        startswith(a, "--") || error("unexpected argument: $(a)")
        if a == "--allow-dirty"
            push!(flags, a)
            i += 1
        else
            i + 1 <= length(args) || error("missing value for $(a)")
            opts[a] = args[i + 1]
            i += 2
        end
    end
    return cmd, opts, flags
end

function _require_repo(opts, key)
    haskey(opts, key) || error("$(key) is required")
    repo = abspath(expanduser(opts[key]))
    isdir(joinpath(repo, ".git")) || error("$(repo) is not a git checkout")
    return repo
end

_git(repo, args...) = readchomp(`git -C $repo $args`)

function _git_head(repo; allow_dirty::Bool = false)
    dirty = !isempty(_git(repo, "status", "--porcelain"))
    dirty && !allow_dirty &&
        error("$(repo) has uncommitted changes; a fixture must come from a committed producer state")
    return _git(repo, "rev-parse", "HEAD"), dirty
end

_uv(repo, args...) = read(`uv run --quiet --directory $repo $args`, String)

"PNE の dynamic artifact から identity を記録する（hash は PNE のコードで計算する）。"
function _pne_dynamic_record(pne::AbstractString, dyn_path::AbstractString)
    d = _read_plain(dyn_path)
    return Dict{String, Any}(
        "schema_version" => d["schema_version"],
        "dynamic_artifact_id" => d["simulation_id"],
        "dynamic_artifact_hash" => strip(_uv(pne, "python", "-c", PNE_DYNAMIC_HASH_PY, dyn_path)),
        "source_input_hash" => d["input_hash"],
        "scenario_hash" => d["scenario_hash"],
        "network_id" => d["network_id"],
        "engine_version" => d["engine_version"],
        "algorithm_versions" => d["algorithm_versions"],
        "horizon_periods" => d["horizon_periods"],
        "completed_periods" => d["completed_periods"],
    )
end

"PNE CLI の 2 段（dynamic-simulate → export-sector-output-path）を実行する。"
function _run_pne_export(pne, work, network, scenario, config, name)
    dyn = joinpath(work, "$(name).dynamic.json")
    sop = joinpath(work, "$(name).sector_output_path.json")
    _uv(pne, "production-network", "dynamic-simulate", network, scenario, "--out", dyn)
    _uv(pne, "production-network", "export-sector-output-path", network, dyn, "--config", config, "--out", sop)
    return sop, _pne_dynamic_record(pne, dyn)
end

# ---------------------------------------------------------------------------
# producer（synthetic fixture）
# ---------------------------------------------------------------------------

function _producer_outputs(pne::AbstractString, work::AbstractString)
    network = joinpath(PRODUCER_INPUTS, PRODUCER_NETWORK)
    config = joinpath(PRODUCER_INPUTS, PRODUCER_EXPORT_CONFIG)
    results = []
    for c in PRODUCER_CASES
        scenario = joinpath(PRODUCER_INPUTS, c.scenario)
        sop, record = _run_pne_export(pne, work, network, scenario, config, c.case_id)
        push!(results, (case = c, sop = sop, record = record))
    end
    return results
end

function generate_producer(pne::AbstractString; allow_dirty::Bool = false)
    commit, dirty = _git_head(pne; allow_dirty = allow_dirty)
    work = mktempdir()
    cases = Any[]
    for r in _producer_outputs(pne, work)
        out = joinpath(PRODUCER_OUTPUTS, "$(r.case.case_id).json")
        mkpath(dirname(out))
        cp(r.sop, out; force = true)  # PNE が書いたバイト列をそのまま置く
        println("wrote ", _rel(out))
        a = load_pne_sector_output_path(out)
        push!(
            cases,
            Dict{String, Any}(
                "case_id" => r.case.case_id,
                "network" => _rel(joinpath(PRODUCER_INPUTS, PRODUCER_NETWORK)),
                "scenario" => _rel(joinpath(PRODUCER_INPUTS, r.case.scenario)),
                "export_config" => _rel(joinpath(PRODUCER_INPUTS, PRODUCER_EXPORT_CONFIG)),
                "output" => Dict{String, Any}("path" => _rel(out), "sha256" => _sha256_file(out)),
                "producer_record" => r.record,
                "dme_content_hash" => a.content_hash,
            ),
        )
    end
    inputs = Any[
        Dict{String, Any}("path" => _rel(p), "sha256" => _sha256_file(p)) for
        p in sort(joinpath.(PRODUCER_INPUTS, readdir(PRODUCER_INPUTS)))
    ]
    manifest = Dict{String, Any}(
        "schema_version" => PRODUCER_MANIFEST_SCHEMA_VERSION,
        "upstream_repository" => PNE_REPOSITORY,
        "upstream_commit" => commit,
        "upstream_tree_dirty" => dirty,
        "upstream_contract" => PNE_SECTOR_OUTPUT_PATH_CONTRACT,
        "producer_commands" => Any[
            "production-network dynamic-simulate <network> <scenario> --out <dynamic>",
            "production-network export-sector-output-path <network> <dynamic> --config <export_config> --out <output>",
        ],
        "generator" => Dict{String, Any}(
            "path" => _rel(@__FILE__),
            "command" => "julia --project=. $(_rel(@__FILE__)) producer --pne-repo <PNE checkout>",
        ),
        "inputs" => inputs,
        "cases" => cases,
        "note" =>
            "Outputs are byte-for-byte what the PNE CLI wrote; do not edit them by hand. Inputs are DME-owned " *
            "fictional documents. The PNE dynamic artifacts are not committed; producer_record keeps their " *
            "identity as computed by PNE itself.",
    )
    _write_pretty_json(PRODUCER_MANIFEST, manifest)
    return nothing
end

function check_producer(pne::AbstractString)
    manifest = _read_plain(PRODUCER_MANIFEST)
    head, dirty = _git_head(pne; allow_dirty = true)
    println("PNE HEAD $(head)$(dirty ? " (dirty)" : ""); fixtures recorded at $(manifest["upstream_commit"])")
    ok = true
    for m in manifest["inputs"]
        if _sha256_file(joinpath(DME_ROOT, m["path"])) != m["sha256"]
            println("  DRIFT  input $(m["path"]) does not match MANIFEST")
            ok = false
        end
    end
    by_case = Dict(c["case_id"] => c for c in manifest["cases"])
    for r in _producer_outputs(pne, mktempdir())
        entry = by_case[r.case.case_id]
        committed = joinpath(DME_ROOT, entry["output"]["path"])
        same_bytes = read(r.sop) == read(committed)
        same_record = r.record == entry["producer_record"]
        println(
            "  $(same_bytes && same_record ? "ok    " : "DRIFT ") $(r.case.case_id)" *
            (same_bytes ? "" : " (output bytes differ)") *
            (same_record ? "" : " (dynamic artifact identity differs)"),
        )
        ok &= same_bytes && same_record
    end
    return ok
end

"vendor した PNE contract fixture（sector_output_path/v1/）を PNE checkout のファイルと比較する。"
function check_vendor(pne::AbstractString)
    manifest = _read_plain(joinpath(VENDOR_DIR, "MANIFEST.json"))
    println("vendored PNE contract recorded at $(manifest["upstream_commit"])")
    ok = true
    for f in manifest["files"]
        upstream = joinpath(pne, f["upstream_path"])
        local_path = joinpath(DME_ROOT, f["path"])
        if !isfile(upstream)
            println("  DRIFT  $(f["upstream_path"]) no longer exists in the PNE checkout")
            ok = false
        elseif read(upstream) != read(local_path)
            println("  DRIFT  $(f["upstream_path"]) differs from the vendored copy $(f["path"])")
            ok = false
        else
            println("  ok     $(f["upstream_path"])")
        end
    end
    return ok
end

# ---------------------------------------------------------------------------
# official Japan（identity metadata のみ）
# ---------------------------------------------------------------------------

"edge の入出次数の中央値に最も近い node（同距離は node_id 昇順の先頭）。PNE の実データ受け入れ検証と同じ規則。"
function _median_degree_node(network::AbstractDict)
    deg = Dict{String, Int}(String(n["node_id"]) => 0 for n in network["nodes"])
    for e in network["edges"]
        deg[String(e["source"])] += 1
        deg[String(e["target"])] += 1
    end
    vals = sort(collect(values(deg)))
    n = length(vals)
    med = isodd(n) ? Float64(vals[(n + 1) ÷ 2]) : (vals[n ÷ 2] + vals[n ÷ 2 + 1]) / 2
    target = first(sort(collect(keys(deg)); by = k -> (abs(deg[k] - med), k)))
    return target, deg[target], med
end

const OFFICIAL_SHOCK = (magnitude = 0.5, start_period = 0, duration_periods = 3, recovery_periods = 3)
const OFFICIAL_HORIZON = 8

function _official_scenario(network_id::AbstractString, target::AbstractString)
    return Dict{String, Any}(
        "schema_version" => "production-network-dynamic-scenario/v1",
        "scenario_id" => "dme-official-jp-staged-recovery-median-degree",
        "network_id" => network_id,
        "decision_time" => "2026-09-28T00:00:00+00:00",
        "horizon_periods" => OFFICIAL_HORIZON,
        "calendar" => Dict{String, Any}("unit" => "year"),
        "policies" => Dict{String, Any}(
            "critical_input" => "strict_leontief",
            "external_supply" => "none",
            "inventory" => "disabled",
            "min_input_coefficient" => 0.0,
        ),
        "settings" => Dict{String, Any}("max_iterations" => 1000, "tolerance" => 1e-10),
        "shocks" => Any[Dict{String, Any}(
            "shock_type" => "supply_capacity_reduction",
            "target_node" => target,
            "magnitude" => OFFICIAL_SHOCK.magnitude,
            "start_period" => OFFICIAL_SHOCK.start_period,
            "duration_periods" => OFFICIAL_SHOCK.duration_periods,
            "recovery_periods" => OFFICIAL_SHOCK.recovery_periods,
        )],
        "assumptions" => Any[
            "The capacity path is stated, not estimated: nothing here says how long a real disruption would last.",
            "The shocked sector is chosen mechanically by median edge degree, not for any claim about its real-world importance.",
        ],
        "metadata" => Dict{String, Any}(
            "is_synthetic" => false,
            "title" => "Median-degree sector staged recovery on the official 2020 Japan IO network (DME negative cross-economy check)",
        ),
    )
end

"negative golden 用の mapping fixture の placeholder sector を official の sector id へメモリ上で置き換える。"
function _official_mapping(file::AbstractString, sector_ids::Vector{String})
    md = cross_model_mapping_to_dict(load_cross_model_mapping(joinpath(MAPPINGS_DIR, file)))
    md["groups"][1]["members"][1]["sector_id"] = sector_ids[1]
    md["declared_unmapped_source_sectors"] = Any[sector_ids[2:end]...]
    return cross_model_mapping_from_dict(md)
end

function generate_official_jp(pne, edp, scratch; allow_dirty::Bool = false)
    scratch = abspath(expanduser(scratch))
    mkpath(scratch)
    startswith(realpath(scratch) * "/", realpath(DME_ROOT) * "/") &&
        error("--scratch must be outside the DME repository (official data is never committed)")
    pne_commit, pne_dirty = _git_head(pne; allow_dirty = allow_dirty)
    edp_commit, edp_dirty = _git_head(edp; allow_dirty = allow_dirty)

    workbook = joinpath(scratch, "jp_io_2020_108.xlsx")
    isfile(workbook) || _uv(edp, "economic-data-provider", "fetch-jp-io", "--out", workbook)
    network_path = joinpath(scratch, "network.json")
    _uv(
        edp,
        "economic-data-provider",
        "export-production-network",
        "--source-xlsx",
        workbook,
        "--out",
        network_path,
        "--auxiliary-dir",
        joinpath(scratch, "auxiliary"),
    )
    network = _read_plain(network_path)
    target, target_degree, median_degree = _median_degree_node(network)
    scenario_path = joinpath(scratch, "scenario.json")
    write(scenario_path, canonical_json_string(_official_scenario(network["network_id"], target)))
    config = joinpath(OFFICIAL_DIR, "export_config.json")
    bridge_path, record = _run_pne_export(pne, scratch, network_path, scenario_path, config, "official_jp")

    a = load_pne_sector_output_path(bridge_path)
    ids = pne_sector_ids(a)
    observed = Dict{String, Any}()
    for (mode, file) in OFFICIAL_MODES
        r = check_cross_model_compatibility(a, _official_mapping(file, ids))
        observed[mode] = Dict{String, Any}(
            "decision" => String(r.decision),
            "geography_status" => String(r.geography_status),
            "rejection_codes" => [String(x.code) for x in r.rejections],
        )
    end

    raw = _read_plain(bridge_path)
    sectors = raw["sectors"]
    status_counts = Dict{String, Any}()
    for s in sectors
        status_counts[s["source_data_status"]] = get(status_counts, s["source_data_status"], 0) + 1
    end
    units = sort(unique([s["baseline_output"]["unit"] for s in sectors if s["baseline_output"] !== nothing]))
    bridge = Dict{String, Any}(k => v for (k, v) in raw if !(k in ("sectors", "aggregate_path")))
    table = network["metadata"]["table_identity"]
    identity = Dict{String, Any}(
        "schema_version" => BRIDGE_IDENTITY_SCHEMA_VERSION,
        "description" =>
            "Identity metadata of a production-network-sector-output-path/v1 artifact that PNE exported from the " *
            "official 2020 Japan Input-Output Tables. The sectors and aggregate_path members are withheld: " *
            "the redistribution terms of the official table have not been reviewed, so no sector identifier, " *
            "label, baseline output or output path derived from it is committed.",
        "bridge" => bridge,
        "withheld_members" => Any["aggregate_path", "sectors"],
        "sector_summary" => Dict{String, Any}(
            "count" => length(sectors),
            "source_data_status_counts" => status_counts,
            "baseline_output_units" => units,
            "aggregate_path_present" => raw["aggregate_path"] !== nothing,
        ),
        "dme_observation" => Dict{String, Any}(
            "dme_content_hash" => a.content_hash,
            "source_bytes_sha256" => a.source_bytes_sha256,
            "decoded" => true,
            "target_model" => "capex_credit_cycle",
            "modes" => observed,
            "note" =>
                "Compatibility decisions DME computed on the full official bridge artifact with the committed " *
                "mappings/ccc_official_jp_*.json, their placeholder sector ids replaced in memory by the official ones.",
        ),
        "generation" => Dict{String, Any}(
            "pne" => Dict{String, Any}("repository" => PNE_REPOSITORY, "commit" => pne_commit, "tree_dirty" => pne_dirty),
            "edp" => Dict{String, Any}("repository" => EDP_REPOSITORY, "commit" => edp_commit, "tree_dirty" => edp_dirty),
            "official_source" => Dict{String, Any}(
                "publisher" => table["publisher"],
                "collection" => table["collection"],
                "estat_table_id" => table["estat_table_id"],
                "table_year" => table["table_year"],
                "release_or_revision" => table["release_or_revision"],
                "workbook_sha256" => table["source_sha256"],
            ),
            "network" => Dict{String, Any}(
                "network_id" => network["network_id"],
                "node_count" => length(network["nodes"]),
                "edge_count" => length(network["edges"]),
            ),
            "scenario" => Dict{String, Any}(
                "scenario_id" => "dme-official-jp-staged-recovery-median-degree",
                "shock_target_rule" =>
                    "the node whose total in+out edge degree is closest to the network median (ties: smallest node_id); its id is withheld",
                "shock_target_degree" => target_degree,
                "median_degree" => median_degree,
                "magnitude" => OFFICIAL_SHOCK.magnitude,
                "start_period" => OFFICIAL_SHOCK.start_period,
                "duration_periods" => OFFICIAL_SHOCK.duration_periods,
                "recovery_periods" => OFFICIAL_SHOCK.recovery_periods,
                "horizon_periods" => OFFICIAL_HORIZON,
                "calendar_unit" => "year",
            ),
            "dynamic_record" => record,
            "export_config" => Dict{String, Any}("path" => _rel(config), "sha256" => _sha256_file(config)),
            "command" =>
                "julia --project=. $(_rel(@__FILE__)) official-jp --pne-repo <PNE> --edp-repo <EDP> --scratch <outside repo>",
        ),
    )
    text = canonical_json_string(identity)
    for s in sectors
        (occursin(s["sector_id"], text) || occursin(s["source_label"], text)) &&
            error("refusing to write: an official sector id or label would be committed")
    end
    _write_pretty_json(joinpath(OFFICIAL_DIR, "bridge_identity.json"), identity)
    println("official data and derived artifacts stay in $(scratch) (outside version control)")
    return nothing
end

# ---------------------------------------------------------------------------

function main(args)
    cmd, opts, flags = _parse_args(args)
    allow_dirty = "--allow-dirty" in flags
    if cmd == "producer"
        generate_producer(_require_repo(opts, "--pne-repo"); allow_dirty = allow_dirty)
    elseif cmd == "check"
        pne = _require_repo(opts, "--pne-repo")
        ok = check_producer(pne)
        ok &= check_vendor(pne)
        println(ok ? "no drift detected" : "drift detected")
        ok || exit(1)
    elseif cmd == "official-jp"
        haskey(opts, "--scratch") || error("--scratch is required")
        generate_official_jp(
            _require_repo(opts, "--pne-repo"),
            _require_repo(opts, "--edp-repo"),
            opts["--scratch"];
            allow_dirty = allow_dirty,
        )
    else
        error("unknown command $(cmd)")
    end
end

main(ARGS)
