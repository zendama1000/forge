# FX バックテスト駆動トレーディングツール開発 リサーチ最終レポート

- **Research ID**: `2026-05-06-f1942f-143817`
- **生成日時**: 2026-05-06
- **テーマ**: FX 市場でバックテスト駆動の高精度トレーディングツール（Web ダッシュボード付き、paper trading まで）を、定量メトリクスで正当化可能な形で構築するための最適スタックを validate する
- **判定**: **GO**（DA は2回目で全領域で収束を確認し、実装フェーズへの移行を承認）

---

## 1. エグゼクティブサマリ

8 項目（戦略カテゴリ・データソース・バックテストエンジン・Web スタック・通貨ペア/時間軸・過学習対策・最適化手法・評価/リスク管理基準）の最適選択を、6 視点（technical / cost / risk / alternatives / metrics_validity / data_realism）で検証した。**全領域でロックされた決定事項（FX 限定 / Web ダッシュボード必須 / paper trading 止まり / 精度最重視 / 出力先 Desktop/innji / ハーネス本体不変）と整合する構成が確定**した。

| 項目 | 主推奨 | フォールバック |
|---|---|---|
| 戦略カテゴリ | トレンドフォロー（Donchian + MACD 組合せ） | KAMA + ATR・MA クロスへ拡張 |
| データソース | **Dukascopy**（tick + bid/ask、無料、15 年以上） | HistData（M1 補助のみ） |
| バックテストエンジン | **vectorbt OSS**（高速・Numba・Plotly 互換） | nautilus_trader（FX ネイティブ・精度優位） |
| Web スタック | **Streamlit + Plotly**（marketcalls/VectorBT-Streamlit 参考） | Dash / Panel（高度インタラクティブ要件時） |
| 通貨ペア × 時間軸 | EURUSD 単独 → メジャー 7 ペア × M1 × 5–10 年 | tick 解像度（精度限界露呈時） |
| 過学習対策 | **Walk-Forward + CPCV + Monte Carlo Permutation** の 3 層構成 | StepM・Block Bootstrap |
| 最適化手法 | **Optuna**（TPE デフォルト + CMA-ES、Objective に DSR/CV Sharpe） | NSGA-II による多目的（過学習量を第二目的） |
| 採用基準 | 二段階閾値（最低/推奨）+ DSR p<0.05 + PBO<0.5 | 単一統合スコアへの集約 |

**コスト総額: 年間 $0**（OSS のみで完結）。**主要リスク**: vectorbt OSS は FX 特有事項（時間帯別スプレッド・水曜トリプルスワップ・週末ギャップ）のネイティブ機能が弱いため、custom callback での拡張が必要。

---

## 2. 調査対象と前提（investigation-plan）

### 2.1 中核質問（8 項目）

1. ロバスト性兼備の戦略カテゴリ（Sharpe/Sortino/Calmar/Max DD/PF + OOS 劣化の小ささ）
2. FX ヒストリカルデータの推奨調達方法（コスト・粒度・スプレッド忠実度・ライセンス・取得容易性）
3. バックテストエンジン選定（速度・look-ahead 防止・WF/CPCV 対応・FX モデリング・コミュニティ）
4. Web ダッシュボードスタック（可視化適合性・最適化結果探索 UI・実装速度・拡張性）
5. 通貨ペア × 時間軸の最小/推奨構成
6. 過学習対策の必須/推奨/任意分類（López de Prado 推奨ベース）
7. パラメータ最適化手法の比較（収束効率・過学習リスク・統合容易性）
8. 評価指標の合格閾値とポジションサイジング基準

### 2.2 ロックされた前提（議論対象外）

- FX 限定 / Web ダッシュボード必須 / paper trading 止まり / 精度最重視 / 出力先 `Desktop/innji` / ハーネス本体不変
- Python ベース（Rust/C++/Julia は補助的にのみ言及）
- 単独開発者・Windows + Git Bash 環境・OneDrive 外
- 商用配布は対象外（自己利用範囲）

### 2.3 視点（fixed 4 + dynamic 2）

