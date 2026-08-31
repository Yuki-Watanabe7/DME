# 部門別CAPEX・信用循環モデル 実証統合設計（整合レビュー・データフロー・型・API・失敗契約・作業分解）

> 関連 Issue: #240（本書）・#170（観測方程式・識別戦略・検証方針）・#171（`CCC` 統合設計）・#196（イベント・シナリオ実行層 統合設計）・#241〜#251（本書が分解する実装作業）・#125（ロードマップ）
> 前提: [観測方程式・識別戦略・検証方針](../models/capex_credit_cycle_empirical_strategy.md)（観測可能性 5 分類・観測方程式 9 項目・パラメータ 6 区分・推定ブロック・履歴再生候補・検証契約）・[部門別CAPEX・信用循環モデル 統合設計](capex_credit_cycle_integration.md)（`CCC` の公開 API・`CapexCreditCycleTargets`・metadata 予約キー）・[イベント・シナリオ実行層 統合設計](macro_event_runtime_integration.md)（`Scenario`・`compose_exogenous_paths`・provenance・replay）
> 決定記録: [ADR 0018](../adr/0018-capex-credit-cycle-empirical-runtime-contract.md)（本書の決定）・[ADR 0012](../adr/0012-capex-credit-cycle-empirical-contract.md)（実証化契約）・[ADR 0013](../adr/0013-capex-credit-cycle-integration-contract.md)（`CCC` 統合実装契約）・[ADR 0015](../adr/0015-macro-event-runtime-contract.md)（イベント実行層契約）

---

## メタ情報

| 項目 | 内容 |
|---|---|
| **対象** | `CapexCreditCycleModel`（以下 `CCC`）を実データへ接続する観測層・measurement 層・較正層・推定層・履歴再生層・検証層の DME 内実装設計 |
| **ステータス** | 整合レビュー・データフロー・公開型/API・失敗契約・標本/vintage semantics・provenance 契約・テスト戦略・作業分解を確定。Julia 実装は未着手 |
| **empirical integration version** | `capex-credit-cycle-empirical-integration/1.0.0` |
| **上位契約** | `capex-credit-cycle-empirical/1.2.0`（本書の改訂を反映した版）・`capex-credit-cycle-integration/1.0.0`・`macro-event-runtime/1.0.0`・`capex-credit-cycle-equations/1.1.0`・`capex-credit-cycle-vars/1.2.0`・`capex-credit-cycle-accounting/1.1.0`・`capex-credit-cycle-boundaries/1.0.1` |
| **継承する横断契約** | `DataSeries` / `MacroDataset`（`src/data/data_series.jl`）・データ取得 3 モード（`:fixture` / `:live` / `:rest_api`）・RFC 8785 正準化（`src/artifacts/json_canonical.jl`）・`comparison-v2/1.0.0`・`keen-empirical/1.0.0` と `keen-calibration/1.0.0` と `keen-validation/1.0.0`（先行実装パターン） |
| **対象モデル** | `CCC`（registry symbol `:capex_credit_cycle`）のみ |
| **基準経済・頻度** | 米国・四半期（`Δt = 0.25` 年）。助走 8 + 評価 20 = 28 四半期 |
| **観測データの provider 境界** | `economic-data-provider`（以下 `EDP`）の REST API のみ。DME から公式 API へ直接 fallback しない |

> **LLM向け要約**: 本書は #170（実証化戦略）と ADR 0012 が確定した契約を、実装済みの `CCC` モデル層（#179–#186）・
> イベント実行層（#197–#205）・DME 既存データ層（`DataSeries`・FRED / e-Stat クライアント・`EDP` REST 経路）と
> 突き合わせ、実データ接続から検証までを**追加の設計判断なしに実装できる形**へ落とす。
> (1) 契約と実装の差異 **30 件**を `Z-01`–`Z-30` として登録し、各件を「上流改訂」「本書決定」「限界として保持」へ
> 明示的に割り当てる（§2）。暗黙に吸収した差異は無い。
> (2) データフローを **7 段**（catalog → raw observation → measurement → empirical dataset → steady-state targets /
> parameter → historical replay → validation / robustness）へ固定し、各段の変換方向と責務を一方向にする（§3）。
> (3) 追加ファイル **11 本**・修正 **2 本**と、公開型 **23 個**・公開関数 **23 個**・公開定数 **21 個**を確定する（§4・§5）。
> (4) 失敗を **例外 / 構造化拒否 / 警告**の 3 層へ分け、段ごとのステータス語彙を固定する（§6）。
> (5) 標本を「較正必須」系列の inner join のみで決め、`:as_of` を実装せず vintage を**申告された場合にのみ**記録する（§7）。
> (6) `FIX` / `CAL-SS` / `CAL-OBS` / `EST` / `SCN` / `SENS` をコード上の**注入点**へ対応させ、`CAL-OBS` の構造パラメータを
> 渡せるよう `capex_credit_cycle_model` に非破壊の `structural` 引数を追加する（§8）。
> (7) 履歴再生を `run_scenario` ではなく `compose_exogenous_paths` + `capex_run` の 3 段で構成し、
> イベント実行層の公開 API を変更しない（§9）。
> (8) `SimulationResult` 型と metadata 予約キー 20 個を変更しない。実証層は独自の結果型と 5 種の hash を持つ（§11）。
> (9) 後続の実装 Issue #241–#251 を `P-1`–`P-11` として対象ファイル・依存・対象外・受け入れ条件つきで確定する（§13）。

---

## 1. 本書の位置づけ

### 1.1 何を確定し、何を確定しないか

| 本書が確定するもの | 本書が確定しないもの |
|---|---|
| 契約（#170・ADR 0012）と既存実装の差異とその解決（§2） | 観測可能性の分類・観測方程式の中身・パラメータ区分の割当（#170 が正本） |
| データフロー 7 段の責務と変換方向（§3） | `CCC` の方程式・診断・会計（#169・#171 が正本） |
| ファイル配置・include 順序・export（§4） | Julia コードそのもの（#241–#251） |
| 公開型・公開 API のシグネチャと契約（§5） | 実系列 ID の存在・定義・基準年の一次資料確認（#241 の実施事項） |
| 失敗契約とステータス語彙（§6） | パラメータの推定値・定常水準の数値（#244・#246） |
| 標本・頻度・vintage semantics（§7） | 標本期間の最終選定・履歴再生候補の最終選定（#243・#247） |
| 較正・推定の責務割当と注入点（§8） | `EDP` 側の endpoint・collector・内部設計（同リポジトリ） |
| 履歴再生・検証・robustness の構成（§9・§10） | LLM プロンプト本文（既存 LLM 層の契約に従う） |
| version・provenance・artifact 契約（§11） | #125 Phase 4 の他モデルとの数値比較 |
| テスト戦略（§12）と実装 Issue への分解（§13） | rolling calibration・状態推定・`:as_of` 実行 |

### 1.2 本書の規律

1. **差異を暗黙に吸収しない**。§2 に登録し、解決先を「上流改訂」「本書決定」「限界」のいずれかへ明示する（#171・#196 の手続きを継承）。
2. **上流契約に無い実証的判断を本書で新設しない**。観測分類の変更・系列の追加・推定対象の追加は行わない。必要が生じた場合は #170 の改訂として処理する。
3. **既存の公開 API を壊さない**。`SimulationResult`・`AbstractMacroModel`・`CapexCreditCycleRun`・`capex_run`・`simulate`・`Scenario`・`run_scenario`・`compose_exogenous_paths`・`DataSeries`・`to_quarterly` の型・シグネチャ・戻り値の数値を変更しない。追加は非破壊のキーワード引数と新規ファイルで行う。
4. **モデル層が外部 API を呼ばず `DataSeries` を受け取らない構造を維持する**（#170 §6.5）。較正層はモデル層へ**数値のみ**を渡す。
5. **観測されていない量を作る既定値を置かない**。欠損の `0` 置換・proxy の黙った差し替え・magnitude の既定値を実装しない（ADR 0010 決定・ADR 0012 決定 7・16）。
6. **provider の不足を DME 側の直接 HTTP で迂回しない**。不足は §10.4 の cross-repo handoff として記録し、DME 側は fixture と契約で待ち受ける。
7. **fit を因果妥当性・景気後退確率・「その時点での判断可能性」へ読み替えない**（ADR 0012 決定 24）。型・フィールド名の水準でこれを担保する（§10.3）。

### 1.3 正典（どの事項の正本がどの文書か）

| 事項 | 正本 |
|---|---|
| 観測可能性 5 分類・観測方程式 9 項目・頻度変換の既定割当・`ext_demand_s` 構成規則 | #170 [観測方程式・識別戦略・検証方針](../models/capex_credit_cycle_empirical_strategy.md) §3・§4 |
| 定常水準の算出方式・逆較正入力の観測対応 | 同 §5（本書 §8.2 の 48 キー表が実装上の正本） |
| データソース境界・企業開示の扱い・fixture 最小セット | 同 §6 |
| パラメータ 6 区分の割当・推定ブロック `EB-1`–`EB-7`・固定推定順序 | 同 §7（`EST` 個数は本書 §2.2 `Z-14` の改訂後が正本） |
| 識別リスク `ID-1`–`ID-7`・弱識別対応 `W1`–`W4` | 同 §8 |
| 履歴再生の必要条件 `NC-1`–`NC-7`・候補 `H1`–`H6` | 同 §9 |
| 検証の 4 レイヤー分離・出力契約・限界 14 件 | 同 §10・§11 |
| `CCC` の公開 API・`CapexCreditCycleTargets`・metadata 予約キー 20 個 | #171 [統合設計](capex_credit_cycle_integration.md) §4・§6 |
| イベント 4 層・`Scenario`・`compose_exogenous_paths`・hash・replay | #196 [イベント実行層 統合設計](macro_event_runtime_integration.md) §5・§9 |
| 実証層のファイル配置・型・API・失敗契約・artifact・作業分解 | 本書 |

---

## 2. 契約と既存実装の整合レビュー結果

### 2.1 レビュー範囲と方法

次の 6 つを横断照合した。照合は**シグネチャ・キー集合・定数名・単位・節参照の逐語一致**で行い、「概ね同じ」を一致とみなしていない。

| # | 照合対象 | 具体的な参照先 |
|---|---|---|
| 1 | #170 §3–§10・§15（改訂節）と ADR 0012 の 24 決定 | `docs/models/capex_credit_cycle_empirical_strategy.md` |
| 2 | `CCC` モデル層の較正・実行 API | `src/models/capex_credit_cycle.jl`（`CAPEX_CC_TARGET_KEYS` 48 キー・`_ccc_calibrate_structural`・`capex_credit_cycle_model`・`capex_run`・`to_simulation_result`） |
| 3 | イベント・シナリオ実行層 | `src/scenarios/`（`Scenario`・`compose_exogenous_paths`・`ScenarioRun`・`ScenarioProvenance`・`event_set_hash`・`replay_scenario`） |
| 4 | DME 既存データ層 | `src/data/data_series.jl`・`preprocess.jl`・`fred.jl`・`estat.jl`（`:fixture` / `:live` / `:rest_api` の 3 モードと `_parse_rest_api_response`） |
| 5 | Keen 実証層の先行実装パターン | `src/data/keen_empirical.jl`・`src/analysis/keen_calibration.jl`・`keen_validation.jl` |
| 6 | 後続 Issue #241–#251 の要求 | GitHub Issue 本文（対象ファイル候補・受け入れ条件） |

### 2.2 検出した差異と解決（`Z-01`–`Z-30`）

解決先の記号: **[U]** 上流文書の改訂として処理（改訂内容は §2.3 に記録）／**[D]** 本書または [ADR 0018](../adr/0018-capex-credit-cycle-empirical-runtime-contract.md) の実装決定として処理／**[L]** 限界として保持し実装で解決しない。

#### 観点 1: `EDP` REST 契約と観測 metadata

| ID | 差異 | 解決 | 解決先 |
|---|---|---|---|
| `Z-01` | `EDP` REST の応答を解釈する `_parse_rest_api_response`（`src/data/fred.jl`）は `id`・`source_id`・`name`・`unit`・`frequency`・`points` のみを読む。#170 §4.1 の 9 項目のうち `published_basis`（季節調整・基準年）・`vintage`・`sector_scope` に対応する field を取らない。FRED fixture 経路（`_parse_fred_json`）は `metadata["seasonal_adjustment"]` を設定するため、**同じ系列でも `:fixture` と `:rest_api` でメタ情報が非対称**になる | raw observation 層で provider metadata を**「未申告（`missing`）」と「空文字」を区別して**保持する。catalog（§5.1）が宣言する `declared_*` と provider が返す `provider_*` を**別フィールド**に持ち、両者の一致検査を行う。provider が返さない項目は `provider_seasonal_adjustment = missing` とし、catalog の宣言値で代替しない（代替すると #170 §4.1 の確認義務を provider 任せにしたことになる）。不足は §10.4 の handoff へ | **[D]** §5.2・**[L]** provider 能力 |
| `Z-02` | `_fetch_fred_rest_api` は URL を `/v1/series/FRED_<id>` と組み立てるため、**FRED 以外の provider prefix を持つ系列を取得できない**。Census M3・BEA・BLS・FRB Z.1 は #170 §6.3 が `EDP` 経由とした系列群であり、既存経路では取得できない | `src/data/data_provider.jl` を新設し、prefix を引数で受ける汎用関数 `fetch_provider_series(series_id; client)` を置く。`FredClient` / `EStatClient` は変更しない（既存 consumer への影響を避ける）。系列 ID の prefix は catalog が持ち、ソースコードへハードコードしない | **[D]** §5.2 |
| `Z-03` | #241 が前提とする `/v1/catalog/series` を呼ぶ実装が DME に無い。また「catalog の正本が DME 側か provider 側か」が未定義である | **DME 内の versioned な Julia const（`CAPEX_CC_SERIES_CATALOG`）を正本**とする。provider catalog は照合用（存在・単位・季節調整・利用可能期間の確認）に使い、DME の系列選定を provider の返り値で書き換えない。catalog を TOML で持たない（`TOML` は現行 `[deps]` に無く、依存追加は本書の対象外）。cross-repo handoff 用に JSON 出力関数を用意する | **[D]** §5.1 |

#### 観点 2: 頻度変換と時点基準

| ID | 差異 | 解決 | 解決先 |
|---|---|---|---|
| `Z-04` | `to_quarterly`（`src/data/preprocess.jl`）は `s.frequency == Monthly` を要求する。#170 §4.4 が要求する**年次 → 四半期**（`cap_s`・`dep_s`）の経路と、§4.2 注意 3 が言及する**日次 → 四半期**の経路が無い。`DataFrequency` に `Daily` が無い | (a) 日次系列（OAS 等）は **provider から月次（月平均）で受け取り** `to_quarterly(:mean)` を通す。`DataFrequency` を変更しない（既存 10 モデル・比較 API への波及を避ける）。集約が provider 側で行われた事実を `methodology` へ記録する。(b) 年次 → 四半期は**実証層の専用関数** `capex_annual_to_quarterly(s; method)` として measurement 層へ置き、`preprocess.jl` の汎用 API を変更しない。方式は #170 §4.4 の「年末値を `:end` として四半期へ配分」を既定とし、方式名を `transformations` へ残す | **[D]** §5.3 |
| `Z-05` | #170 §1.3 は時点基準を `SUM` / `AVG` / `EOP` / `BOP` の 4 種としながら、§4.2 の既定割当表は `SUM` / `EOP` / `AVG` の 3 種しか与えていない。`BOP` に対応する集計方式が未定義 | `BOP` は**観測側の集計方式ではない**。モデルが `x[t−1]` として参照する期首値であり、`EOP` 系列の 1 期ラグとして構成する。measurement 層は `BOP` を独立の `aggregation` 値として実装せず、`EOP` + ラグ指定として表現する | **[D]** §7.3・**[U]** #170 §4.2 |
| `Z-06` | #170 §4.2 注意 1 は「NIPA・BEA のフロー系列は年率表示が既定であり `÷ 4` を必ず入れる」と規律するが、**どの系列が年率表示かは系列単位で列挙されていない**。実装者が系列ごとに判断すると換算漏れが起きる（#170 自身が「照合まで気付かない系統的誤り」と述べている） | catalog の各エントリに `annualized::Bool`（provider が年率表示で返すか）を必須フィールドとして持たせ、`÷ 4` を measurement 層が機械的に適用する。`annualized` の値は #241 が一次資料で確認して埋める。**実装コード側で系列 ID を条件分岐しない** | **[D]** §5.1・§5.3 |

