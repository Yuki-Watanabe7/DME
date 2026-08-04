# ADR 0015: イベント層を 4 レコード型 + 型レジストリで実装し、失敗を 3 層に分け、適用不能を既定で fail closed とし、既存シナリオ API を並置維持する

- **ステータス**: 採用
- **日付**: 2026-08-05
- **関連Issue**: #125（ロードマップ）・#196（本決定・イベント/シナリオ実行層の統合設計）・#168（イベント変換契約・時間軸）・#171（`CCC` 統合設計）・後続 #197–#205（実装）
- **前提ADR**: [ADR 0003](0003-minsky-financing-regime-diagnostics.md)（診断を読み取り専用層として分離）・[ADR 0007](0007-sfc-integration-contract.md)（不整合を自動補正せず構造化する・既存型へ非破壊）・[ADR 0008](0008-real-rate-model-artifact-export.md)（RFC 8785 正準化・UTC 固定）・[ADR 0010](0010-macro-event-scenario-contract.md)（イベントの 4 層分離・適用先 7 変数・期首一括適用・固定順合成）・[ADR 0012](0012-capex-credit-cycle-empirical-contract.md)（`:as_of` を実装しない）・[ADR 0013](0013-capex-credit-cycle-integration-contract.md)（接続点 1 点・`SimulationResult` 非変更・metadata 予約キー）・[ADR 0014](0014-digital-twin-naming-conditions.md)（名称の使用条件）
- **関連ドキュメント**: [イベント・シナリオ実行層 統合設計](../architecture/macro_event_runtime_integration.md)（本 ADR の詳細設計）・[マクロイベント変換契約](../architecture/macro_event_contract.md)・[シナリオ時間軸の意味論](../architecture/scenario_time_semantics.md)・[部門別CAPEX・信用循環モデル 統合設計](../architecture/capex_credit_cycle_integration.md)

## コンテキスト

[ADR 0010](0010-macro-event-scenario-contract.md) はイベントの概念階層（Observed Event / Interpreted Signal / Scenario Assumption / Applied Model Input）・適用先の外生変数 7 個への限定・期首一括適用・固定順合成・再現契約を確定した。しかし Julia 型・API 名・失敗の返し方・実行順・既存 API との関係は「実装（#171 の後続）へ委ねる」として未確定のままであった。

その後、部門別CAPEX・信用循環モデル（`CCC`）の実装が進み、`CapexShockSpec` / `CapexScenario` / `capex_exogenous_paths` という**暫定のシナリオ層が既に存在する**。この暫定層は 4 時間形状と固定順合成を独自に実装し、`Dict{Symbol,Vector{Float64}}` を唯一の接続点として `capex_run` へ渡す。

この状態でイベント層の実装へ進むと、次の失敗様式が具体的に起こりうる。

1. **同一計算の二重実装**: 契約が定める 6 時間形状と固定順合成を、イベント層が既存実装と独立に書く。既定パラメータでの数値が一致する保証がなくなり、「同じシナリオなのに経路によって結果が違う」状態が生じる。
2. **型の爆発と契約表の乖離**: イベント型 9 種 × 4 層を素朴に struct 化すると 36 個の型になる。契約 §4.2–§4.4 の 3 つのマッピング表がコード中の分散した検証へ溶け、表とコードの差分を検査できなくなる。
3. **失敗の返し方の不統一**: 既存実装は `ArgumentError` で拒否する。契約は「構造化して拒否」と述べる。後続 Issue は「execution status で区別する」と述べる。境界を定めないまま実装すると、同種の誤りが呼び出し箇所ごとに例外・戻り値・警告のいずれかで返り、fail closed かどうかが箇所依存になる。
4. **黙った部分実行**: 適用先を持たないイベント（貸出態度・雇用計画・部門別価格など）を含むシナリオを、残りのイベントだけで実行して結果を提示すると、「シナリオに含めたイベントがすべて適用された」という誤読を招く。契約 §4.5 は実行を禁じていないが、既定を定めていない。
5. **理論シナリオが表現できない**: 契約は Scenario Assumption に暦日（`effective_from`）を必須とする。しかし既存の `Sc0`–`Sc4` は暦を持たない理論シナリオであり、`t = 0` 起点の整数時点しか持たない。暦日必須のままではイベント経由で `Sc0`–`Sc4` を再現できず、既存結果との数値互換を検証する手段が失われる。
6. **再現できない replay**: `SimulationResult.metadata["scenario"]` は `shape_params` を含まないため、`:ar1_decay` の半減期などが復元できない。metadata を replay の入力にすると、再実行しても同じ外生パスにならない。