| ID | 焦点 | 種別 |
|---|---|---|
| technical | バックテスト正確性・速度・Web 実装・Python 統合 | fixed |
| cost | データ料金・ライセンス・計算リソース・開発工数 | fixed |
| risk | 過学習・データバイアス・メトリクス解釈・偽陽性 | fixed |
| alternatives | 既存ツール・OSS・ダッシュボードフレームワーク・戦略 | fixed |
| metrics_validity | Sharpe 等の信頼区間・検出力・統計的妥当性 | dynamic |
| data_realism | FX 特有のスプレッド・スワップ・ニュース・週末ギャップ | dynamic |

---

## 3. 視点別主要発見

### 3.1 Technical: 技術的実現性

**結論**: ネイティブ完成度では nautilus_trader が最良、開発速度では vectorbt OSS が最良。

| エンジン | CPCV | bid/ask | スワップ | Optuna 統合実績 | Windows |
|---|---|---|---|---|---|
| **vectorbt PRO** | ネイティブ（Splitter.from_purged_kfold） | fees/slippage 近似 | カスタム必要 | 中 | 良好 |
| **vectorbt OSS** | 非対応（外部実装） | 同上 | 同上 | 中（コミュニティ） | 良好 |
| **nautilus_trader** | 非対応（外部ループ） | QuoteTick ネイティブ | FXRolloverInterestModule | 公式例なし | wheel 配布、ただし高精度モードは Linux/macOS 限定 |
| **backtrader** | 非対応 | slippage で代替 | commission scheme で近似 | GitHub 例最多 | 良好 |
| **zipline-reloaded** | 非対応 | ‐ | ‐ | 少 | **h5py DLL エラー多発、要除外** |
| **bt** | 非対応 | 弱 | 弱 | 少 | 良好 |

**ダッシュボード**: `marketcalls/VectorBT-Streamlit` が完全サンプル付きで MVP 最短（Streamlit + vectorbt + Plotly）。FastAPI + React は工数 2–5 倍。

### 3.2 Cost: コスト・リソース

**結論**: 主要構成すべて年間 $0 でカバー可能。

- **データ**: Dukascopy（tick・bid/ask 付き・15 年以上、無料）/ HistData（M1 OHLC のみ・bid のみ・固定スプレッド扱い）
- **vectorbt PRO ($240/年)**: Rust エンジン高速化・OOM 防止だが、7 ペア × 1000 試行用途では OSS 版で十分
- **過学習対策ライブラリ**: `timeseriescv` + `mlfinpy` + `pypbo` + `arch` で全て無料
- **計算リソース**: 5 年 × 7 ペア × M1 ≈ 1.0–1.5 GB RAM、10 年 ≈ 2.0–3.0 GB。**最低 16 GB / 推奨 32 GB**。1000 試行は単純戦略で 15–30 分、複雑戦略で数時間
- **Forge Harness 親和性**: Streamlit は宣言的・Python 単独で 30 ファイル/タスク制限内。FastAPI+React は分離型で抵触リスク

### 3.3 Risk: 失敗モード

**結論**: 6 層のリスク構造を抑える多層防御が必須。

| 層 | リスク | 対策 |
|---|---|---|
| 1. データバイアス | look-ahead bias / data snooping / regime change | Walk-Forward + 時刻境界スラッシュテスト + HMM |
| 2. メトリクス欺瞞 | 多重検定バイアス・非正規性 | DSR・PSR で補正（López de Prado） |
| 3. 最適化偽陽性 | 試行数増加で extreme value 的に SR 膨張 | DSR を Objective 化 / CSCV で PBO < 0.5 |
| 4. データ品質 | Dukascopy の tick spike・gap、MT4 はスプレッド非保存 | 前処理で外れ値除外 + Dukascopy tick の必須採用 |
| 5. Paper→Live ギャップ | スリッページ・ニュース時 5–10 倍スプレッド・流動性凍結 | 保守的スプレッド仮定 + 時刻フィルタ + 漸進移行 |
| 6. 閾値設定 | 低すぎ→偽陽性、高すぎ→偽陰性 | バックテスト Sharpe ≥ 2.0、Live ≥ 1.0（経験則 1.0 低下） |

