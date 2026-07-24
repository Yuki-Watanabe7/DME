# 最小 SIM 型 SFC モデル — モデル解説ドキュメント

> 関連: [SFC 統合設計](sfc_integration_design.md)（方程式・行列・型の設計書）・
> [ADR 0007](../adr/0007-sfc-integration-contract.md)（統合契約）・
> [出力結果の読み方](../simulation_outputs.md)・[モデル共通インターフェース](../architecture/model_interface.md)

---

## メタ情報

| 項目 | 内容 |
|---|---|
| **モデル名** | 最小 SIM 型 SFC（Stock-Flow Consistent）モデル |
| **Julia 型名** | `SIMModel` |
| **カテゴリ** | Stock-Flow Consistent（ポストケインジアン会計整合モデル） |
| **求解手法** | 離散時間・閉形式（毎期の再帰構造を前向き反復） |
| **実装ファイル** | `src/models/sfc_sim.jl`（モデル）・`src/analysis/sfc_sim_adapter.jl`（会計 adapter） |
| **テストファイル** | `test/test_sfc_sim.jl` |
| **出典** | Godley, W. & Lavoie, M. (2007). *Monetary Economics*, 第3章 "The Simplest Model" |

---

## 1. モデルの目的

- **主な問い**: 「政府が貨幣を発行し家計がそれを蓄積する閉鎖経済で、政府支出・税率が需要と
  家計の富（貨幣ストック）をどう決めるか。そのとき部門別の貸借対照表・取引フローは会計的に閉じるか」
- **対象経済**: 家計・生産（企業）・政府からなる閉鎖経済。金融資産は政府貨幣 `H`（high-powered money）のみ。
- **時間軸**: 無限期間・離散時間（期）。

SIM は「会計が閉じた需要決定＋政府貨幣蓄積」の最小骨格であり、DME の SFC 基盤
（「すべての金融資産は誰かの負債」「各部門の予算制約」「ストック変化＝フロー＋評価損益」を
モデル方程式と独立に検証する契約）を最小構成で実演する。

---

## 2. 経済学的直観

### なぜこのモデルが重要か

SIM は SFC アプローチの出発点であり、「政府赤字は民間（家計）の貨幣資産をちょうど同額だけ増やす」
という会計恒等式を、動学と両立する最小の枠組みで示す。すべての取引に相手方があり、
どの部門も予算制約を破らないことを毎期検証できる。

### 直観的なメカニズム

- 産出は需要で決まる（`Y = C + G`）。消費は当期可処分所得と**前期末の富**に依存する。
- 政府支出が税収を上回る（財政赤字）と、その差額だけ政府貨幣が新規発行され、家計の貨幣資産になる。
- 家計の富が積み上がると富効果で消費が増え、産出・税収も増える。やがて税収が政府支出に追いつき
  （`T = G`）、貯蓄がゼロ（`ΔH = 0`）になる定常状態へ**大域的に収束**する。
- `0 < α1 < 1` のため定常状態は安定で、危機・発散 regime を持たない。

---

## 3. 主要変数

### 状態変数

| 変数 | Julia シンボル | 意味 | 単位・時点 |
|---|---|---|---|
| 政府貨幣ストック | `:H` | 家計保有＝政府負債。家計の富 | 賃金単位（`W` 基準）・**期末** |

### 操作（内生フロー）変数

| 変数 | Julia シンボル | 意味 | 単位・時点 |
|---|---|---|---|
| 産出 | `:Y` | 総需要 `= C + G` | 賃金単位・当期フロー |
| 消費 | `:C` | 家計消費 | 賃金単位・当期フロー |
| 可処分所得 | `:YD` | `= Y − T` | 賃金単位・当期フロー |
| 税 | `:T` | 比例税 `= θ·Y` | 賃金単位・当期フロー |
| 雇用 | `:N` | `= Y / W` | 人・当期フロー |

> 返り値 NamedTuple には政策変数 `:G`（当期の政府支出系列）も含まれる（ショック時に期別で変化するため）。