これらは実装後には切り分けが困難であり、実装前に契約として固定する必要がある。

## 決定

1. **契約と既存実装の差異 30 件を `Y-01`–`Y-30` として登録し、各件の解決先を「上流改訂 / 本決定 / 限界として保持」へ明示的に割り当てる。**
   暗黙に吸収した差異を残さない。上流改訂は該当文書の改訂節として行い、改訂節を当該文書の正本とする（[統合設計](../architecture/macro_event_runtime_integration.md) §2、#171 の手続きを継承）。

2. **4 層を 4 つのレコード型として実装し、イベント型 9 種は宣言的レジストリ（`MacroEventTypeSpec`）として持つ。**
   イベント型ごとの struct を作らない。契約 §4.2–§4.4 の 3 表をレジストリへ 1:1 で写し、表とコードの一致をテストで検査する（同 §5.3・§10.1-10）。

3. **`L1` / `L2` から `L4` を生成する公開関数を提供せず、`map_event` の引数型を `ScenarioAssumption` のみとする。**
   層飛ばしの禁止を文書の規律ではなく型で強制する。`magnitude` の型を層で変える（`Union{Float64,Missing}` / `Float64`）ことで、欠測と 0 の区別も型で保証する（同 §5.2）。

4. **`event_type` の `:other` を Observed / Interpreted に限って許容し、Scenario Assumption 以降で拒否する。レジストリに無い Symbol は全層で拒否する。**
   「観測はしたが解釈できない事象を記録する」ことと「モデルへ適用する」ことを分離する（`Y-01`）。

5. **Scenario Assumption の時点指定を、暦日基準（`effective_from` + 割当規則）とモデル期基準（`t_apply` の直接指定）の 2 基準とし、1 シナリオ内での混在を拒否する。**
   モデル期基準は `timing_basis_period` 警告を必ず伴う。これにより理論シナリオ（`Sc0`–`Sc4` 相当）をイベント経由で表現でき、既存結果との数値互換を検証できる（`Y-02`。[時間軸](../architecture/scenario_time_semantics.md) §11 の改訂）。

6. **失敗を 3 層へ分離する。値の不変条件違反は例外、集合の整合違反は構造化拒否（モデルを実行しない）、それ以外は警告（実行する）とする。**
   実行ステータスを `:completed` / `:rejected_validation` / `:rejected_mapping` / `:terminated` の 4 値に固定し、5 値目を追加しない。拒否コード 12 種・警告コード 12 種を列挙し、実装が新しいコードを追加しない（同 §6）。

7. **適用先を持たないイベント（`unmapped_target`）を含むシナリオを、既定で fail closed とする。**
   `on_unmapped = :reject` を既定とし、`:warn` を明示指定した場合のみ実行する。指定値を metadata へ記録する。契約 §4.5 の「実行してよい」は禁止しないという趣旨であり、既定の指定ではないと解する（`Y-06`）。

8. **`CapexShockSpec` / `CapexScenario` / `capex_scenario` / `capex_exogenous_paths` を非推奨にせず、公開 API として並置維持する。**
   時間形状と固定順合成の**2 つだけ**を共通層へ移し、既存関数は委譲する。戻り値の型・数値・例外条件を変えない（同 §8）。

9. **6 時間形状と固定順合成を 1 箇所に実装し、既存 4 形状が同一パラメータで同一ベクトルを返すことを回帰テストで固定する。**
   Julia シンボルの正本を `:pulse` / `:step` / `:ramp` / `:step_then_ramp` / `:ar1_decay` / `:path` とし、形状パラメータの受け渡しは既存実装を正本とする。打ち切り（`effective_until`）は形状によらず一律に適用する（`Y-10`・`Y-11`）。

10. **`run_scenario` の実行順を validation → mapping → schedule → model → accounting/diagnostics → result に固定し、外生パスをモデル実行前に全期確定させる。**
    モデル実行中にイベントオブジェクトを参照しない。期内反復・期中適用・期内按分を追加しない（同 §5.7・§7.6）。

