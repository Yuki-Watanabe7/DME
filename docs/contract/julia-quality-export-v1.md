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
- 実測捕捉（Issue #208）: [`src/quality/quality_capture.jl`](../../src/quality/quality_capture.jl)（result 組み立ての純粋関数）・[`test/quality_capture_runner.jl`](../../test/quality_capture_runner.jl)（`Pkg.test()` 統合の実行経路）
- Coverage.jl 実測（Issue #209）: [`scripts/quality_export_coverage.jl`](../../scripts/quality_export_coverage.jl)（`Pkg.test(coverage=true)` を呼ぶ driver。§8 方法C）
- 検証ヘルパー: [`scripts/validate_quality_export.jl`](../../scripts/validate_quality_export.jl)（生成済み export の round-trip・schema 検証・サマリー表示。`julia --project=. scripts/validate_quality_export.jl [path]`。#211/#212/#213 が result を追加していく際も変更なしで再利用できる）
- GitHub Actions Artifact 公開（Issue #210）: [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml)（§8.1）
- fixture: [`test/fixtures/quality_export/`](../../test/fixtures/quality_export/)（`valid/`・`invalid/`）
- テスト: [`test/test_quality_export.jl`](../../test/test_quality_export.jl)・[`test/test_quality_capture.jl`](../../test/test_quality_capture.jl)

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

`result` の中身（フィールド構造）はツールごとに §3 の対応 Issue が定義する。現時点では
`Dict`/`Vector`/`String`/`Bool`/`Integer`/有限 `AbstractFloat`/`Nothing` の入れ子であることのみを
Julia 側が強制する（`canonical_json_bytes` の値域制約）。`Pkg.test`/`Aqua.jl`/`JuliaFormatter.jl`
の3ツールは §4.1 で定義済み（Issue #208）。残り4ツールは対応 Issue（#209/#211/#212/#213）が
実装した時点でこのドキュメントへ追記する。

## 4.1 Pkg.test/Aqua.jl/JuliaFormatter.jl の result

Issue #208。`Pkg.test()` の単一実行（`test/runtests.jl` が `DME_QUALITY_EXPORT_ENABLED=1` のときに使う
opt-in 経路。§8 参照）から捕捉する。`status` は3ツールとも通常 `success`（**テスト失敗・
check失敗・未フォーマットファイルの存在も「測定できた」に含まれ、`success` のまま — §4 の
「実行して測定できた（`0` を含む）」の`0`をより一般化した「N件」の場合。合否・スコアの判定は
`software-quality-dashboard` 側の責務であり、本 contract は事実（件数・一覧）のみを保持する）。
`status=failure` はツール自体・捕捉処理そのものが失敗した場合（例:
`Test.get_test_counts`/`Test.TestSetException` から構造化結果を得られなかった、
`Aqua.test_all` が check 用の子テストセットを1つも作らず落ちた）に限る。

Julia オブジェクト（`Test.AbstractTestSet`・`Test.TestSetException`）を直接扱う場所は
`test/quality_capture_runner.jl` に限定し、`result` を組み立てる純粋関数
（`quality_tool_pkgtest_result`/`quality_tool_aqua_result`/`quality_tool_formatter_result`。
`src/quality/quality_capture.jl`）は Test.jl に依存しない（詳しい設計判断・Test internals
依存の範囲は両ファイル冒頭コメント参照。Issue #208「tool result捕捉のためにTest internalsへ
過度に依存しない設計を選び、制約を文書化する」への対応）。

### `Pkg.test`

| フィールド | 型 | 内容 |
|---|---|---|
| `assertions_total` | integer | `assertions_passed + failures + errors + broken` |
| `assertions_passed` | integer | 成功した `@test` の数 |
| `failures` | integer | 失敗した `@test` の数 |
| `errors` | integer | 例外を投げた `@test`/テストセット本体の数 |
| `broken` | integer | `@test_broken`/`@test_skip` の数 |
| `suite_passed` | bool | `failures == 0 && errors == 0`。Dashboard 向けの生の事実の付記であり閾値判定ではない |

