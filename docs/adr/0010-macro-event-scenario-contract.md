# ADR 0010: マクロイベントを 4 層に分離し、適用先を外生変数に限定し、期首一括・固定順合成でシナリオを再現可能にする

- **ステータス**: 採用
- **日付**: 2026-07-30
- **関連Issue**: #125（ロードマップ）・#168（本決定・イベント変換と時間軸）・#163／#164／#165／#166／#167（前提設計）・後続 #169／#170／#171（実装）
- **前提ADR**: [ADR 0003](0003-minsky-financing-regime-diagnostics.md)（診断をモデル本体から分離した読み取り専用層とする）・[ADR 0004](0004-keen-empirical-calibration-strategy.md)（固定/推定パラメータの分離・`Δt = 0.25` の時間軸契約）・[ADR 0005](0005-keen-ai-explanation-contract.md)（観測・測定・推定・モデル出力を分離する根拠階層）・[ADR 0006](0006-cross-model-reasoning-contract.md)（同名概念の非同一視・比較不能の非統合）・[ADR 0007](0007-sfc-integration-contract.md)（不整合を自動補正せず構造化する）・[ADR 0008](0008-real-rate-model-artifact-export.md)（RFC 8785 正準化・UTC 固定）・[ADR 0009](0009-capex-credit-cycle-model-responsibilities.md)（`CCC` の責務境界・イベント翻訳可否表）
- **関連ドキュメント**: [マクロイベント変換契約](../architecture/macro_event_contract.md)・[シナリオ時間軸の意味論](../architecture/scenario_time_semantics.md)・[分析契約](../models/capex_credit_cycle_analysis_contract.md)・[因果グラフ](../models/capex_credit_cycle_causal_graph.md)・[部門境界と変数定義](../models/capex_credit_cycle_sectors_variables.md)・[ストック・フロー会計表](../models/capex_credit_cycle_stock_flow.md)・[責務境界とモデル間比較契約](../models/capex_credit_cycle_model_boundaries.md)

## コンテキスト

Roadmap #125 は、決算ガイダンス変更・CAPEX 見直し・受注キャンセル・信用スプレッド拡大・格付変更・政策金利変更等を時系列で適用するイベント駆動シナリオ分析を目指す。#163–#167 は部門別CAPEX・信用循環モデル（以下 `CCC`）の分析契約・因果グラフ・変数定義・会計表・責務境界を確定したが、「現実のイベント記述をモデル入力へどう変換するか」と「四半期モデルの時間軸をどう定めるか」は未確定である。

この状態で実装へ進むと、次の失敗様式が具体的に起こりうる。

1. **観測と仮定の混同**: 「hyperscaler が CAPEX 見通しを下方修正した」という観測事実と、「期待需要を `-10%`、計画 CAPEX を `-15%` とする」というシナリオ仮定が同じ層で扱われ、仮定がデータの事実として提示される。外部システム（`finance-checker`）の belief をショック量へ直接変換すると、この混同が構造化される。
2. **表現できない事象の押し込み**: 貸出態度の変更・借換条件の変更・部門別の価格ショックなど、`CCC` が外生入力を持たない事象を、既存の外生変数へ近似的に寄せてしまう。結果として内生反応との二重計上が起き、どの機構が結果を生んだかを識別できなくなる。
3. **順序依存と再現不能**: 同一四半期に複数イベントが来たとき、適用順序が結果を変える。`CCC` は閾値型の関数形を複数持つ（`L06` キャンセル閾値・`L15` 目標在庫比率・`L30` カバレッジ閾値・`L32` LTV・`L40` 借換条件）ため、逐次適用の刻み方で閾値の跨ぎ方が変わる。
4. **時点の恣意性**: 四半期モデルでは、期のどこで起きた事象かを表現できない。発表日と経済的有効日、対象期と判明時刻（vintage）を区別しないまま実装すると、「その時点で判断できたか」を問う分析が成立しない。

これらは実装後には切り分けが困難であり、実装前に契約として固定する必要がある。

## 決定