11. **`SimulationResult` 型を変更せず、イベント層の metadata 予約キー 20 個を追加する。`CCC` の既存 20 キーを上書きせず、他モデルへ同じキーを要求しない。**
    `data_as_of` / `data_vintage` / `scenario_seed` は**予約しない**（`:as_of` と確率的シナリオを実装しないため）（同 §9.3）。

12. **replay の入力を保存済み Scenario artifact（正準 JSON）に限定し、`SimulationResult.metadata` と Observed Event 原本を用いない。**
    replay 時に `params_hash` / `initial_state_id` / `solver_settings_hash` を manifest と照合し、不一致なら拒否する（同 §9.5）。

13. **content identity の hash 対象フィールドを明示列挙し、`generated_at` / `notes` / `caveats` / `url` / `retrieved_at` / `confidence` / `uncertainty` を除外する。**
    JSON のキーはすべて ASCII の snake_case とし、日本語は値にのみ置く。正準化は既存の `canonical_json_bytes`（RFC 8785）を変更せず再利用し、前段に型写像 encoder を置く（同 §9.2・§9.4）。

14. **企業レベルイベントの部門集約を実装しない。`entity` フィールドを Scenario Assumption に持たせない。**
    集約重み（`entity_weight`）を型に持たせず、等ウェイト代用の余地を構造的に排除する。`entity` 非空の Scenario Assumption を `aggregation_not_implemented` として拒否する（`Y-03`）。

15. **`:as_of`（vintage 参照）を実装しない。`known_at` は監査属性としてのみ保持し、イベントの取捨選択に用いない。**
    「その時点で判断できた」旨の記述を LLM 禁止表現へ追加する（`Y-08`。[ADR 0012](0012-capex-credit-cycle-empirical-contract.md) の決定を継承）。

16. **`unmapped_target`（`CCC` に適用先の外生変数が無い）・`untranslatable`（他モデルが構造上表現しない）・`unsupported_model`（そのモデルに mapping 実装が無い）を別コードとし、同一視しない。**
    本設計で発生しうるのは前 2 者のうち `unmapped_target` と `unsupported_model` のみである。`untranslatable` の新設は他モデル向け mapping を実装する時点で行う（`Y-26`）。

17. **後続の実装 Issue #197–#205 を `E-1`–`E-9` として、対象ファイル・依存・対象外・受け入れ条件つきで確定する。**
    本 ADR と統合設計が Issue 本文と異なる箇所は、Issue ごとに「本書による変更」として明示する（同 §11）。

## 1. なぜイベント型を struct ではなくレジストリにするか

契約 §3.1 の属性表は**層ごとに 1 つ**であり、イベント型が変わっても属性の集合は変わらない。変わるのは「どの部門が許されるか」「どの単位が許されるか」「既定の時間形状は何か」「どの条件で適用不能か」という**規則**である。

| 方式 | 型の数 | 契約表との対応 | イベント型追加時 |
|---|---|---|---|
| 層 × 型で struct | 36 | 検証が各型の内部コンストラクタへ分散する | 4 個の型 + ディスパッチを追加 |
| **層のみ struct + 型レジストリ（採用）** | **4 + 1** | **§4.2–§4.4 の 3 表をレジストリへ 1:1** | **契約改訂 + レジストリ 1 行** |

レジストリ方式は、契約表とコードの差分をテストで機械的に検査できる（統合設計 §10.1-10・§10.1-11）。これは「契約を文書に書いたが実装が従っていない」という失敗様式を、実装からの逸脱ではなくテストの失敗として検出できることを意味する。

後続 Issue #199・#200 は「event-specific struct / constructor / validator」を求めているが、その受け入れ条件は「型別に必須属性・単位・適用方式・target concept が検証され、generic へ縮約されない」ことである。レジストリ + 型別 smart constructor で同じ性質を満たせる。

## 2. なぜ失敗を 3 層に分けるか

| 層 | 主張 | 返し方の必然性 |
|---|---|---|
| 値の不変条件 | 「そのようなレコードは存在しえない」 | 値を返す余地がない。例外 |
| 集合の整合 | 「入力集合として矛盾している」 | **全件を列挙する必要がある**。1 件目で例外を投げると残りの矛盾が見えない。構造化拒否 |
| その他 | 「結果の解釈に影響する」 | 実行を妨げない。警告 |