#### 観点 3: 逆較正入力（`CapexCreditCycleTargets`）と観測対応

| ID | 差異 | 解決 | 解決先 |
|---|---|---|---|
| `Z-07` | `CAPEX_CC_TARGET_KEYS` は **48 キー**だが、#170 §5.2 は 13 ステップ単位の記述であり、**キー単位の 1:1 対応表が存在しない**。実装者が対応を自分で決めると再現性が失われる | 本書 §8.2 に **48 キー × 観測対応の完全表**（観測ソース・分類・算出式・`source_kind`）を置き、これを実装上の正本とする。#170 §5.2 は導出順序の正本であり続ける | **[D]** §8.2 |
| `Z-08` | 48 キーのうち `cost_capital_s1`–`_s3`（#170 §3.2-6 で `E`・「単独の水準を分析結果として提示しない」）・`cons_s1`（`A`）・`capex_pipe_s1`–`_s3`（`E`。§5.2-4 は `S1` のみ言及）・`order_cap_s2`/`_s3`/`order_inv_s3`（`P` かつ allocation）は**観測から作れない**。しかし逆較正は 48 キー全部を必須とする（`_ccc_validate_target_keys` が欠損を `ArgumentError` にする） | 観測から作れないキーの与え方を規則として固定する（§8.2）。`cost_capital_s^{ss} = st_cc0_s^{lit} + bh_cc_spread · spread^{ss} / 100`、`cons_s1^{ss} = st_cons_share_s1^{obs} · y_s1^{ss}`、`capex_pipe_s^{ss} = st_pipelag_s^{lit} · dep_s^{ss}`。各キーに `source_kind ∈ {:observed, :derived, :literature, :assumption}` を必ず付け、**`:observed` でないキーを観測較正値として提示しない** | **[D]** §8.2 |
| `Z-09` | `capex_credit_cycle_model(targets; behavioral, policy, sectors)` には **`structural` 上書き引数が無い**。したがって #170 §7.2 が `CAL-OBS` とする `st_` 系統（`st_delta_s`・`st_cash_min_s`・`st_cash_ref_s`・`st_dcap_s`・`st_cshare_s3`・`st_pipelag_s`）のうち、targets から導けないものを較正層から注入できない | `capex_credit_cycle_model` に **`structural::NamedTuple = NamedTuple()` を追加**する（既定は空・既存呼び出しは非破壊）。`CAL-SS`（逆較正で閉形式に決まる）の系統を `structural` で上書きしようとした場合は `structural_override_conflict` として `ArgumentError` にする（自由度なしの導出を黙って壊さない）。上書き可能な集合を `CAPEX_CC_STRUCTURAL_OVERRIDABLE` として明示列挙する | **[D]** §5.5・ADR 0018 決定 5 |
| `Z-10` | `_ccc_calibrate_structural` は `st_dcap_s = 2 × debt_s^{ss} / y_s^{ss}` とするが、#170 §5.2-11 は「`1.2 ×`（暫定）」とする。**倍率が実装と契約で異なる** | 倍率を較正層の入力（`CAL-OBS`）として外へ出し、`structural` 経由で渡せるようにする（`Z-09`）。**実装既定の 2.0 は変更しない**（Phase 1 の数値・既存テストを壊さないため）。#170 §5.2-11 の「1.2 ×」は「暫定既定値」ではなく「較正層が観測から与える値の下限側の目安」であることを改訂で明記し、既定値の記述を実装値へ合わせる | **[U]** #170 §5.2-11・**[D]** §8.2 |
| `Z-11` | `_ccc_calibrate_structural` は `st_cor_s1 = 2.0`・`st_maturity_s1`–`_s3 = 5.0`・`st_cash_min_s = 0.05`・`st_commit_s1 = 0.5`・`st_cshare_s3 = 0.3`・`st_coll_ltv` の余裕幅 `1.65` を**ハードコード**する。#170 §7.2 は `st_cshare_s3`・`st_cash_min_s` を `CAL-OBS`、`st_cor_s1` を `CAL-SS` とする。`st_cor_s1` は `util_s1^{ss}` が `E`（対応系列なし）であるため **`CAL-SS` として観測から導けない** | (a) `st_cshare_s3`・`st_cash_min_s`・`st_maturity_s`・`st_commit_s1`・`st_coll_ltv` 余裕幅は `structural` 経由の注入対象とする（`Z-09`）。(b) `st_cor_s1` の区分を **`CAL-SS` から `SENS` へ改める**（`util_s1^{ss}` が観測できず自由度が残るため）。既定 2.0 を維持し、§10.4 の感応度対象に加える | **[U]** #170 §7.2・**[D]** §8.2 |
| `Z-12` | `ext_demand_s^{ss}` の残差方向が矛盾する。#170 §15.4（改訂節＝正本）は `ext_demand_s^{ss}` を残差とするが、§5.2-9 と実装 `_ccc_calibrate_structural`（`order_gen_s = y_s − order_cap_s − ext_demand_s`、`st_gen_share_s = order_gen_s / y_s5`）は `order_gen_s^{ss}` を残差とし `ext_demand_s^{ss}` を入力とする。**定常水準では両者の和のみが恒等式から決まり、分割は観測から識別されない** | 分割に必要な識別仮定を本書で明示的に固定する。**`st_gen_share_s` を baseline 期間より長い共通期間での `order_s` の `y_s5` に対する比として `CAL-OBS` で先に与え、`ext_demand_s^{ss}` を残差とする**。この選択を `allocation` methodology として記録し、#170 §10.4 の `alternative proxy` 感応度の必須対象へ加える。実装（`ext_demand_s^{ss}` を入力とする）は変更しない | **[U]** #170 §5.2-9・§15.4・**[D]** §8.3 |
| `Z-13` | #170 §5.2-5 は「`capex_exec_s1^{ss} = st_delta_s1 · cap_s1^{ss}` は自由度なしの整合条件であり、観測値との乖離を `ss_residual` として必ず報告する」と義務づけるが、**`capex_exec_s1^{obs,ss}` を保持する場所が `CapexCreditCycleTargets` に無い**（48 キーに含まれない） | `ss_residual` は `CapexCreditCycleTargets` ではなく**較正層の結果型 `CapexEmpiricalCalibration` が保持**する。`targets.source::Dict` は自由形式であり契約フィールドとして扱わない（型の意味を変えない） | **[D]** §5.5 |

#### 観点 4: パラメータ区分と推定

| ID | 差異 | 解決 | 解決先 |
|---|---|---|---|
| `Z-14` | #170 §15.2 は `EB-6` の `EST` を 11 個（`bh_emp_up_s1`–`_s5` 5 + `bh_emp_down_s1`–`_s5` 5 + `bh_wage_slope` 1）とし、`EST` 総数を 37 とする。しかし**モデルに `emp_s4` は存在しない**（`state_variables` は `emp_s1`・`emp_s2`・`emp_s3`・`emp_s5` の 4 本）。`bh_emp_up_s4`・`bh_emp_down_s4`・`bh_emp_band_s4` は `st_lprod_s4`・`st_wbase_s4` と同じく**辞書上の空き値**であり、対応する方程式も観測も無い | `EB-6` の `EST` を **9 個**（`bh_emp_up_s1`/`_s2`/`_s3`/`_s5` 4 + `bh_emp_down_s1`/`_s2`/`_s3`/`_s5` 4 + `bh_wage_slope` 1）へ修正する。**`EST` 総数は 35**（4+3+4+4+9+9+2）。`_s4` の 3 系統は「対応する方程式を持たない辞書上の空き値」として推定・較正・感応度のいずれの対象にもしない | **[U]** #170 §15.2 |
| `Z-15` | #170 §7.4-3 は objective を「各行動方程式の左辺の観測値と、右辺を観測値で評価した値の残差」と定めるが、`CCC` の行動方程式は期内 10 ステップの内部関数（`_ccc_financial!` 等・非 export）の中にあり、**単一方程式を観測値で評価する公開関数が存在しない**。Keen は `keen_rhs` 相当の右辺を持つため同型の実装ができない | モデル層に単一方程式 API を**追加しない**（ADR 0013 の「`simulate` は系列のみ返す」と `src/models/` の責務を維持）。推定層に**方程式別の残差関数を閉じて実装**し、関数名を #169 の式 ID（`E5-01` 等）と 1:1 対応させる。二重実装になるため、**同一入力でモデル 1 期実行の中間値と残差関数の右辺が一致することを回帰テストで保証する**（§12.4） | **[D]** §8.5・ADR 0018 決定 8 |
| `Z-16` | #170 §8.3 は `W1`–`W4` を「推定前に割り当てる」と契約するが、同節の**弱識別の検出方法（multi-start の散らばり・objective 曲率・パラメータ間相関・境界張り付き・proxy 依存）はいずれも推定後の情報**である。事前割当と事後検出の関係が未定義 | 2 段に分ける。(a) **事前適用**: `W1`（対応する観測変数が `E`）と `W4`（必要系列が揃わない／閾値パラメータ）は dataset と catalog から推定前に判定し、当該パラメータを `EST` から外す。(b) **事前固定・事後発火**: `W2`・`W3` は「どのパラメータに、どの規則を、どの閾値で適用するか」を**推定前に config へ固定**し、推定後の診断でその規則が発火したか否かだけを決める。**結果を見て規則や閾値を変えない**（変更した場合は config version を上げ、変更前後を両方保存する） | **[D]** §8.6・ADR 0018 決定 9 |
| `Z-17` | `FIX` / `CAL-OBS` とされた行動パラメータの既定値（`bh_spread_pow = 1.0`・`bh_price_scale_s = 0.1`・`bh_cancel_thresh = 0.05` 等）は実装の既定値であり、**文献値としての出所が #170 にも実装にも記録されていない**。#170 §7.4 は「`CAL-OBS`（文献値）」と述べるだけである | 出所の特定は #241（catalog）と #246（parameter artifact）の実施事項として残す。本書は**出所が空のまま `CAL-OBS` と申告しないこと**（`source_kind = :literature` の場合は参照を必須にし、無い場合は `:default_unattributed` とする）を型で強制する | **[L]** 出所の特定・**[D]** §5.6 の `source_kind` |

#### 観点 5: 履歴再生とイベント実行層

| ID | 差異 | 解決 | 解決先 |
|---|---|---|---|
| `Z-18` | #170 §7.5 は履歴再生で `policy_rate`・`ext_demand_s`・`price_s1` を**実現値の観測パス**で与えるとするが、`run_scenario` は baseline 外生を `_ccc_baseline_exog`（定常値の定数パス）から作り、そこへ mapping 差分を重ねる構造である。**実現値パスを baseline として与える経路が公開 API に無い** | `run_scenario` を**変更しない**。履歴再生層は (1) 観測実現値から baseline 外生 `Dict{Symbol,Vector{Float64}}` を構築し、(2) `schedule_events` と `compose_exogenous_paths(baseline, inputs, periods; assumptions)` でイベント差分を重ね（`compose_exogenous_paths` は baseline を引数で受けるため変更不要）、(3) `capex_run(m; exog=…)` を呼ぶ、の 3 段で構成する。戻り値は `ScenarioRun` ではなく `CapexHistoricalReplayRun` とし、イベントログ・`event_set_hash` は既存関数を再利用する | **[D]** §9.2・ADR 0018 決定 10 |
| `Z-19` | 実現値の `policy_rate` パスを助走 8 四半期へ与えると、モデルは定常状態から出発するため **`runup_deviation` が必ず発生する**（`runup_tol` の既定は `1e-8`）。#170 §9.3 は「助走 8 四半期の観測平均を定常水準とする」としており、助走区間で観測が動くことと両立しない | **助走区間の外生は定常値に固定し、評価区間のみ実現値パスを与える**。この非対称性を replay の metadata（`exog_runup_mode = :steady_state_fixed`）へ必ず記録し、検証は #170 §9.3 の baseline 比乖離 `dx_t` で行う。`runup_tol` を緩めて回避しない | **[D]** §9.3・ADR 0018 決定 11 |
| `Z-20` | #247 は episode に「event dates / source provenance」を求めるが、ADR 0010 決定 1・ADR 0015 は `L1`（`ObservedEvent`）から `L4` を生成する公開関数を提供しない（層飛ばしの禁止）。**履歴イベントの `L2`（解釈）を自動生成できない** | episode registry は `L1`（`ObservedEvent`）と `L3`（`ScenarioAssumption`）を**別フィールドで保持**し、`L2` の解釈を明示的な人手入力として記録する（自動生成しない）。観測に magnitude が無いイベントは `ObservedEvent` に magnitude を書かず、`ScenarioAssumption` 側に `magnitude_source = :assumed` として置く（ADR 0010 の magnitude 捏造禁止） | **[D]** §9.4 |
| `Z-21` | #170 §2.4 は `metadata["data_vintage"] = "latest"` の保存を義務づけるが、`EDP` REST は vintage を返さない（`Z-01`）。**provider が申告していない値を `"latest"` と書くことは、確認していない事実の申告になる** | `data_vintage` は「provider が申告した値、無ければ `"unknown"`」とする。`"latest"` と書けるのは provider が明示した場合のみ。`:as_of` を実装しないことを型で表現する（`vintage_mode::Symbol` の許容値を `:latest_only` の **1 値のみ**とし、将来値を先取りしない） | **[U]** #170 §2.4・**[D]** §7.5 |

#### 観点 6: 検証・診断

| ID | 差異 | 解決 | 解決先 |
|---|---|---|---|
| `Z-22` | #249 は `scenario_comparison` の再利用を求めるが、同関数のシグネチャは `scenario_comparison(baseline::ScenarioRun, scenario::ScenarioRun)` であり、履歴再生の戻り値（`Z-18` により `ScenarioRun` ではない）にも観測系列にも適用できない。転換点検出・onset 検出のロジックは `_scenario_diag_extremum`・`_scenario_diag_onset` として非 export で閉じている | `scenario_comparison` の公開シグネチャ・戻り値を**変更しない**。転換点・onset・持続期間の**純関数を `src/analysis/scenario_diagnostics.jl` 内の非 export ヘルパーとして切り出し**、実証検証層がそれを呼ぶ（`Vector{Float64}` を受ける形へ一般化する最小変更）。同じ検出規則が 2 箇所に実装される状態を作らない | **[D]** §10.2 |
| `Z-23` | ADR 0012 決定 18 は「`A`（増幅度）を観測から計算しない」と決めるが、#249 は「credit amplification の検証」を要求する | 検証層が計算するのは**モデル内 `A`（`credit-off` 反実仮想。`capex_counterfactual` の再利用）の episode 間比較のみ**とする。観測側に `A` に相当するフィールドを型として作らない（作れば必ず埋めたくなる） | **[D]** §10.3 |
| `Z-24` | ADR 0012 決定 19 は「診断ラベルの一致率を目的関数・合否条件にしない」と決めるが、#249・#250 は「diagnostic label の安定性」を要求する | ラベルは**報告のみ**とする。`label_agreement_rate` のような一致率フィールドを作らず、`label_changed_variants::Vector{String}`（ラベルが変わった variant の一覧）と `label_by_variant` のみを保持する | **[D]** §10.3・§10.5 |

#### 観点 7: 出力・provenance・秘密情報

