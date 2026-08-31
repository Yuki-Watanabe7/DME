# ADR 0018: 実証層を 7 段の一方向データフローとして実装し、catalog を DME 内の正本とし、観測から作れない量を型で区別し、履歴再生をイベント実行層の API を変えずに構成する

- **ステータス**: 採用
- **日付**: 2026-09-01
- **関連Issue**: #125（ロードマップ）・#240（本決定・実データ接続/較正/履歴再生の統合設計と実装契約）・#170（観測方程式・識別戦略・検証方針）・#171（`CCC` 統合設計）・#196（イベント・シナリオ実行層 統合設計）・後続 #241–#251（実装）
- **前提ADR**: [ADR 0004](0004-keen-empirical-calibration-strategy.md)（指数/比率の検証義務・固定/推定分離・ODE residual）・[ADR 0005](0005-keen-ai-explanation-contract.md)（根拠階層）・[ADR 0007](0007-sfc-integration-contract.md)（不整合を自動補正せず構造化・既存型へ非破壊）・[ADR 0008](0008-real-rate-model-artifact-export.md)（RFC 8785 正準化）・[ADR 0009](0009-capex-credit-cycle-model-responsibilities.md)（`SimulationResult` 非変更）・[ADR 0011](0011-capex-credit-cycle-dynamics-contract.md)（逆較正・baseline を成長率ゼロの定常状態とする）・[ADR 0012](0012-capex-credit-cycle-empirical-contract.md)（実証化契約 24 決定）・[ADR 0013](0013-capex-credit-cycle-integration-contract.md)（統合実装契約）・[ADR 0014](0014-digital-twin-naming-conditions.md)（名称の使用条件）・[ADR 0015](0015-macro-event-runtime-contract.md)（失敗 3 層・hash 対象の明示・`:as_of` 非実装）
- **関連ドキュメント**: [部門別CAPEX・信用循環モデル 実証統合設計](../architecture/capex_credit_cycle_empirical_integration.md)（本 ADR の詳細設計）・[観測方程式・識別戦略・検証方針](../models/capex_credit_cycle_empirical_strategy.md)・[部門別CAPEX・信用循環モデル 統合設計](../architecture/capex_credit_cycle_integration.md)・[イベント・シナリオ実行層 統合設計](../architecture/macro_event_runtime_integration.md)

## コンテキスト

[ADR 0012](0012-capex-credit-cycle-empirical-contract.md) と #170 は、部門別CAPEX・信用循環モデル（`CCC`）を実データへ接続する際の観測可能性の分類・観測方程式の要件・パラメータ区分・推定ブロック・弱識別対応・履歴再生の必要条件・検証契約を確定した。しかしこれらは**設計であって実装契約ではない**。Julia の型・API 名・ファイル配置・失敗の返し方・artifact の identity・provider との境界は未確定のままだった。

その後、`CCC` のモデル層（#179–#186）とイベント・シナリオ実行層（#197–#205）の実装が完了し、DME 既存データ層には `DataSeries` と 3 つの取得モード（`:fixture` / `:live` / `:rest_api`）がある。この状態で実証層の実装へ進むと、次の失敗様式が具体的に起こりうる。