1. **イベントを 4 層（Observed Event / Interpreted Signal / Scenario Assumption / Applied Model Input）へ分離し、層を飛ばした変換を禁止する。**
   外部システムの belief は Interpreted Signal として受け取り、Scenario Assumption を経ずに Applied Model Input へ変換しない。belief の確信度をショックの大きさへ読み替えない（[イベント変換契約](../architecture/macro_event_contract.md) §2）。

2. **イベントの適用先を、`CCC` の `exogenous` 変数 7 個に限定する。**
   `ai_exp` / `capex_plan_shock_ex` / `spread_shock_ex` / `policy_rate` / `ext_demand_s2` / `ext_demand_s3` / `price_s1` のみを適用先とし、`control` 変数・`state` 変数へイベントを直接書き込まない（同 §4.1）。

3. **適用先を持たないイベント型を、既存の適用先へ近似・代理・スケーリングで寄せない。**
   `unmapped_target` として拒否し、必要な `_shock_ex` 変数の追加を #165 への差し戻し `D1`–`D4` として登録する。`unmapped_target` は「効果が無い」ではなく「モデルが構造上その事象を表現しない」ことを意味する（同 §4.5・§8）。

4. **観測値のない定性イベントで magnitude を捏造しない。**
   `magnitude_source`（`:observed` / `:disclosed` / `:derived` / `:assumed_default` / `:external_belief`）を必須属性とし、`:assumed_default` を含む結果は ±50% の感応度併記を義務づける。欠測を 0 に置き換えない（同 §3.2）。

5. **すべてのイベントを適用四半期の期首（[会計表](../models/capex_credit_cycle_stock_flow.md) §2.5 の期内処理順序ステップ 1）に一括適用し、期中適用・期内按分を行わない。**
   暦日は適用四半期の決定にのみ用い、モデル内部へ持ち込まない（[時間軸](../architecture/scenario_time_semantics.md) §3）。

6. **同一 `(期, 変数)` のイベントは「絶対 → 乗算 → 加算」の固定順で合成し、合成後の値を 1 回だけ適用する。**
   各クラス内は可換（和・積）であるため、結果はイベントの入力順に依存しない。逐次適用モードを提供しない。同一 `(期, 変数)` に絶対指定が 2 件以上ある場合はシナリオを拒否する（[イベント変換契約](../architecture/macro_event_contract.md) §5.2・§5.6）。

7. **公表日 `announced_at`・経済的有効日 `effective_from`・判明時刻 `known_at` を別属性として区別し、適用四半期の決定には `effective_from` のみを用いる。**
   割当規則は `:same_quarter` / `:next_quarter` / `:cutoff` の 3 種に限り、`:cutoff` の既定境界（当該四半期の第 2 月末日）は設定値として外部化し、境界近傍のイベントには ±1 期ずらしの併記を義務づける（[時間軸](../architecture/scenario_time_semantics.md) §4）。

8. **持続・減衰の時間形状を 6 種（`pulse` / `step` / `ramp` / `step_then_ramp` / `AR1_decay` / `path`）の離散式として明示する。**
   `AR1_decay` の減衰率は半減期から一意に決め、`ρ` を直接指定しない（同 §5）。

9. **制約違反・矛盾・重複を自動補正せず、構造化して拒否または警告する。**
   符号制約違反（例: 適用後の `policy_rate < 0`）はクリップせずシナリオを拒否する（[イベント変換契約](../architecture/macro_event_contract.md) §6.3。[ADR 0007](0007-sfc-integration-contract.md) の方針を継承）。

10. **入力イベント原本（`L1`・`L2`）と適用後入力（`L4`）を双方保存し、再現契約を `(model_version, contract_versions, scenario_id, scenario_version, event_set_hash, rule_version, initial_state_id, solver_settings)` の一致として定義する。**
    `event_set_hash` は `L3` を [ADR 0008](0008-real-rate-model-artifact-export.md) の RFC 8785 準拠正準化でハッシュする（同 §6）。

