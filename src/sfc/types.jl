# SFC（Stock-Flow Consistent）会計プリミティブ — 標準データ構造
#
# 部門・金融商品・貸借対照表・取引フロー・期別スナップショットを型安全かつ決定的に
# 表現するための標準型。会計恒等式の判定ロジック・モデル方程式・可視化・LLM 説明は
# ここでは扱わない（責務分離。判定は後続の会計検証層が担う）。
#
# 設計契約: docs/adr/0007-sfc-integration-contract.md
#           docs/models/sfc_integration_design.md
#
# 主な規約:
#   - 安定 ID（Symbol）と表示名（String）を分離する。ID が保存形式・比較キーであり、
#     表示名の変更で JSON やキー順が壊れないようにする。
#   - sector・instrument・transaction の順序は入力順や Dict 反復順に依存させず、
#     stable id の文字列昇順へ正準化して決定的にする。
#   - 金額は Float64 を基本とし、非有限値（NaN / Inf / -Inf）は拒否せず保持する。
#     保存時は文字列タグ（"NaN" / "Inf" / "-Inf"）へ符号化して round-trip で失われないようにする
#     （src/sfc/serialization.jl）。
#   - 不整合の自動補正・残差の押込みは行わない。重複 ID・未知参照・次元不一致はコンストラクタで拒否する。

"""SFC 会計プリミティブ契約のバージョン。"""
const SFC_CONTRACT_VERSION = "sfc-primitives/1.0.0"

"""許容する sector type の語彙。"""
const SFC_SECTOR_TYPES =
    (:household, :firm, :government, :bank, :central_bank, :rest_of_world, :other)

"""
許容する符号規約。

- `:source_use`   … 取引フローで資金の源泉を正、使途を負とする（ADR 0007 既定）。
- `:receipt_payment` … 受取を正、支払を負とする代替規約。
"""
const SFC_SIGN_CONVENTIONS = (:source_use, :receipt_payment)

"""
許容する時点規約。

- `:end_of_period` … ストックは期末時点（ADR 0007 の貸借対照表規約）。
- `:during_period` … フローは当期中。
"""
const SFC_TIME_CONVENTIONS = (:end_of_period, :during_period)

# ---------------------------------------------------------------------------
# 内部バリデーションヘルパー
# ---------------------------------------------------------------------------

function _sfc_check_unique(ids, what::AbstractString)
    seen = Set{Symbol}()
    dups = Symbol[]
    for x in ids
        s = Symbol(x)
        if s in seen
            push!(dups, s)
        else
            push!(seen, s)
        end
    end
    isempty(dups) ||
        throw(ArgumentError("$what の stable id が重複しています: $(unique(dups))"))
    return nothing
end

function _sfc_check_refs(
    ids,
    allowed::Set{Symbol},
    what::AbstractString,
    where::AbstractString,
)
    for x in ids
        Symbol(x) in allowed ||
            throw(ArgumentError("$where が未知の $what を参照しています: $(repr(x))"))
    end
    return nothing
end

# ---------------------------------------------------------------------------
# 部門・金融商品
# ---------------------------------------------------------------------------

"""
    SFCSector(id, name, sector_type, metadata)
    SFCSector(; id, name, sector_type=:other, metadata=Dict{String,Any}())

会計主体（部門）。`id` が安定 ID、`name` が表示名。`sector_type` は
[`SFC_SECTOR_TYPES`](@ref) のいずれか。
"""
struct SFCSector
    id::Symbol
    name::String
    sector_type::Symbol
    metadata::Dict{String, Any}

    function SFCSector(id, name, sector_type, metadata)
        stype = Symbol(sector_type)
        stype in SFC_SECTOR_TYPES || throw(
            ArgumentError("未知の sector_type: $(repr(stype))。許容: $(SFC_SECTOR_TYPES)"),
        )
        return new(Symbol(id), String(name), stype, metadata)
    end
end

SFCSector(; id, name, sector_type = :other, metadata = Dict{String, Any}()) =
    SFCSector(id, name, sector_type, metadata)

"""
    SFCInstrument(id, name, issuers, holders, unit, metadata)
    SFCInstrument(; id, name, issuers=Symbol[], holders=Symbol[], unit="", metadata=Dict{String,Any}())

金融商品。`issuers` は負債として発行しうる部門 ID の集合、`holders` は資産として
保有しうる部門 ID の集合。両者は決定性のため stable id 昇順へ正準化して保持する。
"""
struct SFCInstrument
    id::Symbol
    name::String
    issuers::Vector{Symbol}
    holders::Vector{Symbol}
    unit::String
    metadata::Dict{String, Any}

    function SFCInstrument(id, name, issuers, holders, unit, metadata)
        iss = Symbol[Symbol(x) for x in issuers]
        hol = Symbol[Symbol(x) for x in holders]
        _sfc_check_unique(iss, "issuer")
        _sfc_check_unique(hol, "holder")
        return new(
            Symbol(id),
            String(name),
            sort(iss; by = string),
            sort(hol; by = string),
            String(unit),
            metadata,
        )
    end