1. **観測から作れない量を「較正した」と申告する**。逆較正が要求する定常水準は 48 キーあるが、そのうち `cost_capital_s`（潜在）・`cons_s1`（配分仮定）・`capex_pipe_s`（潜在）は公表系列に対応が無い。区別する仕組みが無ければ、literature 値や仮定で埋めた値が観測較正値と同じフィールドに並び、事後に区別できなくなる。
2. **`CAL-OBS` の構造パラメータを注入できない**。`capex_credit_cycle_model` は `behavioral` と `policy` しか受け付けず、`st_cash_min_s`・`st_cshare_s3`・`st_dcap_s` の倍率などがハードコードされている。注入経路が無ければ、較正層はモデル本体を書き換えるか、較正を諦めるかのどちらかになる。
3. **provider の未申告を確認済みとして扱う**。`economic-data-provider`（`EDP`）の REST 応答は季節調整・基準年・vintage を返さない。fixture 経路（FRED 直読み）は季節調整を返す。この非対称を吸収するために catalog の宣言値で埋めると、#170 §4.1 が課した「一次資料で確認してから採用する」義務を provider 任せにしたことになる。
4. **`ext_demand_s` の残差方向が定まらないまま較正する**。#170 §15.4 は `ext_demand_s^{ss}` を残差とし、§5.2-9 と既存実装は `order_gen_s^{ss}` を残差とする。定常水準では両者の和のみが恒等式から決まり、分割は識別されない。どちらを残差にするかを実装者が選ぶと、`st_gen_share_s` と `st_extdem_s` の値が実装依存になる。
5. **推定対象が実装都合で増える**。#170 §15.2 は `EST` 総数を 37 とするが、`bh_emp_up_s4` / `bh_emp_down_s4` は対応する変数 `emp_s4` を持たない辞書上の空き値である。数え方が誤ったまま実装すると、観測も方程式も無いパラメータを最適化しようとする。
6. **履歴再生でイベント実行層の API を壊す**。履歴再生は外生変数を観測実現値で与える必要があるが、`run_scenario` は baseline を定常値から作る。`run_scenario` に baseline 差し替えの引数を足すと、イベント層の再現契約（`ScenarioProvenance`）の意味が変わる。
7. **検証が単一スコアへ潰れる**。RMSE を並べれば「良い / 悪い」を言いたくなる。型に総合スコアや `passed::Bool` があれば、必ず埋められ、参照される。
8. **artifact が再現しない**。`retrieved_at` の保存義務（#170 §2.4）と「2 回実行で canonical artifact が一致すること」（#251）は、hash 対象を決めない限り両立しない。

これらは実装後には切り分けが困難であり、実装前に契約として固定する必要がある。

## 決定

1. **契約と既存実装の差異 30 件を `Z-01`–`Z-30` として登録し、各件の解決先を「上流改訂 / 本決定 / 限界として保持」へ明示的に割り当てる。**
   暗黙に吸収した差異を残さない。上流改訂は #170 の改訂節（§16）として行い、改訂節を同書の正本とする（[実証統合設計](../architecture/capex_credit_cycle_empirical_integration.md) §2。#171・#196 の手続きを継承）。

2. **実証層を 7 段の一方向データフローとして実装し、後段が前段の値を書き換えない。**
   catalog → raw observation → measurement → empirical dataset → 較正/識別/推定 → 履歴再生 → 検証/robustness。データ層はモデル型を参照せず、較正層はモデル層へ数値のみを渡し、検証層は読み取り専用とする（同 §3）。`EDP` の不足を DME 側の直接 HTTP で迂回せず、cross-repo handoff として記録する。

3. **系列 catalog の正本を DME 内の versioned な Julia const（`CAPEX_CC_SERIES_CATALOG`）とし、provider catalog は照合用に限る。`source_kind` を `:official_statistic` / `:market_data` / `:firm_disclosure` の 3 値とし、`:firm_disclosure` が較正・推定の role を持つことを validator で拒否する。**
   [ADR 0012](0012-capex-credit-cycle-empirical-contract.md) 決定 6（企業開示を較正入力から除外）を、文書の規律ではなく型と validator で強制する。BEA NIPA の産業別法人利益のような**産業別集計統計は企業開示ではない**ことを語彙で区別する。catalog は宣言的レジストリ方式（`MACRO_EVENT_TYPE_REGISTRY` と同型）とし、TOML 等の新規依存を追加しない。

4. **provider が返さない metadata を `missing` として保持し、catalog の宣言値（`declared_*`）で埋めない。`declared_*` と `provider_*` を別フィールドに持ち、不一致を `metadata_mismatches` として記録するが取得は失敗させない。**
   確認していない事実を確認済みとして扱わない。fixture 経路と `:rest_api` 経路のメタ情報の非対称は、埋めるのではなく**未申告として可視化する**（`Z-01`）。

5. **`capex_credit_cycle_model` に非破壊の `structural::NamedTuple = NamedTuple()` を追加し、上書き可能な構造パラメータを `CAPEX_CC_STRUCTURAL_OVERRIDABLE` として明示列挙する。`CAL-SS`（逆較正で自由度なしに決まる系統）の上書き要求は例外とする。**
   `CAL-OBS` の構造パラメータを較正層から注入できるようにしつつ、閉形式導出を黙って壊す経路を作らない。既定を空とすることで既存の呼び出しと数値を変えない（`Z-09`）。

