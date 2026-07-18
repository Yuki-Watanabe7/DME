# Keen モデル 実証化の測定・識別・時系列整列方針

> 関連 Issue: #119

---

## メタ情報

| 項目 | 内容 |
|---|---|
| **対象モデル** | Keen モデル（`KeenModel`、[keen.md](keen.md)） |
| **ステータス** | 設計 + データ層 + 推定層 + 検証層実装済み。§2〜§4 のデータ取得・単位変換・四半期整列は `src/data/keen_empirical.jl`（`build_keen_empirical_dataset`、#120）で実装。§5 の限定キャリブレーション（ODE residual）は `src/analysis/keen_calibration.jl`（`calibrate_keen`、#121）で実装。§6 の実証バリデーション・感応度分析は `src/analysis/keen_validation.jl`（`validate_keen`、#122）で実装 |
| **methodology version（推定層）** | `keen-calibration/1.0.0`（`KEEN_CALIBRATION_METHODOLOGY_VERSION`。データ層 `keen-empirical/*` とは独立） |
| **methodology version（検証層）** | `keen-validation/1.0.0`（`KEEN_VALIDATION_METHODOLOGY_VERSION`。推定層・データ層・診断層とは独立） |
| **前提ドキュメント** | [Keen モデル解説](keen.md)・[Minsky系金融不安定性モデル設計方針](minsky_design.md)・[モデル変数と実データ系列のマッピング表](../data/variable_mapping.md)・[Minsky 資金調達区分診断](minsky_regime_diagnostics.md) |
| **methodology version（予定）** | `keen-empirical/1.0.0`（診断層の `minsky-regime/*`・`minsky-diagnostics/*` とは独立に管理） |
| **基準経済（初版）** | 米国。日本は同一契約への拡張対象 |

> **LLM向け要約**: 本書は Keen モデル（状態変数 `ω`・`λ`・`d`、貸出金利パラメータ `r`）を
> 実データへ接続するための観測方程式・系列候補・単位変換規則・共通頻度・時間軸契約・
> 識別戦略・推定 objective・検証方針を、後続実装が追加の理論判断なしに着手できる粒度で定義する。
> モデル変数と統計系列は厳密には同一ではなく、10 個の構造パラメータを少数の観測系列から
> 同時推定することは識別上困難である。したがって本書は (1) 公表系列が指数か比率かを検証せず
> 直接利用しない、(2) 年単位 ODE と四半期観測を `Δt = 0.25` で整合させる、(3) 固定パラメータと
> 推定パラメータを分離し全 10 パラメータ同時推定を既定にしない、を設計原則とする。
> 当てはまり（fit）を危機確率・因果推論・予測精度と同一視しない（§8）。

---

## 1. 基準経済・対象範囲・標本期間

### 1.1 基準経済

初版の基準経済は**米国**とする。

- FRED および既存 `FredClient` の fixture / live 経路で主要系列を取得しやすい（[FRED 接続ガイド](../data/fred.md)）。
- 日本は同一の観測方程式・変換契約へ**追加可能な拡張対象**として設計する。国別系列差は
  モデル本体（`KeenModel`・`keen_rhs`）へ埋め込まず、観測データ設定・measurement metadata で分離する。
- 国別の候補系列は §2 の各表に併記し、米国系列を既定とする。

### 1.2 標本期間の決定

標本期間は**固定値を先に決めない**。必須系列（§2 の `ω`・`λ`・`d`、および `r` を推定に使う場合は `r`）の
**共通利用可能期間**から決定論的に算出する。

- 各系列を共通頻度（四半期、§4）へ整列した後、**全必須系列が非欠損である最初と最後の四半期**を
  標本期間の端点とする（inner join、§4.3）。
- 端点・標本長は methodology metadata に記録する（`sample_start`・`sample_end`・`n_obs`）。
- out-of-sample 検証（§6）用のホールドアウト区間も、この共通期間から決定論的に切り出す。

---

## 2. 状態変数の観測方程式