既存実装の `ArgumentError`（`invalid_unit_mode`・`conflicting_absolute`・`sign` 不一致・`shape_params` 欠落）はすべて第 1 層に該当し、**変更しない**。`conflicting_absolute` だけは、単一シナリオ定義）では即座に知らせる用途で例外、多数イベントの矛盾一覧（イベント層）では構造化拒否と、層によって返し方が異なる。同じ事象を別の返し方にすることの是非は検討したが、用途が異なるため統一しない。統一すると、`capex_exogenous_paths` が拒否オブジェクトを返す設計になり、既存の呼び出し側（統合デモ・テスト）が壊れる。

## 3. なぜ `unmapped_target` を既定で fail closed とするか

契約 §4.5 は「`unmapped_target` を含むシナリオを実行してよい。ただし出力に当該イベントの一覧と理由を必ず含める」と述べる。これは**禁止しない**という規定であり、既定を定めていない。

一方、部分実行の結果は「CAPEX 削減 + 貸出態度引き締めのシナリオを実行した」と記述されうるが、実際には貸出態度は適用されていない。出力に一覧が含まれていても、要約段階で落ちれば区別できない。

fail closed を既定にすると、部分実行は**分析者の明示的な選択**になる。`on_unmapped = :warn` の指定は metadata に残り、「一部のイベントが適用されていないことを承知の上で実行した」という記録になる。契約が求める「一覧と理由の出力」は `:warn` の場合の義務として維持する。

## 4. なぜ時点指定を 2 基準にするか

契約 §3.1 は Scenario Assumption で `effective_from`（暦日）を必須とする。これは「日付付きイベントを扱う」という本来の目的に対しては正しい。しかし [時間軸](../architecture/scenario_time_semantics.md) §9-4 は既に「`period_zero` を持たないシナリオでは日付付きイベントを扱えない。理論シナリオと履歴再生で扱いが分かれることを実装が明示する必要がある」と限界として記録していた。

既存の `Sc0`–`Sc4` は暦を持たない理論シナリオであり、`t = 0` 起点の整数時点しか持たない。

| 選択肢 | 帰結 |
|---|---|
| 暦日必須のまま、`Sc0`–`Sc4` に架空の暦日を割り当てる | 観測されていない日付を作ることになる。捏造禁止（[ADR 0010](0010-macro-event-scenario-contract.md) 決定 4）と同型の問題 |
| 暦日必須のまま、`Sc0`–`Sc4` をイベント経由で表現しない | 既存結果との数値互換を検証できない。2 経路の一致を保証できない |
| **2 基準に分け、混在を拒否する（採用）** | **理論シナリオを理論シナリオとして表現でき、暦由来でないことが警告として残る** |

混在を拒否するのは、`effective_from` を持たない仮定と持つ仮定でソートキー（契約 §5.1 の第 4 キー）が比較不能になり、`period_zero` の要否も定まらないためである。片方が欠けたときの規則を置くと、規則がシナリオ定義の誤りを隠す。

## 5. なぜ既存シナリオ API を並置維持するか

`CapexShockSpec` が表すのは「分析者が定義した抽象的なショック仕様」であり、`ScenarioAssumption` が表すのは「観測事実に由来する仮定と、その適用の記録」である。**表現している対象が違う**。

[統合設計](../architecture/capex_credit_cycle_integration.md) §4.6 は既に「`CapexShockSpec` は `AbstractMacroEvent` の前身ではなく、シナリオ仕様の記録用型である。イベント属性（公表日・出所・解釈シグナル）を `CapexShockSpec` へ持ち込まない」と決定している。前者を後者へ吸収すると、暦日も出所も持たない仮定に空の provenance を持たせることになり、4 層分離が形骸化する。

そのうえで、**時間形状と固定順合成だけは共通化する**。これらは「表現している対象」ではなく「計算」であり、2 つの実装が同じ数値を返すことを保証する手段が回帰テストしかなくなるのを避けるためである。委譲後も `capex_exogenous_paths` の戻り値が bit 単位で変わらないことを golden 値で固定する。演算順序を変えると浮動小数点の結果が変わりうるため、共通層の合成は既存と同じ「クラス順 → 全順序昇順の逐次適用」とし、総和・総積を先に計算する形へ書き換えない。