`test/runtests.jl` の全 include を1つの外側の `@testset` で包んで捕捉する（`Test.get_test_counts`
の再帰集計、または捕捉した `Test.TestSetException` の `pass`/`fail`/`error`/`broken` から算出）。

```json
"Pkg.test": {
  "status": "success",
  "version": "1.12.6",
  "started_at": "2026-08-08T08:00:00Z",
  "completed_at": "2026-08-08T08:05:00Z",
  "duration_seconds": 300.0,
  "result": {
    "assertions_total": 4321, "assertions_passed": 4321,
    "failures": 0, "errors": 0, "broken": 0, "suite_passed": true
  }
}
```

### `Aqua.jl`

| フィールド | 型 | 内容 |
|---|---|---|
| `checks_run` | `Vector<string>` | 実際に実行した check 名（`persistent_tasks=false` 等で無効化した check は含まれない） |
| `failed_checks` | `Vector<string>` | `checks_run` のうち失敗した check 名 |
| `checks` | object（キー=check名） | `{"passed": bool, "message"?: string}`。`message` は失敗時のみ |
| `settings` | object | `Aqua.test_all` へ渡した設定（`ambiguities`/`persistent_tasks` 等）の provenance |

`test/test_quality.jl` の `"Aqua.jl package quality"` テストセットの戻り値（`.results` の
各要素）を check 単位に分解する。無効化した check（例: `persistent_tasks=false`）はそもそも
`Aqua.test_all` が子テストセットを作らないため `checks_run` に現れない
（「未実行toolが success/0件にならない」の粒度を check 単位でも満たす）。

```json
"Aqua.jl": {
  "status": "success",
  "version": "0.8.9",
  "started_at": "2026-08-08T08:00:00Z", "completed_at": "2026-08-08T08:00:12Z",
  "duration_seconds": 12.0,
  "result": {
    "checks_run": ["Compare Project.toml and test/Project.toml", "Compat bounds", "Method ambiguity", "Piracy", "Stale dependencies", "Unbound type parameters", "Undefined exports"],
    "failed_checks": [],
    "checks": { "Method ambiguity": { "passed": true }, "...": "..." },
    "settings": { "ambiguities": { "recursive": false }, "persistent_tasks": false }
  }
}
```

### `JuliaFormatter.jl`

| フィールド | 型 | 内容 |
|---|---|---|
| `formatted` | bool | `src/` 配下の全 `.jl` ファイルがフォーマット済みか |
| `unformatted_files` | `Vector<string>` | 未フォーマットファイルの `src/` からの相対パス一覧（`formatted=true` なら空） |

`JuliaFormatter.format(dir; overwrite=false)` は全体で1つの `Bool` しか返さないため、
`test/test_quality.jl` は `src/` 配下の `.jl` ファイルを列挙し1ファイルずつ
`JuliaFormatter.format(file; overwrite=false)` を呼ぶ（`format(dir)` も内部でファイル単位に
展開しているだけなので、追加のフルディレクトリ走査を行っているわけではない）。

```json
"JuliaFormatter.jl": {
  "status": "success",
  "version": "2.10.1",
  "started_at": "2026-08-08T08:00:12Z", "completed_at": "2026-08-08T08:00:15Z",
  "duration_seconds": 3.0,
  "result": { "formatted": true, "unformatted_files": [] }
}
```

## 4.2 Coverage.jl の result

Issue #209。line coverage を `Coverage.jl`（[JuliaCI/Coverage.jl](https://github.com/JuliaCI/Coverage.jl)）で
測定する。実測は `test/quality_capture_runner.jl` ではなく、`Pkg.test()` を呼び出す**外側**の
driver スクリプト [`scripts/quality_export_coverage.jl`](../../scripts/quality_export_coverage.jl)
が担う（理由は §8 の「なぜ Coverage.jl だけ2段階か」参照）。`result` の組み立て自体は
`quality_tool_coverage_result`（`src/quality/quality_capture.jl`）が担う。