### 3.4 Alternatives: 代替案・競合

**既存 FX バックテストツール**: QuantConnect / MT4-5 / TradingView / FXBlue / Forex Tester すべてエコシステム制約（言語ロック・データ品質・プラットフォーム依存）あり。**自作スタック差別化価値**: Python ML 完全統合・カスタム過学習対策・データパイプライン制御・コストゼロ・スプレッド/約定モデル自由実装。

**過学習対策の使い分け**:

| 手法 | 推奨ユースケース |
|---|---|
| Walk-Forward | 業界標準・基本検証（説明性高） |
| CPCV (Combinatorial Purged CV) | ML 特徴量を含む戦略（情報漏洩防止） |
| Monte Carlo Permutation Test | 既知戦略のストレステスト（1000+ 回） |
| Block Bootstrap | レジーム変化への堅牢性確認 |

**戦略カテゴリ**: Donchian + MACD の組合せが実用的（50 日ブレイク + MACD ヒストグラム陽転 + 両ライン正値でロング）。KAMA はノイズ適応型だが FX 直接比較研究は不足。

### 3.5 Metrics Validity: 統計的妥当性

**主要数値基準（業界標準）**:

| 指標 | 最低（採用可） | 良好 | 優秀 |
|---|---|---|---|
| Sharpe Ratio（バックテスト） | ≥ 1.0 | ≥ 2.0 | ≥ 3.0 |
| Calmar Ratio | ≥ 1.0 | ≥ 2.0 | ≥ 3.0 |
| Sortino Ratio | ≥ 1.0 | ≥ 2.0 | ≥ 3.0 |
| Max Drawdown | < 20%（CTA） | < 15% | < 10%（プロップファーム） |
| PSR（FX 現実値） | > 0.15 | > 0.5 | > 0.95（達成困難） |
| WFE（Walk Forward Efficiency） | ≥ 50% | ≥ 80% | ‐ |

**DSR（Deflated Sharpe Ratio）計算式**:

```
DSR = Φ((SR* - SR₀) × √(T-1) / √(1 - ĝ₃·SR₀ + ((ĝ₄-1)/4)·SR₀²))
SR₀ = √(V[SR̂ₙ]) × ((1-γ)·Φ⁻¹[1-1/N] + γ·Φ⁻¹[1-1/(N·e)])
```
- `N`: 有効独立試行数（ONC 等で推定、過大推定が安全側）
- `γ`: オイラー＝マスケローニ定数 ≈ 0.5772
- `ĝ₃, ĝ₄`: リターンの歪度・尖度

**多重比較検定**: `arch` ライブラリのみが Python で公式 SPA / StepM / MCS を提供。pyfolio/empyrical/quantstats は非対応。

**Walk-Forward 推奨**: IS:OOS = 3:1（または 70:30）、M1 高頻度では Rolling 方式（IS 6 ヶ月 → OOS 2 ヶ月、ステップ 2 ヶ月）でフォールド数を稼ぐ。

### 3.6 Data Realism: FX 特有モデリング

**時間帯別スプレッド**: MT5 の "Every tick based on real ticks" + Dukascopy が業界最高峰。OSS スタックでは vectorbt の custom callback で拡張実装が必要。

**スワップポイント**: 全エンジンで部分対応。`(通貨A金利 - 通貨B金利) / 365 × 為替レート` で計算、水曜→木曜持越しで**トリプルスワップ**（決済日が月曜まで 3 日繰越）を曜日ロジックでモデル化必要。

**週末ギャップ**: EUR/USD で過去 20 年に約 **20–25% の週**で発生、大半は 10pip 未満だが稀に 100pip 超。多くは fill（埋め）パターン。**業界標準は「除外せず含める」**。

**ニューススパイク時スプレッド拡大**: NFP/FOMC 発表前後で通常比 **5–10 倍**に拡大。スキャルピング戦略は**時刻フィルタで取引禁止**、トレンドフォローは**含めて耐性測定**。

**Paper→Live ギャップ**: IG/OANDA demo は公式に「スリッページなし・利息調整なし」と明言。実運用では **Sharpe が 0.5–1.0 低下**するのが経験則。

