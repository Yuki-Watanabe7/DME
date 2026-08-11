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
- JET.jl 実測（Issue #211、slow lane専用）: [`scripts/jet_report_extract.jl`](../../scripts/jet_report_extract.jl)（JET.jl の report オブジェクト→`QualityJetFinding` 抽出の純ライブラリ）・[`scripts/jet_analysis_worker.jl`](../../scripts/jet_analysis_worker.jl)（`report_package` を実行する worker）・[`scripts/quality_export_jet.jl`](../../scripts/quality_export_jet.jl)（worker を subprocess として起動し timeout を管理する driver。§8 方法D）
- 検証ヘルパー: [`scripts/validate_quality_export.jl`](../../scripts/validate_quality_export.jl)（生成済み export の round-trip・schema 検証・サマリー表示。`julia --project=. scripts/validate_quality_export.jl [path]`。#212/#213 が result を追加していく際も変更なしで再利用できる — #211 の JET.jl export でも実際に変更なしで再利用できることを確認済み）
- GitHub Actions Artifact 公開: fast lane（Issue #210）は [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml)（§8.1）、JET.jl slow lane（Issue #211）は [`.github/workflows/quality-slow.yml`](../../.github/workflows/quality-slow.yml)（§8.2）
- fixture: [`test/fixtures/quality_export/`](../../test/fixtures/quality_export/)（`valid/`・`invalid/`）
- テスト: [`test/test_quality_export.jl`](../../test/test_quality_export.jl)・[`test/test_quality_capture.jl`](../../test/test_quality_capture.jl)・[`test/test_quality_jet.jl`](../../test/test_quality_jet.jl)（opt-in、§8 方法D）

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
Julia 側が強制する（`canonical_json_bytes` の値域制約）。定義済みは
`Pkg.test`/`Aqua.jl`/`JuliaFormatter.jl`（§4.1、Issue #208）・`Coverage.jl`（§4.2、#209）・
`JET.jl`（§4.3、#211）・`BenchmarkTools.jl`（§4.4、#212）の6ツール。残る `Documenter.jl` は
対応 Issue（#213）が実装した時点でこのドキュメントへ追記する。

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

## 4.3 JET.jl の result

Issue #211。静的解析（型不安定性・実行時エラー候補の検出）を [JET.jl](https://github.com/aviatesk/JET.jl) で行う。
`Pkg.test/Aqua.jl/JuliaFormatter.jl/Coverage.jl` の4ツール（fast lane、push/PR毎）とは異なり、
JET.jl は **slow lane 専用**（schedule/workflow_dispatch のみ）で実行する。理由は
`docs/development/quality_checks.md` §3 の既存決定（数値計算コード・動的 JSON 応答を扱う
コードでの誤検知が push/PR の所要時間に影響することを避ける）を踏襲しつつ、Issue #211 で
「必要になった時点」として正式導入したもの。

### 対象範囲の決定

解析方式は `JET.report_package(DME; target_modules=(DME,))` を採用する（`JET.report_call` は
不採用）。理由:

- `report_package` は Revise.jl 経由で DME に定義された全メソッドのシグネチャを収集して解析するため、
  「package entry point・主要公開API・中核モデル実行経路・シナリオ/分析層」を個別に列挙する
  必要がなく、一度の呼び出しで package 全体を棚卸しできる。
- `target_modules=(DME,)` は JET.jl 公式ドキュメントが推奨する設定で、報告対象を「最終的に
  DME 自身のモジュールコンテキストで発生したもの」に限定し、JuMP/Ipopt/Plots/Base 等の
  依存パッケージ内部だけで完結する finding を除外する（Issue #211「dependency由来reportと
  DME由来reportを区別する」）。実測（2026-08時点、DME 0.1.0）: `target_modules` 無しでは
  175件、`target_modules=(DME,)` 適用後は113件。
- `src/` 配下を一律に対象とする。`examples/`/`scripts/`/`test/` は対象外だが、これは追加設定
  ではなく `report_package` が「モジュールに定義されたメソッド」しか解析しないことの自然な帰結
  （これらのディレクトリのコードは DME モジュールのメソッドとして定義されていない）。
- 特定ファイル/ディレクトリを個別に除外する設定は導入していない。実測では finding が
  `src/data/`（FRED/e-Stat クライアントが動的な JSON 応答を `Union` 型で扱う経路。union-split
  由来の `MethodErrorReport` が集中する）に偏る傾向を確認したが、これを対象から外して
  不可視化するのではなく、severity を advisory 扱いに留めることで対応する（下記「severity」節、
  ADR 0009/0012 等の「事実の保持と評価の分離」の踏襲）。

対象範囲の決定根拠の詳細（実測値・severity mapping 表を含む Julia 側コメント）は
[`src/quality/quality_capture.jl`](../../src/quality/quality_capture.jl) 冒頭の
「JET.jl（Issue #211）」節を参照。

### `result` フィールド

| フィールド | 型 | 内容 |
|---|---|---|
| `error_count` | integer | `findings` の件数（`length(findings)` から自動導出、矛盾した入力を構造的に排除） |
| `findings` | `Vector<finding>` | 検出した finding の一覧（0件でもよい。下記参照） |
| `target_modules` | `Vector<string>` | 報告対象に限定したモジュール名（現状 `["DME"]` のみ） |
| `analysis_mode` | string | 解析方式。現状 `"report_package"` のみ許可 |
| `config` | object | `{"ignore_missing_comparison": bool, "ignore_throws": bool}`（JET.jl へ渡した解析設定の provenance。両方とも JET.jl の既定値 `true` をそのまま使う） |

finding 1件の構造（`QualityJetFinding`、`src/quality/quality_capture.jl`）:

| フィールド | 型 | 内容 |
|---|---|---|
| `id` | string | `sha1("report_type|file|line|message")` の先頭12桁hex。同一箇所への複数finding（重複4-tuple）は `-2`・`-3`... を付与し一意にする（`quality_jet_stable_finding_ids`） |
| `report_type` | string | JET.jl の report 型名（モジュール修飾子なし。例: `"MethodErrorReport"`） |
| `message` | string | JET.jl が生成する診断メッセージ（`redact_secrets` を自動適用） |
| `severity` | string | `"error"`/`"warning"`/`"unrated"`（下記） |
| `file` | `string \| null` | `src/` からの相対パス。取得できない場合は `null`（contract §4「file/lineなしreportもvalid exportになる」） |
| `line` | `integer \| null` | 1始まりの行番号。取得できない場合は `null` |

`error_count=0`（`findings=[]`）は「実行して0件だった」という成功測定であり、`status=:skipped`
（未実行）とは構造的に異なる（§4 の状態区別と同じ考え方）。

### severity（advisory、CI gate には使わない）

Issue #211 の設計ノート「JET error countの閾値は実データ収集前に固定しない。初期はunratedまたは
advisoryとして扱う」に従い、`severity` は既知の JET.jl report 型への分類ラベルに留め、合否判定・
閾値判定には使わない（`software-quality-dashboard` 側でも同様に扱うことを想定）。

| severity | 対応する report 型（例） | 意味 |
|---|---|---|
| `error` | `MethodErrorReport`・`UndefVarErrorReport`・`UndefKeywordErrorReport`・`DivideErrorReport`・`InvalidInvokeErrorReport`・`NonBooleanCondErrorReport`・`BuiltinErrorReport`・`GeneratorErrorReport` | 実行時に確実にエラーとなる呼び出し形状 |
| `warning` | `UncaughtExceptionReport`・`SeriousExceptionReport`・`UnanalyzedCallErrorReport` | `throw`/`error` 呼び出しに由来（意図的な interface 未実装・validation である可能性がある。`report_package` の既定 `ignore_throws=true` により通常は抑制される） |
| `unrated` | 上記以外（将来 JET.jl が追加する未知の report 型を含む） | 分類なし。未知の型を誤って error/warning に丸めない既定値 |

mapping 本体は `QUALITY_JET_SEVERITY_MAP`（`src/quality/quality_capture.jl`）。JET.jl 自体が
report 型を追加・改名した場合、mapping に無い型は自動的に `unrated` になる（構築時に例外には
ならない）。

### baseline suppression は導入しない

Issue #211 の実施内容は「baseline suppressionを導入する場合、既知問題を不可視化せずbaseline
fileと差分を追跡する」という条件付き要求だが、本 Issue では baseline suppression 自体を
導入しない（全 finding をそのまま `findings` へ含める）。将来必要になった場合は、既存
finding をどう不可視化せずに追跡するかを含めて別 Issue で設計する。

```json
"JET.jl": {
  "status": "success",
  "version": "0.12.1",
  "started_at": "2026-08-11T08:00:00Z", "completed_at": "2026-08-11T08:00:40Z",
  "duration_seconds": 40.0,
  "result": {
    "error_count": 113,
    "findings": [
      {
        "id": "c69d09facbde",
        "report_type": "MethodErrorReport",
        "message": "no matching method found `parse(::Type{Int64}, ::Nothing)` (1/2 union split)",
        "severity": "error",
        "file": "src/data/preprocess.jl",
        "line": 410
      }
    ],
    "target_modules": ["DME"],
    "analysis_mode": "report_package",
    "config": { "ignore_missing_comparison": true, "ignore_throws": true }
  }
}
```

`status=:timeout`（worker subprocess が期限内に終了しなかった）・`status=:failure`
（worker が異常終了した、または出力の解析に失敗した）になるケースの詳細は §8 方法D。

## 4.4 BenchmarkTools.jl の result

Issue #212。代表的な計算経路の実行時間を [BenchmarkTools.jl](https://github.com/JuliaCI/BenchmarkTools.jl)
で測定し、repository 内 baseline との比較結果を構造化する。JET.jl（§4.3）と同じく
**slow lane 専用**（schedule/workflow_dispatch のみ）で、JET.jl とも独立した job・独立した
export ファイル・独立した Artifact として運用する（§8 方法E・§8.3）。

### 対象の選定

「入力規模・乱数 seed・solver 条件・外部 I/O の有無を固定できる」ものだけを選び、
Issue #212 の候補すべてを必須にはしていない。初期 suite は6件:

| `id` | `group` | 内容 | median（参考実測） |
|---|---|---|---|
| `solow_transition_path` | `model_simulate` | Solow の収束経路 T=200 | 12 µs |
| `rbc_impulse_response` | `model_simulate` | RBC の技術ショック IRF | 80 µs |
| `sfc_sim_simulate` | `model_core` | SIM 型 SFC の baseline シミュレーション T=200 | 3.5 µs |
| `keen_simulate_rk4` | `model_core` | Keen の固定刻み RK4 T=300（年） | 0.84 ms |
| `capex_credit_cycle_run` | `scenario_run` | 部門別CAPEX・信用循環モデル Sc3（期内10ステップ） | 4.4 ms |
| `real_rate_artifact_export` | `artifact_export` | real-rate model artifact の構築 + 正準 JSON | 0.35 ms |

参考実測は 2026-08 時点・ローカル Apple Silicon（`local|darwin|aarch64|julia1.12`）の値であり、
CI runner の値ではない（絶対値は環境で変わる。だからこそ baseline は環境ごとに持つ — 下記）。

**除外した候補と理由**（Issue #212「network/API依存処理を対象から除外またはstub化する」）:

| 除外対象 | 理由 |
|---|---|
| Ramsey モデル | 内部で NLsolve・Ipopt（外部ソルバー）を呼ぶ。実行時間がソルバー内部のヒューリスティクス・BLAS スレッド数・Ipopt のビルド差に依存し、DME 側のコード変更への感度より環境差の方が大きい |
| データ層（FRED/e-Stat） | ネットワーク I/O。fixture モードでもファイル読み込みが支配的になり、測定対象が DME の計算ではなくディスク/OS キャッシュになる |
| LLM 層 | 外部 API。MockProvider でも測っているのは mock 自身 |
| 可視化（Plots/GR） | バックエンド初期化・フォント解決が支配的で環境依存が大きい |
| model comparison / cross-model reasoning | 上記モデル実行の薄いラッパーであり、現状は独立した性能特性を持たない |

suite 定義の正本は [`scripts/benchmark_suite.jl`](../../scripts/benchmark_suite.jl)
（`dme_benchmark_cases()`）。

### compile time と steady-state runtime の分離

Issue #212「compile timeとsteady-state runtimeを混同しない」への対応:

- モデル・初期値の構築（setup）は計測対象クロージャの**外**で1回だけ行う。
- 計測前に workload を `warmup_evals`（既定3）回呼んで JIT コンパイルを済ませ、さらに
  `BenchmarkTools.warmup` を呼ぶ（`@benchmarkable` + `run` を手動で組む場合、`run` は
  warmup を自動では行わない — `@benchmark` マクロだけが内部で呼ぶ）。
- `tune!` は呼ばず `evals = 1` に固定する（`tune!` が選ぶ evals は実行時の負荷状況に依存し、
  実行ごとに変わると median の意味が変わるため）。固定値は `config.evals_per_sample` として
  export に残る。
- 代表値は median（mean は外れ値に、minimum は「最良ケース」に寄りすぎる）。
- CI では `Pkg.instantiate()` 後に `using DME` を1回実行し、precompile キャッシュを
  benchmark 実行の前に確定させる（§8.3）。

### baseline の保存方式

**repository 内 versioned baseline（[`benchmarks/baseline.json`](../../benchmarks/baseline.json)）
のみを採用する。** Issue #212 が挙げるもう一方の候補「GitHub Artifact 上の直近 main baseline」
は導入しない。理由:

- Artifact からの取得は「どの run を直近 main とみなすか」の解決・ダウンロード・retention
  切れ時のフォールバックという運用が増え、baseline の由来がコードレビューに現れない。
- repository 内に置けば baseline の変更が PR 差分としてレビューされ、更新理由・対象コミットが
  git 履歴に残る（Issue #212「baseline更新を自動で常に受理せず、更新理由と対象commitを
  記録する」を、専用の仕組みではなく通常のレビュー経路で満たせる）。

baseline ファイルは**環境ごとの表**である（形式は
[`benchmarks/README.md`](../../benchmarks/README.md)）。更新は
[`scripts/update_benchmark_baseline.jl`](../../scripts/update_benchmark_baseline.jl) による
**手動操作のみ**で、`--reason` が空なら拒否する。CI はこのスクリプトを呼ばない。

### environment_key（どの baseline と比較してよいか）

`environment_key = "<runner_label>|<os>|<arch>|julia<major>.<minor>"`。
一致するキーの baseline とだけ比較し、それ以外は比較しない（`baseline_environment_mismatch`）。

- `runner_label`: `DME_BENCHMARK_RUNNER_LABEL` > GitHub Actions なら
  `github-<RUNNER_OS>-<RUNNER_ARCH>` > `local`。
- Julia の patch は key に含めない（patch 更新で baseline を捨てない）。マイナーは含める
  （最適化・インライン化方針が変わりうるため別環境として扱う）。
- **CPU モデル・スレッド数・`manifest_digest` は key に含めない**。GitHub Actions の runner は
  同一ラベルでも CPU モデルが変動するため、key に含めると比較が恒常的に unavailable になり
  回帰検出が成立しない。これらは `environment` の付随情報として保持する（Issue #212
  「runner差・Julia version差・dependency更新差をprovenanceへ保持する」）。

### margin の根拠

`margin_percent` は benchmark ごとに設定できる（Issue #212「回帰判定marginをbenchmarkごとに
設定可能にする」）。同一コミット・同一環境（ローカル、他の負荷なし）で suite を**4回連続実行**
したときの median の最大乖離を実測し、それより広い値を採った:

| `id` | median | 実測乖離（4回） | `margin_percent` |
|---|---|---|---|
| `capex_credit_cycle_run` | 4.4 ms | 5.4% | 25% |
| `keen_simulate_rk4` | 0.84 ms | 4.5% | 25% |
| `real_rate_artifact_export` | 0.35 ms | 16.2% | 30% |
| `rbc_impulse_response` | 80 µs | 36.2% | 40% |
| `solow_transition_path` | 12 µs | 8.3% | 50% |
| `sfc_sim_simulate` | 3.5 µs | 34.3% | 50% |

100µs 未満の case は実測乖離よりさらに広く取っている（共有 vCPU の CI runner はローカルより
変動が大きいという前提。狭い threshold で不安定な `regressed` を出すより、大きな回帰だけを
拾う方を優先する — Issue #212「CIのノイズを考慮し、過度に狭いthresholdを設定しない」）。
**裏返しとして、軽い case が検出できるのは 40–50% 以上の回帰だけである。**

なお同じマシンでも**他プロセスが動いている状態**では suite 全体が 1.3〜2 倍遅くなることを
実測で確認している。margin を超えた `regressed` は「回帰の疑いがあるので人が見る」という
signal であり、それ自体が回帰の証明ではない（下記「advisory」）。

### `result` フィールド

