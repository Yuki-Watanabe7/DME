# Stock-Flow Consistent（SFC）統合設計 — 最小 SIM 型モデル

> 関連Issue: #99（ロードマップ）・#145（本設計）
> 前提: [Minsky系金融不安定性モデル 設計方針](minsky_design.md)（Godley-Lavoie を候補比較）・[ADR 0007](../adr/0007-sfc-integration-contract.md)（統合契約の決定記録）

---

## 1. 背景と目的

既存の Keen モデル（連続時間 ODE）は所得分配と民間債務の動学を扱うが、
部門別の貸借対照表と取引フローが会計的に閉じている（stock-flow consistent）ことを
明示的な検証対象としていない。DME に **SFC 基盤** を導入し、
「すべての金融資産は誰かの負債」「各部門の予算制約」「ストック変化＝フロー＋評価損益」
という会計恒等式を、モデル方程式とは独立した検証契約として持たせる。

本ドキュメントは初版 SFC モデルとして採用する **SIM 型モデル**
（Godley & Lavoie, *Monetary Economics*, 2007, 第3章 "The Simplest Model"）の
方程式・部門・金融資産・政策変数・行列表現・型/API スケッチを記述する実装着手可能な設計書である。
統合契約の決定記録は [ADR 0007](../adr/0007-sfc-integration-contract.md) を参照。実装は後続Issue（#146 以降）で行う。

### 1.1 MVP と非対象範囲

| 区分 | 内容 |
|---|---|
| **MVP 対象** | 家計・政府・生産部門からなる閉鎖経済。金融資産は政府貨幣（high-powered money）`H` のみ。政策変数は政府支出 `G` と税率 `θ`。 |
| **MVP 非対象（将来拡張）** | 銀行貸出、企業債務、中央銀行、複数金融商品（債券・株式）、価格評価益（valuation gains）、開放経済。責務境界だけを型・行列表現に残し、機能は実装しない。 |

非対象を「型で表現できるが値は空/ゼロ」として残すことで、本格 Minsky-SFC（銀行・企業信用を含む）への
拡張時に既存契約を破壊しない。詳細は ADR 0007 §11（将来拡張）。

---

## 2. SIM 型モデルの方程式

閉鎖経済・政府貨幣のみ・企業は利潤ゼロの純導管（在庫・資本なし）。名目賃金率 `W` は数値基準（既定 `1.0`）。
時点添字 `t` は離散（期）。`H_{t-1}` は期首（前期末）ストック。

| 記号 | 定義 | 種別 |
|---|---|---|
| `Y` | 産出 = 総需要 | 内生フロー |
| `C` | 消費 | 内生フロー |
| `G` | 政府支出 | 政策変数（外生一定） |
| `T` | 税 | 内生フロー |
| `YD` | 可処分所得 | 内生フロー |
| `N` | 雇用 | 内生フロー |
| `H` | 政府貨幣ストック（家計保有＝政府負債） | 内生ストック（状態変数） |
| `θ` | 税率 `0<θ<1` | 政策/構造パラメータ |
| `α1` | 所得からの消費性向 `0<α1<1` | 行動パラメータ |
| `α2` | 富（貨幣ストック）からの消費性向 `0<α2<α1` | 行動パラメータ |
| `W` | 名目賃金率（数値基準） | 構造パラメータ |

方程式系（毎期この順で解ける再帰構造）:

```
Y   = C + G                       … 産出＝需要
T   = θ · Y                       … 比例税（賃金所得 W·N = Y に課税）
YD  = Y − T                       … 可処分所得
C   = α1 · YD + α2 · H_{t-1}      … 消費関数（所得＋富）
H   = H_{t-1} + (YD − C)          … 家計貨幣蓄積＝貯蓄
N   = Y / W                       … 雇用
```

`Y` と `C` は同時決定（`C` が `Y` に依存し `Y=C+G`）。閉形式で解ける:

```
Y = (G + α2 · H_{t-1}) / (1 − α1 · (1 − θ))
```

### 2.1 定常状態