各系列は、定義・単位を**一次資料または provider metadata で確認したうえで**採用する。
下表の系列 ID は候補であり、**「指数か比率か」「季節調整の有無」「産業範囲」「基準年」を検証せずに
直接利用してはならない**（受け入れ条件・§7 の設計原則）。産業範囲・基準年・季節調整・部門範囲の差は
measurement metadata へ保存する。

### 2.1 `ω`（賃金シェア `wL/Y`）

| 項目 | 内容 |
|---|---|
| モデル定義 | `ω = wL / Y`（産出比、`0 < ω < 1` 近傍） |
| 候補（米国） | (a) FRED `PRS85006173`（非農業部門 labor share、**指数**）/ (b) 名目雇用者報酬 ÷ 名目産出（所得・GDP）から構成する**比率** |
| 候補（日本） | SNA 雇用者報酬 ÷ 国民所得または名目 GDP（内閣府「国民経済計算」） |
| 単位 | 産出比（無次元、`[0,1]`） |
| 頻度 | 四半期（構成比率で作る場合は分子・分母とも四半期名目系列） |
| 変換規則 | **`PRS85006173` は指数（例: 2012=100）であり、水準シェアとして直接使わない。** 指数を使う場合は基準年の水準シェアへアンカーして比率化する。原則として (b) の**名目比率での直接構成**（`COE / GDP` 等）を推奨する |

**注意**: 指数系列をそのまま `ω ∈ [0,1]` とみなすと `ω > 1` 等の非整合が生じる。指数か比率かは
provider metadata（`units` フィールド）で確認し、指数なら比率化を経る。

### 2.2 `λ`（雇用率 `L/N`）

| 項目 | 内容 |
|---|---|
| モデル定義 | `λ = L / N`（`0 < λ < 1`、`λ = 1` で Phillips 曲線が発散） |
| 候補（米国） | (a) `1 - UNRATE/100`（`UNRATE` = 失業率、%）/ (b) `EMRATIO/100`（雇用人口比率） |
| 候補（日本） | 総務省・労働力調査から `1 − 完全失業率/100` |
| 単位 | 率（無次元、`[0,1]`）へ統一する |
| 頻度 | 月次 → 四半期（平均集計、§4.2） |
| 変換規則 | `%` を `100` で除して `[0,1]` へ。`1 - UNRATE/100` は「就業者/労働力人口」であり、モデルの `L/N`（`N` = 労働人口）とは分母定義が異なる。`EMRATIO`（就業者/生産年齢人口）は `L/N` により近いが水準が異なる。**採用系列と `N` の定義を measurement metadata に明記する** |

### 2.3 `d`（民間債務比率 `D/Y`）

| 項目 | 内容 |
|---|---|
| モデル定義 | `d = D / Y`（産出比、`d ≥ 0` 近傍。崩壊経路で発散） |
| 候補（米国） | FRED `CRDQUSAPABIS`（BIS 民間非金融部門信用 / GDP、`% of GDP`） |
| 候補（日本） | FRED `QJPPAM770A`（同・日本） |
| 単位 | 産出比（無次元）。`% of GDP` を `100` で除して比率へ |
| 頻度 | 四半期 |
| 変換規則 | `% of GDP` → 比率（÷100）。**対象部門を明示する**: BIS「民間非金融部門」は家計＋非金融法人を含む。Keen の `d` は企業（法人）債務に対応するため、総民間系列は家計債務を含む点で**過大カバレッジ**である。より狭い「非金融法人向け信用」系列を代替候補とし、採用系列と部門範囲を measurement metadata に記録する |

### 2.4 `r`（借入金利）

| 項目 | 内容 |
|---|---|
| モデル定義 | 貸出金利（**実質・一定**と仮定するパラメータ。状態変数ではない） |
| 候補（米国） | FRED `DPRIME`（Bank Prime Loan Rate、貸出金利、%）等 |
| 候補（日本） | 日本銀行・貸出約定平均金利 |
| 単位 | 年率（`%` → `100` で除して小数へ） |
| 頻度 | 月次・随時 → 四半期（平均集計、§4.2） |
| 変換規則 | **名目値をそのまま使う方式**と、**期待インフレ率を差し引く実質化方式**を区別する。実質化する場合の期待インフレ代理（実現 CPI 前年比等）を methodology で明示する。**国債実質金利を企業借入金利と同一視しない**（`DPRIME` 等の貸出金利を用い、国債利回りで代替しない） |