---

## 4. 視点間の矛盾と解決

| # | 衝突視点 | 内容 | 解決策 |
|---|---|---|---|
| 1 | technical vs cost | nautilus_trader（FX ネイティブ）vs vectorbt OSS（速度・Streamlit 統合） | **vectorbt OSS をメイン**に採用、FX 特有事項は custom callback / fees パラメータで拡張。nautilus_trader は精度限界露呈時の Fallback として温存 |
| 2 | technical vs alternatives | CPCV ネイティブは vectorbt PRO のみ vs CPCV は ML 限定で WF で十分 | **CPCV は必須扱い**、ただし無料 `timeseriescv` + `mlfinpy` で代替。WF（基本）+ CPCV（二次）+ MC Permutation（三次）の 3 層 |
| 3 | metrics_validity vs risk | FX で PSR > 0.95 は困難 vs Sharpe ≥ 2.0 が業界最低 | **二段階閾値**: 最低 = Sharpe ≥ 1.0 + DSR p<0.05 + PBO<0.5 / 推奨 = Sharpe ≥ 2.0 + Calmar ≥ 1.0 + Sortino ≥ 2.0 + PSR > 0.5 |
| 4 | data_realism vs risk | 週末ギャップ・ニュース時を含める vs 時刻フィルタで除外 | **戦略の性質で使い分け**: トレンドフォロー/スイングは含める、スキャルピング/M1 短期はニュース ±5 分を取引禁止フィルタに組込み、両方をパラメータ化して感度分析 |

---

## 5. 推奨アクション（synthesis）

### 5.1 Primary Recommendation

| 領域 | 推奨 | 根拠（視点合致数） |
|---|---|---|
| データ | Dukascopy tick + M1（メジャー 7 ペア × 5–10 年） | cost / data_realism / risk / alternatives 一致 |
| エンジン | vectorbt OSS + custom callback 拡張 | technical / cost / alternatives 一致 |
| 過学習対策 | Walk-Forward (IS:OOS=3:1, WFE≥50%) + CPCV (PBO<0.5) + Monte Carlo Permutation (1000+) | risk / metrics_validity / alternatives 一致 |
| 評価指標 | Sharpe + DSR (mlfinpy) + PSR + Calmar + Sortino + Max DD（pyfolio/quantstats/arch 自動算出） | metrics_validity / risk 一致 |
| 最適化 | Optuna TPE（事後 DSR 検定でフィルタ）、Objective = WF CV 平均 Sharpe | technical / risk / cost 一致 |
| ダッシュボード | Streamlit + Plotly（marketcalls/VectorBT-Streamlit ベース） | technical / cost / alternatives 一致 |
| Paper trading | OANDA demo API（Phase polish 後半） | data_realism / risk |
| 戦略初手 | Donchian + MACD 組合せ | alternatives |
| 採用基準 | バックテスト Sharpe ≥ 2.0 + DSR p<0.05 + PBO < 0.5 + Max DD < 20% | metrics_validity / risk |

### 5.2 Fallback

vectorbt OSS で paper-live ギャップが Sharpe 1.0 を超えた場合、エンジンを **nautilus_trader に切替**（QuoteTickDataWrangler + FXRolloverInterestModule + BestPriceFillModel をネイティブ利用）。データ層（Dukascopy）と表示層（Streamlit）は再利用、JSON 経由の疎結合構成。

**切替トリガー**:
- Phase 2 paper trading で実運用 Sharpe がバックテストより 1.0 以上低下
- FX 特有モデリングの custom callback でファイル数制限（30/タスク）超過頻発
- DSR p-value が一貫して 0.05 を超え戦略採用不可が連発

### 5.3 Abort 条件

Phase 2 全期間で `Sharpe ≥ 1.0 + DSR p<0.05 + PBO < 0.5` を満たす戦略がゼロ、または Dukascopy データ品質問題が前処理で除去不能水準の場合は中止検討。中止時の機会費用は数ヶ月の開発工数喪失だが、業界標準知識・Streamlit ダッシュボード雛形・ハーネス Windows 互換性データは残せる。