貯蓄がゼロ（`ΔH = 0`）になる状態:

```
Y*  = G / θ                       … 政府予算均衡 T=G
YD* = (1 − θ) · G / θ
H*  = (1 − α1) / α2 · YD*         … 富／可処分所得比 = (1−α1)/α2
```

`steady_state(m::SIMModel)` はこの閉形式を返す。`simulate` は初期ストック `H_0`（既定 `0.0`）からの反復。
ショック（`G` または `θ` の恒久変化）は `impulse_response` / シナリオ比較で表現する（既存モデルと同様）。

---

## 3. 部門・金融資産・行列表現

### 3.1 部門と金融商品の安定 ID

sector・instrument は**安定 ID（`Symbol`）と表示名（`String`）を分離**する（ADR 0007 §1）。

| sector ID | 表示名 |
|---|---|
| `:households` | 家計 |
| `:production` | 生産（企業） |
| `:government` | 政府 |

| instrument ID | 表示名 | `is_financial` |
|---|---|---|
| `:money` | 政府貨幣 `H` | `true` |

### 3.2 貸借対照表行列（balance sheet matrix）

- **方向**: 行 = instrument、列 = sector。
- **符号規約**: 資産 = 正、負債 = 負。
- **時点**: 期末ストック（期 `t` 末）。
- **balance（純資産）行**: 各列の資産合計の符号反転。列和 = 0 を保証する。

SIM の期末貸借対照表（金融資産は `H` のみ）:

| instrument \ sector | households | production | government | Σ(行和) |
|---|---:|---:|---:|---:|
| money `H` | `+H` | `0` | `−H` | `0` |
| balance（純資産） | `−H` | `0` | `+H` | `0` |
| Σ（列和） | `0` | `0` | `0` | `0` |

- **行和 = 0**: すべての金融資産は誰かの負債（`H` は家計資産かつ政府負債）。
- **純資産**: 家計 `+H`、政府 `−H`、生産 `0`。

### 3.3 取引フロー行列（transaction-flow matrix）

- **方向**: 行 = 取引種別、列 = sector。
- **符号規約**: 資金の源泉（source of funds）= 正、資金の使途（use of funds）= 負（Godley-Lavoie 規約）。
- **時点**: 期中フロー（期 `t`）。

SIM の取引フロー行列:

| transaction \ sector | households | production | government | Σ(行和) |
|---|---:|---:|---:|---:|
| consumption | `−C` | `+C` | | `0` |
| govt. expenditure | | `+G` | `−G` | `0` |
| wages `W·N` | `+WN` | `−WN` | | `0` |
| taxes | `−T` | | `+T` | `0` |
| Δ money stock `ΔH` | `−ΔH_h` | | `+ΔH_g` | `0` |
| Σ（列和・予算制約） | `0` | `0` | `0` | `0` |

列和（部門予算制約）:

- **家計**: `−C + WN − T − ΔH_h = 0` → `ΔH_h = YD − C`（貯蓄＝貨幣蓄積）。
- **生産**: `+C + G − WN = 0` → `WN = Y`（利潤ゼロ）。
- **政府**: `−G + T + ΔH_g = 0` → `ΔH_g = G − T`（財政赤字＝貨幣発行）。

`ΔH_h`（家計の貨幣蓄積・資産増）は使途 `−`、`ΔH_g`（政府の貨幣発行・負債増）は源泉 `+`。

---

## 4. 会計恒等式の検証契約

会計恒等式は**モデル方程式とは別の検証対象**として実装する（ADR 0007 §4-5）。
自動補正で不整合を隠さず、違反を構造化して返す。

| 検証名 (`Symbol`) | 内容 |
|---|---|
| `:balance_row_sum` | 貸借対照表 各 instrument 行の行和 = 0（資産＝負債対応） |
| `:balance_column_sum` | 貸借対照表 各 sector 列の列和 = 0（純資産行込み） |
| `:flow_row_sum` | 取引フロー 各取引 行の行和 = 0（すべてのフローに相手方） |
| `:flow_column_sum` | 取引フロー 各 sector 列の列和 = 0（部門予算制約） |
| `:stock_flow` | `stock_t − stock_{t-1} = transaction_flow_t + valuation_change_t` |

