# Minsky系（Keen）モデル DME統合設計

> 関連Issue: #99（ロードマップ）・#101（統合設計）
> 前提: [Minsky系金融不安定性モデル 設計方針](minsky_design.md)・[ADR 0001](../adr/0001-minsky-model-selection.md)（Keen モデル採用決定）

---

## 1. 背景と目的

#100 / ADR 0001 で DME 初版の Minsky 系モデルとして **Keen モデル**
（Grasselli & Costa Lima 2012 定式化、3 変数 ODE 系）を採用した。
本ドキュメントは、Keen モデルを既存 DME アーキテクチャ
（`AbstractMacroModel` インターフェース・`SimulationResult`・可視化・LLM 層）へ
統合するための実装着手可能な設計書である。実装そのものは後続Issueで行う。

統合設計の決定記録は [ADR 0002](../adr/0002-minsky-integration-design.md) を参照。

---

## 2. Model インターフェースへの適合方針

### 2.1 型定義

```julia
struct KeenModel <: AbstractMacroModel
    α::Float64    # 労働生産性成長率
    β::Float64    # 労働人口成長率
    δ::Float64    # 資本減耗率
    ν::Float64    # 資本産出比率
    r::Float64    # 貸出金利（実質・一定）
    φ0::Float64   # Phillips 曲線の定数項
    φ1::Float64   # Phillips 曲線の感応度
    κ0::Float64   # 投資関数の定数項
    κ1::Float64   # 投資関数のスケール
    κ2::Float64   # 投資関数の利潤感応度
end
```

- ファイルは `src/models/keen.jl` に配置する
- 既存モデルと同様、コンストラクタでのパラメータ検証は行わず、想定域は docstring に記載する
- モデル名は選定したモデル名に合わせ `KeenModel` とする（Minsky 系であることは docs で説明する）

### 2.2 メタ情報関数（実装必須）

```julia
model_name(::KeenModel)        = "Keen Model"
state_variables(::KeenModel)   = [:ω, :λ, :d]
control_variables(::KeenModel) = Symbol[]        # 最適化を含まないため空（VARModel と同じ扱い）
parameters(m::KeenModel)       = (α = m.α, β = m.β, δ = m.δ, ν = m.ν, r = m.r,
                                  φ0 = m.φ0, φ1 = m.φ1, κ0 = m.κ0, κ1 = m.κ1, κ2 = m.κ2)
```

### 2.3 計算 API

| 共通関数 | 実装 | 内容 |
|---|---|---|
| `steady_state`（必須） | ○ | 良い均衡 `(ω, λ, d, π, g)` を閉形式で返す |
| `simulate`（任意） | ○ | 初期値 `(ω0, λ0, d0)` からの RK4 時間発展 |
| `impulse_response`（任意） | ○ | 良い均衡を攪乱した初期値からの応答（§3.4） |
| `transition_path`（任意） | 実装しない | 前向き期待を持たないため完全予見経路の概念が該当しない |

シグネチャ（共通インターフェースの `simulate(m, initial_state...; T)` 形式に準拠）:

```julia
steady_state(m::KeenModel) -> NamedTuple                 # (ω, λ, d, π, g)
simulate(m::KeenModel, ω0, λ0, d0; T::Int = 300,
         options::ODESolverOptions = ODESolverOptions()) -> NamedTuple
impulse_response(m::KeenModel, shock::Float64; T::Int = 300,
         variable::Symbol = :d,
         options::ODESolverOptions = ODESolverOptions()) -> NamedTuple
```

戻り値はすべて `NamedTuple`（キー: `ω, λ, d, π, g`）とし、`Dict` は使わない。

### 2.4 定常状態の閉形式

`steady_state` は**良い均衡**を以下の閉形式で返す（`NLsolve` 不要）:

```
π̄ = ln((ν(α + β + δ) - κ0) / κ1) / κ2      （κ(π̄) = ν(α + β + δ) を逆算）
λ̄ = 1 - sqrt(φ1 / (α + φ0))                 （Φ(λ̄) = α を逆算）
d̄ = (κ(π̄) - π̄) / (α + β)
ω̄ = 1 - π̄ - r d̄
ḡ = α + β
```

悪い均衡（`ω → 0, λ → 0, d → ∞`）は座標が無限遠にあるため `steady_state` の対象外とし、
docstring と `docs/models/keen.md` に明記する。

---

## 3. 状態変数・パラメータ・ショックの設計

### 3.1 状態変数と派生変数