| フィールド | 型 | 内容 |
|---|---|---|
| `benchmark_count` | integer | `benchmarks` の件数 |
| `benchmarks` | `Vector<benchmark>` | 個別結果（下表）。**headline へ集約せず必ず全件保持する** |
| `regression_summary` | object | `{"improved": n, "stable": n, "regressed": n, "unavailable": n}` |
| `headline` | object | 共通 headline 用の代表値 `{"benchmark_id", "median_time_ms", "regression_status"}`。現状は `capex_credit_cycle_run`（suite 中で最も重く、DME 固有の計算量を最もよく代表する） |
| `baseline` | object | `{"available", "source", "path", "environment_key", "commit", "recorded_at", "reason"}`。`available=false` のとき後半4項目は `null` |
| `environment` | object | `key`/`runner_label`/`os`/`arch`/`julia_version`（必須）＋ `cpu_model`/`cpu_threads`/`julia_threads`/`manifest_digest` |
| `config` | object | 測定条件の provenance（`seconds_per_benchmark`・`samples_max`・`evals_per_sample`・`warmup_evals`・`seed`・`estimator`・`tuned`・`headline_id`） |

benchmark 1件の構造（`QualityBenchmarkResult`、`src/quality/quality_capture.jl`）:

| フィールド | 型 | 内容 |
|---|---|---|
| `id` | string | benchmark 識別子（suite 内で一意。baseline の突き合わせキー） |
| `group` | string | 分類（`model_simulate`/`model_core`/`scenario_run`/`artifact_export`） |
| `description` | string | 人間向けの説明 |
| `median_time_ns` | integer | median 実行時間（ns、`evals` で割り済み）。`<= 0` は測定不能として構築時に拒否する |
| `memory_bytes` | integer | 1評価あたりの割り当てバイト数 |
| `allocs` | integer | 1評価あたりの割り当て回数 |
| `samples` | integer | 採取したサンプル数 |
| `evals_per_sample` | integer | 1サンプルあたりの評価回数（現状すべて1） |
| `margin_percent` | number | この benchmark の回帰判定の許容幅（%） |
| `baseline_median_time_ns` | `integer \| null` | 比較した baseline の median（比較しなかった場合 `null`） |
| `delta_percent` | `number \| null` | `(median - baseline) / baseline * 100`（小数第4位で丸め）。比較しなかった場合 `null` |
| `regression_status` | string | `"improved"`/`"stable"`/`"regressed"`/`"unavailable"` |
| `unavailable_reason` | `string \| null` | `unavailable` のときのみ非 `null`（下表） |

`regression_status` の判定:

| 条件 | status |
|---|---|
| `delta_percent > margin_percent` | `regressed` |
| `delta_percent < -margin_percent` | `improved` |
| `-margin_percent <= delta_percent <= margin_percent` | `stable` |
| baseline と比較しなかった | `unavailable` |

`unavailable_reason` の3値（Issue #212「baseline不存在時はpassにせずcomparison unavailable
として扱う」— どれも「回帰が無かった」を意味しない。`stable` とは構造的に別物である）:

| 値 | 意味 |
|---|---|
| `baseline_missing` | baseline ファイルが無い・壊れている・環境エントリが1件も無い（初期状態） |
| `baseline_environment_mismatch` | 他環境の baseline はあるが、現在の `environment_key` のエントリが無い |
| `baseline_benchmark_missing` | 環境一致の baseline はあるが、この benchmark id が未収録（新規追加した benchmark） |

矛盾した入力は構築時に拒否する（既存の `result` 組み立て関数と同じ方針）: baseline があるのに
`unavailable_reason` を渡す／baseline が無いのに `unavailable_reason` を省く／
`baseline.environment_key` が `environment.key` と違う／`headline_id` が `benchmarks` に無い、
はいずれも `ArgumentError`。

### advisory（CI gate には使わない）

`regression_status` は事実の記録であり、合否判定には使わない（Issue #212「性能回帰をコード
品質failと即時同一視せず、初期はadvisory/unratedで運用する」）。
`scripts/quality_export_benchmark.jl` の終了コードは `regressed` の有無に依存せず、
slow lane workflow も回帰では失敗しない。`software-quality-dashboard` 側でも同様に扱うことを
想定する。

```json
"BenchmarkTools.jl": {
  "status": "success",
  "version": "1.8.0",
  "started_at": "2026-08-11T07:20:00Z", "completed_at": "2026-08-11T07:20:37Z",
  "duration_seconds": 37.0,
  "result": {
    "benchmark_count": 6,
    "benchmarks": [
      {
        "id": "capex_credit_cycle_run",
        "group": "scenario_run",
        "description": "部門別CAPEX・信用循環モデルのシナリオ Sc3 実行（期内10ステップ）",
        "median_time_ns": 4384200,
        "memory_bytes": 2094400,
        "allocs": 12043,
        "samples": 1083,
        "evals_per_sample": 1,
        "margin_percent": 25.0,
        "baseline_median_time_ns": 4300000,
        "delta_percent": 1.9581,
        "regression_status": "stable",
        "unavailable_reason": null
      }
    ],
    "regression_summary": { "improved": 0, "stable": 6, "regressed": 0, "unavailable": 0 },
    "headline": {
      "benchmark_id": "capex_credit_cycle_run",
      "median_time_ms": 4.3842,
      "regression_status": "stable"
    },
    "baseline": {
      "available": true,
      "source": "repository",
      "path": "benchmarks/baseline.json",
      "environment_key": "github-linux-x64|linux|x86_64|julia1.12",
      "commit": "c4e9ea583934ad52f7e01d855be3ff02b0f4eeac",
      "recorded_at": "2026-08-11T07:21:51Z",
      "reason": "Issue #212 初回 baseline 収集"
    },
    "environment": {
      "key": "github-linux-x64|linux|x86_64|julia1.12",
      "runner_label": "github-linux-x64",
      "os": "linux", "arch": "x86_64", "julia_version": "1.12.6",
      "cpu_model": "AMD EPYC 7763", "cpu_threads": 4, "julia_threads": 1,
      "manifest_digest": "0123456789ab"
    },
    "config": {
      "seconds_per_benchmark": 5.0, "samples_max": 10000, "evals_per_sample": 1,
      "warmup_evals": 3, "seed": 20260812, "estimator": "median", "tuned": false,
      "headline_id": "capex_credit_cycle_run"
    }
  }
}
```