---

## 3. 補助系列と構造パラメータ（固定 / 推定の分離）

Keen の 10 パラメータを、**実データ・文献値・固定仮定のどれで与えるか**を整理する。
**全 10 パラメータ同時推定は既定にしない**（§5・受け入れ条件）。

| パラメータ | 意味 | 初版の付与方法 | 供給源の候補 |
|---|---|---|---|
| `α` | 労働生産性成長率 | **固定** | 実質産出/就業者数の長期トレンド、または文献値（既定 0.025） |
| `β` | 労働人口成長率 | **固定** | 労働力人口の長期成長率、または文献値（既定 0.02） |
| `δ` | 資本減耗率 | **固定** | 資本ストック統計の減耗率、または文献値（既定 0.01） |
| `ν` | 資本産出比率 | **固定** | 名目/実質資本ストック ÷ 産出、または文献値（既定 3.0） |
| `r` | 貸出金利 | **固定**（§2.4 の系列の標本平均・時点値・外生固定値のいずれか） | `DPRIME` 標本平均等。方式を metadata に記録 |
| `φ0`, `φ1` | Phillips 曲線パラメータ | **限定的に推定**（または文献値で固定） | ω 動学・λ の関係（§5） |
| `κ0`, `κ1`, `κ2` | 投資関数パラメータ | **限定的に推定**（`κ2` は固定を推奨） | d 動学・π の関係（§5） |

**初版の既定方針**: `α, β, δ, ν, r` を外部情報・文献値・標本統計で**固定**し、行動パラメータ
（Phillips・投資関数）のみを**限定的に推定**する。行動パラメータも全 5 個を同時推定せず、
曲率パラメータ `κ2` を文献値で固定するなど、識別可能な最小集合から始める（§5.2）。

---

## 4. 時間軸・頻度・整列規則（年単位 ODE ↔ 四半期観測の契約）

### 4.1 モデル時間と観測頻度

- モデル時間の `1.0` を **1 年**とする既存規約（[keen.md](keen.md) §6・`simulate` の `dt = 1/substeps`）を維持する。
- 実証データの共通頻度は**四半期**を第一候補として確定する。
- 四半期観測は `Δt = 0.25`（1/4 年）の時点として扱う。**四半期データを年次シミュレーションへ
  単純に 4 点詰め込まない**（`t = 0,1,2,3,...` の年次格子に四半期値を並べる誤りを禁止する）。

### 4.2 月次 → 四半期の集計方法（系列別に固定）

月次系列の四半期化は**平均・期末・合計のいずれかを系列ごとに固定**する。既定の割り当て:

| 系列 | 集計方法 | 理由 |
|---|---|---|
| `λ`（`1 - UNRATE/100` 等） | 平均（`:mean`） | ストック的な率で、四半期平均が代表値 |
| `r`（`DPRIME` 等） | 平均（`:mean`） | 期間中の平均的な借入コスト |
| フロー量（使用する場合） | 合計（`:sum`） | 期中フローの四半期合計 |

- 既存の `to_quarterly(s; method=:mean|:sum)`（[前処理ユーティリティ](../data/preprocess.md)）を用いる。
- **期末（period-end）集計は現行 `to_quarterly` に未実装**であり、期末値を要する系列を採用する場合は
  `to_quarterly` に `method=:end` を追加する実装が別途必要（後続実装の対象・§9）。
- 採用した集計方法は series 単位で measurement metadata に記録する。

### 4.3 共通時間軸と inner join

- 日付は**文字列順ではなく**、四半期を解析した共通数値時間軸で結合する。四半期ラベル
  `"YYYY-Qn"` を数値時間 `year + (n-1)*0.25` に変換し、この軸で **inner join** する。
- inner join により、全必須系列が揃う四半期のみを標本に含める（§1.2 の標本期間決定と整合）。

### 4.4 欠損・補完

- **欠損を `0` へ変換しない**（`fill_missing(:zero)` を実証データの既定にしない）。
- forward fill の可否は**系列別に明示**し、**既定では暗黙補完しない**。補完した場合は
  measurement metadata の変換履歴（`transformations`）に残す。