6. **逆較正が要求する 48 個の定常水準すべてに `source_kind ∈ {:observed, :derived, :literature, :assumption}` を付け、`:observed` でないキーを観測較正値として提示しない。**
   `cost_capital_s^{ss}`・`cons_s1^{ss}`・`capex_pipe_s^{ss}` は観測に対応が無いため、literature / assumption として算式つきで与える。`:literature` を名乗るには参照を必須とし、参照が無い場合は `:default_unattributed` とする（`Z-07`・`Z-08`・`Z-17`）。

7. **`ext_demand_s^{ss}` と `order_gen_s^{ss}` の分割が定常水準からは識別されないことを明記し、`st_gen_share_s` を標本全体での `order_s` の `y_s5` に対する比として先に与え、`ext_demand_s^{ss}` を残差とする識別仮定を固定する。**
   この選択を `allocation` methodology として記録し、`alternative proxy` 感応度の必須対象に加える。残差が負になる場合もクリップしない（[ADR 0012](0012-capex-credit-cycle-empirical-contract.md) 決定 16 の継承。`Z-12`）。

8. **方程式別残差 objective を推定層に閉じて実装し、モデル層へ単一方程式の公開 API を追加しない。残差関数名を #169 の式 ID と 1:1 対応させ、モデル 1 期実行の中間値との一致を回帰テストで保証する。**
   二重実装を避けるためにモデル層の内部を公開すると、`simulate` が系列のみを返すという契約（[ADR 0013](0013-capex-credit-cycle-integration-contract.md) 決定 12）と `src/models/` の責務が崩れる。二重実装を許し、**一致をテストで統制する**方を選ぶ（`Z-15`）。

9. **弱識別対応を「事前適用」と「事前固定・事後発火」の 2 段に分ける。`W1` / `W4` は dataset と catalog から推定前に判定して `EST` から外し、`W2` / `W3` は適用先と閾値を推定前に config へ固定して発火の有無のみ推定後に決める。**
   #170 §8.3 は「規則を推定前に割り当てる」と契約する一方、同節の検出方法（曲率・相関・境界張り付き）は推定後の情報である。この矛盾を 2 段化で解く。閾値を変更する場合は config version を上げ、変更前後を両方保存する（`Z-16`）。

10. **履歴再生を `run_scenario` ではなく、(1) 観測実現値からの baseline 外生構築 → (2) `schedule_events` + `compose_exogenous_paths` → (3) `capex_run` の 3 段で構成する。イベント実行層の公開 API を変更しない。**
    `compose_exogenous_paths(baseline, inputs, periods; assumptions)` は baseline を引数で受けるため、既存 API の変更を要しない。戻り値は `ScenarioRun` ではなく `CapexHistoricalReplayRun` とし、`ScenarioProvenance` の意味を変えない（`Z-18`）。

11. **履歴再生の助走 8 四半期の外生を定常値に固定し、評価区間のみ実現値パスを与える。`runup_tol` を緩めて回避しない。**
    モデルは定常状態から出発するため、助走で外生が動けば `runup_deviation` が必ず発生する。閾値を結果に合わせて緩める代わりに、**非対称性を `exog_runup_mode` として記録し、比較を baseline 比乖離 `dx_t` で行う**（`Z-19`）。

12. **履歴 episode は `ObservedEvent`（`L1`）と `ScenarioAssumption`（`L3`）を別フィールドで保持し、`L2` の解釈を人手入力として記録する。`L1` から `L3` を自動生成しない。**
    [ADR 0010](0010-macro-event-scenario-contract.md) 決定 1 の層飛ばし禁止を履歴再生にも適用する。観測に magnitude が無いイベントは `L1` に magnitude を書かず、`L3` で `magnitude_source = :assumed` として与える（`Z-20`）。

13. **`data_vintage` を provider が申告した値とし、未申告のときは `"unknown"` とする。`vintage_mode` の許容値を `:latest_only` の 1 値のみとする。**
    `EDP` が vintage を返さない以上、`"latest"` と書くことは確認していない事実の申告になる。`:as_of` を語彙へ先取りせず、実装しないことを型で表現する（[ADR 0012](0012-capex-credit-cycle-empirical-contract.md) 決定 8 の継承。`Z-21`）。