| ID | 差異 | 解決 | 解決先 |
|---|---|---|---|
| `Z-25` | 実証層の情報（dataset hash・parameter set 種別・episode ID）を `SimulationResult.metadata` へ入れるか否かが未定義。#171 §6.1 は予約キー 20 個を確定しており、追加は契約変更にあたる | **`SimulationResult` 型と metadata 予約キー 20 個を変更しない**。replay が生成する `SimulationResult` はモデル層の 20 キーのままとし、実証情報は `CapexHistoricalReplayRun` が並置して保持する。モデル層が実証層を知らない構造を維持する（ADR 0009 決定 8・ADR 0013 決定 13 の継承） | **[D]** §11.1 |
| `Z-26` | #170 §6.6 は `retrieved_at`（取得日時）の保存を義務づけるが、#251 は「2 回実行で canonical artifact が一致すること」を求める。**両立しない** | `retrieved_at` は raw observation manifest に保存し、**canonical hash の対象から除外する**（volatile field。ADR 0015 の hash 対象明示の方針を継承）。fixture 経路では `nothing` を許す（Keen 実証層の `KeenSeriesProvenance.retrieved_at` と同じ扱い） | **[D]** §11.2 |
| `Z-27` | 実証層は dataset・targets・parameter set・episode・replay の 5 段で identity を必要とするが、既存の hash は `event_set_hash`・`scenario_content_hash` の 2 種のみである | 5 種の hash（`dataset_hash`・`targets_hash`・`parameter_set_hash`・`episode_hash`・`replay_hash`）を新設し、すべて `sha256_hex_of_canonical`（RFC 8785 正準化 + SHA-256）で統一する。**hash 対象フィールドを §11.3 に明示列挙し、volatile field を除外する** | **[D]** §11.3 |
| `Z-28` | #241 は「企業利益・cash flow の集計統計として利用可能な範囲」をカテゴリに含むが、ADR 0012 決定 6 は企業開示を較正入力から除外する。BEA NIPA 表 6.16 の産業別法人利益は**マクロ統計であって企業開示ではない**。両者を区別する語彙が無いと、実装者が「企業利益＝企業開示」と読んで必要な系列を落とすか、逆に企業開示を混入させる | catalog に `source_kind ∈ {:official_statistic, :market_data, :firm_disclosure}` を必須フィールドとして持たせ、**`:firm_disclosure` を較正・推定の入力に使えないことを validator で強制する**（`role` に `:calibration_required` / `:estimation_input` を設定した時点で `ArgumentError`）。BEA NIPA・FRB Z.1・Census・BLS は `:official_statistic`、OAS・株価指数は `:market_data` | **[D]** §5.1・ADR 0018 決定 3 |

#### 観点 8: 標本

| ID | 差異 | 解決 | 解決先 |
|---|---|---|---|
| `Z-29` | #170 §2.2 は「§4 の『較正必須』系列がすべて非欠損である最初と最後の四半期」で標本端点を決めるとするが、**「較正必須」の集合そのものが #170 に定義されていない**（§6.2 の表は「用途」欄に「較正・検証」等と書くのみ） | catalog の各エントリに `role ∈ {:calibration_required, :estimation_input, :validation_only, :diagnostic_only}` を持たせ、**標本端点は `:calibration_required` のみで決める**。`:estimation_input` の欠損は標本を縮めず、当該推定ブロックを実行しない扱いにする（#170 §7.4-1）。`:validation_only` は標本にも推定にも影響しない | **[D]** §5.1・§7.2 |
| `Z-30` | #170 §2.2 は「履歴再生区間が最新データを超える場合、超過分を評価対象外として明示する」とし、§9.1 `NC-5` は「評価 20 四半期のうち後半 8 四半期以上を out-of-sample として確保する」と要求する。`H6`（2022Q3–2023）は §9.2 自身が「期間末が最新データに近く評価 20 四半期を確保できない可能性」と述べており、**2 つの条件が同時に成立しない候補が存在しうる** | 実装で解決しない。`NC-1`–`NC-7` の判定は #247 が実データに対して機械的に行い、満たさない候補は `:insufficient_data` として除外理由とともに記録する。**条件を緩めて候補を残さない**。`NC-7`（集合レベルの条件）を満たす組が作れない場合は、履歴再生の範囲を縮小した事実を報告する | **[L]** #247 の判定 |

### 2.3 上流文書への改訂の反映方法

`Z-01`–`Z-30` のうち **[U]** を含む 7 件（`Z-05`・`Z-10`・`Z-11`・`Z-12`・`Z-14`・`Z-21`、および `Z-12` が §5.2-9 と §15.4 の 2 箇所へ及ぶ）は、#170 へ **「#240 統合レビューによる改訂」節（§16）**を追加し、メタ情報のバージョンと改訂履歴を更新する形で反映した。

| 文書 | 改訂後バージョン | 改訂節 | 反映した ID |
|---|---|---|---|
| #170 [観測方程式・識別戦略・検証方針](../models/capex_credit_cycle_empirical_strategy.md) | `capex-credit-cycle-empirical/1.2.0` | §16 | `Z-05`・`Z-10`・`Z-11`・`Z-12`・`Z-14`・`Z-21` |

**改訂節の規律**（#171・#196 と同一）: 改訂節は当該文書の**正本**であり、本文の該当箇所と矛盾する場合は改訂節が優先する。#170 のメタ情報にこの優先関係を明記した（§15 と §16 の関係を含む）。

### 2.4 限界として保持する事項（実装で解決しない）

| 事項 | 出所 | 保持する理由 | 実装での扱い |
|---|---|---|---|
| provider が季節調整・基準年・vintage を metadata として返さない | `Z-01` | `EDP` 側の能力。DME から公式 API へ直接 fallback しない（ADR 0018 決定 2） | `provider_*` を `missing` として保持し、catalog の `declared_*` と区別する。§10.4 の handoff に記録 |
| `FIX` / `CAL-OBS` 行動パラメータの文献値の出所が未特定 | `Z-17` | 一次資料の特定は #241・#246 の実施事項 | `source_kind = :default_unattributed` を許し、`:literature` を名乗るには参照を必須にする |
| `H1`–`H6` の一部で `NC-5` と最新データ制約が両立しない可能性 | `Z-30` | 実データの利用可能期間に依存する | #247 が `:insufficient_data` として除外理由つきで記録する |
| `S1` の収益ブロックが観測に接続されず `R1a` を実証検証できない | #170 §11-8 | 企業開示を較正入力から除外する決定（ADR 0012 決定 6） | `caveats` へ保持。`gain(R1a)` はモデル内診断としてのみ提示 |
| `SH-EXP` の規模を観測から較正できない | #170 §11-9 | `ai_exp` が `A` 分類（ADR 0012 決定 7） | 走査結果として提示（§10.5 の感応度軸 5） |
| 推定ブロックの順序が結果に影響する | #170 §11-12 | 逐次推定はブロック間相互依存を無視する近似 | 固定順序を provenance へ保存し、順序を変えた結果を `alternative specification` として比較できるようにする（既定は固定順） |
| 「その時点で判断できた」という主張を一切行えない | #170 §11-4 | `:as_of` を実装しない（ADR 0012 決定 8） | `vintage_mode = :latest_only` の 1 値。LLM 説明層の禁止表現へ引き渡す（§11.4） |
| 観測とモデルの `dx_t` の非対称性（観測はトレンドを含む） | #170 §9.3 | baseline を成長率ゼロの定常状態とする決定（ADR 0011） | 検証 metric の解釈へ必ず添える（§10.4 の `caveats`） |

---

## 3. データフローと責務境界

### 3.1 7 段の変換

`CCC` の実証化は次の 7 段からなる。**各段は 1 つ前の段の出力のみを入力とし、逆流しない**（後段が前段の値を書き換えない）。

```
[0] 系列 catalog          CAPEX_CC_SERIES_CATALOG（DME 内 versioned 定義）
      │  系列 ID・provider・role・source_kind・9 項目の宣言値
      ▼
[1] raw observation       EDP REST / fixture → CapexRawDataset
      │  provider の生の値 + provider metadata（変換しない）
      ▼
[2] measurement           観測方程式 9 項目の適用（単位・実質化・頻度・アンカー・按分）
      │  → CapexMeasurement（系列ごとに raw → measured の全段を保持）
      ▼
[3] empirical dataset     共通四半期軸への inner join・標本端点の決定
      │  → CapexEmpiricalDataset（モデル単位・四半期整列・観測分類つき）
      ▼
[4a] steady-state targets  baseline 期間平均 → CapexCreditCycleTargets + structural overrides
      │   → CapexEmpiricalCalibration（逆較正・SS-1–SS-17 検証・ss_residual）
[4b] identification        EB-1–EB-7 の推定可否判定 → CapexIdentificationDiagnostic
[4c] estimation            estimable ブロックのみ推定 → CapexParameterSet
      ▼
[5] historical replay     episode（観測 window + L1/L3 イベント）+ parameter set
      │   → CapexHistoricalReplayRun（literature/default と calibrated を別 run）
      ▼
[6] validation            dimension 別検証 → CapexEmpiricalValidationReport
      │
      ▼
[7] robustness            1 軸ずつの感応度 → CapexRobustnessReport
```

### 3.2 段ごとの責務と禁止事項

| 段 | 責務 | 禁止事項 |
|---|---|---|
| [0] catalog | 系列の宣言（ID・provider・role・`source_kind`・9 項目・`annualized`・利用可能期間）。provider catalog との照合 | provider の返り値で catalog を書き換えること。系列 ID をソースコードへ散らすこと |
| [1] raw observation | 取得・正規化・provider metadata の保持・欠損/失敗の構造化 | 値の変換（単位・実質化・頻度）。欠損の `0` 置換。provider が返さない項目を catalog の宣言値で埋めること |
| [2] measurement | 観測方程式 9 項目の適用と各段の出力保持 | 系列の差し替え。#170 §4 に無い変換の追加。`allocation` を按分キー未記録で行うこと |
| [3] dataset | 共通軸への整列・標本端点の決定・観測分類の保持 | `A` 分類の補完。`:validation_only` 系列の較正 dataset への混入 |
| [4a] 較正 | 定常水準の算出・`CapexCreditCycleTargets` 構築・逆較正の呼び出し・`SS` 検証 | `ss_inconsistent` の自動補正。`SCN` / `SENS` パラメータの上書き |
| [4b] 識別 | ブロック別の推定可否判定と `W1`–`W4` の割当 | パラメータ値の最適化 |
| [4c] 推定 | 1 ブロックずつの推定と parameter artifact 生成 | ブロック横断の同時推定。推定後の bounds クリップ |
| [5] 履歴再生 | 外生パス構築・イベント合成・モデル実行・会計検証 | 内生変数への観測値の上書き（tracking）。`Q4` の履歴再生からの判定 |
| [6] 検証 | dimension 別の指標算出と evidence tier の保持 | 単一総合スコアへの集約。単一 pass/fail gate。公式景気後退判定との一致率の目的関数化 |
| [7] robustness | 1 軸ずつの variant 実行と安定性の報告 | 多軸同時走査の既定化。best-fit 仕様の自動採用。確率への変換 |

### 3.3 層境界（#170 §6.5 の実装）

```
[データ層]   src/data/     catalog → provider adapter → measurement → dataset
                           （DataSeries・MacroDataset を扱う。モデル型を知らない）
     │ 数値のみ（NamedTuple・Vector{Float64}）
     ▼
[較正層]     src/analysis/ targets → capex_credit_cycle_model → identification → estimation
     │ 数値のみ（parameters::NamedTuple・初期状態・外生パス）
     ▼
[モデル層]   src/models/capex_credit_cycle.jl（無変更。structural 引数の追加のみ）
     │
     ▼
[検証層]     src/analysis/ historical replay → validation → robustness（読み取り専用）
```

**契約**: データ層はモデル型（`CapexCreditCycleModel`）を参照しない。較正層は `DataSeries` をモデル層へ渡さない。検証層はモデル本体・可視化・LLM 層を変更しない（Minsky 診断層・SFC 会計検証層と同じ配置方針）。

---

## 4. DME パッケージ内の配置

### 4.1 追加・修正するファイル

| 種別 | パス | 責務 | 対応 Issue |
|---|---|---|---|
| **追加** | `src/data/data_provider.jl` | provider 非依存の REST クライアント（`DataProviderClient`・`fetch_provider_series`・`fetch_provider_catalog`）。prefix をハードコードしない（`Z-02`） | `P-2` / #242 |
| **追加** | `src/data/capex_credit_cycle_catalog.jl` | `CapexSeriesSpec`・`CAPEX_CC_SERIES_CATALOG`・`CapexProviderGap`・validator・JSON 出力（`Z-03`・`Z-28`・`Z-29`） | `P-1` / #241 |
| **追加** | `src/data/capex_credit_cycle_provider.jl` | `CapexRawObservation`・`CapexRawDataset`・`build_capex_raw_dataset`。fixture / `:rest_api` を同一 decoder へ通す（`Z-01`） | `P-2` / #242 |
| **追加** | `src/data/capex_credit_cycle_measurements.jl` | 観測方程式の適用・`capex_annual_to_quarterly`・アンカー水準化・按分・`CapexMeasurement`・`CapexEmpiricalDataset`・`build_capex_empirical_dataset`（`Z-04`・`Z-05`・`Z-06`） | `P-3` / #243 |
| **追加** | `src/analysis/capex_credit_cycle_calibration.jl` | 定常水準の算出・48 キーの構築・`structural` の組み立て・逆較正呼び出し・`SS` 検証・`ss_residual`（`Z-07`–`Z-13`） | `P-4` / #244 |
| **追加** | `src/analysis/capex_credit_cycle_identification.jl` | `CapexEstimationBlockSpec`・`CAPEX_CC_ESTIMATION_BLOCKS`・識別診断・`W1`–`W4` の割当（`Z-14`・`Z-16`） | `P-5` / #245 |
| **追加** | `src/analysis/capex_credit_cycle_estimation.jl` | 方程式別残差関数・ブロック別推定・`CapexParameterSet`（`Z-15`） | `P-6` / #246 |
| **追加** | `src/analysis/capex_credit_cycle_history.jl` | `CapexHistoricalEpisodeSpec`・`NC-1`–`NC-7` 判定・episode registry（`Z-20`・`Z-30`） | `P-7` / #247 |
| **追加** | `src/analysis/capex_credit_cycle_historical_replay.jl` | 外生パス構築・イベント合成・`capex_run` 呼び出し・`CapexHistoricalReplayRun`（`Z-18`・`Z-19`） | `P-8` / #248 |
| **追加** | `src/analysis/capex_credit_cycle_empirical_validation.jl` | dimension 別検証・`CapexEmpiricalValidationReport`（`Z-22`–`Z-24`） | `P-9` / #249 |
| **追加** | `src/analysis/capex_credit_cycle_empirical_sensitivity.jl` | 感応度軸 7 種・`CapexRobustnessReport` | `P-10` / #250 |
| 修正 | `src/models/capex_credit_cycle.jl` | `capex_credit_cycle_model` へ `structural::NamedTuple = NamedTuple()` を追加（非破壊）・`CAPEX_CC_STRUCTURAL_OVERRIDABLE` の定義（`Z-09`） | `P-4` / #244 |
| 修正 | `src/analysis/scenario_diagnostics.jl` | 転換点・onset・持続期間の純関数を `Vector{Float64}` 受けの非 export ヘルパーへ切り出す（公開 API は無変更、`Z-22`） | `P-9` / #249 |
| 修正 | `src/DME.jl` | include 追加（§4.2）・export 追加（§4.3） | 各 Issue |
| **追加** | `test/test_capex_credit_cycle_catalog.jl` 他 10 本 | §12 のテスト | 各 Issue |
| **追加** | `test/fixtures/data/capex_credit_cycle/` | provider 応答 fixture（§12.6） | `P-2` |
| **追加** | `test/fixtures/empirical/capex_credit_cycle/` | dataset / 較正 / 推定 / episode / replay の golden artifact | `P-3`–`P-10` |
| **追加** | `examples/capex_credit_cycle_empirical_demo.jl` | 統合デモ（fixture・外部 API 不要） | `P-11` / #251 |
| **追加** | `docs/data/capex_credit_cycle_series_catalog.md` | catalog の人間可読な解説（正本は Julia const） | `P-1` / #241 |
| **追加** | `docs/data/capex_credit_cycle_historical_episodes.md` | episode 選定結果の解説 | `P-7` / #247 |
| **追加** | `docs/examples/capex_credit_cycle_empirical_demo.md` | デモの実行手順 | `P-11` / #251 |

**catalog の正本について**（`Z-03`）: 機械可読な正本は `src/data/capex_credit_cycle_catalog.jl` の Julia const（`MACRO_EVENT_TYPE_REGISTRY`・`CAPEX_CC_EVENT_MAPPING_RULES` と同じ宣言的レジストリ方式）である。`docs/data/capex_credit_cycle_series_catalog.md` は解説であり、**両者の系列 ID 集合と件数が一致することをテストで保証する**（§12.1）。TOML を用いない（`TOML` は現行 `[deps]` に無く、依存追加は本書の対象外）。

### 4.2 include 順序

`src/DME.jl` の既存ブロックへ次のとおり挿入する。