11. **イベント解釈・変換とモデル計算を別層に置く。**
    責務を event validation / interpretation / model-specific mapping / scheduling / execution / logging の 6 つに分け、責務 1–4 はモデルを実行せず、責務 5 はイベントを解釈しない。モデル層はニュース解釈も外部 API 呼び出しも行わない（同 §7）。

## 1. なぜ 4 層に分けるか

3 層（観測 / 仮定 / 適用）でも観測と仮定は分かれる。しかし `finance-checker` のような外部解釈層が存在する構成では、**「観測事実」と「観測事実からの解釈」を分ける層**が必要になる。

| 分けないと起きること | 例 |
|---|---|
| 解釈の誤りが観測の誤りと区別できない | 「CAPEX ガイダンスが下方修正された」という解釈が誤っていた場合、原典に遡って検証できるのは `L1` が独立に保存されているときのみ |
| 外部システムの更新が過去の分析を書き換える | belief が更新されるたびに `L2` が変わる。`L1` が固定されていれば、`L2` の版と分析結果を対応づけられる |
| 確信度が数量へ漏れる | `L2` の `confidence` を `L3` の `magnitude` へ機械的に写す実装が自然に見えてしまう |

`L2` を明示的な層として置くことで、**誤りの所在（観測 / 解釈 / 仮定 / 適用）を特定できる**。これは [ADR 0005](0005-keen-ai-explanation-contract.md) が観測・測定・推定・モデル出力を分離した根拠階層と同型の設計である。

## 2. なぜ適用先を外生変数 7 個に限定するか

[変数定義](../models/capex_credit_cycle_sectors_variables.md) §4.2 は、変数の役割（`state` / `control` / `exogenous` / `diagnostic`）を因果グラフのエッジ型から機械的に導出し、「シナリオショックの適用先は `exogenous` 変数、または `control` 変数に対応する `_shock_ex` 外生変数である」と規定している。この規定を運用規則へ落とすと、適用先は 7 個に確定する。

| `control` 変数へ直接書き込むと起きること |
|---|
| 当該変数を生成する行動方程式が無効化され、Q1–Q5 の「どの機構が結果を生んだか」が識別できなくなる |
| 内生反応と外生入力の二重計上が起きる（例: `lend_stance` を外生で下げつつ、`L33`（`spread → lend_stance`）の内生反応も同時に働く） |
| [分析契約](../models/capex_credit_cycle_analysis_contract.md) §5.3 の「`SH-CAPEX` は内生反応への**上乗せ**であって再指定ではない」という区別が失われる |

限定の代償は、表現できないイベント型が生じることである（貸出態度・借換条件・部門別価格・雇用計画）。これを近似で埋めず `unmapped_target` として拒否するのは、[責務境界](../models/capex_credit_cycle_model_boundaries.md) §5.6 が翻訳不能なイベントについて確立した規律（近似・代理・スケーリングによる適用を行わない）を、モデル内部の適用にも一貫させるためである。

## 3. なぜ期首一括適用か

| 方式 | 不採用の理由 |
|---|---|
| 期中適用（ステップ 2–8 の途中で差し替え） | [会計表](../models/capex_credit_cycle_stock_flow.md) §2.5 は、ステップ 4（資金制約と実行）がステップ 6・8 より前にあることを資金調達恒等式が**事前制約**として働く条件としている。期中適用は同一四半期でも適用位置により結果を変え、この条件を壊す |
| 期内按分（pro-rata） | 四半期フローは `SUM`、レートは `AVG`、ストックは `EOP` であり、按分の意味が変数の時点基準ごとに異なる。按分係数が観測に基づかない自由度になる |

期首一括適用により、「期中のどこで起きたか」の問題は**適用四半期の決定**へ完全に還元される。四半期の位置に応じた区別が必要な場合は、`:cutoff` 規則（四半期の前 2/3 までなら当期、以降は翌期）で表現する。

## 4. なぜ固定順合成か

`CCC` は閾値型の関数形を複数持つ。イベントを 1 件ずつ逐次適用すると、同一のイベント集合でも刻み方によって閾値の跨ぎ方が変わり、結果が変わる。