14. **`EB-6` の `EST` を 9 個へ、`EST` 総数を 35 個へ修正する。`bh_emp_up_s4` / `bh_emp_down_s4` / `bh_emp_band_s4` を推定・較正・感応度のいずれの対象にもしない。**
    モデルに `emp_s4` は存在せず、`st_lprod_s4` / `st_wbase_s4` と同じ辞書上の空き値である。対応する方程式も観測も無いパラメータを最適化しない（`Z-14`）。

15. **標本端点を `role == :calibration_required` の系列の inner join のみで決める。`:estimation_input` の欠損は標本を縮めず、当該推定ブロックを実行しないことで扱う。**
    #170 §2.2 は「較正必須系列」で端点を決めるとしながらその集合を定義していない。catalog の `role` を 4 値（`:calibration_required` / `:estimation_input` / `:validation_only` / `:diagnostic_only`）として定義を与える（`Z-29`）。

16. **失敗を例外 / 構造化拒否 / 警告の 3 層へ分離し、段ごとのステータス語彙を固定する。値の増加を伴う新しい失敗の種類は本 ADR の改訂としてのみ行う。**
    `:missing_series` / `:unavailable_upstream` / `:provider_error` / `:invalid_response` を同一視しない。`:not_identified`（構造的に識別できない）と `:insufficient_data`（データが足りない）も同一視しない（[ADR 0015](0015-macro-event-runtime-contract.md) 決定 6・15 の継承）。

17. **検証を 7 dimension へ分離し、総合スコア・`passed::Bool`・診断ラベル一致率・公式景気後退判定との一致率のフィールドを型に作らない。**
    フィールドがあれば埋められ、参照される。単一 pass/fail を課さないという契約（[ADR 0012](0012-capex-credit-cycle-empirical-contract.md) 決定 22）を、文書の規律ではなく**型の欠如**で担保する。`E` / `A` 分類の変数には `:not_applicable_latent` を返し metric を `nothing` にする。`P` / `allocation` 系列には `evidence_tier` を必須で添える。

18. **観測から `A`（増幅度）を計算するフィールドを型に作らない。`credit_amplification` はモデル内 `credit-off` 反実仮想の値のみを保持する。**
    [ADR 0012](0012-capex-credit-cycle-empirical-contract.md) 決定 18 の継承。履歴再生では信用条件が悪化した局面と安定な局面で**モデルの `A` が異なるか**を報告し、観測の増幅を推定したとは述べない（`Z-23`）。

19. **robustness を 1 軸ずつ（one-axis-at-a-time）実行することを既定とし、多軸同時走査・best-fit 仕様の自動採用・確率への変換を行わない。失敗 variant を黙って除外しない。**
    各 variant が baseline から何を 1 点だけ変えたかを artifact へ保存し、帰属可能性を保つ。観測されていない magnitude の走査は「推定誤差」ではなく `scenario assumption sensitivity` として表現する。

20. **`SimulationResult` 型と `CCC` の metadata 予約キー 20 個を変更しない。実証層の情報は実証層の結果型が並置して保持する。**
    モデル層が実証層を知らない構造を維持する（[ADR 0009](0009-capex-credit-cycle-model-responsibilities.md) 決定 8・[ADR 0013](0013-capex-credit-cycle-integration-contract.md) 決定 13 の継承。`Z-25`）。

21. **artifact の identity を 5 種の hash（`dataset_hash` / `targets_hash` / `parameter_set_hash` / `episode_hash` / `replay_hash`）で連結し、hash 対象フィールドを明示列挙して `retrieved_at`・`provider_base`・実行時刻・`mode` を除外する。**
    正準化は既存の `canonical_json_bytes`（RFC 8785）と `sha256_hex_of_canonical` を変更せず再利用する。`retrieved_at` の保存義務と決定的再現の両立を、保存はするが hash には含めないことで解く（[ADR 0015](0015-macro-event-runtime-contract.md) 決定 13 の継承。`Z-26`・`Z-27`）。

22. **実証 fit を因果妥当性・景気後退確率・投資助言・「その時点での判断可能性」へ読み替えない。検証出力の `caveats` 8 件を必須とし、LLM 説明層へ引き渡す。**
    point-in-time replay ではないこと・`P` / `allocation` と direct 観測の区別・弱識別パラメータの扱い・企業開示を較正入力に用いていない範囲・`SH-EXP` の規模が走査結果であること・観測とモデルの `dx_t` の非対称性を必ず添える（[ADR 0012](0012-capex-credit-cycle-empirical-contract.md) 決定 24・[ADR 0014](0014-digital-twin-naming-conditions.md) の名称条件の継承）。