end

SFCInstrument(;
    id,
    name,
    issuers = Symbol[],
    holders = Symbol[],
    unit = "",
    metadata = Dict{String, Any}(),
) = SFCInstrument(id, name, issuers, holders, unit, metadata)

# ---------------------------------------------------------------------------
# 貸借対照表行列・取引フロー行列
# ---------------------------------------------------------------------------

"""
    BalanceSheetMatrix(instruments, sectors, holdings)
    BalanceSheetMatrix(; instruments, sectors, holdings)

期末ストックの貸借対照表行列。行 = instrument、列 = sector。符号は資産 `+` / 負債 `−`。
`holdings` は `(length(instruments), length(sectors))` 次元。instrument・sector は
stable id 昇順へ正準化し、`holdings` も対応して並べ替える（入力順に依存しない）。
"""
struct BalanceSheetMatrix
    instruments::Vector{Symbol}
    sectors::Vector{Symbol}
    holdings::Matrix{Float64}

    function BalanceSheetMatrix(instruments, sectors, holdings)
        inst = Symbol[Symbol(x) for x in instruments]
        sect = Symbol[Symbol(x) for x in sectors]
        _sfc_check_unique(inst, "instrument")
        _sfc_check_unique(sect, "sector")
        size(holdings) == (length(inst), length(sect)) || throw(
            ArgumentError(
                "holdings の次元 $(size(holdings)) が (instruments, sectors) = " *
                "($(length(inst)), $(length(sect))) と一致しません",
            ),
        )
        ip = sortperm(inst; by = string)
        sp = sortperm(sect; by = string)
        H = Matrix{Float64}(undef, length(inst), length(sect))
        @inbounds for (r, i) in enumerate(ip), (c, j) in enumerate(sp)
            H[r, c] = Float64(holdings[i, j])
        end
        return new(inst[ip], sect[sp], H)
    end
end

BalanceSheetMatrix(; instruments, sectors, holdings) =
    BalanceSheetMatrix(instruments, sectors, holdings)

"""
    TransactionFlowMatrix(transactions, sectors, flows)
    TransactionFlowMatrix(; transactions, sectors, flows)

当期フローの取引フロー行列。行 = 取引種別、列 = sector。符号規約（源泉/使途 または
受取/支払）は [`SFCMethodologyMetadata`](@ref) で保持する。`flows` は
`(length(transactions), length(sectors))` 次元。transaction・sector は
stable id 昇順へ正準化する。
"""
struct TransactionFlowMatrix
    transactions::Vector{Symbol}
    sectors::Vector{Symbol}
    flows::Matrix{Float64}

    function TransactionFlowMatrix(transactions, sectors, flows)
        tx = Symbol[Symbol(x) for x in transactions]
        sect = Symbol[Symbol(x) for x in sectors]
        _sfc_check_unique(tx, "transaction")
        _sfc_check_unique(sect, "sector")
        size(flows) == (length(tx), length(sect)) || throw(
            ArgumentError(
                "flows の次元 $(size(flows)) が (transactions, sectors) = " *
                "($(length(tx)), $(length(sect))) と一致しません",
            ),
        )
        tp = sortperm(tx; by = string)
        sp = sortperm(sect; by = string)
        F = Matrix{Float64}(undef, length(tx), length(sect))
        @inbounds for (r, i) in enumerate(tp), (c, j) in enumerate(sp)
            F[r, c] = Float64(flows[i, j])
        end
        return new(tx[tp], sect[sp], F)
    end
end

TransactionFlowMatrix(; transactions, sectors, flows) =
    TransactionFlowMatrix(transactions, sectors, flows)

# ---------------------------------------------------------------------------
# 導出量（総資産・総負債・純資産・要素参照）
# ---------------------------------------------------------------------------

function _sfc_axis_index(axis::Vector{Symbol}, id, what::AbstractString)
    idx = findfirst(==(Symbol(id)), axis)
    idx === nothing && throw(ArgumentError("$what $(repr(id)) は行列に存在しません"))
    return idx
end

"""
    holding(bs::BalanceSheetMatrix, instrument_id, sector_id) -> Float64

指定 instrument × sector の期末ストックを返す。
"""
holding(bs::BalanceSheetMatrix, instrument_id, sector_id) = bs.holdings[
    _sfc_axis_index(bs.instruments, instrument_id, "instrument"),
    _sfc_axis_index(bs.sectors, sector_id, "sector"),
]