固定順合成（絶対 → 乗算 → 加算）は次の性質を持つ。

- **クラス内は可換**: 乗算は積、加算は和であり、順序に依存しない。
- **クラス間は固定**: 絶対指定が基準値を確定し、相対指定がその上に作用する。順序が一意に決まる。
- **結果は入力順に不変**: 上 2 点により、イベントの入力順・`Dict` の反復順に依存しない。

そのうえで、**同一 `(期, 変数)` の絶対指定が 2 件以上ある場合は拒否する**。どちらを優先するかの規則を置くと、シナリオ定義の誤りが規則によって隠蔽される。分析者がシナリオを修正すべき状況である。

なお、適用四半期が異なるイベントの順序は結果に影響するが、それは順序依存ではなくモデルの動学であり、排除の対象ではない。

## 5. 時間軸の扱い

| 論点 | 決定 | 根拠 |
|---|---|---|
| 内部時刻 | 整数インデックス `t` + 起点四半期 `period_zero` | `SimulationResult.variables` は `Vector{Float64}` であり暦を持てない。暦は `metadata` 予約キーへ（[責務境界](../models/capex_credit_cycle_model_boundaries.md) §5.7 の方式を継承） |
| 適用日の決定 | `effective_from` のみを用いる | 公表日と経済的有効日はずれる。両者を同一視すると、政策金利の決定日と適用日の差などが表現できない |
| 割当規則 | `:same_quarter` / `:next_quarter` / `:cutoff` の 3 種 | 連続的な重み付け（按分）を導入しないという決定 5 の帰結 |
| `cutoff_date` | 第 2 月末日（暫定既定値、外部化） | 理論から導かれた値ではないため、境界近傍では ±1 期ずらしの併記を義務づける（[分析契約](../models/capex_credit_cycle_analysis_contract.md) §4.4 の閾値感応度と同型） |
| vintage | `period` と `known_at` の 2 軸。実行モードを `:as_of` / `:latest` に分け、必ず記録する | 最新 vintage での結果を「その時点で判断できた」と述べないため |

`DataSeries` は vintage 軸を型として持たない。本 ADR は **`DataSeries` 型を変更しない**ことを決め、vintage の保持方式（`metadata` か vintage 別系列か）を #170 へ委ねる。既存モデル・前処理・比較 API への非破壊を優先する（[ADR 0007](0007-sfc-integration-contract.md) の非破壊方針）。

## 6. 再現性の定義

再現契約は次の一致として定義する。

```
(model_version, contract_versions, scenario_id, scenario_version,
 event_set_hash, rule_version, initial_state_id, solver_settings)
```

- `event_set_hash` は `L3`（Scenario Assumption）の集合を正準化してハッシュする。`L1`・`L2` の表記揺れが hash を変えないようにするためであり、`L1`・`L2` は監査のために別途保存する。
- 正準化は [ADR 0008](0008-real-rate-model-artifact-export.md) の RFC 8785 準拠実装を再利用する。新たな正準化方式を作らない。
- 初期MVPは決定論であり乱数を用いないため seed は不要。将来、確率的イベント生成を導入する場合は `scenario_seed` を必須 metadata とし、seed 無しの確率的シナリオを実行しない。
- 浮動小数点の再現性は同一環境・同一 Julia バージョンを前提とする。環境を跨いだ bitwise 一致は契約しない。

## 7. versioning

| version | 対象 | 上げる条件 |
|---|---|---|
| `macro-event-contract/x.y.z` | イベント属性スキーマ・イベント型マッピング・合成規則 | 属性の追加/削除、適用先の変更、合成規則の変更 |
| `scenario-time-semantics/x.y.z` | 時間軸・割当規則・時間形状 | 割当規則の追加、`cutoff_date` の既定値変更、時間形状の追加 |
| `rule_version` | `L2 → L3` / `L3 → L4` の変換ルール実装 | 既定値セット・導出式の変更 |
| `timing_rule_set` | 割当規則の設定値 | `cutoff_date` 等の設定値変更 |