| フィールド | 型 | 内容 |
|---|---|---|
| `covered_lines` | integer | 実行されたコード行数 |
| `coverable_lines` | integer | 実行可能（coverable）なコード行数の総数。**1以上**（0は§4の表と同じ「計測不能」に該当し、`status=:failure` で報告する。§9） |
| `target_paths` | `Vector<string>` | 集計対象にしたディレクトリ（リポジトリルートからの相対パス）。既定 `["src"]` |
| `excluded_paths` | `Vector<string>` | 集計対象から除外したトップレベルディレクトリの一覧（ドキュメント目的。`test`/`examples`/`scripts` を含む） |

`covered_lines`/`coverable_lines` は `Coverage.process_folder("src") |> Coverage.get_summary` の
戻り値をそのまま使う。**percent（`julia.line_coverage` 相当の割合）は DME 側では計算しない**。
`software-quality-dashboard` の Julia Native Provider（`providers/julia/mapper.py` の
`"Coverage.jl"` ケース）が `covered_lines / coverable_lines * 100` を Consumer 側で計算する契約に
既になっており（`coverable_lines <= 0` は `MetricStatus.COLLECTION_ERROR` として扱う実装も
既存）、Producer 側で重複して percent を持つと丸め方式の食い違いで2つの数字が矛盾しうるため
（Issue #209 の「line_coverage percent は Producer/Consumer どちらで計算するか」を、Consumer 側の
既存実装に合わせて確定した）。

```json
"Coverage.jl": {
  "status": "success",
  "version": "1.8.1",
  "started_at": "2026-08-08T08:09:47Z", "completed_at": "2026-08-08T08:10:22Z",
  "duration_seconds": 35.0,
  "result": {
    "covered_lines": 1224,
    "coverable_lines": 1642,
    "target_paths": ["src"],
    "excluded_paths": ["examples", "scripts", "test"]
  }
}
```

**測定対象の範囲**: `src/**/*.jl` のみ（`examples/`・`scripts/`・`test/` は対象外）。
`--code-coverage=user` は JuMP・Ipopt・Plots 等の依存パッケージ本体
（`~/.julia/packages/...` 配下）にも `.cov` を生成するが、それらは `src/` の外にあるため
`Coverage.process_folder("src")` はそもそも読みに行かない（対象への混入は構造的に起きない）。
DME 自身はサブプロセスを spawn しない（`Distributed`/`` `julia ...` `` 呼び出しは無し）ため、
`Pkg.test()` が spawn する唯一のテスト実行サブプロセス以外の coverage 欠落も発生しない。

`status=failure` になるケース: `Coverage.process_folder`/`Coverage.get_summary` が例外を投げた
場合、および `coverable_lines <= 0`（`.cov` トレースファイルが1件も生成されなかった等）の場合。
後者は「0%」ではなく計測不能であることを明示するための決定であり、`quality_tool_coverage_result`
自身が `coverable_lines <= 0` を `ArgumentError` で拒否することで構造的に強制する（§9）。

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

