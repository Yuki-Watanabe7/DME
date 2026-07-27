# Real-rate model artifact 生成デモ

[examples/real_rate_model_artifact_export.jl](../../examples/real_rate_model_artifact_export.jl) は、
New Keynesian モデルから期待インフレ率・model-implied 実質政策金利を含む再現可能な JSON
artifact を構築・保存するデモです。**economic-data-provider ADR 006（[vendor コピー](../contract/README.md)）
に準拠した artifact を、fixture calibration → 構築 → RFC 8785 正準 JSON での atomic 保存 →
読み込み・hash 再検証まで再現可能に完走**します。外部データ取得や乱数を一切使わないため、
API キー不要・完全に決定的です。

> 関連 Issue: [#159](https://github.com/Yuki-Watanabe7/DME/issues/159)

## 全体フロー

| Step | 内容 | 主な API |
|---|---|---|
| 1 | fixture calibration の `NewKeynesianModel` を構築（`docs/models/new_keynesian.md` の典型値） | `NewKeynesianModel` |
| 2 | `E_t[π_{t+h}]` の閉形式・level 復元を経て、必須6 metric（`current_inflation`・`expected_inflation`×2 horizon・`inflation_target`・`nominal_policy_rate`・`model_implied_real_policy_rate`×2 horizon・`natural_real_rate`）の observation を構築 | [`real_rate_model_artifact`](../adr/0008-real-rate-model-artifact-export.md) |
| 3 | `artifact_id`・`parameter_hash`・`calibration_hash`・`snapshot_hash` を構築時に自己計算し、実質金利の算術関係（`nominal - expected`、許容誤差 `1e-9`）を自己検証 | `RealRateModelArtifact` |
| 4 | RFC 8785 正準 JSON バイト列で `.tmp` へ書き、`fsync` 後 atomic rename で確定保存（ADR 006 §6 のファイル名規約） | `save_real_rate_model_artifact` |
| 5 | 保存したファイルを読み込み、hash を再計算して一致することを確認（改ざん・破損の検出） | `load_real_rate_model_artifact` |

steady_state（ショックなし）と trajectory（需要ショック、t=8期）の2シナリオを実演します。

## 実行方法

```bash
julia --project=. examples/real_rate_model_artifact_export.jl
```

| 環境変数 | 既定 | 説明 |
|---|---|---|
| `REAL_RATE_ARTIFACT_OUTDIR` | `artifacts/` | 成果物の出力先（この配下に ADR 006 §6 のディレクトリ構造を作る）。 |

`decision_time`・`data_cutoff_at`・`generated_at` はデモ内で固定値を使うため、同じ出力先へ
再実行すると同じ `artifact_id`・同じファイルパスになります（決定論的生成）。既に存在する
場合は上書きせず、既存ファイルをそのまま読み込みます（atomic save は「同名ファイルへの
上書き」だけを拒否する設計のため）。

## 生成される成果物

`REAL_RATE_ARTIFACT_OUTDIR`（既定 `artifacts/`）配下に、ADR 006 §6 のファイル名規約に従って
保存します。`artifacts/` は `.gitignore` 済みでリポジトリには含めません。

```
artifacts/real-rates/1.0.0/US/2026/07/
  <timestamp>__US__dme.new_keynesian__nk-us-steady-state-demo__<artifact_id 64hex>.json
  <timestamp>__US__dme.new_keynesian__nk-us-demand-shock-demo__<artifact_id 64hex>.json
```

各ファイルは [契約 schema](../contract/dme-real-rate-model-artifact.schema.json) に準拠した
1つの JSON artifact で、以下を含みます（[ADR 0008](../adr/0008-real-rate-model-artifact-export.md)
に設計判断の詳細）。

| セクション | 内容 |
|---|---|
| `model` | model_id・model_version・DME commit SHA・solver identity |
| `parameter_set` | パラメータ値（ASCII 名）と `parameter_hash` |
| `calibration` | calibration_id/version/kind（本デモは常に `fixture`）と `calibration_hash` |
| `input_snapshot` | 外部データ入力なし（`snapshot_kind="none"`） |
| `run` | country・run_id・scenario_id・output_kind（`steady_state`/`trajectory`）・purpose |
| `timing` | decision_time・data_cutoff_at（look-ahead 防止）・generated_at |
| `observations[]` | 6〜8件の metric 観測（`current_inflation`・`expected_inflation`・`inflation_target`・`nominal_policy_rate`・`model_implied_real_policy_rate`・`natural_real_rate`。horizon を持つ metric は `P3M`/`P1Y` の2件ずつ） |
| `warnings` | `fixture_calibration_not_empirical` 等の機械可読タグ |

## 結果の読み方・限界

- **fixture calibration であり実証推計ではない**: パラメータは `docs/models/new_keynesian.md`
  の典型値をそのまま使用しています。`calibration_kind="fixture"` と `warnings` の
  `fixture_calibration_not_empirical` がこれを明示します。
- **`rate_basis="annualized"` の解釈は DME 側の設計判断**: `π_star`/`r_n` を年率相当の値として
  扱い、P1Y horizon は4四半期の年率換算値の単純平均（`arithmetic_mean`）を使います。契約の
  illustrative example が使う `compounded_path`（複利）とは異なります。理由は
  [ADR 0008 §4](../adr/0008-real-rate-model-artifact-export.md#4-rate_basis-の統一と-p1y-集約方式)。
- **policy/overnight 以外は非対応**: `rate_type="policy"`・`tenor="overnight"` に固定されており、
  5年・10年 term structure は生成しません（`horizons` は `"P3M"`/`"P1Y"` のみ）。
- **`natural_real_rate` と `model_implied_real_policy_rate` は別 observation**: steady_state
  シナリオでは数値的に一致しますが（`r_n` の定義上）、`derivation.method`・`observation_id`は
  別のまま保持されます。同一視・代用はしません。
- **診断値であり投資判断・政策判断の自動化を目的としない**: economic-data-provider 側の
  比較 API（#94/#95）も同様の位置づけです。

## economic-data-provider への受け渡し手順

1. 本デモ（または本番相当の run）で artifact を生成し、`REAL_RATE_ARTIFACT_OUTDIR` に保存する。
2. 生成された JSON ファイルを、economic-data-provider が読み取る read-only ディレクトリ/
   object storage へ配置する（DME から provider への同期 HTTP 呼び出しは行わない。
   ADR 006 §3.1 の「immutable, versioned JSON artifact」を境界とする方針）。
3. economic-data-provider 側は schema・semantic validation（hash 一致・timestamp 順序・
   real-rate 算術関係等）を行った上で read-only に取り込み、比較 read model を構築する
   （DME 側はこの取り込み・比較ロジックを実装しない。#94/#95 の対象）。
4. artifact は immutable。再生成する場合は新しい artifact を追加し、既存ファイルを
   上書き・削除しない。