**契約**: `cutoff_date` の既定値変更のように、コード変更を伴わずに結果を変えうる設定は、必ず version を持つ。無記録で結果が変わる経路を残さない。

## 理由

- **誤りの所在を特定できる設計を優先した**: 4 層分離は変換の正しさを保証しない。保証するのは、誤ったときにどの層の誤りかを特定できることである（§1）。
- **表現できないことを表現できないと言う**: 適用先の限定と `unmapped_target` の返却は機能の不足に見えるが、近似適用は「効果が小さい」という誤った結論を生む。[責務境界](../models/capex_credit_cycle_model_boundaries.md) §5.6 が翻訳不能なイベントについて確立した規律と同じ根拠である（§2）。
- **経路依存を構造的に排除した**: 閾値型の関数形を多数持つモデルでは、適用順序の規約を文書で定めるだけでは不十分で、合成を可換にする設計が要る（§4）。
- **時点の恣意性を隠さない**: `cutoff_date` は暫定既定値であり、境界近傍での感応度併記を義務づけることで、恣意性を結果の頑健性の問題として可視化する（§5）。
- **既存資産を変更しない**: `SimulationResult`・`DataSeries`・既存モデルの型と API を一切変更せず、`metadata` 予約キーと新規層の追加のみで成立させた（[ADR 0002](0002-minsky-integration-design.md)・[ADR 0007](0007-sfc-integration-contract.md) と同方針）。

## 見送りとした選択肢

- **3 層（観測 / 仮定 / 適用）とする**: 外部解釈層（`finance-checker`）が存在する構成では、観測と解釈の誤りを切り分けられない（§1）。
- **belief をショック量へ直接変換する**: 確信度と規模は別概念であり、確信度 0.8 が「`-8%`」を意味する根拠は無い。#125 が明示的に禁じている。
- **`control` 変数へ外生入力を書き込めるようにする**: 行動方程式が無効化され、内生反応との二重計上が起きる。判定問題 Q1–Q5 の識別が失われる（§2）。
- **適用先が無いイベントを近い変数へスケーリングして適用する**: 例えば貸出態度の厳格化を `spread_shock_ex` で代替すると、`L33`（`spread → lend_stance`）の内生反応と二重計上になる。
- **欠測 magnitude を 0 とする**: 0 は「変化なし」という別の主張であり、欠測とは異なる。
- **`confidence` に比例して magnitude を縮小する**: 確信度の低いイベントを小さいショックとして扱うと、「不確実だが大きい」事象を表現できない。確信度が低い場合は、規模を縮小するのではなくシナリオに含める/含めないの両方を実行する。
- **期中適用・期内按分を許す**: 資金調達恒等式が事前制約として働く条件が壊れ、按分係数が観測に基づかない自由度になる（§3）。
- **逐次適用モードを提供する**: 閾値型の関数形により結果が刻み方に依存する（§4）。
- **同一 `(期, 変数)` の絶対指定の競合に優先規則を置く**: シナリオ定義の誤りが規則で隠蔽される。拒否して分析者に修正させる。
- **符号制約違反を自動クリップする**: 「指定したショックが適用された」という誤った記録が残る（[ADR 0007](0007-sfc-integration-contract.md) の不整合を自動補正しない方針）。
- **`SimulationResult` にイベント情報のフィールドを追加する**: 既存 8 モデル以上に依存される型の破壊的変更になる。`metadata` 予約キーとイベントログで同じ情報を保持できる。
- **`DataSeries` に vintage 軸を追加する**: 既存の前処理・比較・実証層すべてに影響する。#170 が `metadata` か vintage 別系列かを選ぶ。
- **LLM でイベントを抽出してそのままシナリオ化する**: `L1 → L2` の自動化自体は将来ありうるが、`L2 → L3` の仮定設定を自動化すると、仮定と観測の区別が出力から失われる。

## 影響