### 4.1 ストック・フロー整合式

各部門・各 instrument について:

```
stock_t − stock_{t-1} = transaction_flow_t + valuation_change_t
```

MVP では `valuation_change_t ≡ 0`（政府貨幣は額面固定・単一資産・価格評価益なし）。
ただし恒等式には**独立項として明示保持**し、将来の複数金融商品・価格変動導入時に値を入れるだけで拡張できる形にする。

家計の `H` を例にすると:

```
H_t − H_{t-1} = (YD_t − C_t) + 0
```

これは取引フロー行列の家計 `ΔH_h` 行と一致する（会計が閉じている）。

### 4.2 許容誤差・異常値の扱い

| 状況 | 扱い |
|---|---|
| 残差 `r` の合否 | `|r| ≤ atol + rtol · scale`（`scale` は関与する項の絶対値の代表値）で判定。既定 `atol=1e-8`, `rtol=1e-6` |
| `NaN` / `Inf` | その期の該当検証を `passed=false`・`residual=NaN`（または `Inf`）として構造化記録。例外にせず invalid 期として集計 |
| 欠損 | 検証不能として `passed=false`・理由を `detail` に記録 |
| 発散 | ストックが `Inf`/閾値超過となった最初の期を `divergence_time` に記録し、以降を invalid 期に分類 |

自動的な丸め・補正・クリップは行わない。違反は下記 `AccountingCheck` の配列として返す（ADR 0007 §5）。

---

## 5. 型・API スケッチ（実装は後続Issue）

### 5.1 モデル型

`src/models/sfc_sim.jl`（既存 `models/` include ブロックに追加。`core/model_interface.jl` の後）:

```julia
struct SIMModel <: AbstractMacroModel
    α1::Float64   # 所得からの消費性向 (0<α1<1)
    α2::Float64   # 富からの消費性向 (0<α2<α1)
    θ::Float64    # 税率 (0<θ<1)
    G::Float64    # 政府支出（政策変数・外生一定）
    W::Float64    # 名目賃金率（数値基準・既定 1.0）
end
```

`AbstractMacroModel` インターフェース（`model_name` / `state_variables` / `control_variables` /
`parameters` / `steady_state` / `simulate` / `impulse_response`）を実装。
`simulate` は水準系列の `NamedTuple` `(Y, C, G, T, YD, H, N)` を返し、
汎用 `to_simulation_result(::AbstractMacroModel, ::NamedTuple, scenario)` で `SimulationResult` へ変換する
（既存の cross-model 表面と可視化・`compare_with_data` にそのまま乗る）。

### 5.2 SFC 固有結果型と検証層

`src/analysis/sfc_accounting.jl`（`core/simulation_result.jl` の後に include。Minsky 診断層と同じ配置方針）:

```julia
struct SectorDef;     id::Symbol; label::String; end
struct InstrumentDef; id::Symbol; label::String; is_financial::Bool; end

struct BalanceSheetMatrix           # 期末ストック（資産+ / 負債−）
    instruments::Vector{Symbol}     # 行
    sectors::Vector{Symbol}         # 列
    holdings::Matrix{Float64}       # rows=instrument, cols=sector
    period::Int
end

struct TransactionFlowMatrix        # 期中フロー（源泉+ / 使途−）
    transactions::Vector{Symbol}    # 行
    sectors::Vector{Symbol}         # 列
    flows::Matrix{Float64}          # rows=transaction, cols=sector
    period::Int
end

struct AccountingCheck
    name::Symbol          # :balance_row_sum / :balance_column_sum / :flow_row_sum / :flow_column_sum / :stock_flow
    period::Int
    residual::Float64
    tolerance_abs::Float64
    tolerance_rel::Float64
    passed::Bool
    detail::String
end

struct SFCResult
    model_name::String
    scenario_name::String
    sectors::Vector{SectorDef}
    instruments::Vector{InstrumentDef}
    balance_sheets::Vector{BalanceSheetMatrix}        # 期末（各期）
    transaction_flows::Vector{TransactionFlowMatrix}  # 期中（各期）
    valuation_changes::Vector{Matrix{Float64}}        # MVP は全ゼロ。独立項として保持
    checks::Vector{AccountingCheck}
    methodology_version::String                        # 例 "sfc-sim/1.0.0"
    valid_periods::Vector{Int}
    invalid_periods::Vector{Int}
    divergence_time::Union{Int, Nothing}
    metadata::Dict{String, Any}
end
```