- inner join 後に残る欠損（内部欠損）は objective から除外する（§5.3）。

### 4.5 データ vintage

- 改定後の**確報データを使う分析**と、**リアルタイム / vintage 分析**を区別する。
- **初版はリビジョン後の確報値（最新公表値）を対象**とする。リアルタイム / vintage 分析は
  将来対応予定とし、初版の methodology metadata に「revised（非 vintage）」を明記する。

---

## 5. キャリブレーション・識別戦略

### 5.1 方式の比較

| 方式 | 概要 | 長所 | 短所 |
|---|---|---|---|
| **ODE residual** | 観測状態系列の（対数）差分と `keen_rhs` の残差を最小化。方程式ごとに分解できる | 方程式単位で識別可能・目的関数が滑らか・双安定性の罠を回避 | 差分近似の誤差。状態変数の観測ノイズが微分に増幅される |
| **trajectory** | 初期状態から観測時点まで積分し `ω, λ, d` の軌跡誤差を最小化 | 動学全体の当てはまりを直接評価 | 双安定 ODE のため小さなパラメータ変化で崩壊経路へ跳び、目的関数が不連続・初期値依存 |
| **moment matching** | 定常状態・長期平均などの moments を合わせる | 実装が単純・ノイズに頑健 | moments が少なくパラメータに対し弱識別・過少決定になりやすい |

### 5.2 初版採用方式（ADR 0004 で確定）

**ODE residual 方式**を初版に採用する（決定記録は [ADR 0004](../adr/0004-keen-empirical-calibration-strategy.md)）。

- **推定対象**: 行動パラメータの最小集合。既定は Phillips `φ0, φ1` と投資 `κ0, κ1`。
  曲率 `κ2` は文献値で固定する（同時推定の識別難を避ける）。
- **固定パラメータ**: `α, β, δ, ν, r`（§3）と `κ2`。
- **方程式分解**（`keen_rhs` を各観測時点で評価）:
  - Phillips: `Δlog ω / Δt ≈ Φ(λ) - α = φ1/(1-λ)^2 - φ0 - α` → `λ` を説明変数とする残差最小化。
  - 投資/雇用・債務: `Δλ, Δd` を `κ(π)/ν - δ - α - β`・`κ(π) - π - d(κ(π)/ν - δ)` の残差で評価。
  - `π = 1 - ω - r d`（既存派生式）を観測 `ω, d` と固定 `r` から構成。

### 5.3 推定設計（実装可能な粒度）

| 項目 | 内容 |
|---|---|
| **推定対象 / 固定** | §5.2。全 10 パラメータ同時推定を既定にしない |
| **境界・符号制約** | `φ1 > 0`・`κ1 > 0`・`κ2 > 0`（固定時も正）・`ν > 0`・投資関数が定義域で有限。状態域 `0 < λ < 1`・`d ≥ 0` を逸脱する観測は除外（下記） |
| **重み付け** | 変数ごとのスケール差（`ω, λ ∈ [0,1]` vs `d` は数十のオーダー）を、各方程式残差を系列標準偏差で正規化して吸収する。重み設定を metadata に記録 |
| **objective 除外規則** | 欠損（§4.4 の内部欠損）・発散（`keen_diverged` 相当・`λ ≥ 1`・非有限）・状態域逸脱の期間を残差から除外。除外期間数を metadata に記録 |
| **初期値の扱い** | ODE residual では軌跡積分の初期値に依存しない。将来 trajectory 方式へ切り替える場合の初期値は観測系列の先頭値を用い、その旨を methodology version で区別する |
| **複数局所解・弱識別の検出** | 複数の初期パラメータ推定値から最適化を再起動し解の散らばりを確認。ヤコビアン/ヘッセ行列の条件数、パラメータ間相関、`κ2` 固定値に対する感応度で弱識別を検出。検出結果を診断出力に含める |
| **再現性 metadata** | `keen-empirical/1.0.0`、系列 ID・取得日・vintage 区分・変換履歴・集計方法・標本期間・固定パラメータと供給源・推定パラメータと境界・objective 定義・最適化手法・重み・除外期間を保存 |