| 挿入位置 | ファイル | 根拠 |
|---|---|---|
| `data/estat.jl` の直後 | `data/data_provider.jl` | `DataSeries` のみに依存。`fred.jl` / `estat.jl` から独立 |
| 上記の直後 | `data/capex_credit_cycle_catalog.jl` | `DataSeries` に依存。モデル型に依存しない |
| 上記の直後 | `data/capex_credit_cycle_provider.jl` | catalog と `data_provider.jl` に依存 |
| 上記の直後（`data/keen_empirical.jl` の前） | `data/capex_credit_cycle_measurements.jl` | catalog・provider・`preprocess.jl` に依存 |
| `analysis/capex_credit_cycle_diagnostics.jl` の直後 | `analysis/capex_credit_cycle_calibration.jl` | モデル型・measurement 層に依存 |
| 上記の直後 | `analysis/capex_credit_cycle_identification.jl` | 較正層に依存 |
| 上記の直後 | `analysis/capex_credit_cycle_estimation.jl` | 識別層に依存 |
| `analysis/scenario_diagnostics.jl` の直後 | `analysis/capex_credit_cycle_history.jl` | イベント層（`ObservedEvent`・`ScenarioAssumption`）に依存 |
| 上記の直後 | `analysis/capex_credit_cycle_historical_replay.jl` | history・estimation・イベント scheduler に依存 |
| 上記の直後 | `analysis/capex_credit_cycle_empirical_validation.jl` | replay・`scenario_diagnostics.jl` のヘルパーに依存 |
| 上記の直後 | `analysis/capex_credit_cycle_empirical_sensitivity.jl` | validation に依存 |

**`src/data/` へのサブディレクトリを追加しない**ため、`docs/make.jl` の `DME_API_GROUPS` の更新は不要である（CLAUDE.md ルール 6 は「新しいサブディレクトリを追加した場合」のみ）。

### 4.3 export

`src/DME.jl` の `export` 節へ、責務別のコメント区切りを維持して追加する。公開型 **23 個**・公開関数 **23 個**・公開定数 **21 個**。

| 区分 | 追加する名前 |
|---|---|
| データ provider（汎用） | `DataProviderClient`・`fetch_provider_series`・`fetch_provider_catalog` |
| CCC 実証: version・語彙 | `CAPEX_CC_EMPIRICAL_INTEGRATION_VERSION`・`CAPEX_CC_SERIES_ROLES`・`CAPEX_CC_SOURCE_KINDS`・`CAPEX_CC_METHODOLOGY_KINDS`・`CAPEX_CC_OBSERVABILITY_CLASSES`・`CAPEX_CC_RAW_STATUSES`・`CAPEX_CC_TARGET_SOURCE_KINDS`・`CAPEX_CC_IDENTIFICATION_STATUSES`・`CAPEX_CC_WEAK_ID_ACTIONS`・`CAPEX_CC_ESTIMATION_STATUSES`・`CAPEX_CC_PARAMETER_SET_KINDS`・`CAPEX_CC_EPISODE_STATUSES`・`CAPEX_CC_REPLAY_STATUSES`・`CAPEX_CC_VALIDATION_DIMENSIONS`・`CAPEX_CC_METRIC_APPLICABILITY`・`CAPEX_CC_SENSITIVITY_AXES` |
| CCC 実証: catalog | `CapexSeriesSpec`・`CAPEX_CC_SERIES_CATALOG`・`capex_series_catalog`・`CapexProviderGap`・`CAPEX_CC_PROVIDER_GAPS`・`validate_capex_series_catalog`・`capex_series_catalog_to_dict`・`save_capex_series_catalog` |
| CCC 実証: raw observation | `CapexRawObservation`・`CapexRawDataset`・`build_capex_raw_dataset` |
| CCC 実証: measurement | `CapexMeasurement`・`CapexSampleWindow`・`CapexEmpiricalDataset`・`build_capex_empirical_dataset`・`capex_annual_to_quarterly` |
| CCC 実証: 較正 | `CapexTargetSpec`・`CapexEmpiricalCalibration`・`build_capex_steady_state_targets`・`calibrate_capex_credit_cycle`・`CAPEX_CC_STRUCTURAL_OVERRIDABLE` |
| CCC 実証: 識別 | `CapexEstimationBlockSpec`・`CAPEX_CC_ESTIMATION_BLOCKS`・`CapexIdentificationDiagnostic`・`diagnose_capex_identification` |
| CCC 実証: 推定 | `CapexEstimationConfig`・`CapexBlockEstimate`・`CapexParameterSet`・`estimate_capex_block`・`capex_parameter_set` |
| CCC 実証: 履歴再生 | `CapexHistoricalEpisodeSpec`・`CAPEX_CC_EPISODE_IDS`・`CapexEpisodeAssessment`・`assess_capex_episodes`・`CapexReplayOptions`・`CapexHistoricalReplayRun`・`capex_historical_replay` |
| CCC 実証: 検証・感応度 | `CapexSeriesFit`・`CapexEmpiricalValidationReport`・`validate_capex_empirical`・`CapexSensitivityAxis`・`CapexRobustnessReport`・`capex_empirical_robustness` |
| CCC 実証: artifact | `capex_empirical_artifact_to_dict`・`save_capex_empirical_artifact`・`load_capex_empirical_artifact`・`capex_empirical_report`・`save_capex_empirical_report` |

---

## 5. 公開型と API 契約

シグネチャは実装時の契約である。**戻り値の型を変えずにフィールドを追加することは許容し、フィールドの削除・意味の変更は本書の改訂を要する**。

### 5.1 系列 catalog（`P-1` / #241）

```julia
const CAPEX_CC_EMPIRICAL_INTEGRATION_VERSION = "capex-credit-cycle-empirical-integration/1.0.0"

const CAPEX_CC_SERIES_ROLES        = (:calibration_required, :estimation_input,
                                      :validation_only, :diagnostic_only)
const CAPEX_CC_SOURCE_KINDS        = (:official_statistic, :market_data, :firm_disclosure)
const CAPEX_CC_METHODOLOGY_KINDS   = (:direct, :aggregation, :allocation, :proxy)
const CAPEX_CC_OBSERVABILITY_CLASSES = (:D, :C, :P, :E, :A)

struct CapexSeriesSpec
    key::Symbol                       # 論理観測キー（モデル変数名と一致しなくてよい）
    model_vars::Vector{Symbol}        # 対応する CCC 変数（複数可・0 個も可＝変換の中間系列）
    provider_series_id::String        # EDP の系列 ID（prefix を含む。例 "FRED_GDPC1"）
    provider::String                  # "FRED" / "CENSUS" / "BEA" / "BLS" / "FRB" / "ICE" 等
    source_kind::Symbol               # CAPEX_CC_SOURCE_KINDS
    role::Symbol                      # CAPEX_CC_SERIES_ROLES
    observability::Symbol             # CAPEX_CC_OBSERVABILITY_CLASSES（#170 §3.2）
    methodology::Symbol               # CAPEX_CC_METHODOLOGY_KINDS（#170 §4.6）
    # --- #170 §4.1 の 9 項目のうち catalog が宣言するもの（declared_*） ---
    declared_unit::String             # provider が返すはずの単位
    declared_frequency::DataFrequency
    declared_seasonal_adjustment::String   # "SA" / "NSA" / "unknown"
    declared_real_nominal::Symbol     # :real / :nominal / :ratio / :index / :not_applicable
    declared_base_year::Union{Int, Nothing}
    annualized::Bool                  # 年率表示か（true なら measurement 層が ÷4 する。Z-06）
    level_form::Symbol                # :level / :ratio / :index / :growth
    anchor::Union{Symbol, Nothing}    # level_form == :index のときのアンカー方式（必須）
    sector_scope::String              # 部門範囲の一致/不一致
    scope_bias::Symbol                # :over / :under / :indeterminate / :none
    aggregation::Symbol               # :sum / :mean / :end
    model_timing::Symbol              # :SUM / :AVG / :EOP（:BOP は EOP + lag。Z-05）
    allocation_key::Union{Symbol, Nothing}   # methodology == :allocation のとき必須
    availability_start::Union{String, Nothing}   # "YYYY-Qn"（catalog 宣言・照合用）
    availability_end::Union{String, Nothing}
    notes::String
end

const CAPEX_CC_SERIES_CATALOG::Vector{CapexSeriesSpec}
capex_series_catalog(; role = nothing, provider = nothing) -> Vector{CapexSeriesSpec}
validate_capex_series_catalog(catalog = CAPEX_CC_SERIES_CATALOG) -> Nothing   # 違反は ArgumentError

struct CapexProviderGap
    key::Symbol
    kind::Symbol          # :missing_series / :missing_metadata / :missing_frequency /
                          # :missing_history / :missing_fixture_parity / :missing_vintage
    detail::String
    blocking::Vector{Symbol}   # 影響を受ける EB / episode / target
end
const CAPEX_CC_PROVIDER_GAPS::Vector{CapexProviderGap}

capex_series_catalog_to_dict(catalog) -> Dict{String, Any}    # cross-repo handoff（JSON）
save_capex_series_catalog(path, catalog) -> String             # canonical JSON・atomic write
```

**validator が拒否するもの**（すべて `ArgumentError`）:

1. `source_kind == :firm_disclosure` かつ `role ∈ (:calibration_required, :estimation_input)`（ADR 0012 決定 6、`Z-28`）。
2. `level_form == :index` かつ `anchor === nothing`（#170 §4.1 の契約、ADR 0012 決定 2）。
3. `methodology == :allocation` かつ `allocation_key === nothing`（#170 §4.6-1）。
4. `methodology == :proxy` かつ `scope_bias == :none`（ずれの方向の記載義務、#170 §3.1）。
5. `observability ∈ (:E, :A)` かつ `role ∈ (:calibration_required, :estimation_input)`（潜在・仮定量を較正入力にしない、#170 §3.3）。
6. `key` の重複。`model_timing == :SUM` かつ `aggregation == :mean` 等、時点基準と集計方式の非整合な組（#170 §4.2）。

### 5.2 raw observation（`P-2` / #242）

```julia
const CAPEX_CC_RAW_STATUSES = (:ok, :missing_series, :provider_error,
                               :invalid_response, :unavailable_upstream)

struct CapexRawObservation
    key::Symbol
    spec::CapexSeriesSpec
    status::Symbol                    # CAPEX_CC_RAW_STATUSES
    series::Union{DataSeries, Nothing}      # status == :ok のときのみ非 nothing
    provider_unit::Union{String, Missing}
    provider_frequency::Union{DataFrequency, Missing}
    provider_seasonal_adjustment::Union{String, Missing}   # 未申告は missing（Z-01）
    provider_vintage::Union{String, Missing}               # 未申告は missing（Z-21）
    metadata_mismatches::Vector{String}    # declared_* と provider_* の不一致
    retrieved_at::Union{String, Nothing}   # volatile field（hash 対象外。Z-26）
    mode::Symbol                           # :fixture / :live / :rest_api / :provided
    detail::String
end

struct CapexRawDataset
    observations::Dict{Symbol, CapexRawObservation}   # key => 観測
    catalog_version::String
    integration_version::String
    provider_base::String              # credential を含まない基底 URL（Z-26）
    quality_flags::Dict{String, Any}
    metadata::Dict{String, Any}
end

build_capex_raw_dataset(; catalog = CAPEX_CC_SERIES_CATALOG,
                          client = DataProviderClient(),
                          keys = nothing) -> CapexRawDataset
```

**契約**:

1. `:fixture` と `:rest_api` は**同一の decoder** を通る。fixture は provider 応答と同じ JSON 形式で置く（§12.6）。
2. provider が返さない metadata は `missing` とし、catalog の `declared_*` で埋めない（`Z-01`）。`declared_*` と `provider_*` の不一致は `metadata_mismatches` に記録し、**取得を失敗させない**（#241 の一次資料確認との突き合わせは人手の作業である）。
3. `status != :ok` の観測を空系列・`0` 埋めへ変換しない（fail closed）。`CAPEX_CC_PROVIDER_GAPS` に登録済みのキーは `:unavailable_upstream` とし、`:provider_error` と区別する。
4. API キー・token・credential を含む URL を `metadata` へ保存しない。`provider_base` はスキームとホストのみとする。
5. `DataProviderClient` は `DATA_PROVIDER_BASE_URL` を既定とし、**CCC 固有の localhost fallback を追加しない**（#242 の受け入れ条件）。

### 5.3 measurement と empirical dataset（`P-3` / #243）

```julia
struct CapexMeasurement
    key::Symbol
    spec::CapexSeriesSpec
    stages::Vector{Pair{String, DataSeries}}   # 変換の各段（aggregation → allocation → proxy）
    measured::DataSeries                       # 最終段（モデル単位・四半期）
    conversion_formula::String
    deflator_key::Union{Symbol, Nothing}
    anchor_detail::Union{String, Nothing}
    allocation_key::Union{Symbol, Nothing}
    allocation_shares::Union{Dict{String, Float64}, Nothing}
    n_source_missing::Int
    n_invalid::Int
    warnings::Vector{String}
end

struct CapexSampleWindow
    sample_start::String       # "YYYY-Qn"
    sample_end::String
    n_obs::Int
    binding_series::Vector{Symbol}     # 端点を決めた :calibration_required キー
    dropped_dates::Vector{String}
    exclusion_reasons::Dict{String, Int}
end

struct CapexEmpiricalDataset
    catalog::Vector{CapexSeriesSpec}
    measurements::Dict{Symbol, CapexMeasurement}
    dates::Vector{String}                    # 共通四半期軸（時間順）
    observation_times::Vector{Float64}       # year + (q−1)·0.25
    values::Dict{Symbol, Vector{Union{Float64, Missing}}}
    roles::Dict{Symbol, Symbol}
    observability::Dict{Symbol, Symbol}
    sample::CapexSampleWindow
    vintage_mode::Symbol                     # :latest_only のみ（Z-21）
    quality_flags::Dict{String, Any}
    raw::CapexRawDataset
    metadata::Dict{String, Any}
end

build_capex_empirical_dataset(raw::CapexRawDataset;
                              sample_start = nothing, sample_end = nothing,
                              min_valid_obs::Int = 8) -> CapexEmpiricalDataset

capex_annual_to_quarterly(s::DataSeries; method::Symbol = :end_of_year_allocation) -> DataSeries
```

**契約**:

1. **変換の各段を `stages` に保持する**。最終値のみを保存しない（#170 §4.6-3）。
2. `annualized == true` の系列へ `÷ 4` を機械的に適用し、適用の事実を `conversion_formula` へ書く（`Z-06`）。系列 ID による条件分岐をコードに書かない。
3. `level_form == :index` の系列は `anchor` の方式で水準化し、`anchor_detail` に基準年と算式を書く。**指数をそのまま水準として使う経路を持たない**。
4. 標本端点は `role == :calibration_required` のキーの inner join のみで決める（`Z-29`）。四半期ラベルは数値時間へ変換して結合し、文字列順で結合しない。
5. 欠損を `0` へ変換しない。補完は spec で明示された系列のみで行い、`transformations` へ残す。
6. `observability ∈ (:E, :A)` のキーは dataset に**値を持たない**（キーは持つが `values` に入れない）。`A` を補完して観測済みにしない（#243 の受け入れ条件）。
7. `role == :validation_only` の系列は `values` に含めるが、`roles` により較正・推定の入力から機械的に除外できる形にする。
8. `capex_annual_to_quarterly` は #170 §4.4 の方式（年末値を `:end` として四半期へ配分）を既定とし、`preprocess.jl` の `to_quarterly` を変更しない（`Z-04`）。補間により四半期変動が平滑化されるため、`cap_s`・`dep_s` を高頻度の検証 metric に用いない旨を `warnings` へ入れる。

### 5.4 datasetの identity

`dataset_hash` は次から算出する（§11.3）。

```
sha256_hex_of_canonical(Dict(
  "catalog_version"     => catalog の版とキー集合,
  "integration_version" => CAPEX_CC_EMPIRICAL_INTEGRATION_VERSION,
  "provider_series_ids" => ソート済み系列 ID,
  "measurement_formulas"=> key => conversion_formula,
  "sample"              => (sample_start, sample_end, n_obs, binding_series),
  "values"              => key => 値（非有限は null）,
))
```

`retrieved_at`・`provider_base`・実行時刻は**含めない**（`Z-26`）。

### 5.5 較正（`P-4` / #244）