| 変数 | 種別 | 定義 | 想定域 |
|---|---|---|---|
| `ω` | 状態 | 賃金シェア `wL/Y` | `0 < ω < 1` 近傍（崩壊経路では 0 へ） |
| `λ` | 状態 | 雇用率 `L/N` | `0 < λ < 1`（`λ = 1` で Phillips 曲線が発散） |
| `d` | 状態 | 民間債務比率 `D/Y` | `d ≥ 0` 近傍（崩壊経路では発散） |
| `π` | 派生 | 利潤シェア `1 - ω - r d` | 出力系列に含める |
| `g` | 派生 | 実質成長率 `κ(π)/ν - δ` | 出力系列に含める |

微分方程式（`src/models/keen.jl` の内部関数 `keen_rhs` として実装）:

```
ω' = ω [Φ(λ) - α]
λ' = λ [κ(π)/ν - δ - α - β]
d' = κ(π) - π - d [κ(π)/ν - δ]

Φ(λ) = φ1 / (1 - λ)^2 - φ0
κ(π) = κ0 + κ1 exp(κ2 π)
```

### 3.2 デフォルトパラメータ

Grasselli & Costa Lima (2012) の数値例をデフォルト値とし、
`KeenModel()` 引数なしコンストラクタ（または docstring の推奨値）として提供する:

| パラメータ | 値 | 出典 |
|---|---|---|
| `α` | 0.025 | Grasselli & Costa Lima (2012) |
| `β` | 0.02 | 同上 |
| `δ` | 0.01 | 同上 |
| `ν` | 3.0 | 同上 |
| `r` | 0.03 | 同上 |
| `φ0` | 0.0400641 | 同上（Keen 1995 の Phillips 曲線） |
| `φ1` | 6.41e-5 | 同上 |
| `κ0` | -0.0065 | 同上 |
| `κ1` | exp(-5) ≈ 0.00674 | 同上 |
| `κ2` | 20.0 | 同上 |

このとき良い均衡はおよそ `ω̄ ≈ 0.8361, λ̄ ≈ 0.9686, d̄ ≈ 0.0702, π̄ ≈ 0.1618, ḡ = 0.045` となり、
数値検証テストのアンカーとして使用する（§8）。

### 3.3 時間単位

時間単位は**年**とする（パラメータが年率）。`simulate` の 1 期 = 1 年とし、
出力は各整数時点でサンプリングした長さ `T` の系列（第 1 要素が初期値）を返す。
ODE の内部刻みは §4 の `ODESolverOptions` で制御する。

### 3.4 ショックの設計

Keen モデルは決定論的 ODE であり、RBC/NK のような外生確率ショック項を持たない。
ショック分析は次の 2 方式で設計する。

**(1) 均衡攪乱型 IRF（初版で実装）**

`impulse_response(m, shock; variable = :d)` は、良い均衡から `variable` を
`shock` だけ加法的にずらした初期値で `simulate` を実行し、**水準系列**を返す。

- 小さな攪乱 → 良い均衡へ回帰（局所安定性の確認）
- 大きな攪乱（例: `d̄ + 1.0`）→ 債務崩壊経路へ移行

という双安定性そのものを IRF として観察できる。線形化した対数偏差 IRF は返さない
（非線形性・双安定性がモデルの本質であるため。docstring に明記する）。

**(2) パラメータシナリオ比較（後続Issue）**

金利 `r` や投資感応度 `κ2` を変更した 2 つの `KeenModel` を比較する
`keen_scenario_comparison`（`mf_policy_shock` と同型のベースライン/シナリオ比較）は
分析機能の後続Issueで扱う。

---

## 4. Solver との接続方式

### 4.1 数値積分: 固定刻み RK4 の自前実装

- 連続時間 3 変数 ODE のため、既存の `NLsolve`（完全予見経路）や価値反復とは接続しない
- **古典的 Runge-Kutta 4 次（固定刻み）を `src/models/keen.jl` 内に自前実装**する。
  `Project.toml` への依存追加（DifferentialEquations.jl 等）は行わない（ADR 0002）
- 内部関数は `keen_rhs`（右辺）・`keen_rk4_step`（1 ステップ）として分離し、テスト可能にする

### 4.2 `ODESolverOptions` の新設

数値計算オプションをモデル `struct` に含めない規約（[モデル共通インターフェース](../architecture/model_interface.md) §3.3）に従い、
`src/core/solver_options.jl` に ODE 用オプションを追加する:

```julia
Base.@kwdef struct ODESolverOptions
    substeps::Int = 20         # 1期（1年）あたりの RK4 サブステップ数（dt = 1/substeps）
    guard_max::Float64 = 1e6   # 発散判定の閾値（状態変数の絶対値上限）
end
```

- 将来の連続時間モデルでも再利用できる汎用名とする
- `SolverOptions`（離散反復用）とは役割が異なるため別型とする

### 4.3 発散ガード

崩壊経路では `d` が急速に発散し、`λ → 1` 到達時には Phillips 曲線が特異になる。
数値的な暴走を防ぐため、積分中に以下のいずれかを満たした時点で打ち切る:

- 状態変数に非有限値（`NaN` / `Inf`）が出現
- `abs` が `guard_max` を超過
- `λ ≥ 1`（Phillips 曲線の特異点）

打ち切り後の残り期間は **`NaN` で埋める**（`SimulationResult` は実データ側で既に
欠損を `NaN` として扱っており、`plot_result` / `summarize_result` と互換）。
崩壊判定フラグの提供（Hedge/Speculative/Ponzi 判定・金融不安定性指標）は
分析機能の後続Issueで扱う。

---

## 5. 可視化対象・出力スキーマの設計

### 5.1 出力スキーマ

| API | 戻り値キー | `SimulationResult` 変数名 | scenario_name 規約 |
|---|---|---|---|
| `steady_state` | `(ω, λ, d, π, g)` | —（NamedTuple のまま） | — |
| `simulate` | `(ω, λ, d, π, g)` 各 `Vector{Float64}` 長さ `T` | `"ω", "λ", "d", "π", "g"` | `"simulate"` |
| `impulse_response` | 同上 | 同上 | `"irf_<variable>"`（例: `"irf_d"`） |

- `to_simulation_result(m, result, scenario)` が無変更でそのまま使える
  （`metadata["parameters"]` にパラメータが自動格納される）
- RBC の対数偏差（`ŷ` 等）とは異なり**水準（比率）系列**である点を docstring と
  モデル解説ドキュメントの解釈セクションに明記する

### 5.2 可視化

- 時系列プロット: 既存 `plot_result` / `plot_comparison` が無変更で動作する
  （変数名指定例: `plot_result(sr; vars = ["d", "π"])`）
- 良い均衡への収束と崩壊経路の対比は、初期値の異なる 2 つの `SimulationResult` を
  `plot_comparison` に渡すことで表現できる（追加実装不要）
- **位相図（ω-λ 平面・d-π 平面）** は時系列前提の既存可視化 API に合わないため、
  可視化拡張の後続Issue（金融不安定性の可視化）で `plot_phase` 等として検討する

---

## 6. AIエコノミスト向け説明メタデータの設計

LLM 層は既存構造（`ModelMetadata` / `AnalysisContext` / `build_docs_excerpts` / `build_explain_prompt`）を
そのまま流用し、**新規の型・プロンプト分岐は追加しない**。必要な作業は以下の 3 点。

### 6.1 doc_context への登録

`src/llm/doc_context.jl` の `_MODEL_DOC_MAP` に 1 エントリ追加する:

```julia
"Keen Model" => "models/keen.md",
```

### 6.2 モデル解説ドキュメント `docs/models/keen.md`

[テンプレート](template.md)に準拠して作成する。`build_docs_excerpts` の抽出規約に合わせ、
以下を必ず含める:

- **「LLM向け要約:」行** — 1〜2 文のモデル概要（`_extract_llm_summary` が抽出）
- **「目的」セクション** — `_extract_model_doc` が抽出
- **「限界・注意事項」セクション** — `_extract_caveats_doc` が抽出

### 6.3 Caveats の推奨内容

`AnalysisContext` 構築時に推奨する免責・注意事項（examples・後続の分析機能で使用）:

| フィールド | 推奨内容 |
|---|---|
| `model_limitations` | 閉鎖経済・政府部門なし / 物価・名目金利は固定（実質モデル）/ 資産価格・ポートフォリオ選択は扱わない / 銀行部門は受動的（信用供給制約なし） |
| `interpretation_warnings` | `ω`・`λ`・`d` は水準ではなく比率 / `π` は利払い後の利潤シェア / 債務崩壊経路はモデル内メカニズムの提示であり現実の予測ではない / 崩壊経路の後半は `NaN` 埋めされうる |

特に「債務崩壊」はセンシティブな表現になりうるため、
[LLM出力の安全性ルール](../llm_safety.md)の禁止表現（断定的予測・投資助言）と組み合わせて
`interpretation_warnings` を必ず設定する運用とする。

