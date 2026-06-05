# AIエコノミスト化に向けたアーキテクチャ設計方針

> Phase 2 / P2
> 関連Issue: #15

---

## 1. 背景と目的

DME は現在、基本的なマクロ経済モデル（Ramsey・RBC）の実装を中心とする Julia パッケージである。
今後は可視化・実データ接続・LLM 接続を通じて「AIエコノミスト」として発展させていく予定だが、
実装前に各層の責務・境界・依存関係を整理しておかないと、モデル層・データ層・LLM層が混在しやすい。

本ドキュメントは Phase 3 以降の開発方針の基準となるアーキテクチャメモである。

---

## 2. Phase 1-2 の成果物（起点）

本ドキュメントが前提とする Phase 1-2 の成果物は以下のとおり。

| 成果物 | 場所 | 概要 |
|---|---|---|
| 共通インターフェース | `src/core/model_interface.jl` | `AbstractMacroModel` 抽象型・メタ情報関数・共通関数シグネチャ |
| SimulationResult 型 | `src/core/simulation_result.jl` | モデル横断的なシミュレーション結果コンテナ |
| SolverOptions 型 | `src/core/solver_options.jl` | 数値計算パラメータの分離 |
| Ramsey モデル実装 | `src/models/ramsey.jl` | 定常状態・移行経路・シミュレーション |
| RBC モデル実装 | `src/models/rbc.jl` | 定常状態・移行経路・インパルス応答 |
| モデル共通I/F設計方針 | `docs/architecture/model_interface.md` | 共通インターフェース設計根拠・移行方針 |
| モデル解説ドキュメント | `docs/models/ramsey.md`, `docs/models/rbc.md` | LLM が参照可能な経済学的説明 |
| 出力結果読み方ガイド | `docs/simulation_outputs.md` | 変数の単位・解釈・LLM向け注意点 |
| API リファレンス | `docs/api.md` | Public API 一覧 |

これらが AIエコノミスト化の「基盤」であり、Phase 3 以降はこれらの上に層を積み上げる形をとる。

---

## 3. 全体アーキテクチャ概要

```
┌──────────────────────────────────────────────────────────┐
│  LLM解釈層                                               │
│  （自然言語による説明・要約・対話）                        │
│  inputs: モデルメタ情報 + docs + SimulationResult         │
└────────────────────────┬─────────────────────────────────┘
                         │
┌────────────────────────▼─────────────────────────────────┐
│  ドキュメント/RAG層                                       │
│  （docs/ の構造化・検索・文脈提供）                        │
│  inputs: docs/models/*.md, docs/simulation_outputs.md     │
└───────────────┬────────────────────────┬─────────────────┘
                │                        │
┌───────────────▼──────┐   ┌─────────────▼───────────────┐
│  実データ接続層        │   │  可視化層                    │
│  （外部データの取得・  │   │  （SimulationResult の       │
│   前処理・キャリブ）   │   │   グラフ・比較表示）          │
│  inputs: 外部API/CSV  │   │  inputs: SimulationResult    │
└───────────────┬──────┘   └─────────────┬───────────────┘
                │                        │
┌───────────────▼────────────────────────▼───────────────┐
│  シミュレーション層                                      │
│  （SimulationResult の生成・変換・集約）                  │
│  inputs: モデル層の出力（NamedTuple）                    │
└────────────────────────────┬────────────────────────────┘
                             │
┌────────────────────────────▼────────────────────────────┐
│  モデル層                                                │
│  （AbstractMacroModel を実装する各モデル）                │
│  内容: steady_state / transition_path / simulate /       │
│        impulse_response                                  │
└─────────────────────────────────────────────────────────┘
```

---

## 4. 各層の責務と境界

### 4.1 モデル層

**責務**: 経済モデルの定義・数値計算・定常状態・最適経路の導出。

| 要素 | 内容 |
|---|---|
| 型 | `AbstractMacroModel` のサブタイプ（`RamseyModel`, `RBCModel` 等） |
| 関数 | `steady_state`, `transition_path`, `simulate`, `impulse_response` |
| メタ情報 | `model_name`, `state_variables`, `control_variables`, `parameters` |
| 戻り値 | `NamedTuple`（内部表現。外部向けには `SimulationResult` に変換） |

**境界**:
- モデル層はデータ取得・可視化・LLM 呼び出しを行わない
- 数値計算のパラメータは `SolverOptions` 型で受け取る
- 実データとの比較・キャリブレーションはモデル層の責務ではない（実データ接続層で行う）

---

### 4.2 シミュレーション層

**責務**: モデル層の出力（`NamedTuple`）を `SimulationResult` に変換し、後処理・集約を提供する。

| 要素 | 内容 |
|---|---|
| 型 | `SimulationResult` |
| 関数 | `to_simulation_result`, `nperiods`, `variable_names` |
| 変換 | `NamedTuple → SimulationResult` の統一変換 |