### パラメータ

| 記号 | Julia | 意味 | 制約 |
|---|---|---|---|
| `α1` | `α1` | 所得からの消費性向 | `0 < α1 < 1` |
| `α2` | `α2` | 富（貨幣ストック）からの消費性向 | `0 < α2 < α1` |
| `θ` | `θ` | 税率 | `0 < θ < 1` |
| `G` | `G` | 政府支出（政策変数・外生一定） | `G ≥ 0` |
| `W` | `W` | 名目賃金率（数値基準） | `W > 0`（既定 `1.0`） |

制約に反する引数はコンストラクタで `ArgumentError`。

---

## 4. モデル方程式

名目賃金率 `W` は数値基準（既定 `1.0`）。時点添字 `t` は離散（期）。`H_{t-1}` は期首（前期末）ストック。
毎期この順で再帰的に解ける:

```
Y   = C + G                       … 産出＝需要
T   = θ · Y                       … 比例税
YD  = Y − T                       … 可処分所得
C   = α1 · YD + α2 · H_{t-1}      … 消費関数（所得＋前期富）
H   = H_{t-1} + (YD − C)          … 家計貨幣蓄積＝貯蓄
N   = Y / W                       … 雇用
```

`Y` と `C` は同時決定（`C` が `Y` に依存し `Y = C + G`）で、閉形式に解ける:

```
Y = (G + α2 · H_{t-1}) / (1 − α1 · (1 − θ))
```

`0 < α1 < 1`・`0 < θ < 1` より分母 `1 − α1·(1 − θ) ∈ (0, 1)` は常に正で、0 除算は起きない。

### 4.1 定常状態

貯蓄がゼロ（`ΔH = 0`、政府予算均衡 `T = G`）になる状態:

```
Y*  = G / θ
YD* = (1 − θ) · G / θ
H*  = (1 − α1) / α2 · YD*        … 富／可処分所得比 = (1 − α1)/α2
```

定常では `C* = YD*`（貯蓄ゼロ）・`T* = G`（予算均衡）。`steady_state(m::SIMModel)` はこの閉形式を
`(Y, C, YD, T, G, H, N)` で返す。

---

## 5. 会計表（部門別行列）