`status=:timeout`（worker subprocess が期限内に終了しなかった）・`status=:failure`
（worker が異常終了した、または出力の解析に失敗した）になるケースの詳細は §8 方法E。
benchmark 自体の失敗・timeout を「遅い結果」として `median_time_ns` に反映することはしない
（Issue #212「benchmark自体の失敗/timeoutを遅い結果として扱わない」）。

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

# JET.jl（Issue #211。JET.jl の型そのものは src/ から参照しない — scripts/jet_report_extract.jl が
# JET.get_reports の戻り値から QualityJetFinding を組み立てる。§4.3）
QUALITY_JET_SEVERITIES        # = ("error", "warning", "unrated")
QUALITY_JET_SEVERITY_MAP      # 短縮report型名 => severity
QUALITY_JET_ANALYSIS_MODES    # = ("report_package",)
quality_jet_finding_severity(report_type::AbstractString) -> String   # マップに無い型は "unrated"
QualityJetFinding(; id, report_type, message, severity=quality_jet_finding_severity(report_type), file=nothing, line=nothing)
quality_jet_stable_finding_ids(entries::AbstractVector{<:Tuple}) -> Vector{String}  # (report_type,file,line,message) から安定id生成
quality_tool_jet_result(; findings, target_modules, analysis_mode="report_package", ignore_missing_comparison=true, ignore_throws=true) -> Dict{String,Any}

# BenchmarkTools.jl（Issue #212。BenchmarkTools.jl の型そのものは src/ から参照しない —
# scripts/benchmark_suite.jl が Trial から測定値を取り出す。§4.4）
QUALITY_BENCHMARK_REGRESSION_STATUSES     # = ("improved", "stable", "regressed", "unavailable")
QUALITY_BENCHMARK_UNAVAILABLE_REASONS     # = ("baseline_missing", "baseline_environment_mismatch", "baseline_benchmark_missing")
QUALITY_BENCHMARK_DEFAULT_MARGIN_PERCENT  # = 25.0
QUALITY_BENCHMARK_BASELINE_SOURCES        # = ("repository",)
quality_benchmark_environment_key(; runner_label, os, arch, julia_version) -> String
quality_benchmark_delta_percent(median_time_ns, baseline_median_time_ns) -> Float64
quality_benchmark_regression_status(delta_percent, margin_percent) -> String
QualityBenchmarkResult(; id, group, description, median_time_ns, memory_bytes, allocs, samples, evals_per_sample,
                          margin_percent=QUALITY_BENCHMARK_DEFAULT_MARGIN_PERCENT,
                          baseline_median_time_ns=nothing, unavailable_reason="baseline_missing")
QualityBenchmarkBaselineRef(; available, source="repository", path, environment_key=nothing, commit=nothing, recorded_at=nothing, reason=nothing)
quality_tool_benchmark_result(; results, environment, baseline, config, headline_id) -> Dict{String,Any}
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
方法Aと同じ `skipped` プレースホルダのまま（JET.jl は方法B/Cに統合しない — 下記「方法D」参照）。
`DME_QUALITY_EXPORT_ENABLED` 未設定時（既定）は `test/runtests.jl` の挙動を一切変えない
（この経路自体が有効化されない）。

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

**方法D: JET.jl slow lane（`scripts/quality_export_jet.jl`。Issue #211、方法B/Cとは独立）**

```bash
julia --project=. scripts/quality_export_jet.jl
# 出力先の指定（優先順）: DME_QUALITY_EXPORT_OUTPUT > 既定 artifacts/quality/quality-export-jet.json
#   （方法B/Cが書く artifacts/quality/quality-export.json とは別ファイル）
# timeout秒数: DME_QUALITY_EXPORT_JET_TIMEOUT_SECONDS（既定 1800 = 30分）
```

方法B/Cとはマージしない**独立した自己完結型 export**を生成する: `JET.jl` のみ実測し、他6予約
ツールは「fast lane の export で測定される」という reason 付きの `skipped` プレースホルダで
埋める。CI の slow lane（[`.github/workflows/quality-slow.yml`](../../.github/workflows/quality-slow.yml)、
schedule/workflow_dispatch）がこの方法Dを使う（§8.2）。

**2プロセス構成（driver + worker）**: `scripts/quality_export_jet.jl`（driver、`--project=.`のまま
実行）は `scripts/jet_analysis_worker.jl`（worker）を subprocess として起動し、
`DME_QUALITY_EXPORT_JET_TIMEOUT_SECONDS`（既定30分）を期限として `process_running`/`sleep` で
poll する。期限超過時は `kill`（SIGTERM、猶予後 SIGKILL）して `status=:timeout` として報告する。
worker 自身は `--project=.`（DME 本体の依存: JuMP/Ipopt/Plots 等）で起動した後、
`Pkg.activate("test/")` へ切り替えて `using JET`（`scripts/quality_export_coverage.jl` と同じ
「先に `using DME` を済ませてから test 環境の依存を using する」トリック）し、
`JET.report_package(DME; target_modules=(DME,))` を実行して結果を一時ファイルへ書き出す
（§4.3「対象範囲の決定」）。

**なぜ2プロセスに分けるか**: JET.jl の解析自体は実測で約30〜90秒と短いが（2026-08時点、
`ubuntu-latest` 相当の実測ではなくローカル Apple Silicon 実測値。CI 実測値は今後の
workflow 実行履歴で継続的に確認する）、timeout/crash を明示的な `status` として区別できる
契約上の要件（Issue #211「0件成功、複数finding、timeout、crash、未導入を区別できる」）を
満たすには、実行中の CPU-bound な型推論処理を安全に打ち切る手段が要る。Julia には同一プロセス
内から安全に割り込む標準的な方法が無いため、OS プロセスレベルの kill に頼る（driver が
worker を subprocess として管理する）。詳細な設計判断は `scripts/jet_analysis_worker.jl`
冒頭コメント参照。