### 5.4 主要リスク（recommendation 内 risks）

1. vectorbt OSS の FX ネイティブ機能不足 → custom callback 実装漏れで paper trading 移行時 Sharpe 劣化
2. Dukascopy の tick spike/gap → 前処理外れ値検出ロジック必須
3. Optuna 試行回数増加で偽陽性増加 → DSR/PBO 事後検定が機能しないと過学習採用
4. Streamlit のシングルユーザー想定 → リアルタイム複数クライアントで Dash/FastAPI 移行必要化
5. 業界標準閾値（Sharpe ≥ 2.0）が FX で達成困難の可能性 → 二段階閾値運用でカバーするが現実達成度は実装後検証必要
6. Forge Harness の `development.json` を Streamlit 用に更新する必要（プロジェクト切替時の設定漏れリスク）

---

## 6. 実装基準（implementation-criteria, 自動生成）

リサーチ結果を Phase 1.5 で **8 個の L1 / 4 個の L2 / 6 個の L3** に分解。Phase 構成は **mvp / core / polish** の 3 段階。

### 6.1 Layer 1（単体・構造）

| ID | 対象 | 検証コマンド |
|---|---|---|
| L1-001 | Dukascopy データローダー（DataFrame 整形・bid/ask・UTC tz） | `pytest tests/unit/test_data_loader.py -v` |
| L1-002 | vectorbt Backtester ラッパー（fees/slippage/spread 適用） | `pytest tests/unit/test_backtester.py -v` |
| L1-003 | 評価指標（Sharpe/Sortino/Calmar/Max DD/DSR/PSR） | `pytest tests/unit/test_metrics.py -v` |
| L1-004 | Walk-Forward / CPCV / PBO | `pytest tests/unit/test_validation.py -v` |
| L1-005 | Optuna ラッパー（TPE/CMA-ES + DSR Objective） | `pytest tests/unit/test_optimizer.py -v` |
| L1-006 | 戦略 Donchian + MACD（決定性シグナル） | `pytest tests/unit/test_strategy_donchian_macd.py -v` |
| L1-007 | Streamlit トップページ HTTP 200 + ヘルスチェック | `curl -sf http://localhost:3001/_stcore/health` |
| L1-008 | lint / 型チェック（ruff + mypy --strict） | `ruff check src/ && mypy --strict src/` |

### 6.2 Layer 2（統合・E2E）

| ID | 対象 | 必要環境 |
|---|---|---|
| L2-001 | Dukascopy 実 DL → キャッシュ → ロード E2E | インターネット + 書込権限 |
| L2-002 | バックテスト → 最適化 → WF 検証 → ダッシュボード E2E | キャッシュデータ + Streamlit (3001) |
| L2-003 | OANDA Demo API 連携（注文送信・ポジション取得） | OANDA_API_TOKEN（demo） |
| L2-004 | Optuna 100 試行 + WF 5fold が 10 分以内（性能回帰） | キャッシュ + 16GB RAM |

### 6.3 Layer 3（行動・構造）

| ID | strategy | 内容 | blocking |
|---|---|---|---|
| L3-001 | structural | ダッシュボード必須 5 セクション（Equity / DD / Heatmap / Trade Log / Metrics）レンダリング | ✅ |
| L3-002 | structural | results.json が JSON Schema 準拠（metrics 必須 7 フィールド） | ✅ |
| L3-003 | api_e2e | バックテスト → WF → DSR 検定 → ダッシュボード表示の連続検証 | ✅ |
| L3-004 | structural | 採用判定エンジン（reject / conditional_pass / recommended）3 シナリオ | ✅ |
| L3-005 | cli_flow | CLI バックテスト → results.json → ダッシュボード読込 | ✅ |
| L3-006 | llm_judge | 可視化品質（軸ラベル・凡例・前提条件・小数桁一貫性、閾値 0.7） | warning |

### 6.4 Phase 構成

