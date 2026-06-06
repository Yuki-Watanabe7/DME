# Mundell-Flemingモデル

> **Phase 3 / P2**
> 関連Issue: #48

---

## 1. 目的

`MundellFlemingModel` は小国開放経済における政策ショックの比較分析を提供する静学モデルである。
IS-LMモデルを開放経済へ拡張し、為替レート・国内金利・海外金利・純輸出を同時に扱う。

---

## 2. モデル構造

### 2.1 前提条件

- **小国仮定**: 世界利子率 `r*` は外生
- **完全資本移動**: 国際資本は自由に移動する
- **変動為替相場制**: 為替レート `e` は市場で決定される
- **物価固定**: 短期的に物価 `P` は固定（Mundell-Flemingの標準仮定）

### 2.2 方程式体系

```
IS:  Y = C(Y-T) + I(r) + G + NX(e)
LM:  M/P = l1*Y - l2*r
UIP: r = r*   （小国・完全資本移動）

C(Y-T) = c0 + c1*(Y-T)
I(r)   = I0 - b*r
NX(e)  = nx0 + nx1*e   （e: 高いほど自国通貨安）
```

### 2.3 解析解（均衡）

UIP条件 `r = r*` により、金利は外生として固定される。
LM方程式から産出 `Y` が決定され、国民所得恒等式から `NX`・`e` が導出される。

```
r  = r*
Y  = (M/P + l2*r*) / l1
C  = c0 + c1*(Y - T)
I  = I0 - b*r*
NX = Y - C - I - G
e  = (NX - nx0) / nx1
```

---

## 3. パラメータ

### 3.1 IS-LM継承パラメータ

| パラメータ | 説明 | 制約 |
|---|---|---|
| `c0` | 自律消費 | c0 > 0 |
| `c1` | 限界消費性向 MPC | 0 < c1 < 1 |
| `I0` | 自律投資 | I0 > 0 |
| `b` | 投資の利子率感応度 | b > 0 |
| `G` | 政府支出（財政政策変数） | G ≥ 0 |
| `T` | 定額税 | T ≥ 0 |
| `l1` | 貨幣需要の所得感応度 | l1 > 0 |
| `l2` | 貨幣需要の利子率感応度 | l2 > 0 |
| `M` | 名目マネーサプライ（金融政策変数） | M > 0 |
| `P` | 物価水準（短期固定） | P > 0 |

### 3.2 開放経済追加パラメータ

| パラメータ | 説明 | 制約 |
|---|---|---|
| `r_star` | 世界利子率（外生） | r_star > 0 |
| `nx0` | 自律的純輸出（切片） | — |
| `nx1` | 純輸出の為替感応度 | nx1 > 0 |

---

## 4. 変数

### 4.1 内生変数

| 変数 | 記号 | 説明 |
|---|---|---|
| 実質産出 | `Y` | 実質GDP |
| 国内金利 | `r` | 国内短期金利（= r*） |
| 為替レート | `e` | 名目為替レート（高いほど自国通貨安） |
| 純輸出 | `NX` | 輸出 − 輸入 |
| 消費 | `C` | 家計消費 |
| 投資 | `I` | 民間投資 |

---

## 5. Mundell-Fleming定理

変動為替相場制・完全資本移動のもとで成立する主要な政策命題。

### 5.1 財政政策は無効

政府支出 `G` を増加させても、産出 `Y` は変化しない。

**メカニズム**:
1. `G↑` → IS曲線が右シフト → 「国内金利上昇圧力」
2. しかし r = r* に固定されているため、資本流入が発生
3. 資本流入 → `e` が減少（自国通貨高）→ `NX` が減少
4. `NX` の減少量 = `G` の増加量 → IS曲線が元の位置に戻る
5. 最終的に `Y` は不変

### 5.2 金融政策は有効

マネーサプライ `M` を増加させると、産出 `Y` が増加する。

**メカニズム**:
1. `M↑` → LM曲線が右シフト → `Y` 増加
2. 「国内金利低下圧力」が生じるが、資本流出で `e` が上昇（自国通貨安）
3. `NX` が改善 → IS曲線が右シフトして `Y` の増加を強化

### 5.3 政策効果の比較

| ショック | Y | r | e | NX |
|---|---|---|---|---|
| 財政拡張（G↑） | 不変 | 不変 | 減少（増価） | 減少 |
| 金融緩和（M↑） | 増加 | 不変 | 増加（減価） | 増加 |
| 海外金利上昇（r*↑） | 増加 | 増加 | 変化 | 変化 |
| 外需低下（nx0↓） | 不変 | 不変 | 増加（減価） | 減少 |

---

## 6. API

### 6.1 コンストラクタ

```julia
m = MundellFlemingModel(c0, c1, I0, b, G, T, l1, l2, M, P, r_star, nx0, nx1)
```

### 6.2 共通メタ情報 API