## 6. なぜ replay の入力を Scenario artifact に限定するか

| 候補 | 不採用の理由 |
|---|---|
| `SimulationResult.metadata` | `metadata["scenario"]["shocks"]` は 9 キーのみで `shape_params` を含まない。`:ar1_decay` の半減期・`:step_then_ramp` の hold / ramp_down が復元できず、再実行しても同じ外生パスにならない |
| Observed Event 原本（`L1`） | 変換ルールが更新されると再生成値が変わる。`L1` の表記揺れが結果を変えない設計であることを、replay 経路の入力から `L1` を除くことで構造的に保証する |
| **保存済み Scenario（`L3` 集合 + 時間軸設定）（採用）** | **契約 §6.5 が `event_set_hash` を `L3` に対して定義していることと整合する。`L1`・`L2` は監査のために別途保存する** |

replay 時に `params_hash` / `initial_state_id` / `solver_settings_hash` を照合するのは、「同じシナリオを別のパラメータで実行して同じ結果だと述べる」ことを防ぐためである。

## 7. versioning

| version | 対象 | 上げる条件 |
|---|---|---|
| `macro-event-contract/x.y.z` | イベント属性スキーマ・イベント型マッピング・合成規則 | 属性の追加/削除、適用先の変更、合成規則の変更 |
| `scenario-time-semantics/x.y.z` | 時間軸・割当規則・時間形状 | 割当規則の追加、`cutoff` 既定値の変更、時間形状の追加 |
| `macro-event-runtime/x.y.z` | 公開型・公開 API・実行順・失敗契約 | 型・シグネチャ・status 値・拒否/警告コードの変更 |
| `event-rule/x.y.z` | `L2 → L3` / `L3 → L4` の変換ルール実装 | 既定値セット・導出式の変更 |
| `ccc-event-mapping/x.y.z` | `CCC` 固有 mapping 表 | 行の追加/削除・単位変換の変更 |
| `dme.scenario/x.y.z` | 保存 JSON の schema | キー・構造の変更 |
| `timing-rule-set/x.y.z` | 割当規則の**設定値**（`cutoff_month_offset` 等） | 設定値の変更 |

**契約**: `cutoff_month_offset` の変更のようにコード変更を伴わずに結果を変えうる設定は、必ず version を持つ。無記録で結果が変わる経路を残さない（[ADR 0010](0010-macro-event-scenario-contract.md) §7 を継承）。

本決定に伴い、[マクロイベント変換契約](../architecture/macro_event_contract.md) を `1.0.2`（属性の適用範囲の明確化のため patch）、[シナリオ時間軸の意味論](../architecture/scenario_time_semantics.md) を `1.1.0`（割当規則の追加のため minor）へ上げる。

## 理由

- **契約とコードの差分を検査可能にした**: レジストリ方式（決定 2）と、契約表との一致テスト（統合設計 §10.1）により、「文書に書いたが実装が従っていない」を実装からの逸脱ではなくテストの失敗として検出できる。
- **層飛ばしの禁止を型で強制した**（決定 3）: 文書の規律は読まれなければ守られない。`map_event` の引数型を `ScenarioAssumption` のみにすることで、`L1` / `L2` から直接モデル入力を作る経路が**書けなくなる**。
- **fail closed を既定にした**（決定 7）: 部分実行の結果は、要約段階で「全部適用された」と読まれうる。既定を拒否にすると、部分実行が分析者の明示的な選択として記録に残る。
- **表現している対象が違うものを混ぜなかった**（決定 8）: 理論シナリオとイベント由来の仮定は別物である。片方をもう片方のラッパにすると、空の provenance を持つ仮定が生まれ、4 層分離が意味を失う。
- **計算だけを共通化した**（決定 9）: 型を共通化せず、時間形状と合成という「同じ数値を返すべき計算」のみを 1 箇所に置いた。二重実装のリスクを取り除きつつ、型の意味は分けたままにできる。
- **既存資産を変更しなかった**: `SimulationResult`・`DataSeries`・`CapexShockSpec`・`capex_run`・`simulate`・`to_simulation_result` の型と公開挙動を一切変更せず、新規層の追加と metadata 予約キーのみで成立させた（[ADR 0002](0002-minsky-integration-design.md)・[ADR 0007](0007-sfc-integration-contract.md)・[ADR 0013](0013-capex-credit-cycle-integration-contract.md) と同方針）。
- **できないことをできないと言う設計を維持した**: 部門集約（決定 14）・`:as_of`（決定 15）・他モデル翻訳（決定 16）を「後で足す」のではなく「実装しない」と明記し、拒否コードと限界として出力へ現れるようにした。