### 5.4 実装（`calibrate_keen`、#121）

§5.2〜§5.3 を `src/analysis/keen_calibration.jl` に実装した。設定は `KeenCalibrationConfig`、
結果は `KeenCalibrationResult`（API は [api.md](../api.md) の「Keen 限定キャリブレーション」節）。

| 項目 | 実装 |
|---|---|
| **objective** | 各隣接観測の**前進差分**で state の変化率を作り、**開始点で評価した `keen_rhs`（level 形）** との残差を方程式別（`ω`/`λ`/`d`）に最小化。ADR 0004 決定5「観測状態の差分と `keen_rhs` の残差」に対応。差分近似方式（`:forward`）と端点処理（最終観測点は残差の開始点にしない）を metadata へ保存 |
| **重み** | `weight_mode=:std_normalize`（既定）で各方程式の観測差分の母標準偏差の逆数。`:fixed` / `:none` も選択可。実際に用いた重みを結果へ保存 |
| **除外規則** | 非連続（`Δt≠0.25`）・非有限・状態域逸脱（`λ≥1`・`ω≤0`・`d<0`）のペアを objective から除外し、内訳（`excluded_reasons`）と有効/除外ペア数を保存 |
| **固定/推定分離** | `estimated_params` の既定は `[:φ0,:φ1,:κ0,:κ1]`（`κ2` は文献値で固定）。`α,β,δ,ν,r,κ2` は `fixed_params`。全 10 パラメータ同時推定は公開既定にしない（構築時に固定/推定の網羅性・排他性・符号制約を検証） |
| **符号制約・penalty** | `φ1,κ1,κ2` は下限 `>0` を強制。良い均衡が閉形式で定義できない候補には `invalid_penalty` を付与 |
| **optimizer** | 自前の bound 付き Nelder-Mead（決定的な初期単体）。境界は clamp + 二乗 penalty で内側へ戻す |
| **multi-start・識別診断** | 決定的な擬似乱数（自前 LCG・`seed`）で初期値を摂動し複数 start を実行。全 start・採用 start・境界到達（`boundary_hits`）・objective が近いが異なる解（`nonunique_solutions`/`alternative_solutions`）・収束解のばらつきや感応度の平坦さによる弱識別（`weak_identification`）・各推定値への objective 感応度（曲率近似）を返す |
| **標準誤差** | `standard_errors_supported=false`。`sensitivity` は objective の曲率近似であり分散推定ではない（Hessian ベースの統計推論は本 version 未対応） |
| **literature 比較** | 文献 default での objective（`literature_objective`）を併せて返し、calibrated との差を取得できる |
| **保存・再実行** | `save_keen_calibration` / `save_keen_calibration_config` で JSON 保存、`load_keen_calibration_config` で復元。系列 ID・期間・measurement version・methodology version を含む。optimizer 内部状態ではなく再現に必要な公開設定のみを保存し、同じ fixture・seed・設定で決定的に再現できる |

**限界の明示**: 推定値は近似対応する集計系列への当てはめであり、**因果パラメータ・普遍定数・
危機発生確率ではない**（§8）。短い標本・双安定性のため弱識別や複数局所解が生じうるので、
`weak_identification` / `nonunique_solutions` / `boundary_hits` を単一の確定解として隠さず参照する。

---

## 6. バリデーション方針

| 観点 | 方針 |
|---|---|
| **in-sample / out-of-sample** | 標本を推定区間と後方ホールドアウト区間へ分離（§1.2）。in-sample fit と out-of-sample の予測誤差を**別々に報告**する |
| **literature vs calibrated** | Grasselli & Costa Lima (2012) の文献 default パラメータと calibrated モデルを**必ず比較**する（calibrated が literature を改善するとは限らないことも報告） |
| **評価指標** | RMSE / MAE / correlation に加え、**方向性**（増減の一致）・**転換点**（ピーク/ボトムの一致）・**regime 遷移**（Hedge/Speculative/Ponzi、[minsky_regime_diagnostics.md](minsky_regime_diagnostics.md)）・**発散有無**を分けて評価する |
| **感応度分析** | `amortization_rate`（診断仮定）・`r` の実質化方式（§2.4）・`ω` の proxy（指数 vs 比率、§2.1）・標本期間（§1.2）・initial guess／multi-start・variable weight に対する結果の感応度を確認する |
| **fit の限界** | 当てはまりを**因果推論・危機確率・予測精度と同一視しない**（§8・[ADR 0004](../adr/0004-keen-empirical-calibration-strategy.md)） |