---

## 7. ファイル配置・include 順序・ドキュメント更新

実装Issueで変更するファイルの一覧:

| ファイル | 変更内容 |
|---|---|
| `src/models/keen.jl` | 新規: `KeenModel`・meta 関数・`steady_state`・`simulate`・`impulse_response`・内部関数（`keen_rhs`・`keen_rk4_step`） |
| `src/core/solver_options.jl` | `ODESolverOptions` を追加 |
| `src/DME.jl` | `include("./models/keen.jl")` を `models/mundell_fleming.jl` の直後に追加・`KeenModel`/`ODESolverOptions` を export（`steady_state`/`simulate`/`impulse_response` は export 済み） |
| `src/llm/doc_context.jl` | `_MODEL_DOC_MAP` に `"Keen Model"` を追加 |
| `test/test_keen.jl` | 新規: §8 のテスト。`test/runtests.jl` から include |
| `docs/models/keen.md` | 新規: モデル解説（テンプレート準拠・§6.2 の見出し規約） |
| `docs/api.md` | Public API 一覧に `KeenModel` 系を追加 |
| `docs/architecture/package_structure.md` | ソースツリー・include 順序に追記 |
| `docs/model_selection_guide.md` | 金融不安定性の問いに対する選択肢として追記 |
| `docs/data/variable_mapping.md` | `ω`/`λ`/`d`/`r` の実データ対応を追記（[設計方針 §7](minsky_design.md) の候補系列） |
| `README.md` | モデル一覧・ドキュメント一覧に追記 |
| `CLAUDE.md` | モデル一覧・ドキュメント一覧に追記 |

examples（`examples/` にデモスクリプト追加）は分析機能とあわせて後続Issueで作成する。

---

## 8. テスト設計（数値検証アンカー）

`test/test_keen.jl` に以下を実装する。数値アンカーは §3.2 の均衡値を使用する。

| テスト | 内容 | 判定 |
|---|---|---|
| 定常状態の文献値一致 | デフォルトパラメータの `steady_state` | `ω̄ ≈ 0.8361, λ̄ ≈ 0.9686, d̄ ≈ 0.0702, π̄ ≈ 0.1618`（atol=1e-3） |
| 定常状態の残差 | `keen_rhs(steady_state値)` | 各成分 ≈ 0（atol=1e-10） |
| 均衡の局所安定性 | 均衡 + 微小攪乱（例: `d̄ + 0.01`）から `T = 300` | 終端値が均衡に回帰（atol=1e-3） |
| 崩壊経路 | 高債務初期値（例: `d0 = 5.0`）から simulate | `d` が単調増大 → 発散ガード発動・`NaN` 埋めを確認 |
| RK4 の刻み収束 | `substeps = 10` と `20` の解の差 | 差が十分小さい（RK4 の次数を反映して縮小） |
| インターフェース整合 | meta 4 関数・`to_simulation_result`・`plot_result`・`AnalysisContext` 構築 | 例外なく動作（smoke） |
| 発散ガード | `guard_max` 超過・`λ ≥ 1` のケース | 打ち切りと `NaN` 埋めを確認 |

---

## 9. 実装Issueの分割案

| 順序 | Issue 内容 | 本設計書の対応節 |
|---|---|---|
| 1 | `KeenModel` 実装（struct・meta・`steady_state`・`simulate`・`ODESolverOptions`・テスト・`docs/models/keen.md`・doc map 登録） | §2〜§6・§8 |
| 2 | `impulse_response`（均衡攪乱型）・パラメータシナリオ比較（`keen_scenario_comparison`） | §3.4 |
| 3 | Hedge / Speculative / Ponzi 判定・金融不安定性指標・位相図可視化・examples | §4.3・§5.2 |
| 4 | 実データ接続（賃金シェア・雇用率・債務比率のマッピング実装） | §7・[設計方針 §7](minsky_design.md) |

Issue 1 完了時点で「既存モデルと同一インターフェースで実行可能」というロードマップ（#99）の
最初の完了条件を満たす。

---

## 10. 対象外

- Keen モデル自体の拡張（政府部門・資産価格・SFC 化）→ [設計方針 §6.3](minsky_design.md)
- 確率ショック項の導入（確率 Keen モデル）
- 適応的刻み幅の ODE ソルバー・外部 ODE パッケージへの依存
- LLM プロンプトのモデル固有分岐
