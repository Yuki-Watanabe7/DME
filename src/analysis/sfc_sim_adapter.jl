# sfc_sim_adapter.jl: SIM 型 SFC モデル（src/models/sfc_sim.jl）の水準系列を、
# 部門別貸借対照表・取引フロー行列を持つ会計プリミティブ（src/sfc/）へ変換し、
# 会計恒等式検証（src/analysis/sfc_accounting.jl）まで接続する adapter。
#
# 責務: モデル方程式（sfc_sim.jl）・会計プリミティブ（sfc/）・会計検証層は変更しない。
#       水準系列 (Y, C, YD, T, G, H) から SIM の会計表現（SFCResult）を **構成** し、
#       全期の会計検証 report を保持する（自動補正なし・違反は warnings と metadata に構造化）。
#
# 設計契約: docs/models/sfc_integration_design.md §3, §5.4
#           docs/adr/0007-sfc-integration-contract.md

"""SIM 型 SFC モデルの model version（methodology.model_version へ格納）。"""
const SIM_SFC_MODEL_VERSION = "sfc-sim/1.0.0"

"""金融資産・純資産の単位（`W` を数値基準とする賃金単位）。"""
const _SIM_SFC_UNIT = "wage units (W numeraire)"

# 部門登録簿（決定的）。家計・生産（企業）・政府の 3 部門。
function _sim_sfc_sectors()
    return [
        SFCSector(id = :households, name = "家計", sector_type = :household),
        SFCSector(id = :production, name = "生産（企業）", sector_type = :firm),
        SFCSector(id = :government, name = "政府", sector_type = :government),
    ]
end

# 金融商品登録簿。政府貨幣 H（家計資産＝政府負債）と、列和を 0 にする純資産バランス行。
# 純資産行は role="net_worth" として stock_flow 検証から除外される（対応取引を持たない）。
function _sim_sfc_instruments()
    return [
        SFCInstrument(
            id = :money,
            name = "政府貨幣 H",
            issuers = [:government],
            holders = [:households],
            unit = _SIM_SFC_UNIT,
            metadata = Dict{String, Any}("role" => "financial"),
        ),
        SFCInstrument(
            id = :net_worth,
            name = "純資産（バランス項）",
            issuers = Symbol[],
            holders = Symbol[],
            unit = _SIM_SFC_UNIT,
            metadata = Dict{String, Any}("role" => "net_worth"),
        ),
    ]
end

# 1 期分のスナップショット（期末貸借対照表＋当期取引フロー）を構成する。
# 符号規約 :source_use（源泉+ / 使途−）。wages は W·N = Y（企業利潤ゼロ）、
# money_change は家計貯蓄 saving = YD − C = G − T。
function _sim_sfc_snapshot(period::AbstractString, Y, C, G, taxes, H)
    saving = G - taxes  # 家計の貨幣蓄積＝財政赤字（貨幣発行）

    # 行 = instrument, 列 = sector（資産+ / 負債−）。純資産行で列和を 0 にする。
    bs = BalanceSheetMatrix(
        instruments = [:money, :net_worth],
        sectors = [:households, :production, :government],
        holdings = [
            H 0.0 -H
            -H 0.0 H
        ],
    )

    # 行 = 取引, 列 = sector（源泉+ / 使途−）。各行・各列が 0 に閉じる。
    tf = TransactionFlowMatrix(
        transactions = [:consumption, :govt_expenditure, :wages, :taxes, :money_change],
        sectors = [:households, :production, :government],
        flows = [
            -C C 0.0
            0.0 G -G
            Y -Y 0.0
            -taxes 0.0 taxes
            -saving 0.0 saving
        ],
    )

    return SFCPeriodSnapshot(String(period), bs, tf)
end

# 系列（長さ T の Y, C, G, taxes, H）から SFCResult を構成し、会計検証を実行する共通処理。
function _sim_build_sfc(;
    model_name::AbstractString,
    scenario_name::AbstractString,
    Y,
    C,
    G,
    taxes,
    H,
    parameters,
    periods,
    shock,
    provenance::AbstractDict,
    atol::Real,
    rtol::Real,
    simulation_result,
    validate::Bool,
)
    T = length(Y)
    all(x -> length(x) == T, (C, G, taxes, H)) ||
        throw(ArgumentError("系列 Y, C, G, T, H の長さが一致しません"))
    period_labels =
        periods === nothing ? [string(t) for t in 1:T] : [string(p) for p in periods]
    length(period_labels) == T || throw(
        ArgumentError("periods の長さ $(length(period_labels)) が系列長 $T と一致しません"),
    )

    snaps = SFCPeriodSnapshot[
        _sim_sfc_snapshot(period_labels[t], Y[t], C[t], G[t], taxes[t], H[t]) for t in 1:T
    ]

    prov = Dict{String, Any}("model_version" => SIM_SFC_MODEL_VERSION)
    for (k, v) in provenance
        prov[String(k)] = v
    end
    meth = SFCMethodologyMetadata(
        model_version = SIM_SFC_MODEL_VERSION,
        sign_convention = :source_use,
        time_convention = :end_of_period,
        tolerance_abs = atol,
        tolerance_rel = rtol,
        provenance = prov,
    )

    meta = Dict{String, Any}()
    parameters === nothing || (meta["parameters"] = parameters)
    shock === nothing || (meta["shock"] = shock)

    result = SFCResult(
        model_name = model_name,
        scenario_name = scenario_name,
        sectors = _sim_sfc_sectors(),
        instruments = _sim_sfc_instruments(),
        snapshots = snaps,
        simulation_result = simulation_result,
        methodology = meth,
        warnings = String[],
        metadata = meta,
    )

    validate || return result

    report = validate_sfc_accounting(result)
    meta["accounting_status"] = accounting_status_label(report.status)
    meta["accounting_checks_performed"] = report.checks_performed
    meta["accounting_checks_passed"] = report.checks_passed
    meta["accounting_max_abs_residual"] = report.max_abs_residual
    meta["accounting_invalid_periods"] = report.invalid_periods

    warns = String[]
    for v in report.violations
        push!(
            warns,
            "[$(accounting_status_label(v.status))] $(v.check) @ period=$(v.period): $(v.message)",
        )
    end

    # warnings は SFCResult コンストラクタが複製するため、検証後に再構成する。
    return SFCResult(
        model_name = model_name,
        scenario_name = scenario_name,
        sectors = result.sectors,
        instruments = result.instruments,
        snapshots = result.snapshots,
        simulation_result = result.simulation_result,
        methodology = result.methodology,
        warnings = warns,
        metadata = meta,
    )
