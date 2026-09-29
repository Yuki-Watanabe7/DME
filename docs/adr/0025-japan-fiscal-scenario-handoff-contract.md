# ADR 0025: Japan Fiscal Scenario Lab の deterministic E2E・consumer handoff 契約

- **ステータス**: 採用
- **日付**: 2026-09-30
- **関連Issue**: [#273](https://github.com/Yuki-Watanabe7/DME/issues/273)（Japan Fiscal Scenario Lab ロードマップ）・[#277](https://github.com/Yuki-Watanabe7/DME/issues/277)（本決定）・前提 [#274](https://github.com/Yuki-Watanabe7/DME/issues/274)・[#285](https://github.com/Yuki-Watanabe7/DME/issues/285)・[#275](https://github.com/Yuki-Watanabe7/DME/issues/275)・[#276](https://github.com/Yuki-Watanabe7/DME/issues/276)。consumer: Yuki-Watanabe7/market-analyzer#282（#283–#286）
- **前提ADR**: [ADR 0020](0020-japan-fiscal-scenario-capability-contract.md)・[ADR 0021](0021-japan-fiscal-claim-level-contract.md)・[ADR 0022](0022-japan-fiscal-scenario-schema-contract.md)・[ADR 0023](0023-japan-fiscal-scenario-result-artifact-contract.md)（本決定が result artifact を 2.0.0 に改訂する）・[ADR 0008](0008-real-rate-model-artifact-export.md)（RFC 8785 正準化・hash 自己参照排除・atomic write・汎用バリデータ不使用）・[ADR 0016](0016-julia-quality-export-contract.md)（DME 所有の versioned contract と schemas/）
- **関連ドキュメント**: [deterministic E2E・handoff 契約](../architecture/japan_fiscal_scenario_handoff.md)（本決定の詳細）・[result artifact 契約](../architecture/japan_fiscal_scenario_result_contract.md)（#276）

---

## コンテキスト

#276 で 14 セルの実行と result artifact（1.0.0）ができたが、Market Analyzer が consume する前に次の空白が
残っていた。

1. **未指定の assumption が 0 として実行されていた。** adapter は assumption の無い概念のモデル入力を baseline 値の
   まま保持する。必須概念（例: 財政再建の `tax`）が未指定でも実行され、結果は「税の変化 0」と区別できなかった。
   #274 の `zero_vs_missing`（「未指定は 0 へ丸めない」）に反する。
2. **受理されるはずの assumption が黙って捨てられていた。** `primary_balance` は IS-LM / AD-AS / SIM の mapping で
   `:requires_structural_conversion` として受理されるが、adapter は変換（閉じ変数の選択）を実装しておらず、explicit
   assumption を無視して実行していた。モデルが受け取れない概念の assumption も artifact 上は `assumed` と
   `applied_inputs` の差分からしか分からなかった。
3. **artifact の identity が入力順に依存していた。** `assumed` は入力順のまま、FRE context の `dominant_drivers` も
   入力順のまま正準化されており、同じ意味内容から異なる `result_content_hash` が生じた。
4. **decode が version を検査していなかった。** `schema_version` や契約 version が異なる artifact、coverage の
   `claim_level` を書き換えた artifact でも hash さえ整合すれば受理された。
5. **consumer boundary が無かった。** 機械可読な契約 export（Dict）はあったが、consumer が Julia 型なしに decode
   するための JSON Schema・versioned fixture・fail closed を検証する negative artifact・replay の手段が無かった。
6. **fixture を決定的なバイト列にできなかった。** `generated_at` が常に現在時刻で、また BLAS / LAPACK を使うモデルの
   浮動小数点の最終桁はプラットフォームで変わりうる。

## 決定

1. **必須概念のうちモデルが受理する概念に explicit assumption が無い場合、`japan_fiscal_run` はモデルを実行せず
   `JapanFiscalScenarioRejection`（`rejection_code = :missing_required_assumption`）を返す。** 「変化なし」を主張する
   場合は magnitude = 0.0 の assumption を明示させる。任意概念の未指定は実行するが、disposition に
   `:held_at_baseline` として開示する（0 の applied input を作らない）。
2. **adapter が変換を実装している概念を `JAPAN_FISCAL_ADAPTER_IMPLEMENTED_CONCEPTS` として宣言し、mapping 上は受理
   されるが変換が未実装の概念に explicit assumption がある場合は `:conversion_not_implemented` として拒否する。**
   実行後に `applied_inputs` と disposition の一致を検査し、不一致は実装の誤りとして `ArgumentError` にする
   （宣言と実装の乖離を黙認しない）。PB 変換は本決定では実装しない。
3. **result artifact に `assumption_disposition` を加える。** family の required → optional の宣言順に全概念について
   `assumption_state`（`explicit` / `not_specified`）と `model_input`（`applied` / `held_at_baseline` / `not_accepted` /
   `conversion_not_implemented`）を持たせ、explicit assumption の黙殺と未指定の 0 化を表す組はコンストラクタと
   JSON Schema の両方で表現不能にする。
4. **拒否を構造化する。** `JapanFiscalScenarioRejection` に `rejection_code`・`concepts`・scenario identity・`horizon`・
   `coverage`・`rejection_content_hash` を持たせ、result と同じ fail closed decode を行う。result / rejection に
   `artifact_kind` を持たせ、consumer が discriminated union として decode できるようにする。
5. **result artifact を `japan-fiscal-scenario-result/2.0.0` に上げる。** enum と必須フィールドの追加は major 変更と
   扱う（ADR 0016 の versioning 方針と同じ）。1.0.0 は consumer fixture として公開していないため、互換の読み込み経路は
   設けない。DME の decoder は schema version と契約 version chain の完全一致を要求し、coverage が #285 registry と
   一致すること・diagnostics の timing 診断が claim_level と整合すること・disposition の整合を検査する。
6. **artifact を入力順に依存させない。** `assumed` は `assumption_id` 昇順、FRE context の `dominant_drivers` は整列して
   出力する（identity が並び順を意味に含めない以上、serialization も含めない）。
7. **`japan_fiscal_run` に `generated_at` を注入できるようにする。** `generated_at` は hash 対象外の volatile フィールドで
   あり、固定値を渡すのは fixture を決定的なバイト列にするときだけである。
8. **Market Analyzer への受け渡しを versioned handoff bundle（`japan-fiscal-scenario-handoff/1.0.0`）とする。** bundle は
   `index.json` を入口とし、契約 export 4 種・scenario・result / rejection artifact・negative artifact を RFC 8785 正準 JSON
   で持ち、各ファイルの SHA-256 と `bundle_content_hash` を index が保持する。index の case 要約は artifact から機械的に
   導出した値に限り（新しい主張を追加しない）、load 時に再導出して一致を検査する。
9. **JSON Schema（draft 2020-12）を `schemas/` に DME 所有の契約として置く**（result / rejection・scenario・handoff index の
   3 種）。JSON Schema で表現できない整合条件は `x-semantic-invariants` に列挙し、DME の decoder が検査する。src に汎用
   バリデータを置かない方針（ADR 0008）は維持し、CI ではテスト専用の最小 validator（schema が使うキーワードだけを
   解釈し、未対応キーワードが現れたら失敗する）で全 fixture を検証する。
10. **consumer が fail closed を検証するための negative artifact を bundle に含める。** 6 種（hash 改変・未知の major・
    必須フィールド欠落・claim_level の昇格・not_representable を result と装う・必須 assumption の欠落を 0 と装う）を
    有効な result から 1 事実だけを破って決定的に生成し、`load_japan_fiscal_handoff` はそれらが DME の decoder で
    **拒否されること**を検査する。
11. **replay は数値以外の完全一致と数値の許容誤差内の一致で成立とし、content hash の完全一致は `exact_match` として別に
    報告する。** identity に使う hash（scenario・assumption 集合・FRE context・パラメータ）は入力だけから決まり
    プラットフォームに依存しないが、model-implied の系列は BLAS 等の差で最終桁が変わりうる。committed fixture の drift
    検出も、数値を含まないファイルはバイト一致、数値系列を含むファイルは許容誤差で比較する。
12. **fixture の magnitude は FRE snapshot と独立した入力ファイルで明示し、FRE snapshot は架空の fixture とする。**
    FRE context だけを変えた case（なし・unavailable・score を大きく変えた snapshot）を置き、結果が不変であることを
    E2E で検査する。

## 理由

- **決定 1・2 は、#274 が契約として定めた「未指定を 0 へ丸めない」「受け取れない概念を黙って無視しない」を
  runner の実行可否として強制するためである。** 開示フィールドだけを足して実行を続ける案では、consumer が
  「tax = 0 の財政再建」と「tax を置いていない財政再建」を同じ結果として表示する経路が残る。
- **決定 3・4・9 は、consumer が semantics を再実装しないためである。** `assumed` と `applied_inputs` と coverage の
  差分から disposition を再導出させると、Market Analyzer が mapping 規則を持つことになり、#282 の責務境界
  （モデル・mapping を再実装しない）に反する。
- **決定 5 で major を上げるのは、未公開の 1.0.0 に互換経路を残すより、consumer の最初の実装を 2.0.0 に揃える方が
  安全だからである。** fail closed decode は未知キーを拒否するため、minor として追加しても strict な consumer には
  非互換になる。
- **決定 8 で要約を artifact からの導出に限るのは、index と本体の二重管理による乖離を構造的に検出するためである。**
  consumer は一覧表示に index だけを使えるが、その値が本体と異なる bundle は load できない。
- **決定 11 は、content hash の完全一致を CI の合否条件にすると、実装の誤りではなく CPU アーキテクチャの違いで
  失敗する検査になるためである。** 構造・identity・診断の離散値（peak の期・onset など）は完全一致を要求するので、
  意味のある再現性の破れは検出できる。

## 見送りとした選択肢

- **必須概念の未指定を警告付きで実行する**: 決定 1 の理由のとおり、結果が 0 の assumption と区別できなくなる。
- **PB 目標を (G, T) へ変換する閉じ変数の選択を本 Issue で実装する**: #274 §5.3 のとおり変換は一意でなく、閉じ変数の
  選択と感応度の記録という独立した設計判断を要する。#277 の範囲（E2E・fixture・handoff）を超えるため、未実装を
  明示的な拒否として公開する。
- **result artifact 1.0.0 のまま disposition を任意フィールドとして足す**: 決定 5 の理由のとおり strict な consumer に
  非互換であり、かつ「必須概念の未指定を 0 として実行した 1.0.0 artifact」を受理する経路が残る。
- **src に汎用 JSON Schema バリデータを導入する**: ADR 0008・0016 の doctrine に反し、依存も増える。schema は consumer の
  ための契約であり、DME の正本は Julia の decoder である。
- **content hash の完全一致を replay の必要条件にする**: 決定 11 の理由のとおり。
- **fixture の FRE snapshot を fiscal-regime-engine の実出力から取る**: live 接続は #277 の non-goal であり、FRE 側の
  schema 変更に DME の fixture が追随する結合を作る。架空の snapshot で observed context の扱いは検証できる。

## 影響

- **`src/scenarios/japan_fiscal_result.jl` を改訂する**（2.0.0・`JapanFiscalAssumptionDisposition`・構造化された拒否・
  fail closed decode の強化・`generated_at`）。`src/scenarios/adapters/japan_fiscal_model_adapters.jl` に
  `JAPAN_FISCAL_ADAPTER_IMPLEMENTED_CONCEPTS` を加える。`src/scenarios/japan_fiscal_scenario_schema.jl` の
  `to_dict(::JapanFiscalFREContext)` は `dominant_drivers` を整列して出力する（identity は不変）。
- **`src/scenarios/japan_fiscal_handoff.jl` を新設する**（bundle の build / write / load / replay・negative artifact）。
- **`schemas/` に 3 つの JSON Schema を加える。** `test/fixtures/japan_fiscal/` に入力 fixture・consumer fixture
  （`handoff/v1/`）・invalid input・再生成スクリプトを置く。
- モデル方程式・#274/#285 の registry・一般 macro-event レイヤーは変更しない。#276 の 14 セルの数値結果は変わらない
  （必須概念をすべて明示した scenario について）。
- Market Analyzer #284 以降は `test/fixtures/japan_fiscal/handoff/v1/` と `schemas/japan-fiscal-scenario-*.schema.json` を
  vendor して接続する。

## 参考

- [deterministic E2E・handoff 契約](../architecture/japan_fiscal_scenario_handoff.md) — bundle 構成・schema・fixture・interpretation guide・既知の限界・完了条件との対応
- [result artifact 契約](../architecture/japan_fiscal_scenario_result_contract.md)（#276） — 14 セルの adapter・artifact フィールド
- [claim-level / coverage 契約](../architecture/japan_fiscal_claim_level_contract.md)（#285） — H-13–H-16（#277 向け handoff requirements）
- [Julia品質Export Contract](../contract/julia-quality-export-v1.md) — DME 所有の versioned contract と versioning 方針の先例