"""
    flow_value(tf::TransactionFlowMatrix, transaction_id, sector_id) -> Float64

指定 transaction × sector の当期フローを返す。
"""
flow_value(tf::TransactionFlowMatrix, transaction_id, sector_id) = tf.flows[
    _sfc_axis_index(tf.transactions, transaction_id, "transaction"),
    _sfc_axis_index(tf.sectors, sector_id, "sector"),
]

"""
    net_worth(bs::BalanceSheetMatrix, sector_id) -> Float64

部門の純資産（列和）。非有限値があれば伝播する。
"""
net_worth(bs::BalanceSheetMatrix, sector_id) =
    sum(@view(bs.holdings[:, _sfc_axis_index(bs.sectors, sector_id, "sector")]); init = 0.0)

"""
    total_assets(bs::BalanceSheetMatrix, sector_id) -> Float64

部門の総資産（正の保有の合計）。非有限値は集計から除外する（規約）。
"""
total_assets(bs::BalanceSheetMatrix, sector_id) = sum(
    x -> isfinite(x) && x > 0 ? x : 0.0,
    @view(bs.holdings[:, _sfc_axis_index(bs.sectors, sector_id, "sector")]);
    init = 0.0,
)

"""
    total_liabilities(bs::BalanceSheetMatrix, sector_id) -> Float64

部門の総負債（負の保有の絶対値の合計、正の数で返す）。非有限値は除外する（規約）。
"""
total_liabilities(bs::BalanceSheetMatrix, sector_id) = sum(
    x -> isfinite(x) && x < 0 ? -x : 0.0,
    @view(bs.holdings[:, _sfc_axis_index(bs.sectors, sector_id, "sector")]);
    init = 0.0,
)

"""
    zero_valuation(bs::BalanceSheetMatrix) -> BalanceSheetMatrix

`bs` と同じ instrument × sector 軸を持つ、全要素ゼロの評価調整行列を返す
（MVP では評価損益は 0 の独立項）。
"""
zero_valuation(bs::BalanceSheetMatrix) =
    BalanceSheetMatrix(bs.instruments, bs.sectors, zeros(Float64, size(bs.holdings)))

# ---------------------------------------------------------------------------
# 期別スナップショット・methodology metadata・結果型
# ---------------------------------------------------------------------------

"""
    SFCPeriodSnapshot(period, balance_sheet, transaction_flow, valuation_adjustment, warnings)
    SFCPeriodSnapshot(period, balance_sheet, transaction_flow; valuation_adjustment=zero_valuation(balance_sheet), warnings=String[])

1 期分のスナップショット。`period` は期ラベル、`valuation_adjustment` は評価調整
（貸借対照表と同じ軸、MVP では全ゼロ）、`warnings` は非致命的な注記。
"""
struct SFCPeriodSnapshot
    period::String
    balance_sheet::BalanceSheetMatrix
    transaction_flow::TransactionFlowMatrix
    valuation_adjustment::BalanceSheetMatrix
    warnings::Vector{String}
end

SFCPeriodSnapshot(
    period,
    balance_sheet::BalanceSheetMatrix,
    transaction_flow::TransactionFlowMatrix;
    valuation_adjustment::BalanceSheetMatrix = zero_valuation(balance_sheet),
    warnings = String[],
) = SFCPeriodSnapshot(
    String(period),
    balance_sheet,
    transaction_flow,
    valuation_adjustment,
    String[String(w) for w in warnings],
)

"""
    SFCMethodologyMetadata(contract_version, model_version, sign_convention, time_convention, tolerance_abs, tolerance_rel, provenance)
    SFCMethodologyMetadata(; contract_version=SFC_CONTRACT_VERSION, model_version="", sign_convention=:source_use, time_convention=:end_of_period, tolerance_abs=1e-8, tolerance_rel=1e-6, provenance=Dict{String,Any}())

方法論メタデータ。契約/モデルのバージョン、符号規約、時点規約、許容誤差、provenance を保持する。
"""
struct SFCMethodologyMetadata
    contract_version::String
    model_version::String
    sign_convention::Symbol
    time_convention::Symbol
    tolerance_abs::Float64
    tolerance_rel::Float64
    provenance::Dict{String, Any}

    function SFCMethodologyMetadata(
        contract_version,
        model_version,
        sign_convention,
        time_convention,
        tolerance_abs,
        tolerance_rel,
        provenance,
    )
        sc = Symbol(sign_convention)
        tc = Symbol(time_convention)
        sc in SFC_SIGN_CONVENTIONS || throw(
            ArgumentError(
                "未知の sign_convention: $(repr(sc))。許容: $(SFC_SIGN_CONVENTIONS)",
            ),
        )
        tc in SFC_TIME_CONVENTIONS || throw(
            ArgumentError(
                "未知の time_convention: $(repr(tc))。許容: $(SFC_TIME_CONVENTIONS)",
            ),
        )
        (tolerance_abs >= 0 && tolerance_rel >= 0) || throw(
            ArgumentError(
                "許容誤差 tolerance_abs / tolerance_rel は非負でなければなりません",
            ),
        )
        return new(
            String(contract_version),
            String(model_version),
            sc,
            tc,
            Float64(tolerance_abs),
            Float64(tolerance_rel),
            provenance,
        )
    end