`sfc_result` は各期について次の 2 行列を構成する。符号規約は `:source_use`（源泉+ / 使途−）、
ストックは期末時点。会計恒等式は [`validate_sfc_accounting`](../api.md#sfc-会計恒等式検証エンジンvalidate_sfc_accounting)
で全期を検証する。

### 5.1 貸借対照表行列（期末ストック、資産+ / 負債−）

| instrument \ sector | households | production | government | Σ(行和) |
|---|---:|---:|---:|---:|
| money `H` | `+H` | `0` | `−H` | `0` |
| net_worth（純資産） | `−H` | `0` | `+H` | `0` |
| Σ（列和） | `0` | `0` | `0` | `0` |

- **行和 = 0**: すべての金融資産は誰かの負債（`H` は家計資産かつ政府負債）。
- **純資産バランス行**（`role="net_worth"`）で各列和を 0 にする。この行は対応する取引フローを持たないため
  stock_flow 検証から除外される。

### 5.2 取引フロー行列（当期フロー、源泉+ / 使途−）

`W·N = Y`（企業利潤ゼロ）。家計貯蓄 `saving = YD − C = G − T`。

| transaction \ sector | households | production | government | Σ(行和) |
|---|---:|---:|---:|---:|
| consumption | `−C` | `+C` | | `0` |
| govt_expenditure | | `+G` | `−G` | `0` |
| wages `W·N` | `+Y` | `−Y` | | `0` |
| taxes | `−T` | | `+T` | `0` |
| money_change `ΔH` | `−saving` | | `+saving` | `0` |
| Σ（列和・予算制約） | `0` | `0` | `0` | `0` |

- **家計**: `−C + Y − T − saving = 0`（貯蓄＝貨幣蓄積）。
- **生産**: `+C + G − Y = 0`（利潤ゼロ、`Y = C + G`）。
- **政府**: `−G + T + saving = 0`（財政赤字＝貨幣発行、`saving = G − T`）。

### 5.3 ストック・フロー整合

各部門・`money` について `H_t − H_{t-1} = money_change_t + valuation_t`（MVP は `valuation ≡ 0`）。
`money` の対応取引は規約どおり `money_change`。連続 2 期で検証され、`:source_use` 規約のため
残差 = `Δstock + flow − valuation` として評価される。

---

## 6. シナリオとショック

| シナリオ | 生成方法 |
|---|---|
| baseline | `simulate(m, H0=0.0; T)` |
| 政府支出の恒久的増加 | `impulse_response(m, ΔG; shock=:G, permanent=true)` |
| 政府支出の一時的増加 | `impulse_response(m, ΔG; shock=:G, permanent=false, shock_start=t)` |
| 税率変更 | `impulse_response(m, Δθ; shock=:θ, permanent=true)` |
| 初期資産差の移行経路 | `simulate(m, H0; T)` を異なる `H0` で比較 |

`impulse_response` は既定で定常状態 `H*` から出発する（`H0` で上書き可）。ショック後に `G < 0` または
`θ ∉ (0, 1)` となる場合は `ArgumentError`。ショック定義は `sfc_result(m, series; shock=...)` で
`SFCResult.metadata["shock"]` に保存できる。

```julia
using DME
m = SIMModel(; α1 = 0.6, α2 = 0.4, θ = 0.2, G = 20.0)

# baseline（H_0 = 0 から定常 Y*=100 へ収束）
base = simulate(m, 0.0; T = 100)

# 恒久的な政府支出増（+5 → 新定常 Y* = 25/0.2 = 125、家計資産も増加）
irf = impulse_response(m, 5.0; shock = :G, T = 200, permanent = true)

# 会計整合性の検証（全期 pass）
r = sfc_result(m, irf; scenario_name = "G_permanent",
               shock = (type = "G", size = 5.0, permanent = true))
@assert accounting_passed(validate_sfc_accounting(r))

# 既存の可視化・サマリー API に接続
plot_result(r.simulation_result; vars = ["Y", "C", "H"])
summarize_result(r.simulation_result)
```

---

## 7. 何に使えて・何に使えないか

### 使える

- 政府赤字と民間（家計）貨幣資産の会計的な対応の実演。
- 財政政策（`G`・`θ`）の需要・富・雇用への効果の定性分析。
- SFC 会計恒等式（貸借対照表・取引フロー・ストック更新）の全期検証の実演。

### 使えない（限界）

- **金融不安定性を持たない**: 銀行貸出・企業債務・利子付き資産・在庫・資本・価格変動なし。
  Minsky 的な内生的危機は Keen モデル側の役割で、SIM は大域安定な需要決定に留まる。
- **危機・発散 regime なし**: `0 < α1 < 1` で定常状態は大域安定。
- **物価・実質化を行わない**: `W` は数値基準にすぎず、名目/実質の区別・インフレは扱わない。
- **開放経済でない**: 対外部門・為替を持たない。

将来拡張（銀行・企業信用を含む本格 Minsky-SFC、複数金融商品・価格評価益）は
[ADR 0007 §11](../adr/0007-sfc-integration-contract.md) を参照。責務境界は型・行列表現に残してあり、
既存契約を破壊せず値を入れるだけで拡張できる形にしている。

---

## 参考

- Godley, W. & Lavoie, M. (2007). *Monetary Economics: An Integrated Approach to Credit, Money,
  Income, Production and Wealth*, 第3章.
- [SFC 統合設計（最小 SIM 型モデル）](sfc_integration_design.md)
- [ADR 0007: SFC 統合契約](../adr/0007-sfc-integration-contract.md)
- [API リファレンス](../api.md)（`SIMModel` 計算 API・`sfc_result` adapter・会計検証エンジン）