**status の対応**:

| worker の状態 | `JET.jl` の `status` |
|---|---|
| 期限内に正常終了し、`error_count`（0件を含む）を含む結果を書き出した | `success` |
| `DME_QUALITY_EXPORT_JET_TIMEOUT_SECONDS` を超過し kill された | `timeout` |
| 異常終了した（出力ファイル無し、または解析処理自体が例外を投げた） | `failure` |
| 出力ファイルが JSON として壊れている（解析不能） | `failure` |

**失敗の扱い**: 方法Dは `Pkg.test()` を呼ばない（テストスイート自体とは無関係）。JET.jl の
timeout/crash は `JET.jl` エントリの `status` に反映されるのみで、方法D自体の終了コードは
常に0（export の書き出し自体が失敗しない限り）— Issue #211「通常PR mergeを初期段階でblock
しない」「timeoutしても他のslow lane tool結果を失わない」という決定を、現状唯一の slow lane
ツールである JET.jl 単体の文脈で満たす（他ツールが増えた場合の扱いは #212/#213 の対象）。

**driver 自体のテスト方針**: `scripts/jet_analysis_worker.jl`/`scripts/quality_export_jet.jl`
自体（subprocess・timeout制御を含む driver 経路）は自動テストの対象にしない
（`scripts/quality_export_coverage.jl` 等の既存 driver スクリプトと同じ方針。
`test/test_quality_capture.jl` 冒頭コメント参照）。実行（手動/CI slow lane）で検証する
（本 Issue の作業中に success/timeout の両経路を実際に実行して確認済み — `error_count=113`
での成功、および人為的に短い timeout を与えた kill の双方）。一方、JET.jl オブジェクトから
`QualityJetFinding` を組み立てる純粋な抽出ロジック（`scripts/jet_report_extract.jl`）は
`test/test_quality_jet.jl`（opt-in、`DME_QUALITY_EXPORT_JET_ENABLED=1`）で自動テストする。

**方法E: BenchmarkTools.jl slow lane（`scripts/quality_export_benchmark.jl`。Issue #212、方法B/C/Dとは独立）**

```bash
julia --project=. scripts/quality_export_benchmark.jl
# 出力先の指定（優先順）: DME_QUALITY_EXPORT_OUTPUT > 既定 artifacts/quality/quality-export-benchmark.json
#   （方法B/Cの quality-export.json・方法Dの quality-export-jet.json とは別ファイル）
# timeout秒数: DME_QUALITY_EXPORT_BENCHMARK_TIMEOUT_SECONDS（既定 1800 = 30分）
# baselineパス: DME_BENCHMARK_BASELINE_PATH（既定 benchmarks/baseline.json）
# runner識別子: DME_BENCHMARK_RUNNER_LABEL（既定は自動検出。§4.4 environment_key）
```

他の方法とはマージしない**独立した自己完結型 export** を生成する: `BenchmarkTools.jl` のみ
実測し、他6予約ツールは「どの経路が実測するか（`Documenter.jl` はまだどこにも接続されて
いないこと）」を reason に書いた `skipped` プレースホルダで埋める。CI の slow lane
（[`.github/workflows/quality-slow.yml`](../../.github/workflows/quality-slow.yml) の
`benchmark` job）がこの方法Eを使う（§8.3）。

**2プロセス構成（driver + worker）**: 方法Dと同じく `scripts/quality_export_benchmark.jl`
（driver）が `scripts/benchmark_worker.jl`（worker）を subprocess として起動し、
`DME_QUALITY_EXPORT_BENCHMARK_TIMEOUT_SECONDS` を期限として poll する（期限超過時は
SIGTERM → 猶予後 SIGKILL、`status=:timeout`）。benchmark 特有の理由として、driver 側で
既に走らせた処理（baseline の読み込み・JSON パース）が残したヒープ状態・GC 圧を測定へ
持ち込まない、という目的もある。

**環境の組み合わせ方が方法Dと異なる**: worker は `--project=.`（root）を active にしたまま
`push!(LOAD_PATH, "test/")` で BenchmarkTools.jl だけを追加で可視にする（方法Dの
`Pkg.activate("test/")` とは別方式）。JuMP 経由で読み込まれる MathOptInterface が
BenchmarkTools.jl への weak dependency 拡張を持つため、active 環境を切り替えると拡張の
解決に失敗して毎回エラーログが出ること、および切り替え後に初めて読み込まれる共有依存が
test/ 側の manifest バージョンで解決されうることを避ける（詳細は
`scripts/benchmark_worker.jl` 冒頭コメント）。

**status の対応**:

| worker の状態 | `BenchmarkTools.jl` の `status` |
|---|---|
| 期限内に正常終了し、全 benchmark の測定値を書き出した | `success` |
| `DME_QUALITY_EXPORT_BENCHMARK_TIMEOUT_SECONDS` を超過し kill された | `timeout` |
| 異常終了した（出力ファイル無し、または測定処理自体が例外を投げた） | `failure` |
| 出力ファイルが JSON として壊れている／`result` の組み立てが契約違反で失敗した | `failure` |

baseline が無い・環境が違う・その benchmark だけ未収録、はいずれも `status=:success` の中の
`regression_status = "unavailable"` であり、`status` レベルの失敗ではない（測定自体は
成功しているため）。

**失敗の扱い**: 方法Eは `Pkg.test()` を呼ばない。timeout/crash は `BenchmarkTools.jl`
エントリの `status` に反映されるのみで、方法E自体の終了コードは常に0（export の書き出し
自体が失敗しない限り）。回帰（`regressed`）も終了コードに影響しない（§4.4「advisory」）。