end

SFCMethodologyMetadata(;
    contract_version = SFC_CONTRACT_VERSION,
    model_version = "",
    sign_convention = :source_use,
    time_convention = :end_of_period,
    tolerance_abs = 1e-8,
    tolerance_rel = 1e-6,
    provenance = Dict{String, Any}(),
) = SFCMethodologyMetadata(
    contract_version,
    model_version,
    sign_convention,
    time_convention,
    tolerance_abs,
    tolerance_rel,
    provenance,
)

"""
    SFCResult(model_name, scenario_name, sectors, instruments, snapshots, simulation_result, methodology, warnings, metadata)
    SFCResult(; model_name, scenario_name, sectors, instruments, snapshots=SFCPeriodSnapshot[], simulation_result=nothing, methodology, warnings=String[], metadata=Dict{String,Any}())

SFC 結果型。既存の [`SimulationResult`](@ref)（任意）と、部門・金融商品の登録簿、
期別スナップショット、方法論メタデータ、構造検証で得た注記を束ねる。

コンストラクタは次を保証する（会計恒等式の判定は対象外）:

- `sectors` / `instruments` を stable id 昇順へ正準化し、ID 重複を拒否する。
- 各スナップショットの行列軸が登録簿に存在する sector / instrument のみを参照することを検証する
  （未知参照は `ArgumentError`）。
"""
struct SFCResult
    model_name::String
    scenario_name::String
    sectors::Vector{SFCSector}
    instruments::Vector{SFCInstrument}
    snapshots::Vector{SFCPeriodSnapshot}
    simulation_result::Union{SimulationResult, Nothing}
    methodology::SFCMethodologyMetadata
    warnings::Vector{String}
    metadata::Dict{String, Any}

    function SFCResult(
        model_name,
        scenario_name,
        sectors,
        instruments,
        snapshots,
        simulation_result,
        methodology,
        warnings,
        metadata,
    )
        sec = sort(collect(SFCSector, sectors); by = s -> string(s.id))
        ins = sort(collect(SFCInstrument, instruments); by = i -> string(i.id))
        _sfc_check_unique([s.id for s in sec], "sector")
        _sfc_check_unique([i.id for i in ins], "instrument")

        sector_ids = Set(s.id for s in sec)
        instrument_ids = Set(i.id for i in ins)
        snaps = collect(SFCPeriodSnapshot, snapshots)
        for (k, snap) in enumerate(snaps)
            tag = "snapshot[$k]（period=$(repr(snap.period))）"
            _sfc_check_refs(
                snap.balance_sheet.instruments,
                instrument_ids,
                "instrument",
                "$tag.balance_sheet",
            )
            _sfc_check_refs(
                snap.balance_sheet.sectors,
                sector_ids,
                "sector",
                "$tag.balance_sheet",
            )
            _sfc_check_refs(
                snap.transaction_flow.sectors,
                sector_ids,
                "sector",
                "$tag.transaction_flow",
            )
            _sfc_check_refs(
                snap.valuation_adjustment.instruments,
                instrument_ids,
                "instrument",
                "$tag.valuation_adjustment",
            )
            _sfc_check_refs(
                snap.valuation_adjustment.sectors,
                sector_ids,
                "sector",
                "$tag.valuation_adjustment",
            )
        end

        return new(
            String(model_name),
            String(scenario_name),
            sec,
            ins,
            snaps,
            simulation_result,
            methodology,
            String[String(w) for w in warnings],
            metadata,
        )
    end
end

SFCResult(;
    model_name,
    scenario_name,
    sectors,
    instruments,
    snapshots = SFCPeriodSnapshot[],
    simulation_result = nothing,
    methodology = SFCMethodologyMetadata(),
    warnings = String[],
    metadata = Dict{String, Any}(),
) = SFCResult(
    model_name,
    scenario_name,
    sectors,
    instruments,
    snapshots,
    simulation_result,
    methodology,
    warnings,
    metadata,
)