```julia
model_name(m)        # => "Mundell-Fleming Model"
state_variables(m)   # => Symbol[]
control_variables(m) # => [:Y, :r, :e, :NX]
parameters(m)        # => NamedTuple（全パラメータ）
```

### 6.3 統一計算 API

```julia
ss  = steady_state(m)   # NamedTuple: (Y, r, e, NX, C, I)
sim = simulate(m)       # NamedTuple: 各変数を長さ1のベクトルで返す
sr  = to_simulation_result(m, sim, "equilibrium")  # SimulationResult
```

### 6.4 政策ショック比較 API（内部API）

```julia
result = DME.mf_policy_shock(m_base, m_policy; scenario_names=("baseline", "policy"))
```

`SimulationResult` を返す。変数ごとに長さ2のベクトルを持ち、インデックス1がベースライン、2が政策後。

---

## 7. 使用例

### 7.1 基本的な均衡計算

```julia
using DME

m = MundellFlemingModel(
    100.0, 0.8,    # c0, c1
    200.0, 50.0,   # I0, b
    100.0, 100.0,  # G, T
    0.2, 100.0,    # l1, l2
    1000.0, 1.0,   # M, P
    0.02,          # r_star
    50.0, 10.0     # nx0, nx1
)

ss = steady_state(m)
# => (Y=..., r=0.02, e=..., NX=..., C=..., I=...)
```

### 7.2 金融緩和の効果分析

```julia
m_base     = MundellFlemingModel(100.0, 0.8, 200.0, 50.0, 100.0, 100.0,
                                  0.2, 100.0, 1000.0, 1.0, 0.02, 50.0, 10.0)
m_monetary = MundellFlemingModel(100.0, 0.8, 200.0, 50.0, 100.0, 100.0,
                                  0.2, 100.0, 1200.0, 1.0, 0.02, 50.0, 10.0)

result = DME.mf_policy_shock(m_base, m_monetary;
                              scenario_names=("baseline", "monetary_easing"))

# Y は増加、e は増価（自国通貨安）、NX は改善
println("ΔY  = ", result["Y"][2]  - result["Y"][1])
println("Δe  = ", result["e"][2]  - result["e"][1])
println("ΔNX = ", result["NX"][2] - result["NX"][1])
```

### 7.3 財政拡張の効果分析（クラウドアウト確認）

```julia
m_base   = MundellFlemingModel(100.0, 0.8, 200.0, 50.0, 100.0, 100.0,
                                0.2, 100.0, 1000.0, 1.0, 0.02, 50.0, 10.0)
m_fiscal = MundellFlemingModel(100.0, 0.8, 200.0, 50.0, 150.0, 100.0,
                                0.2, 100.0, 1000.0, 1.0, 0.02, 50.0, 10.0)

result = DME.mf_policy_shock(m_base, m_fiscal;
                              scenario_names=("baseline", "fiscal_expansion"))

# Y は不変（完全クラウドアウト）
println("ΔY  = ", result["Y"][2]  - result["Y"][1])   # ≈ 0
println("ΔNX = ", result["NX"][2] - result["NX"][1])  # ≈ -50 (= -ΔG)
```

### 7.4 可視化

```julia
result = DME.mf_policy_shock(m_base, m_monetary;
                              scenario_names=("baseline", "monetary_easing"))
plot_comparison(result; title="金融緩和の効果")
```

---

## 8. 相場制度と限界

### 8.1 本モデルがカバーする相場制度

本実装は**変動為替相場制**のみを扱う。UIP条件 `r = r*` の成立と為替レートの内生的決定が前提。

### 8.2 固定為替相場制（対象外）

固定相場制では `e` が外生的に固定され、`M` が内生的に調整される。
このケースでは財政政策が有効になる（Mundell-Fleming定理の逆）。
固定相場制のシミュレーションは後続Issueで対応予定。

### 8.3 その他の限界

| 限界事項 | 説明 |
|---|---|
| 静学モデル | 時間を通じた動学的調整過程は扱わない |
| 物価固定 | 短期分析のみ。物価内生化は開放経済AD-ASで対応予定 |
| 完全資本移動 | 不完全資本移動（BP曲線の傾きが有限なケース）は非対応 |
| 期待形成なし | 前向き期待・UIP動学は開放経済NKで対応予定 |
| 実データ未接続 | キャリブレーション・実データ推定は後続フェーズ |

---

## 9. 参考文献

| 文献 | 内容 |
|---|---|
| Mundell (1963), "Capital Mobility and Stabilization Policy under Fixed and Flexible Exchange Rates" | 原論文 |
| Fleming (1962), "Domestic Financial Policies under Fixed and Floating Exchange Rates" | 原論文 |
| Mankiw (2019), *Macroeconomics*, Ch.12-13 | 標準的な教科書解説 |
| Krugman, Obstfeld & Melitz (2022), *International Economics*, Ch.17 | 開放マクロの標準テキスト |