---

## 1. なぜ catalog を DME 内の正本にするか

#170 §4.1 は「系列 ID は候補であり、存在・定義・単位・基準年・季節調整を provider metadata または一次資料で確認してから採用する」という義務を課している。この義務の主体は DME 側の設計者である。

provider catalog を正本にすると、(a) provider が系列を差し替えたときに DME の観測方程式が黙って変わる、(b) 「どの系列を選んだか」の決定履歴が DME 側に残らない、(c) provider が返さない項目（季節調整・基準年・vintage）について宣言する場所が無くなる、という 3 つの問題が生じる。

DME 内の versioned な const を正本とし、provider catalog を照合に使えば、不一致は `metadata_mismatches` として可視化され、系列の変更は catalog の版として記録される。これは `MACRO_EVENT_TYPE_REGISTRY`（イベント型 9 種を宣言的レジストリで持つ）と同じ方式であり、リポジトリの既存の作法に合う。

## 2. なぜ観測から作れない量を型で区別するか

逆較正は 48 個の定常水準を**必須**とする（`_ccc_validate_target_keys` が欠損を例外にする）。一方 #170 §3.2 は、そのうち `cost_capital_s`・`capex_pipe_s` を `E`（潜在）、`cons_s1` を `A`（観測不能・仮定）に分類している。

型で区別しなければ、literature 値と仮定値が観測較正値と同じ `NamedTuple` に並ぶ。較正結果を読む側にとって、`cost_capital_s1 = 8.0` が観測から来たのか文献から来たのかは**事後に判別できない**。`CapexTargetSpec.source_kind` を必須にすることで、48 キーそれぞれについて由来が artifact に残り、「観測から較正した」と申告できる範囲が限定される。

`:literature` に `reference` を必須とし、無い場合を `:default_unattributed` としたのは、出所を書けないものを「文献値」と呼ばないためである（`Z-17`）。

## 3. なぜ残差の方向を本 ADR で固定するか

定常水準の恒等式 `y_s = order_cap_s + order_inv_s + order_gen_s + ext_demand_s` は、`order_gen_s` と `ext_demand_s` の**和のみ**を決める。どちらを残差にするかは経済的な仮定であり、実装の都合で選ぶべきものではない。

#170 §15.4（改訂節・正本）と §5.2-9 が逆の方向を述べており、既存実装は §5.2-9 側である。放置すると、`P-4` の実装者が「実装に合わせる」か「正本に合わせる」かを自分で決めることになり、`st_gen_share_s` と `st_extdem_s` の値が実装依存になる。

本 ADR は「分割は識別されない」という事実を先に明記した上で、識別仮定（`st_gen_share_s` を標本全体の回帰から先に与える）を固定し、それを `allocation` として感応度の必須対象に入れる。**識別されていないものを識別されたように見せない**という #170 §1.2 の規律に沿う。

## 4. なぜ履歴再生でイベント層の API を変えないか

`run_scenario` の戻り値 `ScenarioRun` は `ScenarioProvenance`（再現契約タプル 11 項目）を持ち、「これらが一致するのに結果が異なればバグである」という契約を負っている。ここに「baseline 外生を差し替える引数」を足すと、同じ `ScenarioProvenance` で異なる結果が出る状態が生じ、再現契約が壊れる。

一方 `compose_exogenous_paths(baseline, inputs, periods; assumptions)` は既に baseline を引数で受ける純関数であり、これを再利用すれば **API の変更なしに**観測実現値ベースの外生パスを構成できる。履歴再生の結果型を `ScenarioRun` と別にすることで、理論シナリオの再現契約と履歴再生の再現契約を混同しない。

## 5. なぜ助走区間を定常固定にするか

`CCC` は定常状態から出発し、助走 8 四半期で定常に留まることを `runup_tol`（既定 `1e-8`）で検査する。実現値の `policy_rate` パスを助走へ与えれば、この検査は必ず失敗する。