### 5.3 adapter と検証関数

Minsky 診断層と同じ「`SimulationResult` を消費して richer な型を返す」idiom:

```julia
# SimulationResult（水準系列）から SFC 構造を復元して会計検証まで行う
sfc_result(sr::SimulationResult; atol=1e-8, rtol=1e-6) -> SFCResult

# 会計恒等式だけを検査（補正しない・違反を構造化）
check_accounting(r::SFCResult; atol=1e-8, rtol=1e-6) -> Vector{AccountingCheck}
```

`sfc_result` は `sr` に `Y, C, G, T, YD, H` 系列と `sr.metadata["parameters"]`（`θ, W` 等）が
あることを要求し、無ければ `ArgumentError`（Minsky 診断層の契約と同じ）。
`SIMModel` 経由の `NamedTuple` overload と内部コアを共有し、両経路で同一結果を保証する。

---

## 6. 既存 API・cross-model 層との接続

| 接続先 | 方針 |
|---|---|
| `SimulationResult` | SFC の水準系列（`Y,C,G,T,YD,H,N`）を格納。SFC 固有の行列・検証は `SFCResult` 側に分離（責務境界＝ ADR 0007 §7）。 |
| `compare_with_data` | 既存シグネチャ（`SimulationResult × SimulationResult; mapping`）を破壊しない。SFC は水準系列を出すため既存比較に即乗る。部門別ストック/フロー比較は比較 API v2（加算的・後方互換）で対応（ADR 0007 §9）。 |
| `ModelMetadata` | `SIMModel` から自動生成（既存 `ModelMetadata(::AbstractMacroModel)`）。 |
| cross-model 概念 registry | `MODEL_CONCEPT_REGISTRY` に `:sim` の `ModelConceptCoverage` 行を追加。`_XM_MODEL_LABELS` にも `:sim` を追加。SFC は `:private_debt_credit`（政府債務／貨幣）・`:demand_and_instability`（需要決定）で登録し、同名変数の定義差は `caveats` に明示（ADR 0006 の非同一視方針を継承）。 |
| LLM 説明層 | ADR 0007 §10 の必須情報（部門・金融資産・会計恒等式・違反の有無・methodology version・provenance）を渡す。会計違反があれば「モデル出力の信頼性が損なわれている」旨を必ず明示。 |

---

## 7. 限界

- SIM は銀行・企業信用・利子付き資産・在庫・資本・価格変動を持たない。金融不安定性の内生化は Keen 側の役割で、SIM は「会計が閉じた需要決定＋政府貨幣蓄積」の最小骨格に留まる。
- 定常状態は大域安定（`0<α1<1`）で、危機 regime を持たない。Minsky 的動学の SFC 版は本格 Minsky-SFC（次期 Roadmap 候補、ADR 0007 §11）で扱う。
- 名目賃金 `W` は数値基準にすぎず、物価・実質化は行わない。

---

## 参考

- Godley, W. & Lavoie, M. (2007). *Monetary Economics: An Integrated Approach to Credit, Money, Income, Production and Wealth*, 第3章.
- [ADR 0007: SFC 統合契約](../adr/0007-sfc-integration-contract.md)
- [Minsky系金融不安定性モデル 設計方針](minsky_design.md) — Godley-Lavoie(SFC) を含む候補比較
- [出力結果の読み方](../simulation_outputs.md) — 水準・偏差・ストック/フローの別
- [モデル共通インターフェース](../architecture/model_interface.md)