```julia
const CAPEX_CC_TARGET_SOURCE_KINDS = (:observed, :derived, :literature, :assumption)

struct CapexTargetSpec
    key::Symbol                       # CAPEX_CC_TARGET_KEYS の 1 つ
    source_kind::Symbol               # CAPEX_CC_TARGET_SOURCE_KINDS
    observation_keys::Vector{Symbol}  # 参照する dataset のキー（:observed / :derived のみ）
    formula::String                   # 算式（逐語）
    timing::Symbol                    # :SUM / :AVG / :EOP
    reference::String                 # source_kind == :literature のとき必須
end

struct CapexEmpiricalCalibration
    dataset_hash::String
    targets::CapexCreditCycleTargets          # 既存型（無変更）
    target_specs::Dict{Symbol, CapexTargetSpec}
    structural_overrides::NamedTuple          # CAL-OBS の st_（Z-09）
    model::CapexCreditCycleModel
    steady_state_report::CapexSteadyStateReport
    ss_residual::Dict{String, Float64}        # 自由度なし整合条件の乖離（Z-13）
    ss_inconsistent::Vector{String}           # 破れた SS-n
    baseline_window::CapexSampleWindow
    admissibility_warnings::Vector{String}
    parameter_provenance::Dict{Symbol, Symbol}  # パラメータ名 => 6 区分
    warnings::Vector{String}
    targets_hash::String
    metadata::Dict{String, Any}
end

build_capex_steady_state_targets(ds::CapexEmpiricalDataset;
                                 baseline_start, baseline_end)
    -> Tuple{CapexCreditCycleTargets, Dict{Symbol, CapexTargetSpec}, NamedTuple}

calibrate_capex_credit_cycle(ds::CapexEmpiricalDataset;
                             baseline_start, baseline_end,
                             literature = NamedTuple()) -> CapexEmpiricalCalibration
```

モデル層への非破壊の追加（`Z-09`）:

```julia
# src/models/capex_credit_cycle.jl
const CAPEX_CC_STRUCTURAL_OVERRIDABLE = (
    :st_cor_s1, :st_maturity_s1, :st_maturity_s2, :st_maturity_s3,
    :st_cash_min_s1, :st_cash_min_s2, :st_cash_min_s3,
    :st_commit_s1, :st_cshare_s3, :st_coll_ltv,
    :st_dcap_s1, :st_dcap_s2, :st_dcap_s3,
    :st_pipelag_s1, :st_pipelag_s2, :st_pipelag_s3,
)

capex_credit_cycle_model(targets::CapexCreditCycleTargets;
                         behavioral = NamedTuple(),
                         policy     = NamedTuple(),
                         structural = NamedTuple(),   # ← 追加（既定は空・非破壊）
                         sectors    = CapexSectorSets()) -> CapexCreditCycleModel
```

**契約**:

1. `structural` に `CAPEX_CC_STRUCTURAL_OVERRIDABLE` 以外のキーを渡した場合、`structural_override_conflict` として `ArgumentError` を投げる。**`CAL-SS`（逆較正で自由度なしに決まる系統）を黙って上書きさせない**。
2. `structural` の適用順は `_ccc_calibrate_structural` の出力へ `merge` する形とし、逆較正の閉形式を再計算しない。上書きの結果 `SS-1`–`SS-17` や許容条件 15 件が破れた場合は `capex_steady_state_report` が検出し、`capex_run` が入力エラーとして拒否する（既存の挙動、ADR 0013 決定 14）。
3. **`ss_inconsistent` を自動補正しない**（ADR 0007 の方針・#170 §5.1）。どの条件が破れたかを構造化して返す。
4. `SCN`（ショック規模・形状・初期状態・診断閾値）と `SENS` のパラメータを較正で上書きしない。`parameter_provenance` により 6 区分を全パラメータについて保持する。
5. `source_kind == :literature` の `CapexTargetSpec` は `reference` を必須とする。空の場合は `:default_unattributed` を用いる（`Z-17`）。

### 5.6 識別と推定（`P-5`・`P-6` / #245・#246）

```julia
const CAPEX_CC_IDENTIFICATION_STATUSES = (:estimable, :weakly_identified,
                                          :not_identified, :insufficient_data)
const CAPEX_CC_WEAK_ID_ACTIONS = (:W1, :W2, :W3, :W4)
const CAPEX_CC_ESTIMATION_STATUSES = (:converged, :boundary_solution, :not_converged,
                                      :invalid_objective, :demoted)
const CAPEX_CC_PARAMETER_SET_KINDS = (:literature_default, :calibrated, :estimated)

struct CapexEstimationBlockSpec
    id::Symbol                       # :EB1 … :EB7
    order::Int                       # 固定推定順序（#170 §7.4-2）
    est_params::Vector{Symbol}
    fixed_params::Vector{Symbol}
    required_keys::Vector{Symbol}    # 欠けると実行しない（#170 §7.4-1）
    supporting_keys::Vector{Symbol}
    equation_ids::Vector{String}     # #169 の式 ID（残差関数と 1:1。Z-15）
    identification_risks::Vector{Symbol}   # :ID1 … :ID7
    preassigned_actions::Dict{Symbol, Symbol}   # param => :W1/:W2/:W3/:W4（事前適用・事前固定）
end
const CAPEX_CC_ESTIMATION_BLOCKS::Vector{CapexEstimationBlockSpec}   # 7 件・EST 総数 35（Z-14）

struct CapexIdentificationDiagnostic
    block::Symbol
    status::Symbol                   # CAPEX_CC_IDENTIFICATION_STATUSES
    missing_keys::Vector{Symbol}
    proxy_only_keys::Vector{Symbol}
    n_obs::Int
    variation::Dict{Symbol, Float64}         # 系列別の標準偏差（変動不足の検出）
    collinearity::Dict{Tuple{Symbol, Symbol}, Float64}
    applied_actions::Dict{Symbol, Symbol}    # 事前適用された W1 / W4
    armed_actions::Dict{Symbol, Symbol}      # 事前固定された W2 / W3（発火は推定後）
    reasons::Vector{String}
end

diagnose_capex_identification(ds::CapexEmpiricalDataset,
                              cal::CapexEmpiricalCalibration;
                              blocks = CAPEX_CC_ESTIMATION_BLOCKS)
    -> Vector{CapexIdentificationDiagnostic}

estimate_capex_block(block::Symbol, ds::CapexEmpiricalDataset,
                     cal::CapexEmpiricalCalibration,
                     diag::CapexIdentificationDiagnostic;
                     config::CapexEstimationConfig = CapexEstimationConfig())
    -> CapexBlockEstimate

capex_parameter_set(cal::CapexEmpiricalCalibration,
                    estimates::Vector{CapexBlockEstimate};
                    kind::Symbol) -> CapexParameterSet
```

**契約**:

1. `estimate_capex_block` は **1 回につき 1 ブロック**を受け取る。ブロック横断の同時最適化を公開 API として提供しない（ADR 0012 決定 12）。
2. `diag.status ∈ (:not_identified, :insufficient_data)` のブロックの推定を**拒否する**（`ArgumentError`）。`:weakly_identified` は `armed_actions` に従って `W2`（範囲報告）・`W3`（複数仕様）へ降格し、点推定を返さない。
3. `FIX` / `CAL-SS` / `CAL-OBS` / `SCN` / `SENS` のパラメータが `est_params` に含まれることを validator が拒否する。
4. bounds・符号制約・許容条件 15 件はモデル層の契約と共有し、**推定後に不正値をクリップしない**（境界に張り付いた場合は `:boundary_solution`）。
5. `standard_errors_supported = false` を保持する（#170 §8.3-1）。objective の曲率を分散推定と呼ばない。
6. 推定順序 `EB-1 → EB-3 → EB-4 → EB-6 → EB-7 → EB-5 → EB-2` を `order` で固定し、実行順を provenance へ保存する。
7. `CapexParameterSet` は `:literature_default` / `:calibrated` / `:estimated` を**同一 artifact 内で別フィールドとして**保持し、由来不明の混在を作らない。

---

## 6. 失敗契約

[ADR 0015](../adr/0015-macro-event-runtime-contract.md) の 3 層分離を実証層へ継承する。

### 6.1 3 層の境界

| 層 | 使う場面 | 表現 |
|---|---|---|
| **例外**（`ArgumentError` / `ErrorException`） | 呼び出し側のプログラミング誤り・契約違反。続行しても意味のある結果が出ない | `throw`。catalog の validator 違反・`structural_override_conflict`・`:not_identified` ブロックの推定要求・`CapexCreditCycleTargets` のキー不足・ブロック横断同時推定の要求 |
| **構造化拒否**（status + reason） | データ側の事情で実行できない。呼び出し側は正しい | 結果型の `status` フィールド。`:missing_series`・`:unavailable_upstream`・`:insufficient_data`・`:not_identified`・episode の `:excluded` |
| **警告**（`warnings::Vector`） | 実行はできたが解釈に注意が必要 | 結果型の `warnings`。`metadata_mismatches`・`ss_inconsistent`・`boundary_hits`・`runup_deviation`・`acc_fail`・proxy 依存・打ち切り |

**契約**: 警告の有無は `status` を変えない。`status` が `:ok` / `:completed` でも `warnings` が空とは限らない（ADR 0015 と同一の規律）。

### 6.2 段ごとのステータス語彙

| 段 | 語彙 | 値 |
|---|---|---|
| raw observation | `CAPEX_CC_RAW_STATUSES` | `:ok` / `:missing_series` / `:provider_error` / `:invalid_response` / `:unavailable_upstream` |
| 識別 | `CAPEX_CC_IDENTIFICATION_STATUSES` | `:estimable` / `:weakly_identified` / `:not_identified` / `:insufficient_data` |
| 推定 | `CAPEX_CC_ESTIMATION_STATUSES` | `:converged` / `:boundary_solution` / `:not_converged` / `:invalid_objective` / `:demoted` |
| episode | `CAPEX_CC_EPISODE_STATUSES` | `:selected` / `:excluded` / `:insufficient_data` |
| 履歴再生 | `CAPEX_CC_REPLAY_STATUSES` | `:completed` / `:terminated` / `:accounting_failed` / `:rejected_input` |
| 検証 metric | `CAPEX_CC_METRIC_APPLICABILITY` | `:applicable` / `:not_applicable_role` / `:not_applicable_latent` / `:unavailable_data` |

**5 値目を追加しない**（ADR 0015 の「実行ステータスを 4 値に固定する」と同型の規律）。新たな失敗の種類が必要になった場合は本書の改訂として処理する。

**同一視しないもの**（ADR 0015 決定 15 の継承）: `:missing_series`（provider に系列が無い）・`:unavailable_upstream`（`CAPEX_CC_PROVIDER_GAPS` に登録済みの既知の不足）・`:provider_error`（一時的な取得失敗）・`:invalid_response`（形式違反）は別値として保持する。`:not_identified`（構造的に識別できない）と `:insufficient_data`（データが足りない）も同一視しない。

---

## 7. 標本・頻度・vintage semantics

### 7.1 基準経済と時間軸

米国・四半期を維持する（#170 §2.1）。共通時間軸は四半期ラベル `"YYYY-Qn"` を `year + (n−1)·0.25` へ変換した数値時間で扱い、**文字列順で結合しない**（`_parse_quarter_label` 相当を measurement 層に持つ。Keen 実証層と同じ規律）。

### 7.2 標本端点の決定（`Z-29`）

| 項目 | 規約 |
|---|---|
| 端点 | `role == :calibration_required` のキーがすべて非欠損である最初と最後の四半期（inner join） |
| `binding_series` | 端点を決めたキーを記録する。複数ある場合はすべて記録する |
| `:estimation_input` の欠損 | **標本を縮めない**。当該ブロックの `required_keys` を満たさない場合は `:insufficient_data` として推定しない（#170 §7.4-1） |
| `:validation_only` の欠損 | 標本にも推定にも影響しない。検証で `:unavailable_data` として報告する |
| 手動指定 | `sample_start` / `sample_end` を明示的に与えた場合はそれを優先し、自動決定との差を `warnings` に記録する |
| 最低観測数 | `min_valid_obs`（既定 8）を下回る場合は例外（暗黙に短い標本で較正しない） |

### 7.3 時点基準と集計方式（`Z-05`）

| モデルの時点基準 | 観測の集計方式 | 実装 |
|---|---|---|
| `SUM`（四半期合計） | `:sum`（月次）／四半期公表はそのまま。`annualized == true` なら `÷ 4` | measurement 層 |
| `AVG`（四半期平均） | `:mean` | `to_quarterly(:mean)` |
| `EOP`（期末値） | `:end` | `to_quarterly(:end)` |
| `BOP`（期首値） | **独立の集計方式として実装しない**。`EOP` 系列の 1 期ラグとして構成する | measurement 層 |

日次系列は provider から月次で受け取る（`Z-04`）。年次系列は `capex_annual_to_quarterly` で四半期化し、方式を `transformations` へ残す。

### 7.4 欠損

`fill_missing(:zero)` を既定にしない。補完は spec で明示された系列のみ。inner join 後に残る欠損期は推定 objective・検証 metric の有効ペアから除外し、除外期数と理由を `exclusion_reasons` へ記録する。`NaN` を `0` として扱わない（#170 §2.3）。

### 7.5 vintage（`Z-21`）

| 項目 | 決定 |
|---|---|
| `vintage_mode` | **`:latest_only` の 1 値のみ**。将来値（`:as_of`）を語彙へ先取りしない |
| `data_vintage` の記録 | provider が申告した値。**未申告のときは `"unknown"`** とし、`"latest"` と書かない |
| `provider_vintage` metadata | provider が返す場合は保存する。**保存と能力表示に限定**し、値の as-of 再生には用いない |
| `retrieved_at` | raw observation manifest に保存し、canonical hash から除外する（`Z-26`） |
| 改定の追跡 | 行わない。定義変更・改定により結果が変わった場合は「変わった事実を報告する」義務のみ（#170 §2.4） |
| 禁止 | 「その時点で判断できた」「当時利用可能だった情報だけで再現した」という記述。この禁止を LLM 説明層へ引き渡す（§11.4） |

---

## 8. 較正・推定の責務割当

### 8.1 6 区分とコード上の注入点

| 区分 | 決め方 | コード上の注入点 | 上書き可否 |
|---|---|---|---|
| `FIX` | 定義・制度・数値下限 | `_ccc_default_behavioral` / `_ccc_default_policy` / `_ccc_calibrate_structural` の定数 | 不可 |
| `CAL-SS` | 定常水準から閉形式で逆算 | `CapexCreditCycleTargets.values`（48 キー） | 不可（`structural` で上書きしようとすると例外） |
| `CAL-OBS` | 観測比率・文献値から直接較正 | `behavioral` / `policy` / **`structural`**（`Z-09`） | 較正層が与える |
| `EST` | ブロック別に推定（35 個。`Z-14`） | `estimate_capex_block` の結果を `behavioral` へ merge | 推定層が与える |
| `SCN` | シナリオ入力 | `exog` / `state0` / `CapexShockSpec` / `ScenarioAssumption` | `parameters` に含めない |
| `SENS` | 既定値 + 走査 | 既定値のまま。感応度層が variant ごとに差し替える | 感応度層が与える |

**契約**: `parameters(m)` の 147 個すべてについて `parameter_provenance` が 6 区分のいずれか 1 つを返す（区分の欠落・重複を許さない。#170 §7.1）。区分と「感応度走査の対象であること」は直交する（#170 §15.1）。

### 8.2 48 target キーの観測対応（`Z-07`・`Z-08`）

`CAPEX_CC_TARGET_KEYS` の全 48 キーについて `source_kind` と算出方法を固定する。**`:observed` 以外のキーを「観測から較正した」と申告しない。**