**境界**:
- モデル固有のロジックを持たない（モデル層に委譲）
- 可視化・LLM 呼び出しは行わない
- `SimulationResult` は可視化層・実データ接続層・LLM解釈層の共通入力型

---

### 4.3 可視化層

**責務**: `SimulationResult` を受け取り、グラフ・比較表・ダッシュボードとして出力する。

| 機能 | 概要 |
|---|---|
| 時系列プロット | `plot_result(result; vars, title)` — 単一シナリオの時系列 |
| 比較プロット | `compare_results(results...; vars)` — 複数シナリオの並列表示 |
| 定常状態比較 | `plot_steady_state(models...; vars)` — パラメータ感度の棒グラフ等 |

**境界**:
- 入力は常に `SimulationResult`（モデルの内部実装に依存しない）
- グラフ描画ライブラリ（Plots.jl / Makie.jl 等）は可視化層内部に閉じる
- LLM への出力はこの層の責務ではない

---

### 4.4 実データ接続層

**責務**: 外部データ（マクロ統計・FRED・日本銀行等）を取得・前処理し、モデル変数と対応づける。

| 機能 | 概要 |
|---|---|
| データ取得 | API・CSV からの生データ取得 |
| 前処理 | 実質化・季節調整・対数偏差変換 |
| キャリブレーション補助 | 実データの長期平均からパラメータ推定を補助 |
| 比較用変換 | 実データを `SimulationResult` 互換の形式に変換 |

**境界**:
- 実データの取得・前処理は実データ接続層で完結する
- モデル層・シミュレーション層に外部データの依存を持ち込まない
- 実データとモデル変数の対応は `docs/simulation_outputs.md` のマッピング表を参照する

---

### 4.5 ドキュメント/RAG層

**責務**: `docs/` 以下の構造化ドキュメントを LLM が利用できる形で提供する。

| 内容 | 場所 |
|---|---|
| モデル経済学的説明 | `docs/models/ramsey.md`, `docs/models/rbc.md` |
| 出力変数の解釈 | `docs/simulation_outputs.md` |
| API リファレンス | `docs/api.md` |
| アーキテクチャ設計 | `docs/architecture/` |

**境界**:
- ドキュメント/RAG層は読み取り専用（ドキュメントの内容を更新しない）
- LLM への文脈提供のみを担う
- 検索・埋め込み・チャンク分割等の RAG 処理はこの層の実装問題

---

### 4.6 LLM解釈層

**責務**: モデルメタ情報・ドキュメント・`SimulationResult` を入力として、自然言語による説明・要約・対話を生成する。

| 機能 | 概要 |
|---|---|
| 結果要約 | `summarize(result, model)` → シミュレーション結果の日本語説明 |
| モデル説明 | `describe(model)` → モデルの経済学的意味の説明 |
| 比較説明 | `compare_explain(results...)` → シナリオ間の差異の言語化 |
| 対話 | ユーザーの自然言語クエリに応じて計算・説明を組み合わせる |

**境界**:
- LLM呼び出しはこの層のみ（下位層は LLM に依存しない）
- 下位層の出力（`SimulationResult`、メタ情報、docs）を入力として受け取るのみ
- LLM の出力を `SimulationResult` に書き戻さない（一方向の流れ）

---

## 5. データフロー

### 5.1 基本フロー（モデル計算 → 可視化）

```
RamseyModel / RBCModel
  │
  │ steady_state / transition_path / simulate / impulse_response
  ▼
NamedTuple（内部表現）
  │
  │ to_simulation_result
  ▼
SimulationResult
  │
  │ plot_result / compare_results
  ▼
グラフ出力
```

### 5.2 実データ比較フロー（モデル + 実データ → 比較）

```
AbstractMacroModel          外部データ（FRED / 日銀 / SNA）
  │                             │
  │ transition_path             │ fetch + preprocess
  ▼                             ▼
SimulationResult（モデル）  DataSeries（実データ）
  │                             │
  └────────────┬────────────────┘
               │ compare_results
               ▼
          比較プロット・乖離指標
```

**重要**: 実データとモデル変数の対応は `docs/simulation_outputs.md` セクション 6.2 に記載のマッピングに従う。
単純な数値の一致をもって「モデルが現実を説明している」と主張しない。

### 5.3 LLM 説明フロー（docs + 計算結果 → 自然言語）

```
docs/models/*.md                SimulationResult
docs/simulation_outputs.md          │
      │                             │
      │ RAG (検索・チャンク化)       │
      ▼                             │
文脈テキスト                         │
      │                             │
      └──────────────┬──────────────┘
                     │
             model_name / state_variables /
             control_variables / parameters
                     │
                     ▼
                LLM プロンプト
                     │
                     ▼
               自然言語説明・要約
```