選択肢は 3 つあった。(a) `runup_tol` を緩める、(b) 助走を定常固定にする、(c) 助走の観測から初期状態を推定する。(a) は「閾値を結果に合わせて緩める」ことであり #170 §10.5 が明示的に禁じている。(c) は状態推定であり #125 Phase 5 の範囲である。(b) を選び、**非対称性を隠さずに記録する**（`exog_runup_mode`）ことにした。比較は baseline 比乖離 `dx_t` で行うため、助走が定常であることは比較の妥当性を損なわない。

## 6. なぜ検証の型に総合スコアを置かないか

フィールドは埋められる。`passed::Bool` があれば、CI がそれを見る。総合スコアがあれば、レポートがそれを引用する。[ADR 0012](0012-capex-credit-cycle-empirical-contract.md) 決定 22 の「単一の pass/fail 閾値を課さない」を文書の規律として書くだけでは、実装時に「便利だから」追加される。

型に存在しなければ追加は本 ADR の改訂を要し、改訂の議論が発生する。同じ理由で、観測側の増幅度フィールド（決定 18）・診断ラベル一致率フィールド（決定 17）も作らない。これは「できないことをできないと言う設計」（[ADR 0015](0015-macro-event-runtime-contract.md) の方針）を、実証層の出力へ適用したものである。

## 7. versioning

| 契約 | version | 変更条件 |
|---|---|---|
| `capex-credit-cycle-empirical-integration/1.0.0` | 本書 | 型・API・ステータス語彙・hash 対象の変更 |
| `capex-credit-cycle-empirical/1.2.0` | #170 | 観測分類・観測方程式・パラメータ区分・推定ブロックの変更 |
| catalog version | `CAPEX_CC_SERIES_CATALOG` | 系列の追加・削除・`role` / `source_kind` / 9 項目の変更 |
| measurement contract version | measurement 層 | 変換式・頻度規則・アンカー方式の変更 |
| estimation config version | `CapexEstimationConfig` | `W2` / `W3` の閾値・objective・重み・seed の変更 |

**patch**: 記述の明確化・誤記修正。**minor**: 後方互換な追加（catalog への系列追加・新しい `caveats`）。**major**: ステータス語彙の値の変更・hash 対象の変更・型のフィールド削除。

## 理由

- **一方向のデータフローにした**（決定 2）: 後段が前段を書き換えられると、「どの値が観測でどの値が調整結果か」が追跡できなくなる。段の境界を型で区切ることで、artifact だけを見て由来を辿れる。
- **確認していない事実を型で表現した**（決定 4・13）: `missing` と空文字、`"unknown"` と `"latest"` を区別することで、「provider が返さなかった」ことが結果に残る。埋めてしまえば、後から区別する方法はない。
- **注入点を明示列挙して塞いだ**（決定 5）: `structural` を無制限に受け付ければ、逆較正の閉形式を黙って壊せる。`CAPEX_CC_STRUCTURAL_OVERRIDABLE` に限ることで、自由度なしの導出と較正可能な部分が構造的に分かれる。
- **識別されていない分割を先に宣言した**（決定 7）: 実装者が知らずに一方を選ぶ状況を作らない。感応度の必須対象に入れることで、選択の影響が必ず報告される。
- **二重実装を許してテストで統制した**（決定 8）: モデル層の内部を公開する代償（`simulate` の契約の破壊）より、残差関数の重複を一致テストで縛る代償の方が小さい。テストが落ちれば差分は検出される。
- **規則の事後選択を構造的に不可能にした**（決定 9）: 閾値を config に固定し、変更に version を要求することで、「結果を見て規則を選んだ」ことが記録に残る。
- **既存資産を変更しなかった**（決定 10・20）: `SimulationResult`・`DataSeries`・`to_quarterly`・`run_scenario`・`compose_exogenous_paths`・`scenario_comparison` の型と公開挙動を変えず、新規ファイルと 1 つの非破壊キーワード引数のみで成立させた（[ADR 0007](0007-sfc-integration-contract.md)・[ADR 0013](0013-capex-credit-cycle-integration-contract.md)・[ADR 0015](0015-macro-event-runtime-contract.md) と同方針）。
- **型の欠如で規律を担保した**（決定 17・18）: 総合スコア・観測側増幅度・ラベル一致率のフィールドを作らないことで、禁止事項が「守るべき規律」ではなく「書けないコード」になる。

## 見送りとした選択肢