| # | キー群 | `source_kind` | 算出方法 |
|---|---|---|---|
| 1 | `y_s2`・`y_s3` | `:observed` | FRB IP 指数（`IPG3344S` / `IPG333S`）を BEA 産業別実質産出額でアンカー水準化（#170 §4.3）。baseline 8 四半期平均 |
| 2 | `y_s1` | `:observed` | BEA GDP by Industry（データ処理・ホスティング関連）。部門範囲が過大（`scope_bias = :over`） |
| 3 | `y_s5` | `:derived` | `GDPC1 − Σ_{s∈{S1,S2,S3}} va_s`（#170 §3.2-5） |
| 4 | `util_s2`・`util_s3` | `:observed` | FRB 稼働率 `CAPUTLG3344S` / `CAPUTLG333S`（`÷ 100`）。定義差は `proxy` として記録 |
| 5 | `emp_s1`–`emp_s3`・`emp_s5` | `:observed` | BLS CES 部門別。`emp_s5 = PAYEMS − Σ emp_s`（`:derived`） |
| 6 | `cap_s1`–`cap_s3` | `:observed` | BEA 固定資産統計（年次 → `capex_annual_to_quarterly`） |
| 7 | `dep_s1`–`dep_s3` | `:observed` | BEA 固定資本減耗（年次 `÷ 4` → 四半期化） |
| 8 | `capex_pipe_s1`–`_s3` | `:literature` | `capex_pipe_s^{ss} = st_pipelag_s^{lit} · dep_s^{ss}`（既定 `st_pipelag_s = 3` 四半期。#170 §5.2-4）。**観測しない**（`E` 分類） |
| 9 | `order_cap_s2`・`order_cap_s3` | `:derived` | Census M3 資本財相当 + BEA 投資の財別内訳による按分（`allocation`）。`st_capex_share_s` の較正元。**`alternative proxy` 感応度の必須対象**（`ID-3`） |
| 10 | `order_inv_s3` | `:derived` | 同上（`st_invest_share_s3` の較正元） |
| 11 | `backlog_s2`・`backlog_s3`・`inv_s2`・`inv_s3` | `:observed` | Census M3 受注残・在庫（`:end`） |
| 12 | `ext_demand_s2`・`ext_demand_s3` | `:derived` | §8.3 の残差構成規則（`allocation`）。**残差であることを出力へ明記する**（#170 §4.3） |
| 13 | `va_s1`–`va_s3` | `:observed` | BEA GDP by Industry 実質付加価値（年率 `÷ 4`） |
| 14 | `wagebill_s1`–`_s3`・`wagebill_s5` | `:derived` | BEA/BLS 産業別雇用者報酬。`wagebill_s5` は総額から `S1`–`S3` を控除 |
| 15 | `debt_s1`–`_s3` | `:derived` | FRB Z.1 B.103 総額 × 按分キー（`allocation`。既定は `sales_s` シェア）。**按分キーの感応度必須**（`ID-2`） |
| 16 | `cash_s1`–`_s3` | `:derived` | Z.1 の現金性資産 × 同一按分キー |
| 17 | `spread` | `:observed` | ICE BofA OAS（日次 → 月次 → 四半期平均。`Z-04`） |
| 18 | `policy_rate` | `:observed` | `FEDFUNDS`（四半期平均） |
| 19 | `cost_capital_s1`–`_s3` | `:literature` | `cost_capital_s^{ss} = st_cc0_s^{lit} + bh_cc_spread · spread^{ss}/100`。**観測しない**（`E` 分類・#165 §5.4 の「単独の水準を分析結果として提示しない」） |
| 20 | `cons` | `:observed` | `PCECC96`（年率 `÷ 4`）。部門範囲が過小（`scope_bias = :under`） |
| 21 | `cons_s1` | `:assumption` | `cons_s1^{ss} = st_cons_share_s1^{obs} · y_s1^{ss}`。`st_cons_share_s1` は `CAL-OBS`。**観測しない**（`A` 分類） |

`structural` 経由で渡す `CAL-OBS` の `st_`（`Z-09`・`Z-11`）:

| パラメータ | 算出 | 備考 |
|---|---|---|
| `st_cshare_s3` | BLS CES の建設 23 + 公益 22 が `emp_s3` に占める比 | 実装既定 0.3 |
| `st_cash_min_s1`–`_s3` | Z.1 の現金/売上比の下位分位 | 実装既定 0.05。許容条件 11 を検査 |
| `st_dcap_s1`–`_s3` | `debt_s^{ss} / y_s^{ss}` の倍率。倍率は `CAL-OBS` 入力 | 実装既定 2.0（`Z-10`） |
| `st_pipelag_s1`–`_s3` | 業界の着工〜完工期間（既定 3 四半期） | `alternative proxy` 感応度の必須対象 |
| `st_maturity_s1`–`_s3` | `SENS`。文献・社債市場の平均残存期間 | 実装既定 5.0。企業開示を使わない（ADR 0012 決定 6） |
| `st_commit_s1` | `SENS`。契約確定比率の観測が無い | 実装既定 0.5 |
| `st_coll_ltv` | `CAL-SS`（余裕幅は `SENS`） | 実装既定の余裕幅 1.65。許容条件 14 を満たすよう選ぶ |
| `st_cor_s1` | **`SENS`**（`util_s1^{ss}` が観測できず自由度が残る。`Z-11`） | 実装既定 2.0 |

### 8.3 `ext_demand_s^{ss}` の識別仮定（`Z-12`）

定常水準の恒等式（実装の `_ccc_calibrate_structural`）は

```
y_s^{ss} = order_cap_s^{ss} ( + order_inv_s3^{ss} ) + order_gen_s^{ss} + ext_demand_s^{ss}
```

であり、**`order_gen_s^{ss}` と `ext_demand_s^{ss}` の和のみが観測から決まる**。分割には追加の識別仮定が要る。

**決定**: `st_gen_share_s` を **baseline 期間より長い共通利用可能期間での `order_s` の `y_s5` に対する比**として `CAL-OBS` で先に与え、`ext_demand_s^{ss}` を残差とする。

| 論点 | 規約 |
|---|---|
| 推定窓 | baseline 8 四半期ではなく標本全体（`sample_start`–`sample_end`）。窓の指定を metadata へ保存する |
| methodology | `allocation`。按分キーは `y_s5`。#170 §10.4 の `alternative proxy` 感応度の**必須対象**に加える |
| 負値 | `ext_demand_s^{ss} < 0` を**クリップしない**。配分比が過大であることを示す診断として報告する（#170 §4.3 の 3 契約） |
| 分散 | `ext_demand_s` の分散が `order_s` の分散を超える場合、`ID-3` の対応（`W2`）を適用する |
| 出力 | `ext_demand_s` の水準・変動を「モデル外需要の推定値」として提示しない。**残差であることを `CapexTargetSpec.formula` と検証出力へ明記する** |

### 8.4 推定ブロックと `EST` の総数（`Z-14`）

| ブロック | 順序 | `EST` | 内訳 |
|---|---|---|---|
| `EB-1` 金融条件 | 1 | 4 | `bh_fc_pol`・`bh_spread_cov`・`bh_spread_fc`・`bh_lend_spread` |
| `EB-3` 生産・在庫・受注残 | 2 | 4 | `bh_inv_adj_s2`/`_s3`・`bh_prod_cut_s2`/`_s3` |
| `EB-4` 価格 | 3 | 4 | `bh_price_adj_s2`/`_s3`・`bh_price_sens_s2`/`_s3` |
| `EB-6` 雇用・賃金 | 4 | **9** | `bh_emp_up_s1`/`_s2`/`_s3`/`_s5`・`bh_emp_down_s1`/`_s2`/`_s3`/`_s5`・`bh_wage_slope` |
| `EB-7` 消費 | 5 | 2 | `bh_mpc`・`bh_cons_adj` |
| `EB-5` CAPEX・投資 | 6 | 9 | `bh_alpha_capex_s1`・`bh_cc_elas_s1`・`bh_alpha_inv_s2`/`_s3`・`bh_cc_elas_inv_s2`/`_s3`・`bh_lend_elas_inv_s2`/`_s3`・`bh_defer_roll` |
| `EB-2` 資本コスト・評価・担保 | 7 | 3 | `bh_ev_elas`・`bh_coll_elas`・`bh_roll_slope`（`bh_cc_lend`/`bh_cc_equity`/`bh_cc_fc` は `W1` 事前適用で `CAL-OBS`） |
| **合計** | — | **35** | — |

`bh_emp_up_s4`・`bh_emp_down_s4`・`bh_emp_band_s4` は **`emp_s4` が存在しないため対象外**（`st_lprod_s4`・`st_wbase_s4` と同じ辞書上の空き値）。推定・較正・感応度のいずれの対象にもしない。

### 8.5 objective と残差関数（`Z-15`）

| 論点 | 決定 |
|---|---|
| objective | 方程式別残差（#170 §7.4-3）。trajectory matching を採らない |
| 実装場所 | **推定層に閉じる**。`src/models/capex_credit_cycle.jl` へ単一方程式の公開 API を追加しない |
| 命名 | 残差関数名を #169 の式 ID と 1:1 対応させる（例 `_ccc_resid_E5_01`）。`CapexEstimationBlockSpec.equation_ids` と一致させる |
| 二重実装の統制 | **同一入力に対し、モデル 1 期実行の中間値と残差関数の右辺が一致することを回帰テストで保証する**（§12.4）。一致しない場合はテストが落ちる |
| 重み | 方程式ごとの観測標準偏差の逆数（`:std_normalize`）を既定とし、実際に用いた重みを保存する。単一の総合スコアへ集約しない |
| 除外 | 欠損期・`NaN`/`Inf`・符号制約違反期・out-of-sample 区間を除外し、除外期数と理由を記録する |
| 決定性 | multi-start の初期値摂動は決定的な擬似乱数（seed を config へ保存。Keen 実証層と同方式）で生成する |

### 8.6 弱識別対応の 2 段（`Z-16`）

| 段 | 対象 | 時点 | 内容 |
|---|---|---|---|
| **事前適用** | `W1`（対応する観測変数が `E`）・`W4`（必要系列が揃わない／閾値パラメータ） | dataset と catalog から**推定前**に判定 | 当該パラメータを `est_params` から外し、`CAL-OBS` / `SENS` へ移す。移した事実と移動先を記録する |
| **事前固定・事後発火** | `W2`（範囲報告）・`W3`（複数仕様併記） | 適用先と閾値を**推定前に config へ固定**し、発火の有無のみ推定後に決める | `armed_actions` に記録。曲率・相関・境界張り付き・proxy 依存の閾値を結果を見て変えない |

**契約**: `W2` / `W3` の閾値を変更する場合は `CapexEstimationConfig` の version を上げ、**変更前後の結果を両方保存する**。「推定後に規則を選ぶ」ことを構造的に不可能にする。**弱識別を理由に推定対象を増やさない**（#170 §8.3-3）。

---

## 9. 履歴再生

### 9.1 episode の構成（`P-7` / #247）

```julia
const CAPEX_CC_EPISODE_IDS = (:H1, :H2, :H3, :H4, :H5, :H6)
const CAPEX_CC_EPISODE_STATUSES = (:selected, :excluded, :insufficient_data)

struct CapexHistoricalEpisodeSpec
    id::Symbol                      # :H1 … :H6
    label::String
    period_zero::CalendarQuarter    # 評価区間の起点（イベント層と同じ型）
    runup_quarters::Int             # 既定 8
    eval_quarters::Int              # 既定 20
    observed_events::Vector{ObservedEvent}       # L1（人手記録・magnitude 無しを許す。Z-20）
    assumptions::Vector{ScenarioAssumption}      # L3（magnitude_source を必ず持つ）
    interpretation_notes::String                 # L2 に相当する人手の解釈（自動生成しない）
    in_sample::Bool                              # false なら out-of-sample 用
    notes::String
end

struct CapexEpisodeAssessment
    id::Symbol
    status::Symbol                   # CAPEX_CC_EPISODE_STATUSES
    nc_results::Dict{Symbol, Bool}   # :NC1 … :NC7
    nc_details::Dict{Symbol, String}
    missing_keys::Vector{Symbol}
    coverage_start::Union{String, Nothing}
    coverage_end::Union{String, Nothing}
    exclusion_reason::String
    episode_hash::String
end

assess_capex_episodes(ds::CapexEmpiricalDataset;
                      specs = CAPEX_CC_EPISODE_SPECS) -> Vector{CapexEpisodeAssessment}
```

**契約**:

1. `NC-1`–`NC-7` の判定は dataset に対して**機械的に**行う。`NC-7`（集合レベル）は候補集合全体に対して評価する。
2. **`L1` から `L3` を自動生成しない**（`Z-20`・ADR 0010 決定 1）。`ObservedEvent` に magnitude が無い場合、`ScenarioAssumption` 側で `magnitude_source = :assumed` として与え、その事実を artifact へ残す。
3. 選定した候補と**除外した候補の除外理由**を両方記録する。fit を見た後の事後選択を行わない（ADR 0012 決定 20）。
4. `metadata["replay_kind"] = "revised_data_historical_replay"` を必須とし、**point-in-time replay ではないこと**を artifact に固定する（`Z-21`）。

### 9.2 実行の 3 段（`Z-18`）

`run_scenario` を**変更しない**。履歴再生層は次の 3 段を自前で行う。

```julia
struct CapexReplayOptions
    parameter_set_kind::Symbol        # CAPEX_CC_PARAMETER_SET_KINDS
    exog_runup_mode::Symbol           # :steady_state_fixed（既定・Z-19）
    model_options::CapexCreditCycleOptions
    validate_accounting::Bool         # 既定 true
    diagnostics::Bool                 # 既定 true
    on_unmapped::Symbol               # 既定 :reject（ADR 0015 決定 7 の継承）
end

struct CapexHistoricalReplayRun
    status::Symbol                    # CAPEX_CC_REPLAY_STATUSES
    episode::CapexHistoricalEpisodeSpec
    parameter_set::CapexParameterSet
    model::CapexCreditCycleModel
    exog::Dict{Symbol, Vector{Float64}}
    event_log::Vector{EventLogEntry}          # 既存型を再利用
    applied_inputs::Vector{AppliedModelInput}
    rejections::Vector{EventRejection}
    model_run::CapexCreditCycleRun
    result::Union{SimulationResult, Nothing}  # モデル層の 20 キーのまま（Z-25）
    observed::Dict{Symbol, Vector{Union{Float64, Missing}}}   # 比較用の観測（同一四半期軸）
    in_sample::Bool
    dataset_hash::String
    parameter_set_hash::String
    episode_hash::String
    event_set_hash::String
    replay_hash::String
    warnings::Vector{String}
    metadata::Dict{String, Any}
end

capex_historical_replay(m::CapexCreditCycleModel,
                        ep::CapexHistoricalEpisodeSpec,
                        ds::CapexEmpiricalDataset,
                        ps::CapexParameterSet;
                        options = CapexReplayOptions()) -> CapexHistoricalReplayRun
```

実行手順（固定順）:

1. **観測実現値から baseline 外生を構築する**。`policy_rate`・`ext_demand_s2`・`ext_demand_s3`・`price_s1` は評価区間で実現値、助走区間は定常値（`Z-19`）。`ai_exp`・`capex_plan_shock_ex`・`spread_shock_ex` は全期 baseline 値（観測に対応が無い `A` 分類）。
2. `schedule_events` でイベントを四半期へ割り当て、`compose_exogenous_paths(baseline, inputs, periods; assumptions)` で差分を重ねる。`compose_exogenous_paths` は baseline を引数で受けるため**既存 API の変更を要しない**。
3. `capex_run(m; exog = paths, options = model_options, validate_accounting, diagnostics)` を呼ぶ。会計検証 12 項目・診断を既存関数で実施する。

**禁止事項**:

- 内生変数へ観測値を上書きして系列を追従させる（tracking）こと。外生扱いは `CAPEX_CC_EXOGENOUS_VARIABLES` の 7 変数に限る。
- `Q4`（金融緩和による遮断の判定）を履歴再生から行うこと（ADR 0012 決定 17・`ID-6`）。理論シナリオ `Sc3` vs `Sc4` の反実仮想比較に限る。
- 観測から `A`（増幅度）を計算すること（ADR 0012 決定 18・`Z-23`）。

### 9.3 助走区間の扱い（`Z-19`）

| 論点 | 決定 |
|---|---|
| 助走 8 四半期の外生 | **定常値に固定する**（`exog_runup_mode = :steady_state_fixed`）。実現値パスを助走へ与えない |
| 理由 | モデルは定常状態から出発するため、助走で外生が動くと `runup_deviation` が必ず発生し、`runup_tol`（既定 `1e-8`）を緩める以外に回避できない。閾値を結果に合わせて緩めない |
| 記録 | `metadata["exog_runup_mode"]` を必須とする。評価区間のみ実現値であることを検証出力へ添える |
| 比較 | 観測とモデルの比較は baseline 比乖離 `dx_t` で行う（#170 §9.3）。観測側の `dx_t` は助走期間平均を `x^{base}` として計算する |
| 限界 | 観測の `dx_t` はトレンドを含み、モデルの `dx_t` は含まない。この非対称性を metric の解釈へ必ず添える（§2.4） |

### 9.4 parameter set の比較（#248）

同一 episode・同一入力条件で `:literature_default` と `:calibrated` / `:estimated` を**別 run** として実行する。`in_sample` / out-of-sample を `metadata` へ必須保存する。**calibrated が literature/default より悪化した場合は `calibrated_worse_than_literature` として明示し隠さない**（#170 §10.1）。