### 6.1 実装（`validate_keen`、#122）

`src/analysis/keen_validation.jl` が `KeenEmpiricalDataset` を入力に取り、`calibrate_keen`（§5.4）・
`simulate` の RK4 積分・`minsky_diagnostics_summary`（Phase 2 診断）を組み合わせて実証結果を
構造化して返す**読み取り専用の後処理層**。`KeenModel`・`KeenEmpiricalDataset`・
`KeenCalibrationResult` は変更しない。

- **入出力型**: `KeenValidationConfig`（設定）→ `validate_keen` → `KeenValidationResult`（結果）。
  既定設定は `keen_default_validation_config(dataset)`。
- **予測 trajectory**: 初期状態から観測時間軸（`Δt = 0.25`、§4）に沿って RK4 で積分する
  （`substeps_per_year` 既定 4 = 四半期刻み）。発散ガードに抵触した以降は `NaN`。
- **期間分離**: `in_sample` = `dataset.calibration_indices`、`out_of_sample` =
  `dataset.validation_indices`（look-ahead・重複なし。`split_info` に境界・観測数・除外を保存）。
  validation の情報は推定 objective へ使わない（推定は §5.4 の calibration split のみ）。
- **validation 初期値**: `:observed_start`（validation 開始の実観測から積分）と
  `:calibration_continued`（calibration 開始から連続積分し validation 部分をスライス）を
  **別 metric として区別**する（`initial_state_modes`）。
- **変数別 metric**（`KeenVariableMetrics`、`:ω`・`:λ`・`:d` 各々）: RMSE・MAE・correlation・
  mean error（bias）・direction accuracy（前期比符号一致）・turning point 数と timing error。
  スケール差は単一総合点へ集約せず、観測標準偏差で正規化した `rmse_standardized` を別途提供する。
  欠損・発散後 `NaN` は有効ペアから除外し、`0` として扱わない。
- **regime 検証**（`KeenRegimeComparison`）: observed proxy（観測 `ω`・`d` へ Phase 2 診断を直接適用。
  `g` は観測不能のため成長依存指標のみ未定義）・literature モデル・calibrated モデルの
  full-sample 予測 trajectory を、同一契約の `MinskyDiagnosticsSummary` で並べる
  （first speculative/ponzi・hedge 回復・coverage/margin 最小値と時点・peak debt・発散）。
  **observed proxy は集計系列への操作的定義の代理であり、企業別実測分類ではない**。
- **感応度分析**（`KeenSensitivityResult`、base を含む）: `KeenSensitivityScenario` で base に対する
  `dataset` / `calibration_config` / `regime_config` の上書きを表す。`dataset` と
  `calibration_config` が両方 base のシナリオ（＝ `amortization_rate` 変更等）は**再推定せず base の
  calibrated モデルを再利用**するため、ODE・推定結果は不変で診断だけが変わる。既定シナリオは
  `amortization_rate` 3 値・実質金利代理・initial guess 変更・variable weight 変更。`ω` proxy 代替・
  標本期間変更は代替 `KeenEmpiricalDataset` を要するため、`sensitivity_scenarios` へ追加して指定する。
- **合格判定**: Phase 3 では単一 pass/fail 閾値を課さない。calibrated が literature より悪化した場合は
  `calibrated_worse_than_literature` と `warnings` で明示し隠さない。発散・弱識別・境界張り付きも
  `warnings` に集約する。`caveats`（`KEEN_VALIDATION_CAVEATS`）で fit ≠ 因果・危機確率・投資助言を明記する。
- **再現性**: 同一 `dataset`・`config` で決定的。`keen_validation_to_dict` / `save_keen_validation` で
  metric・regime サマリー・感応度・split 情報・provenance を JSON 保存する（生系列・dataset は含めない）。

---

