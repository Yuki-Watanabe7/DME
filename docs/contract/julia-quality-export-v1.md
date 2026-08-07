# Julia品質Export Contract（`julia-quality-export/v1`）

> 関連Issue: [Yuki-Watanabe7/DME#207](https://github.com/Yuki-Watanabe7/DME/issues/207)
> （Parent Roadmap: [Yuki-Watanabe7/software-quality-dashboard#6](https://github.com/Yuki-Watanabe7/software-quality-dashboard/issues/6)）
> 設計判断: [ADR 0016](../adr/0016-julia-quality-export-contract.md)

DME **が所有する** versioned contract。`software-quality-dashboard` の Julia Native
Provider（`julia_native.py`）が読み取る、Julia ツールチェーンの品質測定結果の機械可読
export。`docs/contract/README.md`（DME real-rate model artifact）とは逆方向の契約であることに
注意: あちらは economic-data-provider が所有し DME が満たす側、こちらは **DME が所有し**
software-quality-dashboard が満たす側。

## 1. 位置づけと対象外

- Schema: [`schemas/julia-quality-export-v1.schema.json`](../../schemas/julia-quality-export-v1.schema.json)（JSON Schema 2020-12）
- Julia 実装: [`src/quality/quality_export.jl`](../../src/quality/quality_export.jl)（型・バリデーション・シリアライズ・redaction。schema に対する汎用 JSON Schema バリデータは持たず、この実装自体が validator を兼ねる — `src/artifacts/real_rate_model_artifact.jl` と同じ doctrine）
- Exporter骨格: [`scripts/quality_export.jl`](../../scripts/quality_export.jl)
- fixture: [`test/fixtures/quality_export/`](../../test/fixtures/quality_export/)（`valid/`・`invalid/`）
- テスト: [`test/test_quality_export.jl`](../../test/test_quality_export.jl)

1ファイル = **1コミットに対する1回の実行**を表す（複数コミットの履歴を1ファイルへまとめない）。
`software-quality-dashboard` 側の `fixtures/providers/julia/*.json` のように複数コミットを
`runs` 配列へ束ねる形とは異なる（あちらは Provider 側が複数の export ファイルを履歴として
束ねるフィクスチャであり、本 contract が定義する1ファイルの形ではない）。

対象外（本 Issue #207 の範囲。roadmap の後続 Issue が扱う）:

- 各品質ツールの本格実行（`tools.*.result` の中身の構造化は #208/#209/#211/#212/#213 が個別に行う。本 Issue は envelope とツール実行1件の共通構造のみを定義する）
- GitHub Actions Artifact upload（#210）
- Dashboard からの Artifact 取得（#8）
- 閾値判定・品質スコア化（`software-quality-dashboard` 側の責務。ADR 0009/0012 等で確立した「事実の保持と評価の分離」を踏襲し、本 contract は測定事実のみを保持する）

## 2. トップレベル構造

```json
{
  "export_schema": "julia-quality-export/v1",
  "producer": { "name": "dme-quality-export", "version": "0.1.0" },
  "package": { "name": "DME", "uuid": "32de5cd0-ad60-11e9-36bc-9b7c9b1e2078", "version": "0.1.0" },
  "repository": { "owner": "Yuki-Watanabe7", "name": "DME" },
  "branch": "main",
  "commit": "cafe0002cafe0002cafe0002cafe0002cafe0002",
  "measured_at": "2026-08-03T08:05:00Z",
  "generated_at": "2026-08-03T08:05:01Z",
  "julia_version": "1.12.6",
  "tools": { "Pkg.test": { "...": "..." } }
}
```

| フィールド | 型 | 内容 |
|---|---|---|
| `export_schema` | `const "julia-quality-export/v1"` | contract 識別子。メジャーバージョンのみ含む（§6） |
| `producer.name`/`producer.version` | string | export を生成した Exporter 自体の識別（`dme-quality-export`） |
| `package.name`/`package.uuid`/`package.version` | string | 測定対象パッケージ（DME 自身）の識別。`Project.toml` と一致（`quality_export_package_identity()` が `Base.PkgId`/`pkgversion` から自動導出し、ハードコードによる乖離を構造的に避ける） |
| `repository.owner`/`repository.name` | string | GitHub リポジトリ識別 |
| `branch` | string | 実行時のブランチ名 |
| `commit` | 40桁小文字16進 | フル commit SHA |
| `measured_at` | UTC datetime | 測定対象の実行が開始した時刻 |
| `generated_at` | UTC datetime | この export ファイルを書き出した時刻（`measured_at` 以上） |
| `julia_version` | string | 実行環境の Julia バージョン |
| `tools` | object（キー=ツール名） | 1件以上。§4 |

タイムゾーンは real-rate model artifact（[ADR 0008 §3](../adr/0008-real-rate-model-artifact-export.md)）
と同じ MVP 制約で UTC 固定、`"...Z"` 接尾辞のみをサポートする（オフセット表記・小数秒は非対応）。

## 3. 予約ツール名

`tools` は open な辞書（`additionalProperties`）であり、以下7件を contract 上の予約名とする。
実測実行は本 Issue の対象外で、どの Issue が実装するかを併記する。

| ツール名 | 対応 Issue |
|---|---|
| `Pkg.test` | #208 |
| `Aqua.jl` | #208 |
| `JuliaFormatter.jl` | #208 |
| `Coverage.jl` | #209 |
| `JET.jl` | #211 |
| `BenchmarkTools.jl` | #212 |
| `Documenter.jl` | #213 |

予約名以外のツール名を追加してもスキーマの互換性は破らない（§6、新規 `metric_id` 追加と同じマイナー扱い）。

## 4. ツール実行1件の構造

`status` に応じて必須/禁止フィールドが変わる。`0`・未計測・未導入・実行失敗を混同しないための
強制であり、`QualityToolExecution` のキーワードコンストラクタ（および `quality_export_from_dict`）
がこの表をそのまま検証する。

| `status` | 必須 | 禁止 | 意味 |
|---|---|---|---|
| `success` | `started_at`・`completed_at`・空でない `result` | `error` | 実行して測定できた（`0` を含む） |
| `failure` | `started_at`・`completed_at`・`error`（`type`/`message`） | `result` | 実行したが失敗した |
| `timeout` | `started_at`・`completed_at`・`error`（`type`/`message`） | `result` | 実行したが時間切れになった |
| `skipped` | `reason` | `result`・`error` | この実行では対象外だった（例: fast lane では slow lane 専用ツールを走らせない） |
| `not_installed` | `reason` | `result`・`error` | 環境にツール自体が存在しない |

`version`（ツールのバージョン文字列）は全 status で任意。`duration_seconds` は呼び出し側が渡す
ものではなく `completed_at - started_at` から自動導出する（矛盾した入力を構造的に排除する）。
`tool_name` は `tools` オブジェクトのキー自身が担い、値側に重複したフィールドは持たない。

`result` の中身（フィールド構造）は本 Issue の対象外で、ツールごとに §3 の対応 Issue が定義する。
現時点では `Dict`/`Vector`/`String`/`Bool`/`Integer`/有限 `AbstractFloat`/`Nothing` の入れ子で
あることのみを Julia 側が強制する（`canonical_json_bytes` の値域制約）。

## 5. Secret/環境変数/API credential の redaction 方針

DME が実際に使う秘匿環境変数（[設定・環境変数管理ガイド](../development/configuration.md)）は
`FRED_API_KEY`・`ESTAT_APP_ID`・`OPENAI_API_KEY`、加えて GitHub Actions の `GITHUB_TOKEN`。

- `error.type`・`error.message`・`reason` は自由記述フィールドとして扱い、`redact_secrets`
  （既知のクラウドトークン形状・`key=`/`token=` 等の代入パターン・上記環境変数名を検出して
  `"[REDACTED]"` に置換）を `QualityToolError`/`QualityToolExecution` のコンストラクタが自動的に
  適用する。呼び出し側が意識しなくても二重の防御になる。
- `result` は構造化データであり、黙って文字列を置換すると壊れる可能性があるため redact ではなく
  **拒否**する。秘匿情報らしき文字列が1箇所でも見つかった場合、`ArgumentError` で構築自体が失敗する
  （`test/fixtures/quality_export/invalid/secret-like-result.json` が具体例）。
- 将来ツール固有の実装（#208 等）が生のサブプロセス出力を人間可読フィールドへ渡す場合は、渡す前に
  `redact_secrets` を呼ぶことを推奨する（自動 redaction はあるが、構造化データ側の生ログ混入は
  上記の通り拒否されるため、そもそも `result` に生ログを入れない設計が必須）。
- **この redaction はベストエフォートである。既知パターンに一致しない秘匿情報は検出できない。**
  ツール実装側（#208 等）は、そもそも subprocess の環境変数へ秘匿情報を渡さない・生の
  stdout/stderr を `result`/`error.message` へ丸ごと転記しない、という一次防御を優先すること。

## 6. Versioning 方針

`export_schema` はメジャーバージョンのみを含む（`"julia-quality-export/v1"`）。
`software-quality-dashboard` の `docs/provider-development.md` §10 と同じ考え方を踏襲する。

| 変更 | バージョン影響 |
|---|---|
| 新しい任意フィールドの追加 | 影響なし（`result`/`producer`/`package` 等は open か、追加はスキーマの `additionalProperties: false` 更新を伴う PR で吸収する） |
| 予約名以外の新しいツール名の追加 | 影響なし（`tools` は open な辞書） |
| `status` enum への新メンバー追加 | メジャーバージョンアップ（`v2`）。schema・`QUALITY_EXPORT_TOOL_STATUSES`・consumer 側の enum 全てが同時に変わる必要があるため |
| 必須フィールドの削除・意味変更 | メジャーバージョンアップ |
| editorial（文言のみ） | 影響なし |

## 7. Julia API 早見表

詳細は [API リファレンス](../api.md#julia品質export-contract-v1quality_export) を参照。

```julia
# 構築
QualityExportProducer(; name = QUALITY_EXPORT_DEFAULT_PRODUCER_NAME, version = QUALITY_EXPORT_DEFAULT_PRODUCER_VERSION)
QualityExportPackage(; name, uuid, version)
quality_export_package_identity() -> QualityExportPackage  # Project.toml から自動導出
QualityExportRepository(; owner, name)
QualityToolError(; type, message)
QualityToolExecution(; tool_name, status, version=nothing, started_at=nothing, completed_at=nothing, result=nothing, error=nothing, reason=nothing)
quality_tool_not_run(tool_name, reason; status = :skipped)  # :skipped/:not_installed の糖衣関数
QualityExport(; producer=QualityExportProducer(), package, repository, branch, commit, measured_at, generated_at, julia_version=string(VERSION), tools)

# シリアライズ・保存
to_dict(e::QualityExport) -> Dict{String,Any}
to_json(e::QualityExport) -> String            # 正準 JSON（RFC 8785 JCS、real-rate model artifact と同じ経路）
quality_export_from_dict(d::AbstractDict) -> QualityExport   # validator を兼ねる
quality_export_from_json(s::AbstractString) -> QualityExport
save_quality_export(e, path; overwrite = true) -> String     # atomic write（.tmp + fsync + mv）
load_quality_export(path) -> QualityExport

# redaction
redact_secrets(s::AbstractString) -> String
```

## 8. 実行方法

```bash
julia --project=. scripts/quality_export.jl                       # 既定出力先 artifacts/quality/quality-export.json
julia --project=. scripts/quality_export.jl ./out/quality.json    # 出力先を指定
DME_QUALITY_EXPORT_OUTPUT=./out/quality.json julia --project=. scripts/quality_export.jl
```

現状の骨格は7予約ツールすべてを `status="skipped"` のプレースホルダとして埋めるのみ
（`quality_export_package_identity()`・git commit/branch 検出・atomic 保存の配線が動くことを
確認するためのもの）。実測実行への置き換えは §3 の対応 Issue が行う。

## 9. 限界

- 本 contract は「DME 側が何を測定したか」という事実のみを保持する。品質スコア・合否判定は
  `software-quality-dashboard` 側の責務であり、本 contract には存在しない（ADR 0009/0012 の
  「事実と評価の分離」を踏襲）。
- `result` の構造は本 Issue で確定しない。#208 等が実装した時点で、各ツールの `result` フィールド
  一覧をこのドキュメントへ追記する（envelope 自体のスキーマ変更は伴わない想定）。
- redaction は既知パターンベースのベストエフォートであり、機密情報の漏洩を構造的に防げる保証では
  ない（§5）。