| Phase | Goal | 含む criteria | mutation_threshold |
|---|---|---|---|
| **mvp** | EURUSD M1 で Donchian+MACD を 1 回バックテスト → 主要指標 + Equity Curve を Streamlit 表示 | L1-001/002/006/007/008, L3-001/002/005 | 0.4 |
| **core** | WF / CPCV / Optuna / DSR・PSR・PBO / メジャー 7 ペア / 採用判定エンジン / Heatmap | L1-003/004/005, L2-001/002/004, L3-003/004 | 0.3 |
| **polish** | OANDA Demo paper trading / ニュース時間フィルタ / UI 仕上げ / 10 年データ性能チューニング | L2-003, L3-006 | 0.2 |

### 6.5 重要な実装上の前提（assumptions 抜粋）

- ダッシュボードポートは **3001**（Forge Harness `development.json` の `start_command` を `streamlit run src/dashboard/app.py --server.port 3001`、`health_check_url` を `/_stcore/health` に更新）
- メインエンジン: vectorbt OSS。FX 特有事項は fees パラメータ + custom callback で拡張
- メジャー 7 ペア: EURUSD / USDJPY / GBPUSD / AUDUSD / USDCAD / USDCHF / NZDUSD
- 二段階採用閾値:
  - 最低: Sharpe ≥ 1.0 + DSR p<0.05 + PBO < 0.5
  - 推奨: Sharpe ≥ 2.0 + Calmar ≥ 1.0 + Sortino ≥ 2.0 + PSR > 0.5
- Implementer の 30 ファイル/タスク制限に収まるよう、setup/UI 系は小粒度に分割

---

## 7. 残存ギャップ（次フェーズで埋めるべき不確実性）

| 領域 | 未確認事項 |
|---|---|
| vectorbt | OSS と PRO の機能差分の網羅、v1.2.0 公式 changelog 確認 |
| nautilus_trader | Optuna 統合の現実動作、Windows 標準精度モードの FX 影響 |
| データ品質 | Dukascopy の gap 率・tick spike 率の定量データ |
| 過学習 | バックテスト Sharpe → live Sharpe 0.5–1.0 低下の査読論文根拠、Optuna 試行数の直接ペナルティ実装例 |
| FX 戦略 | USDJPY/EURUSD での Donchian/MA/MACD/KAMA 直接 head-to-head |
| paper trading | デモ vs 本番スリッページの統制 A/B 研究、ニュース時スプレッド倍率の通貨ペア別統計 |
| Forge Harness | Streamlit を Harness 自動開発した成功事例の確認 |

---

## 8. ロック決定との整合確認

| ロック決定 | 整合状況 |
|---|---|
| FX 限定 | ✅ 全視点が FX データ・FX 特有約定モデリングを中心に調査 |
| Web ダッシュボード必須 | ✅ Streamlit + vectorbt + Plotly が 3 視点一致推奨、ハーネス制限内 |
| Paper trading まで | ✅ data_realism / risk が paper-live ギャップを Sharpe 0.5–1.0 低下と定量化 |
| 精度最重視 | ✅ DSR・PSR・PBO・CPCV・SPA 多層検定で定量判定可能 |
| 出力先 Desktop/innji・ハーネス本体不変 | ✅ 全 OSS で外部依存ゼロ |
| Windows + Git Bash 互換 | ✅ vectorbt / nautilus_trader / Streamlit が Windows 動作確認済（zipline-reloaded のみ除外） |

**conflicts: なし**。実装フェーズへ進行可能。

---

## 9. 次のアクション

1. `forge-flow.sh` または既存の Phase 1.5 出力（`implementation-criteria.json`）を Phase 2 へ引継
2. 起動前準備:
   - `cd <work-dir> && git init` + `.gitignore`（`node_modules/`, `__pycache__/`, `.venv/`, `data/cache/`, `*.parquet`, `.env`）
   - `.forge/config/development.json` の `server.start_command` を `streamlit run src/dashboard/app.py --server.port 3001`、`health_check_url` を `/_stcore/health` に更新
3. `research-config.json` の `locked_decisions` に必要な `assertions`（vectorbt OSS 採用 / Streamlit ポート 3001 / mlfinpy 利用 等）を追加して Ralph Loop に渡す
4. mvp → core → polish の順で実装、各 Phase の exit_criteria を `auto + human_check` で検証
