# ADR 0021: Phase 3 の結果を claim-level / coverage 契約として downstream へ伝播し、未較正モデルの数値を日本の量として提示させない

- **ステータス**: 採用
- **日付**: 2026-09-19
- **関連Issue**: [#273](https://github.com/Yuki-Watanabe7/DME/issues/273)（Japan Fiscal Scenario Lab ロードマップ）・[#274](https://github.com/Yuki-Watanabe7/DME/issues/274)（capability audit。本決定の前提）・[#285](https://github.com/Yuki-Watanabe7/DME/issues/285)（本決定）・downstream [#275](https://github.com/Yuki-Watanabe7/DME/issues/275)・[#276](https://github.com/Yuki-Watanabe7/DME/issues/276)・[#277](https://github.com/Yuki-Watanabe7/DME/issues/277)。consumer: Yuki-Watanabe7/market-analyzer#283・#285・#286
- **前提ADR**: [ADR 0020](0020-japan-fiscal-scenario-capability-contract.md)（55 セルの representability・`claim_level` を較正基準に結び付ける決定・gap register 15 件）・[ADR 0014](0014-digital-twin-naming-conditions.md)（名乗る条件を先に固定し自己申告しない）・[ADR 0005](0005-keen-ai-explanation-contract.md)（根拠階層・禁止解釈）・[ADR 0006](0006-cross-model-reasoning-contract.md)（比較不能の非統合）
- **関連ドキュメント**: [claim-level / coverage 契約](../architecture/japan_fiscal_claim_level_contract.md)（本決定の詳細）・[capability / mapping 契約](../architecture/japan_fiscal_scenario_capability.md)（#274）・[LLM出力の安全性・免責・禁止表現ルール](../llm_safety.md)

---

## コンテキスト

#274 の capability audit により、Phase 3 の当初想定よりも重い構造的限界が確定した。

- `G-01` 利付き政府債務ストックを持つモデルが無く、債務残高/GDP・利払費・`r − g` 動学を返せない
- `G-02` 日本較正済みモデルが無く、`claim_level = :magnitude` を名乗れる mapping が 0 件
- `G-03` GDP 成長率パスを直接入力できるモデルが無い
- `G-04` 中央銀行の JGB 吸収を入力できるモデルが無い
- `G-14` 現在の長期金利 mapping は民間へのパススルーであり sovereign funding-cost leg ではない

#274 の registry には `claim_level`・未対応概念・未対応出力・`cannot_state` がすでに存在する。
しかし #275 と Market Analyzer 側の既存 Issue はこの監査より前に作られており、
**limitation が artifact と UI へ到達することが acceptance criteria に固定されていない**。

契約が文書の注意書きに留まると、次の読み替えが起こる。

1. family 名（「JGB funding-cost ショック」）だけが表示され、sovereign leg が覆われていないことが伝わらない。
2. 未較正モデルの数値が「日本の GDP が X% 変化する」「JGB 利払費が Y 増える」として読まれる。
3. 静学モデル（IS-LM・AD-AS・Mundell-Fleming）の均衡 1 点解に、peak / onset / duration の時間軸 UI が当てられる。
4. 受け取れなかった assumption（例: 中央銀行の JGB 吸収）が silent ignore され、全概念が効いたと解釈される。
5. 将来どこかのモデルが日本較正されたときに、consumer 側が `claim_level` を暗黙に昇格させる。

## 決定

1. **`claim_level` を「artifact が主張してよい診断」と「数値系列に付ける意味づけ」の 2 つに機械可読へ展開する。**
   `JapanFiscalClaimLevelSpec` が `permitted_diagnostics`（`JAPAN_FISCAL_DIAGNOSTICS` の部分集合）と
   `numeric_semantics`（`:none` / `:model_unit_relative` / `:normalized_deviation` / `:japan_magnitude`）を持つ。
   上位段階が下位段階の診断を包含することを登録時に検査する。`forbidden_diagnostics` はフィールドとして
   二重保持せず補集合として導出する。

2. **現在の 55 セルに `claim_level = :magnitude` が 0 件であることを load 時 invariant として検査する。**
   同時に `numeric_semantics = :japan_magnitude` の coverage も 0 件、`calibration_geography = :jp` も 0 件である。
   これはテストだけでなくパッケージ読み込み時に落ちる不変条件とし、誤って解禁されたまま出荷されない状態にする。

3. **representability（表現可能性）と coverage（被覆）を別々のフィールドとして追跡する。**
   `JapanFiscalCoverage` が required / accepted / unsupported concepts、required / produced / unsupported outputs、
   covered / uncovered channels、`calibration_basis` / `calibration_geography`、`cannot_state` / `major_caveats` /
   `gap_ids` を保持する。すべて #274 registry からの**導出**であり、手書きの二重 registry を持たない。

4. **family と同じ粒度で因果チャネルを宣言し、何が覆われていないかを機械可読にする（`JapanFiscalChannel`、25 本）。**
   `:covered` / `:partially_covered` / `:unsupported` の 3 値。`:unsupported` は `covered_by` が空であることと
   `limitation`（覆われていない内容）が非空であることをコンストラクタで強制する。
   `covered_by` はその family の採用モデルに限る。各 family に `:unsupported` が最低 1 本残ることを登録時に検査する。

5. **`family_complete` を coverage に持たせ、現在の 55 セルすべてで `false` であることを invariant とする。**
   全 family に `:unsupported` のチャネルが残るため真になるセルは無い。これは未実装の placeholder ではなく
   監査結果そのものであり、`false` の結果を family 完全な結果として提示しないことを consumer 規則にする。

6. **未較正モデルの数値系列は保持してよいが、ラベルを `numeric_semantics` に従わせる。**
   deterministic なモデル出力としての保持は禁じない。禁じるのは「日本の実現幅・予測幅」「日本 GDP が X%」
   「JGB 利払費が Y」というラベルである。`:japan_magnitude` は `calibration_geography = :jp` のときのみ許す。

7. **契約を文書ではなく実行時の検証関数として提供する（`japan_fiscal_validate_claims`）。**
   違反コード 7 種（`:diagnostic_not_permitted` / `:numeric_semantics_exceeds_claim` /
   `:magnitude_without_japan_calibration` / `:unsupported_concept_hidden` / `:unsupported_output_hidden` /
   `:forbidden_claim_kind` / `:family_presented_as_complete`）を返す。#276 は artifact 生成前にこれを実行し、
   違反があれば artifact を生成しない。未対応概念・未対応出力を**開示しなかった**場合も違反とし、
   silent ignore を検出する。

8. **禁止する主張を 8 種の語彙として固定する（`JAPAN_FISCAL_FORBIDDEN_CLAIM_KINDS`）。**
   forecast・probability・crisis_probability・default_probability・japan_realized_magnitude・
   observed_outcome・investment_recommendation・debt_sustainability_judgment。
   それぞれに禁止理由を持たせ、語彙と理由の対応が漏れないことを登録時に検査する。

9. **downstream handoff requirements を 22 件（`H-01`–`H-22`）の宣言的レジストリとして持つ。**
   対象は #275（scenario schema）5 件・#276（result artifact）7 件・#277（E2E / fixture）4 件・
   consumer（Market Analyzer）6 件。各件が `requirement` / `rationale` / `verification` を持ち、
   「どう検証するか」を要件と同じレコードに書く。文書の箇条書きではなく引ける形にする。

10. **`claim_level` 昇格の version 規則を先に固定する（`JAPAN_FISCAL_CLAIM_UPGRADE_RULE`）。**
    昇格には日本較正の実装・テスト・デモが要り、`JAPAN_FISCAL_CAPABILITY_CONTRACT_VERSION` と
    `JAPAN_FISCAL_CLAIM_CONTRACT_VERSION` の**両方**を上げる。consumer による暗黙昇格を禁じ、
    `claim_level` は artifact から読む値であって推論する値ではないと定める。

11. **#274 の registry・モデル方程式・既存 API を変更しない。本契約は #274 の上に載る導出層である。**
    `JAPAN_FISCAL_MODEL_MAPPINGS` の判定も `japan_fiscal_capability_matrix()` の出力も変えない。

12. **consumer 向け export を `japan_fiscal_downstream_contract()` の 1 本に集約する。**
    `japan_fiscal_capability_matrix()`（#274）は変更せず並置する。Market Analyzer は Julia 内部型を
    import せず、この Dict と #276 の result artifact のみを consume する。

## 理由

- **limitation は「伝わらなければ無い」のと同じ**。#274 が正しく判定していても、artifact と UI へ届かなければ
  利用者は family 名と数値だけを見る。伝播を acceptance criteria として固定する必要がある。
- **load 時 invariant はテストより強い**。`:magnitude` 0 件をパッケージ読み込み時に検査すると、
  テストを実行しない経路（スクリプト・デモ・他リポジトリからの利用）でも保証が効く。
- **導出は二重保持より壊れにくい**。coverage を #274 registry から導出することで、判定を更新したときに
  artifact 契約が自動で追随する。ADR 0020 決定 2（representability を導出値として強制する）と同じ設計判断。
- **チャネルは family 名の過大解釈を直接打ち消す**。「何を含むか」ではなく「何を含まないか」を
  family と同じ粒度で宣言すると、`family_complete = false` が具体的な意味を持つ。
- **検証関数は実装者の記憶に依存しない**。#276 の実装者が `claim_level` の意味を毎回読み直さなくても、
  `japan_fiscal_validate_claims` が違反を返す。ADR 0015 決定 3（層飛ばしを型で禁じる）と同型。
- **昇格規則を先に固定するのは ADR 0014 と同じ理由**。条件を後から決めると、較正が「部分的に」進んだ時点で
  緩められる。

## 見送りとした選択肢

- **#274 の registry に claim 契約のフィールドを直接足す**: #274 は「モデルで何が表現できるか」の監査であり、
  本契約は「結果をどう提示してよいか」の規則である。混ぜると、監査結果の更新と提示規則の更新が
  同じ version で動くことになり、consumer が変更の性質を区別できない。version を分けた。
- **`claim_level` を文書の注意書きとしてだけ持つ**: #285 が解こうとしている問題そのもの。
  文書は artifact にも UI にも自動では届かない。
- **未較正モデルの数値系列を artifact から削除する**: 数値そのものは deterministic なモデル出力であり、
  再現性・デバッグ・寄与分解に必要。削除ではなくラベル（`numeric_semantics`）で制御する。
- **`family_complete` を廃し「partial」フラグだけにする**: どのチャネルが欠けているかが分からず、
  「JGB funding-cost の sovereign leg が無い」という具体性が失われる。
- **consumer 規則を Market Analyzer 側の Issue にだけ書く**: producer 側に規則が無いと、
  artifact が規則を満たす形になっているかを DME 側で検証できない。`H-17`–`H-22` を DME に置き、
  consumer fixture（#277）で検証可能にした。
- **`:magnitude` を語彙から削除する**: 将来の日本較正で必要になる。削除ではなく、
  `calibration_basis = :japan_calibrated` との結び付きと昇格規則で 0 件を担保した。

## 影響

- **`src/scenarios/japan_fiscal_claim_contract.jl` を新設する**（型 6 種・語彙 8 種・registry 4 種・
  照会/検証 API 13 種）。`src/DME.jl` の include と export のみを変更する。
- **#274 の `japan_fiscal_capability.jl`・モデル方程式・`SimulationResult`・イベント層 API は変更しない**。
  既存テスト・既存 artifact の数値互換に影響しない。
- **#275 は `H-01`–`H-05` を満たす**。catalog は #274 registry から引き、artifact identity に両 version を含め、
  欠測と 0 を区別し、`magnitude_source` を検査し、FRE context を assumption と別構造にする。
- **#276 は `H-06`–`H-12` を満たす**。`japan_fiscal_coverage` の全フィールドを artifact へ保持し、
  生成前に `japan_fiscal_validate_claims` を実行する。
- **#277 は `H-13`–`H-16` を満たす**。`:magnitude` 0 件・serialization での limitation 保持・
  negative fixture・consumer fixture の公開。
- **Market Analyzer #283 / #285 / #286 は `H-17`–`H-22` を満たす**。`claim_level` の暗黙昇格禁止、
  limitation の同一画面表示、`numeric_semantics` ラベル、未被覆チャネルの明示、
  sovereign / private と observed / assumed / model_implied の区別、禁止主張の非表示。
- **日本較正（`G-02`）・日本 financial-stress 系列（`G-15`）・政府債務モデル（`G-01`）は引き続き対象外**。

## 参考

- [claim-level / coverage 契約](../architecture/japan_fiscal_claim_level_contract.md) — claim level 4 段階・coverage フィールド・因果チャネル 25 本・handoff requirements 22 件・昇格規則
- [capability / mapping 契約](../architecture/japan_fiscal_scenario_capability.md) — 55 セルの判定と gap register（本契約の前提）
- [ADR 0020](0020-japan-fiscal-scenario-capability-contract.md) — `claim_level` を較正基準に結び付ける決定
- [ADR 0014](0014-digital-twin-naming-conditions.md) — 名乗る条件を先に固定し自己申告しない