# Coverage.jl（Issue #209）
QUALITY_COVERAGE_TARGET_PATHS    # = ["src"]
QUALITY_COVERAGE_EXCLUDED_PATHS  # = ["examples", "scripts", "test"]
quality_tool_coverage_result(; covered_lines, coverable_lines, target_paths=QUALITY_COVERAGE_TARGET_PATHS, excluded_paths=QUALITY_COVERAGE_EXCLUDED_PATHS) -> Dict{String,Any}
quality_export_with_tool(e::QualityExport, tool::QualityToolExecution; generated_at=e.generated_at) -> QualityExport  # 1 tool だけ置き換えた新しい QualityExport を返す
```

## 8. 実行方法

**方法A: スタンドアロン骨格（`scripts/quality_export.jl`。テストを実行しない）**

```bash
julia --project=. scripts/quality_export.jl                       # 既定出力先 artifacts/quality/quality-export.json
julia --project=. scripts/quality_export.jl ./out/quality.json    # 出力先を指定
DME_QUALITY_EXPORT_OUTPUT=./out/quality.json julia --project=. scripts/quality_export.jl
```

7予約ツールすべてを `status="skipped"` のプレースホルダとして埋めるのみ
（`quality_export_package_identity()`・git commit/branch 検出・atomic 保存の配線が動くことを
確認するためのもの。テストを一切実行しないため `Pkg.test`/`Aqua.jl`/`JuliaFormatter.jl` も
含め常に `skipped`）。

**方法B: `Pkg.test()` 統合（`test/quality_capture_runner.jl`。Issue #208）**

```bash
DME_QUALITY_EXPORT_ENABLED=1 julia --project=. -e "using Pkg; Pkg.test()"
# 出力先の指定(優先順): DME_QUALITY_EXPORT_OUTPUT > 既定 artifacts/quality/quality-export.json
```

`Pkg.test/Aqua.jl/JuliaFormatter.jl` の3ツールを実測（§4.1）、`Coverage.jl` は「driver プロセス
側で後段計測する」という reason 付きの `skipped` プレースホルダで埋める（実測は方法Cが行う。
理由は §4.2・下記参照）。残り3ツール（JET.jl/BenchmarkTools.jl/Documenter.jl。#211/#212/#213）は
方法Aと同じ `skipped` プレースホルダのまま。`DME_QUALITY_EXPORT_ENABLED` 未設定時（既定）は
`test/runtests.jl` の挙動を一切変えない（この経路自体が有効化されない）。

有効化したときだけの意図的な副作用: 通常（未設定時）は `test/runtests.jl` の各テストファイルが
独立した最初の失敗で以降のファイルの実行を打ち切るのに対し、有効化時は全テストファイルを
1つの `@testset` で包んで実行しきり、失敗があれば最後に1回だけ例外を投げる（CI の exit code は
変えない）。これにより `Aqua.jl`/`JuliaFormatter.jl`（最後に実行される `test_quality.jl`）は
他のテストファイルの成否に関わらず必ず実行され捕捉される。詳細な設計判断・Test.jl 依存の範囲は
`test/quality_capture_runner.jl` 冒頭コメントを参照。

**方法C: `Coverage.jl` を含めた実測（`scripts/quality_export_coverage.jl`。Issue #209、推奨）**

```bash
julia --project=. scripts/quality_export_coverage.jl
# 出力先の指定（優先順）: DME_QUALITY_EXPORT_OUTPUT > 既定 artifacts/quality/quality-export.json
```

方法Bを内部で1回だけ実行し（`DME_QUALITY_EXPORT_ENABLED=1` を自動設定、`Pkg.test(coverage=true)`。
テストスイートを2回実行しない）、そのサブプロセスが終了した後に `Coverage.jl`（line coverage）を
実測して同じファイルへ差し込む（§4.2）。CI の fast lane はこの方法Cを使う
（`.github/workflows/ci.yml`）。

**なぜ Coverage.jl だけ2段階か**: `.cov` トレースファイルは計測対象を実行した julia プロセス自身
が**終了したとき**にのみディスクへ書き出される（Coverage.jl 自体の制約）。`Pkg.test()` は常に
`test/runtests.jl` を別のサブプロセスとして spawn するため、そのサブプロセスの内側で動く
`test/quality_capture_runner.jl` は自分自身の coverage を読めない。`Pkg.test()` を呼び出す
**外側**のプロセス（サブプロセスが終了した後に制御が戻ってくる）でなければ `.cov` を集計できない
——これが `scripts/quality_export_coverage.jl` が別ファイル・別実行ステップとして存在する理由
（`quality_export_with_tool`（`src/quality/quality_export.jl`）が、方法Bが書き出したファイルへ
`Coverage.jl` のエントリだけを後から差し込む）。詳細は `scripts/quality_export_coverage.jl`
冒頭コメント参照。

**失敗の扱い**: `Pkg.test()` 自体の失敗（テスト失敗）は従来どおり CI を失敗させる。coverage の
集計だけが失敗した場合（`coverable_lines <= 0` を含む）は `Coverage.jl` のエントリを
`status=:failure` にするのみで、方法C自体の終了コードには影響させない（Issue #209
「初期導入では Quality Gate で merge を阻止せず、baseline 収集を優先する」という決定）。

## 8.1 GitHub Actions Artifact 公開（Issue #210）

CI の fast lane（[`.github/workflows/ci.yml`](../../.github/workflows/ci.yml)）は方法C
（`scripts/quality_export_coverage.jl`）が書き出した `quality-export.json` を、job の成否に
関わらず（`if: always()`）検証した上で GitHub Actions Artifact として公開する。job 成功時だけ
upload する設計にはしない（テスト失敗・coverage 失敗の run ほど診断情報が必要なため）。

**手順（Test ステップの後）**:

1. `python3 -m pip install jsonschema`（scripts/validate_quality_export.jl の schema 検証を
   ベストエフォート skip ではなく必ず実行させるため。ローカル開発では未インストールでも
   skip されるだけで許容するが、CI では検証自体を無効化しない）
2. `julia --project=. scripts/validate_quality_export.jl` を実行し、
   `load_quality_export`/round-trip/JSON Schema の3種の検証すべてを通すことを確認する
   （§7 の Julia API 早見表がそのまま validator を兼ねる。`quality-export.json` が存在しない
   場合＝ Test ステップが致命的に失敗して export 自体を書き出せなかった場合も、この時点で
   「invalid」として扱う）
3. 検証結果に応じて公開する Artifact 名を分ける:
   - **valid**: `dme-julia-quality-v1-${{ github.sha }}`（schema major + full commit SHA。
     retention 90日）
   - **invalid/missing**: `dme-julia-quality-v1-invalid-${{ github.sha }}`
     （検証ログ `quality-export-validate.log` を同梱。retention 14日）

   invalid な export を正規Artifact名の下で公開しない（consumer 側が名前だけを見て
   valid だと誤認しないための構造的な区別）。

**Artifact 内容の最小化**: 公開する Artifact は `quality-export.json`（と invalid 時のみ
検証ログ）に限定する。coverage raw summary（`.cov` トレースファイル）は集計後に
`Coverage.clean_folder` で削除済みであり、そもそも artifact 化しない（§4.2 の
`covered_lines`/`coverable_lines` が quality export 自身に含まれるため、raw summary を
別途保持する必要がない）。

**rerun 時の識別・置換方針**: 同一 job を rerun した場合、Artifact 名（`${{ github.sha }}`
込み）は変わらない。`actions/upload-artifact@v4` の `overwrite: true` により、rerun の結果で
既存 Artifact を置き換える（複数 run の結果を同名で共存させず、常に「その commit の最新の
実行結果」を指す1つの Artifact にする。過去の run 結果を履歴として保持する用途は本 contract の
対象外 — §1「1ファイル=1コミットに対する1回の実行」）。

**Artifact と workflow run/job の対応**: Artifact 自体は GitHub Actions の
Artifacts API（`GET /repos/{owner}/{repo}/actions/artifacts`）を通じて、それを生成した
workflow run（`workflow_run.id`）と構造的に紐づく。quality export の JSON 内に
`run_id`/`job_id` を重複して持たせない（Artifact 内容の最小化を優先し、GitHub 側が既に
提供する対応関係を DME 側で再実装しない）。

**commit SHA の整合性**: `pull_request` イベントでは `github.sha` は PR head と base の
synthetic merge commit（`refs/pull/<N>/merge`）を指すが、`actions/checkout` は同じ
merge commit をデフォルトで checkout するため、export 内の `commit`（`git rev-parse HEAD`
由来、§8 の `_qe_detect_branch`/`_detect_git_commit_sha`）は常に `github.sha` と一致する
（`push` イベントでは両者とも実際に push された commit を指す）。

**権限・fork PR 安全性**: workflow の `permissions` は `contents: read` のみ（`actions: write`
は付与しない — `actions/upload-artifact`・`julia-actions/cache` はいずれも
`ACTIONS_RUNTIME_TOKEN` 経由の専用エンドポイントを使い `GITHUB_TOKEN` の `actions` scope に
依存しないため、artifact upload・cache save/restore の両方とも権限を必要としない）。
トリガーは `pull_request`（`pull_request_target` ではない）のままなので、fork からの PR でも
`GITHUB_TOKEN` は GitHub 側の既定で自動的に read-only になり、secrets へのアクセスも生じない。

**action 参照の固定方針**: `actions/checkout@v7`・`julia-actions/setup-julia@v2`・
`julia-actions/cache@v3`・`actions/upload-artifact@v4` はいずれもメジャーバージョンタグで
固定する（SHA pin へは変更しない）。DME の既存 workflow（`claude.yml`・`claude-code-review.yml`
含む）がすべて同じメジャーバージョンタグ方式であり、本 Issue 単体で異なる固定方式を混在させない
ことを優先した（SHA pin へ統一する場合はリポジトリ全体を対象にした別 Issue で扱う）。
`actions/checkout` は Node.js 20 ランタイムの deprecation（v4 は Node20 固定のため実行時に
Node24 へ強制フォールバックする旨の警告が CI ログに出る）を解消するため、後日 v7
（Node24 ネイティブ対応）へ更新した。`claude.yml`/`claude-code-review.yml` は本更新の対象外
（別途の更新が必要であれば別 Issue/PR で扱う）。

## 9. 限界

- 本 contract は「DME 側が何を測定したか」という事実のみを保持する。品質スコア・合否判定は
  `software-quality-dashboard` 側の責務であり、本 contract には存在しない（ADR 0009/0012 の
  「事実と評価の分離」を踏襲）。
- `result` の構造は `Pkg.test`/`Aqua.jl`/`JuliaFormatter.jl`/`Coverage.jl` の4ツールで確定した
  （§4.1・§4.2、Issue #208/#209）。残り3ツールは対応 Issue（#211/#212/#213）が実装した時点で、
  `result` フィールド一覧をこのドキュメントへ追記する（envelope 自体のスキーマ変更は伴わない想定）。
- redaction は既知パターンベースのベストエフォートであり、機密情報の漏洩を構造的に防げる保証では
  ない（§5）。
- `Test.get_test_counts`・`Test.TestSetException` の各フィールドは Julia の Test stdlib が
  意味を明記して公開している準内部 API であり、将来のマイナーバージョンで構造が変わりうる
  （`test/quality_capture_runner.jl` 冒頭コメント）。取得できない場合は `status=:failure`
  として報告し、黙って `0` 件や `skipped` に丸めない。
- 方法B/Cは `DME_QUALITY_EXPORT_ENABLED` が有効なときに限り、テストファイル1件の失敗で以降が
  未実行になる挙動を「全ファイル実行しきってから最後に1回失敗を報告する」へ変える（上記§8）。
- `Coverage.jl` の line coverage は `src/**` のみを対象とする（§4.2）。分岐カバレッジ
  （branch coverage）・diff coverage・coverage threshold による merge 阻止は対象外（Issue #209の
  「対象外」）。複数コミットにまたがる履歴・トレンドの保持は本 contract の範囲外（1ファイル=
  1コミットの1回の実行、§1）。
- GitHub Actions Artifact としての公開（Artifact 名規約・schema validation gate・
  retention・rerun 時の置換方針）は Issue #210 で確定した（§8.1）。ただし Dashboard 側からの
  Artifact 取得（一覧・ダウンロード・vintage 管理）は対象外のまま（#8 に委ねる）。
- Artifact の schema validation gate（§8.1）は「DME 側の export 生成自体が壊れている」ことを
  検出する目的に限る。個々の品質ツールの測定結果自体（テスト失敗・coverage 未達等）を理由に
  gate で CI を止めることはしない（Issue #209 の「baseline 収集を優先する」方針を踏襲。
  両者は独立に扱う — §8.1・§8「失敗の扱い」）。