- **provider catalog を正本にする**: 系列の差し替えが DME に無断で観測方程式を変える。#170 §4.1 の確認義務を provider 任せにすることになる（§1）。
- **catalog を TOML で持つ**: `TOML` は現行 `[deps]` に無く、依存の追加は本書の対象外である。JSON（`JSON3` は既存依存）または Julia const で足りる。宣言的レジストリは既にリポジトリの作法である。
- **provider が返さない metadata を catalog の宣言値で埋める**: 「確認した」と「宣言した」が同一フィールドに入り、事後に区別できない（§2 と同じ理由）。
- **`capex_credit_cycle_model` の `structural` を無制限にする**: `CAL-SS` の閉形式導出を黙って壊せる。定常条件違反として後段で検出されるが、なぜ違反したのかが分からない。
- **モデル層に単一方程式の公開 API を追加する**: `simulate` が系列のみを返すという契約と `src/models/` の責務（[ADR 0013](0013-capex-credit-cycle-integration-contract.md) 決定 12）が崩れる。期内 10 ステップの内部状態を公開すると、実装の変更が公開 API の変更になる。
- **残差関数を持たず `capex_run` の出力から objective を作る（trajectory matching）**: [ADR 0012](0012-capex-credit-cycle-empirical-contract.md) 決定 13 が非線形・閾値による目的関数の不連続を理由に不採用としている。
- **`run_scenario` に baseline 差し替え引数を追加する**: `ScenarioProvenance` の再現契約が壊れる（§4）。
- **`runup_tol` を履歴再生で緩める**: 閾値を結果に合わせて緩めることであり、#170 §10.5 が明示的に禁じている（§5）。
- **助走区間の観測から初期状態を推定する**: 状態推定であり #125 Phase 5 の範囲。逆較正で定常状態を与えるという [ADR 0011](0011-capex-credit-cycle-dynamics-contract.md) の設計とも整合しない。
- **`L1` から `L3` を生成するヘルパを履歴再生に限って提供する**: [ADR 0010](0010-macro-event-scenario-contract.md) 決定 1 の層飛ばし禁止に例外を作ることになる。履歴イベントこそ、観測事実と解釈の区別が重要である。
- **`vintage_mode` に `:as_of` を語彙として先に置く**: 実装しない値を語彙に置くと「いずれ対応する」と読まれ、`DataSeries` に vintage 軸が無いまま部分実装される余地が残る（[ADR 0012](0012-capex-credit-cycle-empirical-contract.md) 決定 8 の維持）。
- **`EST` 総数 37 のまま `bh_emp_*_s4` を推定対象にする**: 対応する変数も観測も方程式も無い。最適化しても objective に寄与せず、境界へ張り付くか初期値のまま残る。
- **検証に総合スコアと `passed::Bool` を置く**: 単一 pass/fail を課さないという契約が実装時に破られる（§6）。
- **robustness を多軸同時走査（grid search）にする**: 結果の差がどの軸に帰属するか分からなくなる。best-fit 仕様の自動採用は #170 §9.2-1 の「fit の良い期間を事後選択しない」と同じ理由で採らない。
- **`SimulationResult.metadata` に実証層のキーを追加する**: 既存 10 モデル以上に依存される型の契約変更になる。実証層の結果型で同じ情報を保持できる。
- **`retrieved_at` を hash 対象に含める**: 2 回実行で artifact が一致しなくなる。保存はするが hash から除くことで、監査可能性と決定性を両立できる。
- **`DataFrequency` に `Daily` を追加する**: 既存 10 モデル・比較 API・前処理関数すべてが `DataFrequency` を分岐に使っている。日次系列は provider から月次で受け取れば足りる。
- **`to_quarterly` を年次入力へ拡張する**: 汎用 API の挙動変更であり、既存の呼び出し（Keen 実証層を含む）へ波及する。実証層専用の関数として分ける方が影響が閉じる。

## 影響