---

## 10. 検証と robustness

### 10.1 4 レイヤーの分離（#170 §10.1 の実装）

| レイヤー | 対応する dimension | 集約 |
|---|---|---|
| 数値fit | `:numerical_fit` | 変数別。総合点を作らない |
| 動学・構造 | `:turning_point`・`:timing`・`:direction`・`:persistence`・`:credit_amplification`・`:propagation` | 項目別の真偽・時点差 |
| 比較 | parameter set 別・in/out-sample 別・variant 別 | 同一 schema で並置 |
| 数値解法頑健性 | `CapexRobustnessReport` の軸 7 | 設定別の差 |

```julia
const CAPEX_CC_VALIDATION_DIMENSIONS = (:numerical_fit, :turning_point, :timing,
                                        :direction, :persistence,
                                        :credit_amplification, :propagation)
const CAPEX_CC_METRIC_APPLICABILITY = (:applicable, :not_applicable_role,
                                       :not_applicable_latent, :unavailable_data)

struct CapexSeriesFit
    key::Symbol
    model_var::Symbol
    observability::Symbol             # :D / :C / :P（:E / :A は対象にしない）
    applicability::Symbol             # CAPEX_CC_METRIC_APPLICABILITY
    evidence_tier::Symbol             # :direct / :composed / :proxy / :allocation
    rmse::Union{Float64, Nothing}
    mae::Union{Float64, Nothing}
    rmse_standardized::Union{Float64, Nothing}
    correlation_level::Union{Float64, Nothing}
    correlation_diff::Union{Float64, Nothing}
    bias::Union{Float64, Nothing}
    n_pairs::Int
    n_excluded::Int
    caveats::Vector{String}
end

struct CapexEmpiricalValidationReport
    episode::Symbol
    parameter_set_kind::Symbol
    in_sample::Bool
    fits::Dict{Symbol, CapexSeriesFit}
    turning_points::Dict{Symbol, NamedTuple}     # peak/bottom の個数と timing error（四半期）
    onset_order::Vector{Symbol}                  # 悪化開始時点の順序（モデル / 観測を別に保持）
    onset_order_observed::Vector{Symbol}
    direction_agreement::Dict{Symbol, Float64}
    persistence::Dict{Symbol, Int}
    credit_amplification::Dict{String, Float64}  # モデル内 A の episode 間比較のみ（Z-23）
    diagnostic_label::Symbol                     # 報告のみ（Z-24）
    accounting::Any                              # 12 項目の結果
    warnings::Vector{String}
    caveats::Vector{String}
    metadata::Dict{String, Any}
end

validate_capex_empirical(run::CapexHistoricalReplayRun,
                         ds::CapexEmpiricalDataset) -> CapexEmpiricalValidationReport
```

### 10.2 転換点・onset の共有（`Z-22`）

転換点・onset・持続期間の検出は `src/analysis/scenario_diagnostics.jl` の非 export 純関数へ切り出し、シナリオ比較診断と実証検証層の**両方が同じ実装を呼ぶ**。`scenario_comparison` の公開シグネチャ・戻り値・数値は変更しない。検出規則には version を持たせ、`metadata["turning_point_rule_version"]` へ記録する。

### 10.3 禁止事項（型で担保する）

| 禁止 | 型上の担保 |
|---|---|
| 単一総合スコアへの集約 | `CapexEmpiricalValidationReport` に総合スコアのフィールドを置かない |
| 単一 pass/fail gate | `passed::Bool` を持たない。dimension 別の値と `applicability` のみ |
| `P` 分類の水準 fit を根拠として提示 | `CapexSeriesFit.evidence_tier` を必須とし、`:proxy` / `:allocation` を出力へ必ず添える |
| `E` / `A` 分類の fit 計算 | `applicability = :not_applicable_latent` とし、metric を `nothing` にする |
| 観測からの増幅度算出 | `credit_amplification` はモデル内 `credit-off` 反実仮想の値のみを持つ。観測側フィールドを作らない |
| 診断ラベル一致率の目的関数化 | `label_agreement_rate` のフィールドを作らない。`diagnostic_label` と variant 別のラベル一覧のみ |
| 公式景気後退判定との一致率 | フィールドを作らない。記述的な言及に留める |
| 打ち切り後の `0` 補完 | 有効区間のみを評価し、`n_excluded` に理由つきで記録する |

### 10.4 caveats の必須項目

検証出力の `caveats` へ必ず含める（LLM 説明層へ引き渡す）。

1. point-in-time replay ではなく、現在利用可能な**改定後データ**による履歴再生である（`Z-21`）。
2. fit は因果妥当性・景気後退確率・投資助言ではない（ADR 0012 決定 24）。
3. `P` / `allocation` 系列と direct 観測を区別している（`evidence_tier`）。
4. 弱識別パラメータの扱い（`W1`–`W4` の適用先と結果）。
5. 企業開示を較正入力に用いていない範囲（`S1` の収益ブロックと `R1a` の非検証）。
6. 観測とモデルの `dx_t` の非対称性（トレンドの扱い、§9.3）。
7. `SH-EXP` の規模は走査結果であり較正値ではない。
8. `unmapped` イベント・モデル境界（表現できないイベントを近似で寄せていない）。

### 10.5 robustness の軸（`P-10` / #250）

```julia
const CAPEX_CC_SENSITIVITY_AXES = (:proxy, :sample, :binding_series, :event_timing,
                                   :event_magnitude, :weak_id_parameter, :threshold)
```

| 軸 | 内容 | 必須対象 |
|---|---|---|
| `:proxy` | primary series と許可された fallback proxy の入れ替え | `spread`（HY / IG）・`debt_s`/`int_burden_s` の按分キー・`ai_exp` の 3 仕様・`st_capex_share_s` の配分比・`y_s` のアンカー基準年・`ycap_s` の 2 方式（#170 §10.4） |
| `:sample` | 事前定義した標本 window の変更 | in/out-sample の役割が変わる場合は**別 run** として扱う |
| `:binding_series` | binding series の除外可否（較正必須契約を破らない範囲） | `binding_series` に現れたキー |
| `:event_timing` | ±1 四半期（[シナリオ時間軸](scenario_time_semantics.md) §4.6 の義務） | `scenario_timing_sensitivity` の既存実装を再利用 |
| `:event_magnitude` | 観測されていない magnitude の走査 | **「推定誤差」ではなく `scenario assumption sensitivity` として表現する** |
| `:weak_id_parameter` | `W2` / `W3` / `W4` の range・alternate spec | 範囲を報告し点推定を作らない |
| `:threshold` | 診断閾値 ±50%・`breadth` の 3 通りの離散比較・`S1` 除外版 | #170 §7.6 の義務 |

**契約**:

1. **1 軸ずつ（one-axis-at-a-time）を既定とする**。多軸同時走査を既定にしない（帰属可能性を保つため）。
2. baseline 仕様を明示し、各 variant が**何を 1 点だけ変えたか**を artifact へ保存する。
3. proxy 変更時は `evidence_tier` と methodology metadata を variant ごとに更新する。
4. `:invalid` / `:failed` な variant を黙って除外して平均しない。失敗理由を保持する。
5. best-fit 仕様を自動採用しない。結果を確率へ変換しない。
6. ラベルが変わった variant を `label_changed_variants` として列挙する（一致率にしない。`Z-24`）。

---

## 11. version・provenance・artifact 契約

### 11.1 `SimulationResult` を変更しない（`Z-25`）

| 論点 | 決定 |
|---|---|
| `SimulationResult` 型 | **変更しない**（ADR 0009 決定 8・ADR 0013 決定 13 の継承） |
| metadata 予約キー 20 個（#171 §6.1） | **追加も変更もしない**。replay が生成する `SimulationResult` はモデル層の 20 キーのまま |
| 実証情報の保持場所 | `CapexHistoricalReplayRun`・`CapexEmpiricalCalibration`・`CapexParameterSet` 等の実証層の結果型が並置して保持する |
| 理由 | モデル層が実証層を知らない構造を維持する。`SimulationResult` を消費する既存の比較 API・可視化・LLM 層が実証層のキーを前提にしない |

### 11.2 provenance の連結

artifact 間を次の identity で連結する。

```
catalog_version
  → dataset_hash        （catalog + provider series ID + 変換式 + sample + 値）
      → targets_hash    （dataset_hash + 48 キーの値 + target_specs + structural_overrides）
          → parameter_set_hash  （targets_hash + block spec + config + 推定値 + kind）
              → replay_hash     （parameter_set_hash + episode_hash + event_set_hash + exog + options）
      → episode_hash    （episode spec + L1/L3 + window + dataset_hash）
```

各段の結果型は**上流の hash をフィールドとして保持する**。artifact 単体から上流を辿れる状態にする。

### 11.3 hash 対象（`Z-26`・`Z-27`）

すべて `sha256_hex_of_canonical`（RFC 8785 正準化 + SHA-256、`src/artifacts/json_canonical.jl`）で算出する。

| hash | 対象に**含める** | 対象から**除外する**（volatile / 秘密） |
|---|---|---|
| `dataset_hash` | catalog 版・系列 ID・変換式・sample・値 | `retrieved_at`・`provider_base`・実行時刻・`mode`（fixture/live の別） |
| `targets_hash` | `dataset_hash`・48 キーの値・`target_specs`・`structural_overrides` | `targets.source` の自由記述 |
| `parameter_set_hash` | `targets_hash`・block spec・config（seed を含む）・推定値・`kind` | 反復回数・所要時間 |
| `episode_hash` | episode spec・`L1`/`L3`・window・`dataset_hash` | 記述的な `notes` |
| `replay_hash` | `parameter_set_hash`・`episode_hash`・`event_set_hash`・外生パス・`CapexReplayOptions` | 警告の順序に依存しない形へ正規化した上で除外しない（警告は含める） |

**契約**: 同一 fixture・同一 config から**同一 hash と同一数値**が再現される（§12.7）。`mode` を hash に含めないのは、fixture と live で同じ値が得られる場合に artifact が一致すべきだからである（値が異なれば `dataset_hash` が異なる）。

### 11.4 秘密情報と LLM 説明層

| 項目 | 規約 |
|---|---|
| 保存しないもの | API キー・token・credential を含む URL・環境変数値・ローカル絶対パス（#170 §6.6・Keen 実証層と同方針） |
| 根拠階層 | 観測（`D`/`C`/`P`）・逆較正（`CAL-SS`）・推定（`EST`）・モデル出力・診断・感応度を分離して出力する（ADR 0005 の category へ写像） |
| 禁止表現 | 「その時点で判断できた」「当時利用可能だった情報で再現した」「Digital Shadow / Digital Twin」（[ADR 0014](../adr/0014-digital-twin-naming-conditions.md)）・fit を因果/危機確率/投資助言へ読み替える表現 |
| 非有限値 | JSON `null` として保存し `0` 化しない |

---

## 12. テスト戦略

分類 7・**合計 62 項目**。各 Issue の受け入れ条件は本節の項目番号を参照する。

### 12.1 catalog（8 項目）

1. `validate_capex_series_catalog` が全エントリを通す。
2. `source_kind == :firm_disclosure` かつ `role ∈ (:calibration_required, :estimation_input)` を拒否する。
3. `level_form == :index` かつ `anchor === nothing` を拒否する。
4. `methodology == :allocation` かつ `allocation_key === nothing` を拒否する。
5. `methodology == :proxy` かつ `scope_bias == :none` を拒否する。
6. `observability ∈ (:E, :A)` かつ較正/推定 role を拒否する。
7. `key` の重複と、時点基準×集計方式の非整合な組を拒否する。
8. catalog の系列 ID 集合と `docs/data/capex_credit_cycle_series_catalog.md` の記載が一致する。

### 12.2 raw observation（9 項目）

9. 正常応答から `status = :ok` の `CapexRawObservation` を得る。
10. 空系列・必須 field 欠損・未知 unit・HTTP error・timeout 相当が別 status になる。
11. `CAPEX_CC_PROVIDER_GAPS` 登録済みキーが `:unavailable_upstream` になり `:provider_error` と区別される。
12. 取得失敗が空系列・`0` 埋めへ変換されない。
13. fixture と `:rest_api` が同一 decoder を通り同じ contract を返す。
14. provider が返さない metadata が `missing` になり、catalog の `declared_*` で埋められない。
15. `declared_*` と `provider_*` の不一致が `metadata_mismatches` に記録され、取得を失敗させない。
16. 複数系列の取得順を shuffle しても同一 `CapexRawDataset` identity になる。
17. credential を含む URL・API キーが `metadata` へ入らない。

### 12.3 measurement / dataset（11 項目）

18. 月次フロー（`:sum`）・月次ストック（`:end`）・月次レート（`:mean`）が期待値と一致する（手計算可能な小規模 fixture）。
19. `annualized == true` の系列に `÷ 4` が適用され、`false` には適用されない。
20. 指数系列がアンカー方式で水準化され、`anchor_detail` に基準年が残る。
21. 年次系列が `capex_annual_to_quarterly` で四半期化され、方式が `transformations` に残る。
22. `BOP` が `EOP` + 1 期ラグとして構成される。
23. 変換の各段が `stages` に残り、最終値のみになっていない。
24. `:calibration_required` のみで標本端点が決まり、`binding_series` が記録される。
25. `:estimation_input` の欠損が標本を縮めない。
26. `:validation_only` が `roles` で識別でき、較正入力から機械的に除外できる。
27. `observability ∈ (:E, :A)` のキーに値が入らない（補完されない）。
28. 入力系列の順序・`Dict` 順に依存せず同一 `dataset_hash` になる。

### 12.4 較正（10 項目）

29. 48 キーすべてに `CapexTargetSpec` があり、`source_kind` が付く。
30. `source_kind == :literature` に `reference` が無い場合 `:default_unattributed` になる。
31. `structural` で `CAPEX_CC_STRUCTURAL_OVERRIDABLE` 以外を渡すと `ArgumentError`。
32. `structural` を渡さない場合、既存の `capex_credit_cycle_model(targets)` と**同一のパラメータ**を返す（非破壊の確認）。
33. `capex_credit_cycle_default_targets()` と同値の synthetic fixture で、既存（#179）の逆較正結果と一致する。
34. `SS-1`–`SS-17` 違反が `ss_inconsistent` として構造化され、自動補正されない。
35. 自由度なし整合条件の乖離が `ss_residual` に記録される。
36. `SCN` / `SENS` パラメータが較正で上書きされない。
37. `parameter_provenance` が 147 パラメータすべてに 6 区分のいずれか 1 つを返す（欠落・重複なし）。
38. 同一 dataset から同一 `targets_hash` を生成する。

### 12.5 識別・推定（11 項目）

39. `CAPEX_CC_ESTIMATION_BLOCKS` が 7 件で、`EST` 総数が 35 になる。
40. `bh_emp_up_s4`・`bh_emp_down_s4`・`bh_emp_band_s4` がどのブロックの `est_params` にも現れない。
41. 変動不足・短標本・近似特異・必須系列欠損が別 status になる。
42. proxy / allocation のみのキーが direct と同じ識別強度として扱われない。
43. `:not_identified` / `:insufficient_data` のブロックの推定要求が `ArgumentError` になる。
44. `W1` / `W4` が推定前に適用され、対象が `est_params` から外れる。
45. `W2` / `W3` の閾値が config に固定され、結果を見ずに発火判定される。
46. `FIX` / `CAL-SS` / `CAL-OBS` / `SCN` / `SENS` を `est_params` に入れると拒否される。
47. 境界張り付き・非収束・非有限 objective が別 status になり、post-hoc クリップされない。
48. **残差関数の右辺がモデル 1 期実行の中間値と一致する**（`Z-15` の二重実装統制）。
49. 同一 fixture / config から同一 `parameter_set_hash` を生成する（seed を含む決定性）。

### 12.6 履歴再生・検証・感応度（9 項目）

50. `H1`–`H6` すべてに `NC-1`–`NC-7` の判定と採否理由が付く。
51. `L1` に magnitude が無いイベントが `L3` で `magnitude_source = :assumed` になり、`L1` へ書き戻されない。
52. 助走区間の外生が定常値に固定され、`exog_runup_mode` が記録される。
53. 内生変数へ観測値を上書きする経路が無い（外生は 7 変数のみ）。
54. `:literature_default` と `:calibrated` が同一 episode / 入力で別 run として比較できる。
55. 打ち切り run で有効区間のみ評価され、残りが `0` 補完されない。
56. `E` / `A` 分類の変数に fit metric が適用されない（`:not_applicable_latent`）。
57. 感応度が 1 軸ずつ実行され、variant ごとに変更点が 1 つだけ記録される。
58. 失敗 variant が黙って除外されず、失敗理由が保持される。