## 見送りとした選択肢

- **イベント型ごとに struct を定義する**: 層 × 型で 36 個の型になり、契約 §4.2–§4.4 の 3 表がコードへ分散して差分を検査できない（§1）。
- **`CapexShockSpec` を `ScenarioAssumption` のラッパへ置き換える**: [統合設計](../architecture/capex_credit_cycle_integration.md) §4.6 の決定（前身ではない）の反故に当たり、暦日も出所も持たない仮定に空の provenance を持たせることになる（§5）。
- **`CapexShockSpec` を非推奨にする**: 理論シナリオ（暦日・出所・解釈シグナルを持たない）は今後も必要であり、イベント層で置き換えるべきものではない。既存テスト・統合デモ・モデル解説ドキュメントが公開 API として参照している。
- **イベント層を独立に実装し、時間形状も別に書く**: 既定パラメータでの数値が一致する保証がなくなる。同じシナリオが経路によって別の結果を返しうる（§5）。
- **`unmapped_target` を既定で警告にして実行する**: 部分実行が既定になり、「シナリオに含めたイベントがすべて適用された」という誤読を招く（§3）。
- **Scenario Assumption に暦日を必須のまま残す**: 理論シナリオに架空の暦日を割り当てるか、`Sc0`–`Sc4` をイベント経由で表現できなくなる。前者は捏造、後者は数値互換の検証手段の喪失である（§4）。
- **暦日基準とモデル期基準の混在を許し、欠けた側を補う規則を置く**: 規則がシナリオ定義の誤りを隠す。ソートキーも比較不能になる（§4）。
- **`run_scenario` が拒否時に例外を投げる**: 1 件目の矛盾で止まり、残りの矛盾が見えない。分析上の発見は列挙して返すべきである（§2）。
- **実行ステータスに `:completed_with_warnings` を追加する**: 警告の有無は `warnings` フィールドで表せる。status を増やすと、呼び出し側が「成功」の判定条件を状況ごとに変えることになる。
- **`SimulationResult.metadata` を replay の入力にする**: `shape_params` を含まないため同じ外生パスを再現できない（§6）。
- **`SimulationResult` にイベント情報のフィールドを追加する**: 既存 10 モデル以上に依存される型の破壊的変更になる。metadata 予約キーとイベントログで同じ情報を保持できる（[ADR 0010](0010-macro-event-scenario-contract.md) と同じ判断）。
- **`json_canonical.jl` を汎用 JSON 正準化へ拡張する**: 既存 artifact（real-rate model artifact）の hash を動かすリスクがある。前段に型写像 encoder を置けば足りる（決定 13）。
- **`entity_weight` を型に持たせ、集約は後回しにする**: 使われない自由度が残ると、等ウェイト代用が「実装されていないだけ」に見える。持たせなければ代用は書けない（決定 14）。
- **`confidence` を hash 対象に含める**: `confidence` は magnitude・適用可否・順序のいずれにも作用しない。含めると、結果が同一なのに hash が異なる状態が生じ、再現契約が弱まる。
- **`:as_of` を「限定的に」実装する**: `DataSeries` が vintage 軸を持たない以上、部分的な実装は「その時点で判断できた」という主張を可能にしてしまう。[ADR 0012](0012-capex-credit-cycle-empirical-contract.md) の決定を維持する。
- **他モデル（`Keen` / `SIM` / `NK` / `VAR`）向け mapping を同時に実装する**: 翻訳可否は #167 §5.5 が判定済みだが、`△`（部分翻訳）の情報損失の記録方法は未確定であり、`CCC` の実装と独立に検討すべき事項が多い。

## 影響