- **既存コードへの影響**: `src/models/capex_credit_cycle.jl` に `structural` キーワード引数（既定 `NamedTuple()`）と `CAPEX_CC_STRUCTURAL_OVERRIDABLE` が追加される。既存の呼び出しと数値は変わらない。`src/analysis/scenario_diagnostics.jl` は転換点・onset 検出の純関数を非 export ヘルパーへ切り出す（公開 API と数値は不変）。`src/DME.jl` に include と export が追加される。`src/core/simulation_result.jl`・`src/data/preprocess.jl`・`src/data/fred.jl`・`src/data/estat.jl`・`src/scenarios/` は変更しない。
- **新規ファイル 11 本**が `src/data/`（4 本）と `src/analysis/`（7 本）へ追加される。新しいサブディレクトリを作らないため `docs/make.jl` の `DME_API_GROUPS` の更新は不要である。
- **#241（`P-1`）** は catalog と provider gap を実装する。`:firm_disclosure` と `E` / `A` 分類が較正 role を持てないことを validator で強制する。
- **#242（`P-2`）** は provider 非依存の REST クライアントと raw observation を実装する。`FredClient` / `EStatClient` を変更しない。
- **#243（`P-3`）** は観測方程式・頻度変換・標本整列を実装する。`preprocess.jl` の `to_quarterly` を変更しない。
- **#244（`P-4`）** は 48 キーの観測対応と `structural` 注入を実装する。synthetic 互換 fixture で既存の逆較正結果と一致することを検査する。
- **#245（`P-5`）** は `EB-1`–`EB-7` の spec（`EST` 総数 35）と識別診断・`W1`–`W4` の 2 段適用を実装する。
- **#246（`P-6`）** はブロック別推定と parameter artifact を実装する。残差関数とモデル 1 期実行の一致テストが必須である。
- **#247（`P-7`）** は episode registry と `NC-1`–`NC-7` 判定を実装する。`L1` と `L3` を別フィールドで保持する。
- **#248（`P-8`）** は履歴再生の 3 段構成を実装する。`run_scenario` を変更しない。
- **#249（`P-9`）** は 7 dimension の検証を実装する。総合スコア・`passed`・一致率のフィールドを作らない。
- **#250（`P-10`）** は 7 軸の robustness を実装する。1 軸ずつを既定とする。
- **#251（`P-11`）** は fixture で完走する統合デモと E2E を追加する。live `EDP` 接続は明示 opt-in の smoke として分離する。
- **LLM 説明層**: [実証統合設計](../architecture/capex_credit_cycle_empirical_integration.md) §10.4 の caveats 8 件を必須記載へ追加する。特に **point-in-time replay ではないこと**と **fit を因果妥当性・景気後退確率・投資助言へ読み替えないこと**を [llm_safety.md](../llm_safety.md) の禁止表現と併せて適用する。[ADR 0014](0014-digital-twin-naming-conditions.md) の `DS-1`–`DS-4` は本フェーズでは充足せず、`Digital Shadow` を名乗らない。
- **外部プロジェクト**: `economic-data-provider` へは `CAPEX_CC_PROVIDER_GAPS` を JSON で受け渡す。要求は「不足系列・不足 metadata（季節調整・基準年・年率表示・vintage）・不足頻度/履歴・fixture/live parity」の 4 種類に限り、DME 側から公式 API を直接叩く実装は行わない。

## 参考

- [部門別CAPEX・信用循環モデル 実証統合設計](../architecture/capex_credit_cycle_empirical_integration.md) — 本 ADR の詳細設計（`Z-01`–`Z-30`・7 段のデータフロー・型と API・失敗契約・テスト 62 項目・作業分解 `P-1`–`P-11`）
- [観測方程式・識別戦略・検証方針](../models/capex_credit_cycle_empirical_strategy.md) — 観測可能性 5 分類・観測方程式 9 項目・パラメータ 6 区分・推定ブロック・識別リスク・履歴再生候補・検証契約・限界 14 件
- [部門別CAPEX・信用循環モデル 統合設計](../architecture/capex_credit_cycle_integration.md)・[イベント・シナリオ実行層 統合設計](../architecture/macro_event_runtime_integration.md)
- [ADR 0012](0012-capex-credit-cycle-empirical-contract.md)・[ADR 0013](0013-capex-credit-cycle-integration-contract.md)・[ADR 0014](0014-digital-twin-naming-conditions.md)・[ADR 0015](0015-macro-event-runtime-contract.md)
- [Keen モデル 実証化戦略](../models/keen_empirical_strategy.md)・[ADR 0004](0004-keen-empirical-calibration-strategy.md)・[ADR 0005](0005-keen-ai-explanation-contract.md)