- **既存コードへの影響は無い**。本 ADR は既存モデル・`SimulationResult`・`DataSeries` の型・API・出力キーの変更を求めない。実装（#171）が新規層を追加する時点で初めてコード変更が生じる。
- **#169（動学方程式）** は、適用先 7 変数以外に外生入力を作らない。`control` 変数へ外生入力を直接書き込む実装を行わない。受注キャンセルイベントについては、キャンセルと延期の配分を行動方程式側で決める（[イベント変換契約](../architecture/macro_event_contract.md) §4.4。#166 §6.1 の閉じ変数指定と整合）。合成後の値が閾値近傍にある場合の `threshold_proximity` 診断を診断層へ実装する。
- **#170（観測・検証）** は、`:assumed_default` の magnitude と §4.3 の暫定 `duration` / `half_life`、`cutoff_date` の既定値を較正対象として受け取る。vintage の保持方式（`DataSeries` を変更せずに `known_at` を扱う方法）を決める。
- **#171（統合）** は、`AbstractMacroEvent` 相当の型・6 責務の API・イベントログ・再現契約のテストを実装する。`metadata` 予約キー（`event_contract_version` / `event_rule_version` / `period_zero` / `period_labels` / `shock_origin_index` / `data_as_of`）を追加する。
- **#165（変数定義）** は差し戻し事項 `D1`–`D3`（`price_shock_ex_s2` / `_s3`・`lend_stance_shock_ex`・`rollover_shock_ex` の追加要否）を受け取る。`D4`（雇用計画改定を独立入力としない設計）の妥当性は #163 で確認する。
- **外部プロジェクト**: `economic-data-provider` は `L1` と観測系列を、`finance-checker` は `L2` を提供する層として位置づけられる。DME 側は belief を `L3` を経ずに適用しない。
- **LLM 説明層** は、`magnitude_source` に基づく観測と仮定の区別、`:assumed_default` の感応度併記、`unmapped_target` / `untranslatable` を「影響が無い」と述べない規律、相殺（`offsetting_events`）と集約カバレッジの明示を、[llm_safety.md](../llm_safety.md) の必須記載と併せて適用する。

## 参考

- [マクロイベント変換契約](../architecture/macro_event_contract.md) — 本 ADR の詳細設計。概念階層・共通属性・イベント型マッピング表・競合規則・再現性・API 境界
- [シナリオ時間軸の意味論](../architecture/scenario_time_semantics.md) — 本 ADR の詳細設計。内部時刻・期内適用位置・日付割当・時間形状・vintage
- [部門別CAPEX・信用循環モデル 分析契約](../models/capex_credit_cycle_analysis_contract.md) — シナリオ `Sc0`–`Sc4`・ショック指定必須 7 項目・閾値感応度の義務
- [部門別CAPEX・信用循環モデル 因果グラフ](../models/capex_credit_cycle_causal_graph.md) — エッジ型・遅れ・閾値型の所在・`EXT` エッジ
- [部門別CAPEX・信用循環モデル 部門境界と変数定義](../models/capex_credit_cycle_sectors_variables.md) — 役割判定規則・外生変数・`_shock_ex` 命名規則・符号制約
- [部門別CAPEX・信用循環モデル ストック・フロー会計表](../models/capex_credit_cycle_stock_flow.md) — 期内処理順序・CAPEX 資金調達恒等式・キャンセル/延期の閉じ変数
- [部門別CAPEX・信用循環モデル 責務境界とモデル間比較契約](../models/capex_credit_cycle_model_boundaries.md) — イベント翻訳可否表・翻訳不能時の規則・`metadata` 予約キー方式
- [ADR 0005: Keen 実証結果の AI 説明契約](0005-keen-ai-explanation-contract.md) — 観測・測定・推定・モデル出力を分離する根拠階層の先行例
- [ADR 0007: SFC 統合契約](0007-sfc-integration-contract.md) — 不整合を自動補正せず構造化する方針・既存型への非破壊
- [ADR 0008: Real-rate model artifact 統合契約](0008-real-rate-model-artifact-export.md) — RFC 8785 正準化・UTC 固定
- [ADR 0009: 部門別CAPEX・信用循環モデルの責務境界](0009-capex-credit-cycle-model-responsibilities.md) — 独立モデルとする決定・翻訳可否表の確定