---

## 6. Phase 3 以降の実装順序感

Phase 1-2 の成果物（共通I/F・SimulationResult・docs）が揃った段階で、以下の順序で拡張する。

```
Phase 3-A: モデル拡張
  - Solow モデル（最もシンプルな成長モデル）
  - New Keynesian モデル（名目硬直性・金融政策）
  → AbstractMacroModel の共通I/Fに従い追加するだけで済む体制

Phase 3-B: 可視化
  - Plots.jl ベースの plot_result / compare_results 実装
  - Jupyter Notebook / Pluto.jl での使用例整備
  → 入力は常に SimulationResult（モデル固有ロジック不要）

Phase 3-C: 実データ接続
  - FRED API / e-Stat / 日本銀行のデータ取得ユーティリティ
  - 実質化・季節調整・対数偏差変換パイプライン
  - モデル変数との比較プロット
  → 可視化層が完成していると比較表示が容易

Phase 3-D: LLM接続
  - docs/ の RAG 化（埋め込み・検索）
  - Claude / OpenAI API による summarize / describe 実装
  - シミュレーション結果の自然言語要約
  → 可視化・実データ接続が揃うと LLM への文脈が豊かになる
```

各フェーズは依存関係があるが、Phase 3-A は他に依存しないため並行して進められる。

---

## 7. 直近では実装しないこと（明示的な非対象）

以下は DME の AIエコノミスト化の将来的な方向性に含まれるが、Phase 3 時点では意図的に対象外とする。

| 項目 | 理由 |
|---|---|
| **LLM による自動予測** | 現行モデルは条件付きシミュレーションであり、将来の経済変数の予測ツールではない。LLM の出力をそのまま経済予測として扱うことは誤解を招く |
| **投資判断の自動化** | モデルの出力は「特定の仮定下での条件付き反応」であり、実際の投資判断に直結させることは設計外 |
| **実データとの無検証な同一視** | キャリブレーションなしにモデル変数と実データ値を直接比較・同一視しない（`docs/simulation_outputs.md` セクション 6.2 参照） |
| **外部モデルの自動評価** | LLM が DME 外の経済モデルを評価・比較する機能はスコープ外 |
| **リアルタイムデータ連携** | データ取得は明示的な呼び出しによる。自動ポーリング・イベント駆動取得は行わない |

---

## 8. 各層の実装ファイル配置（将来構成案）

```
src/
  DME.jl
  core/
    model_interface.jl      ← Phase 1-2 完了
    simulation_result.jl    ← Phase 1-2 完了
    solver_options.jl       ← Phase 1-2 完了
  models/
    ramsey.jl               ← Phase 1-2 完了
    rbc.jl                  ← Phase 1-2 完了
    solow.jl                ← Phase 3-A
    nk.jl                   ← Phase 3-A（後続）
  numerics/
    grids.jl
    interpolation.jl
  visualization/            ← Phase 3-B（新設）
    plot_result.jl
    compare.jl
  data/                     ← Phase 3-C（新設）
    fetch.jl
    preprocess.jl
    calibrate.jl
  llm/                      ← Phase 3-D（新設）
    summarize.jl
    describe.jl
    rag.jl

docs/
  api.md
  simulation_outputs.md
  architecture/
    model_interface.md      ← Phase 1-2 完了
    ai_economist.md         ← 本ドキュメント（Phase 2 完了）
  models/
    ramsey.md               ← Phase 1-2 完了
    rbc.md                  ← Phase 1-2 完了
    solow.md                ← Phase 3-A
    nk.md                   ← Phase 3-A（後続）
```

---

## 9. 設計上の制約・原則

1. **単方向依存**: 上位層は下位層を呼び出すが、下位層は上位層を知らない。モデル層は LLM を呼び出さない
2. **LLM 非依存コア**: モデル層・シミュレーション層・可視化層は LLM なしで完全に動作する
3. **型による境界**: 層間のインターフェースは `SimulationResult` 型に集約する。`NamedTuple` は内部表現に留める
4. **実データとモデルの分離**: 実データの取得・前処理は実データ接続層に閉じる。モデル層は実データに依存しない
5. **ドキュメントは人間と LLM の両方のための一次資料**: `docs/` はコードと同等の成果物として管理する

---

## 10. 受け入れ条件チェック

- [x] AIエコノミスト化に向けたアーキテクチャ文書が作成されていること（本ドキュメント）
- [x] 各層の責務と境界が明確であること（セクション 4）
- [x] Phase 1-2 の成果物（共通I/F、SimulationResult、モデル解説docs）との関係が説明されていること（セクション 2・5）
- [x] Phase 3 以降のモデル拡張・可視化・データ接続・LLM接続の順序感が分かること（セクション 6）
- [x] 直近では実装しないことが明記されていること（セクション 7）
