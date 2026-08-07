# ADR 0016: Julia品質Export Contract v1（`julia-quality-export/v1`）

- **ステータス**: 採用
- **日付**: 2026-08-07
- **関連Issue**: [Yuki-Watanabe7/DME#207](https://github.com/Yuki-Watanabe7/DME/issues/207)
  （Parent Roadmap: [Yuki-Watanabe7/software-quality-dashboard#6](https://github.com/Yuki-Watanabe7/software-quality-dashboard/issues/6)）
- **関連ドキュメント**: [Julia品質Export Contract](../contract/julia-quality-export-v1.md)・
  [ADR 0008: Real-rate model artifact 統合契約](0008-real-rate-model-artifact-export.md)（逆方向の
  先行契約・実装 doctrine の踏襲元）

## コンテキスト

`software-quality-dashboard`（別リポジトリ）は SonarQube が解析できない DME（Julia）を
first-class の Julia Native Provider として扱う方針を採っている。Phase 0 では
`fixtures/providers/julia/*.json` に `julia-quality-export/v1` 相当の payload を模倣した
フィクスチャを置き、Provider 側の Report Mapper（`julia_native.py`）を実装済みだが、
producer である DME 側には正式な contract（JSON Schema・Exporter）が存在しなかった。

本 Issue の範囲は「後続 Issue が独自のツール固有判断を追加せず、同一形式へ結果を書き込める
envelope を確立する」ことに限定される（`Pkg.test`/`Aqua.jl`/`Coverage.jl`/`JET.jl`/
`BenchmarkTools.jl`/`Documenter.jl` の実測実行と `result` の構造化は #208/#209/#211/#212/#213 に
分割済み）。

DME は economic-data-provider ADR 006（[docs/contract/README.md](../contract/README.md)）で
「他リポジトリが所有する契約を DME が満たす」側を既に経験している（[ADR 0008](0008-real-rate-model-artifact-export.md)）。
本 Issue はその**逆方向**——DME が契約を所有し、他リポジトリ（software-quality-dashboard）が
満たす側——の初めてのケースである。

## 決定

1. schema を DME 側で新規に所有・定義する: `schemas/julia-quality-export-v1.schema.json`
   （JSON Schema 2020-12）。`docs/contract/` は econimic-data-provider 所有契約の vendor コピー
   専用ディレクトリのため、新規契約は `schemas/`（リポジトリルート直下、CLAUDE.md リポジトリ構成表に
   追記）に置く。
2. Julia 実装は新規モジュール `src/quality/quality_export.jl` に集約する。既存モデル層・LLM 層とは
   独立した CI/tooling メタデータであるため、`src/artifacts/`（経済モデルの再現可能 artifact）とは
   別ディレクトリとする。
3. `real_rate_model_artifact.jl` の doctrine をそのまま踏襲する: keyword constructor +
   `ArgumentError` バリデーション、DME は汎用 JSON Schema バリデータを持たず
   `quality_export_from_dict` 自体が validator を兼ねる、正準 JSON（RFC 8785 JCS、
   `canonical_json_bytes` を再利用）でシリアライズし、atomic write（`.tmp` + `fsync` + `mv`）で保存する。
4. `tools` は `Dict{String,QualityToolExecution}`（ツール名をキーとする open な辞書）とし、
   各ツール実行の `result` フィールド内部構造は本 Issue で確定しない（§「見送りとした選択肢」参照）。
5. タイムゾーンは real-rate model artifact と同じ MVP 制約で UTC 固定（`"...Z"` 接尾辞のみ）。
6. `status` は `success`/`failure`/`timeout`/`skipped`/`not_installed` の5値の閉じた enum とし、
   status ごとに必須/禁止フィールドを構造的に強制する（`0`・未計測・未導入・実行失敗の混同を防ぐ）。
7. Secret/環境変数/API credential の redaction を自由記述フィールドへの自動適用（redact）と
   構造化フィールドへの拒否（reject）の2層で実装する。
8. 保存は「1コミット1回の実行=1ファイル」を単位とし、real-rate model artifact のような
   permanent content-addressed store（上書き拒否）ではなく、CI 実行ごとに上書き可能な ephemeral
   artifact として扱う（既定 `overwrite=true`）。
9. Exporter骨格 `scripts/quality_export.jl` は7予約ツールすべてを `status=:skipped` の
   プレースホルダで埋めた export を生成する。実測実行は行わない。

## 1. `tools` を open な辞書とし `result` の構造を確定しない

Issue #207 の「実施内容」は envelope（トップレベルフィールド・ツール実行1件の共通構造）の
確立に限定され、「初期tool section」節は7ツール名を**予約するが実測実行まで必須としない**と
明記している。並行して roadmap 側は各ツールの構造化を個別 Issue（#208 Pkg.test/Aqua/Formatter、
#209 Coverage、#211 JET、#212 Benchmark、#213 Documenter）へ分割済みである。

ここで `result` のフィールド構造を本 Issue で先に固定してしまうと、後続 Issue の設計判断
（例: JET.jl の `reports` 配列の形、Coverage.jl の `covered_lines`/`coverable_lines` の単位）を
先取りすることになり、[ADR 0013](0013-capex-credit-cycle-integration-contract.md) が確立した
「統合の名目で経済的判断を新設しない」と同種の問題を tooling contract 側で再現する。そこで
`tools` は open な辞書（`propertyNames` パターンのみ制約）とし、`result` は
`canonical_json_bytes` がサポートする値域（JSON-safe な入れ子）であることのみを強制する。
7予約名は「この契約が想定する語彙」を文書として明示するに留め、スキーマ上の enum 制約にはしない
（新しいツール名の追加はマイナー扱い、`docs/provider-development.md` §10 の
「`metric_id` は閉じた集合ではない」という設計と同じ考え方）。

## 2. `status` ごとの必須/禁止フィールドによる強制

Issue の実施内容は「`0`、未計測、未導入、適用不能、実行失敗を混同しない」ことを明示的に要求する。
これを実現する方法は主に2つあった:

- (a) `result`/`error`/`reason` を任意フィールドとして許容し、呼び出し側の規律に委ねる。
- (b) `status` の値ごとに必須/禁止フィールドをコンストラクタが構造的に強制する。

(a) は `software-quality-dashboard` 側の `MetricFactory.absent` が「値なしの観測は `absent` 経由
以外で作れない」という設計で防いでいるのと同じ問題を、DME 側で再現してしまう
（コンストラクタが `result=nothing` かつ `status=success` を許せば、後続 Issue の実装ミスで
「測定していないのに空の成功」を書けてしまう）。(b) を採用し、`QualityToolExecution` の
キーワードコンストラクタが `success` → `result` 必須・`error` 禁止、`failure`/`timeout` →
`error` 必須・`result` 禁止、`skipped`/`not_installed` → `reason` 必須・`result`/`error` 禁止、を
強制する。JSON Schema 側も `allOf`/`if`/`then` で同じ制約を表現する（real-rate model artifact の
`status`/`value`/`validity_reasons` 相関条件と同じパターン）。

`duration_seconds` は呼び出し側が渡す入力ではなく `completed_at - started_at` からコンストラクタが
自動導出する。「渡された `duration_seconds` と実際の時刻差が矛盾する」というクラスの不整合を
構造的に排除するため（[ADR 0008 §2](0008-real-rate-model-artifact-export.md) の
「hash フィールドを自己参照排除する」設計と同種の判断）。

## 3. Secret/redaction: 自由記述は redact、構造化データは reject

Issue の実施内容は「Secret/環境変数/外部API credentialを出力しないredaction方針を定義する」と
「Secretらしきfixture値を出力しないことを確認する」テストを要求する。DME が実際に使う秘匿環境変数
（[設定・環境変数管理ガイド](../development/configuration.md)）は `FRED_API_KEY`・`ESTAT_APP_ID`・
`OPENAI_API_KEY`、加えて CI 環境の `GITHUB_TOKEN`。

`error.message`/`reason` のような自由記述フィールドは、既知のトークン形状・`key=`/`token=` 等の
代入パターン・上記環境変数名を検出して `"[REDACTED]"` に置換する（`redact_secrets`、
`QualityToolError`/`QualityToolExecution` のコンストラクタが自動適用）。一方 `result` は
ツール固有の構造化データであり、文字列を黙って置換すると JSON の意味が壊れる可能性がある
（数値のつもりが文字列に化ける、キーの内容が変わる等）ため、redact ではなく **reject**
（秘匿情報らしき文字列が1箇所でもあれば `ArgumentError` で構築自体を失敗させる）を選んだ。

この redaction はパターンベースのベストエフォートであり、機密情報漏洩の構造的な防止を保証しない。
一次防御は #208 等のツール実装側（生ログを `result`/`error.message` へ丸ごと転記しない）に委ねる。
この限界は contract doc §5 に明記する。

## 4. UTC 固定・正準 JSON・atomic write は real-rate model artifact の doctrine を再利用する

[ADR 0008](0008-real-rate-model-artifact-export.md) が確立した以下の decision をそのまま流用する
（新規に再設計しない）:

- タイムゾーン: `Dates.DateTime`（naive）+ `"...Z"` 接尾辞固定。`TimeZones.jl` は導入しない。
- 正準化: `src/artifacts/json_canonical.jl` の `canonical_json_bytes`/`canonical_json_string` を
  そのまま呼び出す（RFC 8785 JCS の限定実装を再実装しない）。
- 保存: `.tmp` へ書いて `fsync` した後 `mv`（atomic rename）。
- schema バリデーション: 汎用 JSON Schema バリデータを導入せず、Julia 側の型・バリデーション
  ロジックを schema と構造が一致するよう手動で保守する（`docs/contract/README.md` と同じ
  「見送りとした選択肢」を再確認し、今回も踏襲する）。

再利用しない・意図的に変えた点は「同名ファイルへの上書きを許可する」（§5）と「hash
自己参照フィールドを持たない」（§6）の2点のみ。

## 5. 上書き可能な ephemeral artifact（real-rate model artifact との違い）

real-rate model artifact は economic-data-provider が読む cross-repository の
permanent content-addressed store であり、同名ファイルへの上書きを拒否する
（`artifact_id`（内容の hash）がファイル名に含まれるため、同じ内容なら同じパスに書ける設計）。

Julia品質Export は用途が異なる: GitHub Actions が CI 実行ごとに生成し、`if: always()` で
Artifact としてアップロードする想定（#210 の対象）。1回の CI 実行では出力パスは固定
（例: `artifacts/quality/quality-export.json`）であり、同一パスへの複数回書き込み
（ローカルでの再実行・リトライ）を許すほうが自然な運用になる。そこで
`save_quality_export` は既定で上書きを許可する（`overwrite=false` で real-rate 同様の拒否も選べる）。

## 6. hash 自己参照フィールドを持たない

real-rate model artifact は `artifact_id`/`parameter_hash`/`calibration_hash`/`snapshot_hash` を
自己参照排除の設計で持つ（[ADR 0008 §2](0008-real-rate-model-artifact-export.md)）。これは
economic-data-provider 側の契約（ADR 006 §4.1）が「内容の改ざん検出」を要求するため。

Julia品質Export v1 の契約（Issue #207 の実施内容）は identity hash を要求していない。CI Artifact
としての改ざん検出は GitHub Actions 自体のアップロード/ダウンロード完全性に委ね、契約としては
持たない。将来 replay/audit 用途で必要になった場合は、`macro_event_runtime` 層の
`event_set_hash`（[ADR 0015](0015-macro-event-runtime-contract.md)）と同種の設計を別途検討する。

## 見送りとした選択肢

- **`result` の構造をこの Issue で先に固定する**: 後続 Issue（#208 等）の設計判断を先取りする
  ことになり不採用（§1）。
- **`tools` を7予約名の閉じた enum にする**: 将来ツール追加のたびにメジャーバージョンアップが
  必要になり、`software-quality-dashboard` 側の「`metric_id` は閉じた集合ではない」という設計
  思想と整合しない（§1）。
- **`status` に `not_applicable` を追加する（6値目）**: Issue #207 の実施内容が明示する enum は
  5値（`success`/`failure`/`timeout`/`skipped`/`not_installed`）であり、
  `software-quality-dashboard` 側の `ToolExecutionStatus` enum とも1:1で対応する。「適用不能」は
  契約上の実行 status ではなく、「このツールがそもそも `tools` に含まれない」という省略で表現する
  （§1 の open な辞書設計）。
- **汎用 JSON Schema バリデータ（`JSONSchema.jl` 等）の導入**: [ADR 0008](0008-real-rate-model-artifact-export.md)
  と同じ理由（新規依存とメンテナンスコストに見合わない）で不採用。
- **identity hash（`artifact_id` 相当）の追加**: 本 contract の要求範囲外（§6）。
- **`duration_seconds` を呼び出し側の入力にする**: `started_at`/`completed_at` との不整合を
  構造的に防げないため、自動導出のみ許可（§2）。

## 影響

- #208/#209/#211/#212/#213 は `result` の内部フィールドを新規に設計できる（本 ADR・schema は
  それを制約しない）。ただし `result` は JSON-safe な値域に限定され、秘匿情報らしき文字列を
  含めると `ArgumentError` になる（§3）。
- `tools` に予約名以外のキーを追加してもメジャーバージョンアップは不要（§1）。
- `status` enum への新メンバー追加・必須フィールドの削除/意味変更は `julia-quality-export/v2`
  を要する（contract doc §6）。
- #210（GitHub Actions Artifact 公開）は `save_quality_export` の既定上書き許可を前提に設計できる
  （§5）。

## 参考

- [ADR 0008: Real-rate model artifact 統合契約](0008-real-rate-model-artifact-export.md)（UTC固定・
  正準JSON・atomic write・「汎用バリデータを持たない」doctrine の踏襲元）
- [software-quality-dashboard `docs/provider-development.md`](https://github.com/Yuki-Watanabe7/software-quality-dashboard/blob/main/docs/provider-development.md) §10（互換性・バージョニングの考え方）
- [ADR 0009: 部門別CAPEX・信用循環モデルの責務境界](0009-capex-credit-cycle-model-responsibilities.md)
  （「事実の保持」と「評価」の責務分離という先行方針）