## 7. 設計原則（受け入れ条件との対応）

| 受け入れ条件 | 本書での対応 |
|---|---|
| `ω, λ, d, r` の観測方程式・系列候補・単位・頻度・変換規則 | §2 各表 |
| 公表系列が指数か比率かを検証せず直接利用しない | §2.1（`PRS85006173` は指数、比率化を経る）・§2 冒頭の検証義務 |
| 年単位 ODE と四半期観測を整合させる時間軸契約 | §4（`Δt = 0.25`・共通数値時間軸 inner join・4 点詰め込み禁止） |
| 固定パラメータと推定パラメータの分離・全同時推定を既定にしない | §3・§5.2 |
| 推定 objective・境界・欠損/発散処理・再現性 metadata | §5.3 |
| in-sample/out-of-sample・literature/calibrated・診断仮定感応度 | §6 |
| 危機予測・因果推論との誤認を防ぐ限界 | §8・[ADR 0004](../adr/0004-keen-empirical-calibration-strategy.md) |

---

## 8. 理論上・実証上の限界

| 限界 | 内容 |
|---|---|
| 変数と系列の非同一 | モデル変数（`ω, λ, d`）と統計系列は近似対応であり厳密に同一ではない（[variable_mapping.md](../data/variable_mapping.md) §はじめに） |
| 部門・分母定義のずれ | `d` の BIS 総民間は家計を含み、Keen の企業債務を過大カバレッジ。`λ` の分母 `N` の定義差（§2.2・2.3） |
| `r` の性質差 | モデルは `r` を実質・一定と仮定するが実データは時変・名目。国債実質金利と企業借入金利は別物（§2.4） |
| 双安定性による当てはめの脆弱性 | trajectory 方式は崩壊経路への跳びで目的関数が不連続。ODE residual を採るが差分近似誤差は残る（§5） |
| 弱識別 | 短い標本から非線形行動パラメータを同時推定すると弱識別・複数局所解が生じうる（§5.3 で検出） |
| fit ≠ 予測・因果・危機確率 | in-sample の当てはまりの良さは、危機の予測精度・因果関係・危機発生確率を意味しない（§6・[ADR 0004](../adr/0004-keen-empirical-calibration-strategy.md)・[LLM 安全性ルール](../llm_safety.md)） |

---

## 9. 対象外（本設計のスコープ外）

> 以下は本設計（#119）自体のスコープ外。データ取得・変換（#120）・限定キャリブレーション（#121, §5.4）・
> 実証バリデーションと感応度分析（#122, §6.1）は後続 Issue で実装済み。

- 全 10 パラメータの完全推定（限定キャリブレーションは §5.4 で実装済み。全同時推定は将来オプション）
- 日本向け系列の最終実装
- ベイズ推定・粒子フィルタ・状態空間モデル
- 標準誤差の厳密な統計推論（Hessian ベース）
- 危機発生確率・投資シグナルの推定
- LLM による自然言語解説

---

## 10. 参考

- [Keen モデル解説](keen.md) — 状態変数・`keen_rhs`・良い均衡の閉形式・発散ガード
- [Minsky系金融不安定性モデル設計方針](minsky_design.md) §7 — 実データ接続時の候補系列
- [モデル変数と実データ系列のマッピング表](../data/variable_mapping.md) §2.9 — Keen 変数の対応品質・変換注意
- [Minsky 資金調達区分診断](minsky_regime_diagnostics.md) — regime 遷移による検証で再利用する診断層
- [FRED API 接続ガイド](../data/fred.md)・[実データ前処理ユーティリティ](../data/preprocess.md) — 取得・変換の実装基盤
- [API リファレンス](../api.md) の「Keen 実証データセット」節 — `build_keen_empirical_dataset`・`KeenEmpiricalDataConfig`・`KeenEmpiricalDataset`（本戦略のデータ層実装）
- [ADR 0004](../adr/0004-keen-empirical-calibration-strategy.md) — 識別戦略の決定記録
- Grasselli, M. R., & Costa Lima, B. (2012). An analysis of the Keen model for credit expansion, asset price bubbles and financial fragility. *Mathematics and Financial Economics*, 6(3), 191-210.