**baseline の更新**（`scripts/update_benchmark_baseline.jl`。手動専用）:

```bash
# 1. 差分の確認だけ（書き込みなし）
julia --project=. scripts/update_benchmark_baseline.jl artifacts/quality/quality-export-benchmark.json --dry-run
# 2. 理由を付けて書き込む（--reason が空なら拒否される）
julia --project=. scripts/update_benchmark_baseline.jl artifacts/quality/quality-export-benchmark.json \
    --reason "Issue #212 初回 baseline 収集（ubuntu-latest / Julia 1.12）"
```

`status != success` の export を baseline にはできない（拒否する）。書き込まれるのは
`environment.key` に対応するエントリのみで、`commit`・`recorded_at`（＝export の
`measured_at`）・`reason` が併せて記録される。CI はこのスクリプトを呼ばない。

**driver 自体のテスト方針**: `scripts/benchmark_worker.jl`/`scripts/quality_export_benchmark.jl`
自体（subprocess・timeout制御・baseline 突き合わせを含む driver 経路）は自動テストの対象に
しない（方法C/Dと同じ方針）。実行（手動/CI slow lane）で検証する（本 Issue の作業中に
success（baseline なし／あり）・`stable`/`regressed` の判定・timeout の3経路を実際に実行して
確認済み）。一方、suite 定義と1 case の実測ロジック（`scripts/benchmark_suite.jl`）は
`test/test_quality_benchmark.jl`（opt-in、`DME_QUALITY_EXPORT_BENCHMARK_ENABLED=1`）で
自動テストし、`result` の組み立て（純粋関数）は `test/test_quality_capture.jl` で
4つの `regression_status` すべてを含めて検証する。

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
込み）は変わらない。`actions/upload-artifact@v7` の `overwrite: true` により、rerun の結果で
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

**action 参照の固定方針**: `actions/checkout@v7`・`julia-actions/setup-julia@v3`・
`julia-actions/cache@v3`・`actions/upload-artifact@v7` はいずれもメジャーバージョンタグで
固定する（SHA pin へは変更しない）。DME の既存 workflow（`claude.yml`・`claude-code-review.yml`
含む）がすべて同じメジャーバージョンタグ方式であり、本 Issue 単体で異なる固定方式を混在させない
ことを優先した（SHA pin へ統一する場合はリポジトリ全体を対象にした別 Issue で扱う）。
`actions/checkout`・`actions/upload-artifact`・`julia-actions/setup-julia` はいずれも
Node.js 20 ランタイムの deprecation（旧バージョンは Node20 固定のため実行時に Node24 へ
強制フォールバックする旨の警告が CI ログに出る）を解消するため、後日 Node24 ネイティブ対応の
メジャーバージョン（`actions/checkout@v7`・`actions/upload-artifact@v7`・
`julia-actions/setup-julia@v3`）へ更新した。`julia-actions/setup-julia` の v2→v3 は
`version: min`/`min-minor`/`min-patch` の解決結果変更と Apple Silicon macOS 上での
`x86_64` バイナリ要求時の挙動（警告→エラー）が breaking change だが、本 workflow は
`version: '1.12.6'`（厳密指定）かつ `runs-on: ubuntu-latest` のため非該当。
`claude.yml`/`claude-code-review.yml` は本更新の対象外（別途の更新が必要であれば別 Issue/PR で扱う）。

## 8.2 JET.jl slow lane の GitHub Actions Artifact 公開（Issue #211）

[`.github/workflows/quality-slow.yml`](../../.github/workflows/quality-slow.yml) は §8.1 の
fast lane 実装をそのまま踏襲するが、以下の点が異なる:

- **トリガー**: `schedule`（nightly、毎日 UTC 18:30 = JST 03:30）と `workflow_dispatch`
  のみ。`push`/`pull_request` には組み込まない（通常CIの所要時間へ影響しない）。
- **実行頻度の決定根拠**: JET.jl 解析自体は実測で数十秒〜2分程度と短く（§4.3・上記「方法D」）、
  nightly でもコストは小さいと判断した。当面は固定頻度とし、実際の workflow 実行履歴
  （所要時間・timeout/crash の発生有無）を継続的に観察した上で、必要なら頻度を見直す
  （Issue #211「実行時間と安定性を複数回計測し、最終頻度を決定する」への当面の回答。
  §5.2 のような CI 実測ベースの継続観察は
  [品質チェックとローカル検証手順](../development/quality_checks.md) 側に追記する）。
- **Artifact名**: `dme-julia-quality-v1-jet-${{ github.sha }}`（valid）・
  `dme-julia-quality-v1-jet-invalid-${{ github.sha }}`（invalid/missing）。fast lane の
  Artifact名（`dme-julia-quality-v1-${{ github.sha }}`）とは `-jet-` の有無で構造的に区別する
  （Issue #211「slow lane Artifactを通常CI Artifactと識別可能にする」）。
  retention は fast lane と同じ（valid 90日・invalid 14日）。
- **依存環境の instantiate**: `Pkg.test()` は test 環境の instantiate を内部で自動的に行うが、
  方法Dはそれを経由しないため、workflow 側で `--project=.`・`--project=test` の両方を
  明示的に `Pkg.instantiate()` する。
- それ以外（`if: always()` による検証・valid/invalid の Artifact 名分離・`overwrite: true`
  による rerun 時の置換・`contents: read` のみの権限・action 参照のメジャーバージョン固定）は
  §8.1 と同じ方針。

## 8.3 BenchmarkTools.jl slow lane の GitHub Actions Artifact 公開（Issue #212）

[`.github/workflows/quality-slow.yml`](../../.github/workflows/quality-slow.yml) の
`benchmark` job は §8.2（JET slow lane）をそのまま踏襲するが、以下の点が異なる:

- **トリガー**: `schedule`（weekly、毎週日曜 UTC 19:30 = 月曜 JST 04:30）と
  `workflow_dispatch`。同一 workflow 内に nightly（JET）と weekly（benchmark）の2つの cron を
  置き、`github.event.schedule` を見る job 条件でどちらの job を動かすか分岐する
  （`on.schedule` は workflow 単位のトリガーであり、cron ごとに job を選ぶ仕組みが無いため）。
  `workflow_dispatch` では両方の job が動く。
- **実行頻度が nightly ではなく weekly である理由**: (a) 性能測定は静的解析と違って
  「毎日の差分」ではなくトレンドを見るもの、(b) baseline は手動更新であり日次の細かい変動を
  追う運用ではない、(c) CI runner のノイズ（§4.4 の margin）に対して日次の点は情報量が小さい
  （Issue #212「低頻度scheduleで実行する」）。
- **Artifact名**: `dme-julia-quality-v1-benchmark-${{ github.sha }}`（valid）・
  `dme-julia-quality-v1-benchmark-invalid-${{ github.sha }}`（invalid/missing）。
  fast lane（`dme-julia-quality-v1-…`）とも JET slow lane（`…-jet-…`）とも区別する。
  retention は同じ（valid 90日・invalid 14日）。
- **precompile の事前確定**: `Pkg.instantiate()` の後に `julia --project=. -e "using DME"` を
  1ステップ挟み、DME のロード・precompile を benchmark 実行の前に済ませる（§4.4
  「compile time と steady-state runtime の分離」）。
- それ以外（`if: always()` による検証・valid/invalid の Artifact 名分離・`overwrite: true`・
  `contents: read` のみの権限・action 参照のメジャーバージョン固定）は §8.1 と同じ方針。

**初回実行時の挙動**: `benchmarks/baseline.json` には初期状態で環境エントリが1件も無いため、
最初の slow lane 実行では全 benchmark が `regression_status = "unavailable"`
（`baseline_missing`）になる。これは設計どおりの挙動であり `pass` ではない（§4.4）。
CI 環境の baseline は、この実行の Artifact をダウンロードして
`scripts/update_benchmark_baseline.jl` を手動実行し、PR としてレビュー・マージすることで
確立する（§8 方法E）。

## 9. 限界

- 本 contract は「DME 側が何を測定したか」という事実のみを保持する。品質スコア・合否判定は
  `software-quality-dashboard` 側の責務であり、本 contract には存在しない（ADR 0009/0012 の
  「事実と評価の分離」を踏襲）。
- `result` の構造は `Pkg.test`/`Aqua.jl`/`JuliaFormatter.jl`/`Coverage.jl`/`JET.jl`/
  `BenchmarkTools.jl` の6ツールで確定した（§4.1・§4.2・§4.3・§4.4、Issue
  #208/#209/#211/#212）。残り1ツール（Documenter.jl）は対応 Issue（#213）が実装した時点で、
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
- JET.jl（§4.3）の `severity` は既知の report 型への advisory な分類であり、error countの
  閾値・合否判定には使わない。誤検知（false positive）を自動判定する仕組みは無く、初期実測で
  `src/data/`（動的 JSON 応答の union-split 由来）に finding が偏る傾向を確認しているが、対象
  そのものからは除外しない（§4.3「対象範囲の決定」）。全 finding の即時修正・JET.jl を PR 必須
  Quality Gate にすることは Issue #211 の対象外。
- JET.jl の baseline suppression（既知finding を不可視化せず追跡する差分機構）は導入していない
  （§4.3）。finding の `id` は同一コミット・同一 JET.jl バージョンでの解析順序に依存する
  best-effort な安定性であり、JET.jl バージョン更新をまたいだ永続的な finding 追跡には使えない
  （`quality_jet_stable_finding_ids` docstring）。
- JET.jl slow lane（§8 方法D・§8.2）の driver/worker 自体（subprocess 起動・timeout の kill
  制御）は自動テストの対象にせず、実行（手動/CI）で検証する方針を取る（既存の
  `scripts/quality_export_coverage.jl` と同じ方針）。timeout 判定の精度は poll 間隔
  （既定1秒）・SIGTERM後の猶予（既定10秒）に依存し、厳密な即時停止は保証しない。
  BenchmarkTools.jl slow lane（§8 方法E・§8.3）の driver/worker も同じ方針・同じ制約。
- BenchmarkTools.jl（§4.4）の `regression_status` は advisory であり、CI gate・PR 必須の
  performance gate には使わない（Issue #212 の「対象外」）。`regressed` は「人が見るべき
  signal」であって回帰の証明ではない — 共有 CI runner のノイズ、同一マシン上の他プロセスの
  負荷でも margin を超えうる（§4.4「margin の根拠」）。
- benchmark の対象は代表6経路のみで、全関数の microbenchmark・本番環境と同一性能の保証は
  対象外（Issue #212 の「対象外」）。100µs 未満の case は margin が広く、40–50% 未満の回帰は
  検出できない（§4.4）。
- benchmark の baseline は `environment_key` が一致する環境とだけ比較する（§4.4）。
  `runner_label` を明示しないローカル実行はすべて `local` に集約されるため、複数の異なる
  ローカルマシンで測った値を1つの baseline として混ぜてしまいうる（`DME_BENCHMARK_RUNNER_LABEL`
  でマシンを区別すること）。同一 `environment_key` の中では CPU モデルの違いは吸収されない
  （provenance として記録するだけ）。
- benchmark baseline の更新は手動であり、自動追随しない（§8 方法E）。baseline を更新しない
  限り、意図的な性能変更（アルゴリズム変更等）は `regressed`/`improved` として残り続ける。
  複数コミットにまたがる性能トレンドの保持は本 contract の範囲外（1ファイル=1コミットの
  1回の実行、§1）。