### 12.7 統合・決定性（4 項目）

59. fixture モードで catalog → raw → measurement → dataset → 較正 → 識別 → 推定 → episode → replay → 検証 → 感応度を公開 API のみで完走する（外部ネットワーク・API キー不要）。
60. 2 回実行で canonical artifact と主要数値が一致する。
61. 保存済み artifact から同一結果を再構築できる。
62. 成功 run で会計検証 12 項目が `acc_pass` になる。

### 12.8 fixture

| 項目 | 規約 |
|---|---|
| 配置 | provider 応答は `test/fixtures/data/capex_credit_cycle/<series_id>.json`（`EDP` REST の応答形式と同一）。golden artifact は `test/fixtures/empirical/capex_credit_cycle/` |
| 範囲 | #170 §6.6 の最小セット（`EB-1`・`EB-3`・`EB-6`・`EB-7` に必要な系列と baseline 期間 + 履歴再生候補 1 件以上） |
| 決定性 | API キー不要・ネットワークアクセスなしで完走する。CI は fixture モードで動作させる |
| live smoke | 明示 opt-in（`DME_DATA_MODE=rest_api`）とし、CI の決定性を壊さない。`test_fred_live.jl` と同じ分離方式 |
| 秘密情報 | 保存しない |

---

## 13. 後続の実装作業への分解

追加の実証的・API 判断なしに着手できる粒度へ分解した 11 件。GitHub Issue #241–#251 と 1:1 対応する。

```
P-1(#241) ─> P-2(#242) ─> P-3(#243) ─┬─> P-4(#244) ─> P-5(#245) ─> P-6(#246) ─┐
                                    │                                        ├─> P-8(#248)
                                    └─> P-7(#247) ───────────────────────────┘        │
                                                                                      v
                                              P-11(#251) <─ P-10(#250) <─ P-9(#249) <──┘
```

`P-4` と `P-7` は `P-3` 完了後に並行できる。`P-8` は `P-6`（parameter artifact）と `P-7`（episode）の両方を必要とする。

### `P-1` 系列 catalog と provider 能力ギャップ（#241）

| 項目 | 内容 |
|---|---|
| 対象ファイル | `src/data/capex_credit_cycle_catalog.jl`（新規）・`src/DME.jl`・`docs/data/capex_credit_cycle_series_catalog.md`（新規）・`test/test_capex_credit_cycle_catalog.jl`（新規） |
| 実施内容 | `CapexSeriesSpec`（§5.1 の全フィールド）・`CAPEX_CC_SERIES_CATALOG`・`validate_capex_series_catalog`・`CapexProviderGap`・`CAPEX_CC_PROVIDER_GAPS`・JSON 出力。#170 §3.2 の 8 群と §6.2/§6.3 の系列を一次資料で確認して埋める |
| 依存 | なし |
| 対象外 | HTTP adapter・観測値の変換・較正 |
| 受け入れ条件 | §12.1 の 8 項目。`:firm_disclosure` が較正 role を持たない。`E`/`A` 分類が較正 role を持たない。gap が系列単位で列挙される |

### `P-2` provider adapter と raw observation（#242）

| 項目 | 内容 |
|---|---|
| 対象ファイル | `src/data/data_provider.jl`（新規）・`src/data/capex_credit_cycle_provider.jl`（新規）・`src/DME.jl`・`test/test_capex_credit_cycle_provider.jl`（新規）・`test/fixtures/data/capex_credit_cycle/` |
| 実施内容 | `DataProviderClient`・`fetch_provider_series`・`fetch_provider_catalog`（prefix をハードコードしない、`Z-02`）。`CapexRawObservation`・`CapexRawDataset`・`build_capex_raw_dataset`。`declared_*` / `provider_*` の分離と `metadata_mismatches` |
| 依存 | `P-1` |
| 対象外 | 観測方程式・頻度変換・`:as_of` 取得・`EDP` 側 endpoint |
| 受け入れ条件 | §12.2 の 9 項目。`FredClient` / `EStatClient` の既存挙動が変わらない（`test_fred.jl`・`test_estat.jl` が通る） |

### `P-3` 観測方程式・四半期変換・標本整列（#243）

| 項目 | 内容 |
|---|---|
| 対象ファイル | `src/data/capex_credit_cycle_measurements.jl`（新規）・`src/DME.jl`・`test/test_capex_credit_cycle_measurements.jl`（新規） |
| 実施内容 | 9 項目の適用・`annualized` の `÷ 4`・アンカー水準化・按分・`capex_annual_to_quarterly`・`BOP` のラグ構成・inner join と標本端点・`dataset_hash` |
| 依存 | `P-2` |
| 対象外 | 較正・推定・任意の季節調整推定 |
| 受け入れ条件 | §12.3 の 11 項目。`preprocess.jl` の `to_quarterly` を変更していない |

### `P-4` 定常水準・targets・逆較正（#244）

| 項目 | 内容 |
|---|---|
| 対象ファイル | `src/analysis/capex_credit_cycle_calibration.jl`（新規）・`src/models/capex_credit_cycle.jl`（`structural` 引数の追加のみ）・`src/DME.jl`・`test/test_capex_credit_cycle_calibration.jl`（新規） |
| 実施内容 | §8.2 の 48 キー表・§8.3 の識別仮定・`structural` の組み立てと validator・`SS` 検証・`ss_residual`・`parameter_provenance` |
| 依存 | `P-3` |
| 対象外 | `EST` の統計推定・ショック規模の較正・モデル方程式の変更 |
| 受け入れ条件 | §12.4 の 10 項目。既存の `test_capex_credit_cycle.jl` が通る（`structural` 追加が非破壊） |

### `P-5` 識別診断と `W1`–`W4`（#245）

| 項目 | 内容 |
|---|---|
| 対象ファイル | `src/analysis/capex_credit_cycle_identification.jl`（新規）・`src/DME.jl`・`test/test_capex_credit_cycle_identification.jl`（新規） |
| 実施内容 | `CAPEX_CC_ESTIMATION_BLOCKS`（7 件・`EST` 35）・`CapexIdentificationDiagnostic`・§8.6 の 2 段（事前適用 / 事前固定） |
| 依存 | `P-3`・`P-4` |
| 対象外 | パラメータ値の最適化・ブロック横断 API |
| 受け入れ条件 | §12.5 のうち 39〜42・44〜46。推定値を出さずに診断のみ実行できる |

### `P-6` ブロック別限定推定と parameter artifact（#246）

| 項目 | 内容 |
|---|---|
| 対象ファイル | `src/analysis/capex_credit_cycle_estimation.jl`（新規）・`src/DME.jl`・`test/test_capex_credit_cycle_estimation.jl`（新規） |
| 実施内容 | 式 ID と 1:1 の残差関数・`estimate_capex_block`・`CapexParameterSet`・`:literature_default` / `:calibrated` / `:estimated` の分離 |
| 依存 | `P-4`・`P-5` |
| 対象外 | 同時推定・MCMC・自動モデル選択 |
| 受け入れ条件 | §12.5 のうち 43・47〜49。特に **48（残差関数とモデル 1 期実行の一致）** |

### `P-7` 履歴再生候補の選定と episode（#247）

| 項目 | 内容 |
|---|---|
| 対象ファイル | `src/analysis/capex_credit_cycle_history.jl`（新規）・`src/DME.jl`・`docs/data/capex_credit_cycle_historical_episodes.md`（新規）・`test/test_capex_credit_cycle_history.jl`（新規）・`test/fixtures/empirical/capex_credit_cycle/episodes/` |
| 実施内容 | `CapexHistoricalEpisodeSpec`・`NC-1`–`NC-7` 判定・`L1`/`L3` の分離保持・`episode_hash`・`replay_kind` の固定 |
| 依存 | `P-1`・`P-3` |
| 対象外 | replay 実行・`:as_of` replay・fit を見た候補選択 |
| 受け入れ条件 | §12.6 のうち 50〜51。`H1`–`H6` 全件に判定と採否理由がある |

### `P-8` 履歴再生の実行と parameter set 比較（#248）

| 項目 | 内容 |
|---|---|
| 対象ファイル | `src/analysis/capex_credit_cycle_historical_replay.jl`（新規）・`src/DME.jl`・`test/test_capex_credit_cycle_historical_replay.jl`（新規） |
| 実施内容 | §9.2 の 3 段・`CapexReplayOptions`・`CapexHistoricalReplayRun`・`replay_hash`・in/out-sample の記録 |
| 依存 | `P-6`・`P-7` |
| 対象外 | 総合スコア・rolling 再推定・point-in-time replay |
| 受け入れ条件 | §12.6 のうち 52〜55。`run_scenario`・`compose_exogenous_paths` の公開 API を変更していない |

### `P-9` dimension 別検証（#249）

| 項目 | 内容 |
|---|---|
| 対象ファイル | `src/analysis/capex_credit_cycle_empirical_validation.jl`（新規）・`src/analysis/scenario_diagnostics.jl`（ヘルパー切り出しのみ）・`src/DME.jl`・`test/test_capex_credit_cycle_empirical_validation.jl`（新規） |
| 実施内容 | 7 dimension・`CapexSeriesFit`・`applicability` と `evidence_tier`・§10.3 の禁止事項の型上の担保・§10.4 の caveats |
| 依存 | `P-8` |
| 対象外 | 総合スコア・景気後退確率・他モデル比較 |
| 受け入れ条件 | §12.6 のうち 56。`scenario_comparison` の既存テストが通る（数値が変わらない） |

### `P-10` robustness / sensitivity（#250）

| 項目 | 内容 |
|---|---|
| 対象ファイル | `src/analysis/capex_credit_cycle_empirical_sensitivity.jl`（新規）・`src/DME.jl`・`test/test_capex_credit_cycle_empirical_sensitivity.jl`（新規） |
| 実施内容 | 7 軸の 1 軸ずつ実行・variant 追跡・失敗 variant の保持・`label_changed_variants` |
| 依存 | `P-9` |
| 対象外 | 無制限 grid search・best-fit の自動採用・確率変換 |
| 受け入れ条件 | §12.6 のうち 57〜58 |

### `P-11` 統合デモ・artifact・利用文書（#251）

| 項目 | 内容 |
|---|---|
| 対象ファイル | `examples/capex_credit_cycle_empirical_demo.jl`（新規）・`docs/examples/capex_credit_cycle_empirical_demo.md`（新規）・`test/test_capex_credit_cycle_empirical_demo.jl`（新規）・`test/runtests.jl`・`README.md`・`CLAUDE.md`・本書・#170 の status 同期 |
| 実施内容 | §3.1 の 7 段を公開 API のみで完走するデモ。§11.2 の identity 連結。§10.4 の caveats を最終レポートへ出力 |
| 依存 | `P-8`・`P-9`・`P-10` |
| 対象外 | live データを CI 必須にすること・Digital Shadow / Twin 表記・投資判断 |
| 受け入れ条件 | §12.7 の 4 項目。`Pkg.test()`・Aqua・JuliaFormatter・docs build が green |

**全 Issue に共通の受け入れ条件**: (a) `julia --project=. -e "using DME"` が通る、(b) 変更対象の関数に対する smoke test が通る、(c) `test_quality.jl`（Aqua・JuliaFormatter）が通る、(d) 本書・#170 に無い系列・変換・推定対象・閾値を独自に追加していない。

---

## 14. 引き渡し事項と未解決事項

### 14.1 後続フェーズへの引き渡し

| 引き渡し先 | 内容 |
|---|---|
| `EDP`（cross-repo） | §5.1 の `CAPEX_CC_PROVIDER_GAPS` を JSON で受け渡す。要求は「不足系列・不足 metadata（季節調整・基準年・年率表示・vintage）・不足頻度/履歴・fixture/live parity」の 4 種類に限る。**DME 側から公式 API を直接叩く実装は行わない** |
| モデル横断比較・説明（#125 Phase 4） | `CapexParameterSet` と `CapexEmpiricalValidationReport` が接続点。`equivalent` が存在しないため数値比較は `mechanism` モードに限る。`AnalysisContext` の拡張は Phase 4 |
| 異質性・逐次状態推定（#125 Phase 5） | vintage 対応（`:as_of`）・rolling calibration・状態推定は Phase 5。本書は `vintage_mode` を 1 値に固定し、語彙の先取りをしない。[ADR 0014](../adr/0014-digital-twin-naming-conditions.md) の `DS-1`–`DT-4` の充足判定も Phase 5 |
| LLM 説明層 | §10.4 の caveats 8 件・§11.4 の根拠階層と禁止表現。#170 §11 の限界 14 件 |

### 14.2 本書で解決しなかった事項

| 事項 | 状態 | 扱い |
|---|---|---|
| §2.4 の限界 8 件 | 保持 | `caveats`・警告・status として表現する |
| `FIX` / `CAL-OBS` 行動パラメータの文献値の出所 | 未特定 | `P-1`・`P-6` の実施事項。`:default_unattributed` を許す |
| `H1`–`H6` の最終選定 | 未確定 | `P-7` が実データに対して機械的に判定する |
| 標本期間の最終値 | 未確定 | `P-3` が `:calibration_required` の inner join から決定論的に算出する |
| `st_dcap_s` の倍率の妥当な水準 | 未確定 | 実装既定 2.0 を維持し、`P-4` が観測から与える。差は感応度で報告する |
| 残差関数とモデル本体の二重実装 | 保持 | §12.5-48 の一致テストで統制する。単一方程式 API をモデル層へ追加しない |
| `EDP` が vintage metadata を返す場合の保存形式 | 予約のみ | `provider_vintage` フィールドを持つが、値の as-of 再生には用いない |

---

## 15. 改訂履歴

| version | 日付 | 変更 |
|---|---|---|
| `capex-credit-cycle-empirical-integration/1.0.0` | 2026-09-01 | 初版（#240）。#170・ADR 0012 と実装済みモデル層・イベント層・データ層の整合レビュー（`Z-01`–`Z-30`）・データフロー 7 段・ファイル配置 11 本・公開型 24 個と公開関数 21 個・失敗契約 3 層と段別ステータス語彙・標本/頻度/vintage semantics・6 区分の注入点と 48 target キーの観測対応・`ext_demand_s^{ss}` の識別仮定・`EST` 総数 35 への修正・履歴再生の 3 段構成・検証 7 dimension と禁止事項の型上の担保・robustness 7 軸・hash 5 種と provenance 連結・テスト 62 項目・作業分解（`P-1`–`P-11`）を確定 |

---

## 参考

- [観測方程式・識別戦略・検証方針](../models/capex_credit_cycle_empirical_strategy.md) — 観測可能性 5 分類・観測方程式・パラメータ 6 区分・推定ブロック・識別リスク・履歴再生候補・検証契約・限界 14 件
- [部門別CAPEX・信用循環モデル 統合設計](capex_credit_cycle_integration.md) — `CCC` の公開 API・`CapexCreditCycleTargets`・metadata 予約キー 20 個・テスト戦略
- [イベント・シナリオ実行層 統合設計](macro_event_runtime_integration.md) — `Scenario`・`schedule_events`・`compose_exogenous_paths`・`ScenarioProvenance`・hash・replay
- [統合モデル仕様 index](../models/capex_credit_cycle_design.md) — 正典表・横断辞書
- [ADR 0018](../adr/0018-capex-credit-cycle-empirical-runtime-contract.md)・[ADR 0012](../adr/0012-capex-credit-cycle-empirical-contract.md)・[ADR 0013](../adr/0013-capex-credit-cycle-integration-contract.md)・[ADR 0014](../adr/0014-digital-twin-naming-conditions.md)・[ADR 0015](../adr/0015-macro-event-runtime-contract.md)
- [Keen モデル 実証化戦略](../models/keen_empirical_strategy.md)・[ADR 0004](../adr/0004-keen-empirical-calibration-strategy.md)・[ADR 0005](../adr/0005-keen-ai-explanation-contract.md) — 測定・識別・検証・根拠階層の設計原則の継承元
- [FRED API 接続ガイド](../data/fred.md)・[実データ前処理ユーティリティ](../data/preprocess.md)・[DataSeries / MacroDataset 利用ガイド](../data/data_series_guide.md)
- [LLM出力の安全性・免責・禁止表現ルール](../llm_safety.md)