end

"""
    sfc_result(m::SIMModel, series::NamedTuple; scenario_name="baseline", periods=nothing,
               shock=nothing, provenance=Dict(), atol=1e-8, rtol=1e-6, validate=true) -> SFCResult

SIM モデルの水準系列 `series`（`simulate` / `impulse_response` の返り値、必須キー
`Y, C, YD, T, G, H`）を、部門別貸借対照表・取引フロー行列を持つ [`SFCResult`](@ref) へ変換する。

- 主要系列 `Y/C/YD/T/G/H`(/N) は [`to_simulation_result`](@ref) で `SimulationResult` に変換し、
  `SFCResult.simulation_result` に格納する（既存 `plot_result` / `summarize_result` にそのまま乗る）。
- `validate=true`（既定）で [`validate_sfc_accounting`](@ref) を全期に対して実行し、集約結果を
  metadata（`accounting_status` 等）に、違反を `warnings` に構造化して保持する（自動補正なし）。
- `shock`（NamedTuple / Dict 等）を渡すと `metadata["shock"]` にショック定義を保存する。

会計 report 自体は決定的なため、`validate_sfc_accounting(result)` でいつでも同一のものを再取得できる。
"""
function sfc_result(
    m::SIMModel,
    series::NamedTuple;
    scenario_name::AbstractString = "baseline",
    periods = nothing,
    shock = nothing,
    provenance::AbstractDict = Dict{String, Any}(),
    atol::Real = 1e-8,
    rtol::Real = 1e-6,
    validate::Bool = true,
)
    for k in (:Y, :C, :YD, :T, :G, :H)
        haskey(series, k) ||
            throw(ArgumentError("series に必須系列 $(repr(k)) がありません"))
    end
    sr = to_simulation_result(m, series, String(scenario_name))
    return _sim_build_sfc(
        model_name = model_name(m),
        scenario_name = scenario_name,
        Y = series.Y,
        C = series.C,
        G = series.G,
        taxes = series.T,
        H = series.H,
        parameters = parameters(m),
        periods = periods,
        shock = shock,
        provenance = provenance,
        atol = atol,
        rtol = rtol,
        simulation_result = sr,
        validate = validate,
    )
end

"""
    sfc_result(sr::SimulationResult; scenario_name=sr.scenario_name, periods=nothing,
               shock=nothing, provenance=Dict(), atol=1e-8, rtol=1e-6, validate=true) -> SFCResult

`SimulationResult` の水準系列（必須変数 `"Y", "C", "YD", "T", "G", "H"`）から SIM の
SFC 構造（部門・行列・スナップショット）を復元する adapter（設計 §5.4）。

`SimulationResult` を `simulation_result` に格納し、`metadata["parameters"]` があれば SFC 側の
metadata にも引き継ぐ。会計検証は `validate=true` で全期に対して実行する。必須変数が欠ける場合は
`ArgumentError`。
"""
function sfc_result(
    sr::SimulationResult;
    scenario_name::AbstractString = sr.scenario_name,
    periods = nothing,
    shock = nothing,
    provenance::AbstractDict = Dict{String, Any}(),
    atol::Real = 1e-8,
    rtol::Real = 1e-6,
    validate::Bool = true,
)
    for k in ("Y", "C", "YD", "T", "G", "H")
        haskey(sr, k) ||
            throw(ArgumentError("SimulationResult に必須変数 $(repr(k)) がありません"))
    end
    return _sim_build_sfc(
        model_name = sr.model_name,
        scenario_name = scenario_name,
        Y = sr["Y"],
        C = sr["C"],
        G = sr["G"],
        taxes = sr["T"],
        H = sr["H"],
        parameters = get(sr.metadata, "parameters", nothing),
        periods = periods,
        shock = shock,
        provenance = provenance,
        atol = atol,
        rtol = rtol,
        simulation_result = sr,
        validate = validate,
    )
end