- **既存コードへの影響**: `src/analysis/capex_credit_cycle_scenarios.jl` の**内部実装のみ**が変わる（時間形状と合成を共通層へ委譲）。公開 API・戻り値の数値・例外条件は変わらない。`src/DME.jl` に include と export が追加される。`src/models/capex_credit_cycle.jl`・`src/core/simulation_result.jl`・`src/core/model_interface.jl` は変更しない。
- **新規ディレクトリ `src/scenarios/`** が追加される。`src/models/`（モデル実装）・`src/analysis/`（読み取り専用の分析層）のいずれにも属さない「モデル実行の前段」を責務単位で分ける。
- **#197（`E-1`）** は 4 層レコード型と語彙・version 定数を実装する。イベント型別 struct を作らない。`entity` を Scenario Assumption に持たせない。
- **#198（`E-2`）** は時間形状 6 種と全順序・合成を共通層へ実装し、`capex_exogenous_paths` を委譲へ書き換える。golden 値による数値不変の回帰テストが必須である。
- **#199・#200（`E-3`・`E-4`）** はイベント型 9 種をレジストリ行として登録する。struct ではない。
- **#201（`E-5`）** は `CCC` mapping 表 13 行と `map_event` を実装する。`CapexScenario → Vector{ScenarioAssumption}` の一方向変換のみを提供し、逆方向を作らない。
- **#202（`E-6`）** は `run_scenario` を実装する。status 4 値・fail closed 既定・実行順固定。
- **#203（`E-7`）** は hash・シリアライズ・replay と metadata 予約キー 20 個を実装する。`data_as_of` / `scenario_seed` を予約しない。
- **#204（`E-8`）** は `SimulationResult` を受け取るモデル非依存の比較診断を実装する。`capex_diagnostics` を変更しない。
- **#205（`E-9`）** は fictional な統合デモと E2E を追加する。`Sc0`–`Sc4` との対応は外生パスの数値一致として検査する。
- **LLM 説明層** は [統合設計](../architecture/macro_event_runtime_integration.md) §12.3 の必須記載 8 件を適用する。特に **`:as_of` を実装していないため「その時点で判断できた」と述べない**を [llm_safety.md](../llm_safety.md) の禁止表現へ追加する。
- **外部プロジェクト**: `economic-data-provider` は Observed Event と観測系列を、`finance-checker` は Interpreted Signal を提供する層として位置づけられる。DME 側は belief を Scenario Assumption を経ずに適用しない。企業レベルの belief を部門レベルへ集約する処理は DME 側で行わない（決定 14）。

## 参考

- [イベント・シナリオ実行層 統合設計](../architecture/macro_event_runtime_integration.md) — 本 ADR の詳細設計。差異 `Y-01`–`Y-30`・型・API・失敗契約・移行・再現契約・テスト・作業分解
- [マクロイベント変換契約](../architecture/macro_event_contract.md) — 4 層の概念階層・共通属性・イベント型マッピング表・合成規則
- [シナリオ時間軸の意味論](../architecture/scenario_time_semantics.md) — 内部時刻・割当規則・時間形状・`period` と `known_at`
- [ADR 0010: マクロイベント変換・シナリオ時間軸契約](0010-macro-event-scenario-contract.md) — 本 ADR が実装へ落とす契約
- [ADR 0013: 部門別CAPEX・信用循環モデルの統合実装契約](0013-capex-credit-cycle-integration-contract.md) — 接続点 1 点・`SimulationResult` 非変更・metadata 予約キー
- [ADR 0012: 部門別CAPEX・信用循環モデルの実証化契約](0012-capex-credit-cycle-empirical-contract.md) — `:as_of` を実装しない決定
- [ADR 0007: SFC 統合契約](0007-sfc-integration-contract.md) — 不整合を自動補正せず構造化する方針・既存型への非破壊
- [ADR 0008: Real-rate model artifact 統合契約](0008-real-rate-model-artifact-export.md) — RFC 8785 正準化・UTC 固定
- [ADR 0014: Digital Twin / Digital Shadow の名称使用条件](0014-digital-twin-naming-conditions.md) — 成果物・文書での名称禁止
- [部門別CAPEX・信用循環モデル 統合設計](../architecture/capex_credit_cycle_integration.md) — `CCC` の公開 API・`Sc0`–`Sc4`・metadata 予約キー 20 個
- [LLM出力の安全性・免責・禁止表現ルール](../llm_safety.md) — 禁止表現・必須記載・チェックリスト
