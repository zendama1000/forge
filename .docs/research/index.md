# リサーチ一覧

Forge Research Harnessによる調査結果のインデックス。

## 形式

各リサーチは `YYYY-MM-DD-{topic_hash}/` ディレクトリに格納される。

| 日付 | テーマ | Verdict | レポート |
|------|--------|---------|---------|
| （リサーチ完了後に追記） | — | — | — |

## ディレクトリ構成（各リサーチ）

```
YYYY-MM-DD-{hash}/
├── investigation-plan.json    # ① Scope Challenger 出力
├── perspective-technical.json # ② Researcher 出力（技術的実現性）
├── perspective-cost.json      # ② Researcher 出力（コスト・リソース）
├── perspective-risk.json      # ② Researcher 出力（リスク・失敗モード）
├── perspective-alternatives.json # ② Researcher 出力（代替案・競合）
├── perspective-dynamic-*.json # ② Researcher 出力（動的視点、0〜2）
├── synthesis.json             # ③ Synthesizer 出力
├── devils-advocate.json       # ④ Devil's Advocate 出力
└── final-report.md           # 人間向け最終レポート
```
| 2026-02-13 | 宗教生成AIウェブサービス — AIを活用して宗教的コンテンツ（教義解説、祈りのガイド、スピリチュアルQ&A、宗教間対話支援）を生成するWebサービスの設計と実装 | GO | [レポート](.docs/research/2026-02-13-a4c740-231328/final-report.md) |
| 2026-02-15 | 宗教生成AIウェブサービス — 架空宗教の世界観一式（教義・神話・戒律・儀式・シンボル等）をAIが一括生成するフルスタックWebアプリ | CONDITIONAL-GO | [レポート](.docs/research/2026-02-15-17dde1-122138/final-report.md) |
| 2026-02-21 | x-auto-agent の実運用レベル改善（UI刷新 + アーキテクチャ整理） | GO | [レポート](.docs/research/2026-02-21-479641-124218/final-report.md) |
| 2026-02-22 | x-auto-agent UI刷新 | GO | [レポート](.docs/research/2026-02-22-e048f8-220718/final-report.md) |
| 2026-02-23 | x-auto-agent UI ビジュアルリデザイン | GO | [レポート](.docs/research/2026-02-23-2a1cf1-090444/final-report.md) |
| 2026-02-23 | Evolve Harness v1 — 既存プロジェクト改善特化ハーネスの実装 | GO | [レポート](.docs/research/2026-02-23-7be515-235438/final-report.md) |
| 2026-02-27 | LLMを使用した占いウェブサービス（Next.js + Hono基盤、7次元パラメータ活用、モックLLM） | DIRECT | [レポート](.docs/research/2026-02-27-8a3c28-220518/final-report.md) |
| 2026-03-04 | タロット占いWebアプリ（Next.js）— LLM鑑定生成、78枚カードDB、4種スプレッド対応 | DIRECT | [レポート](.docs/research/2026-03-04-2a54f8-004510/final-report.md) |
| 2026-03-06 | uranai-1 占いサービスにローカルLLM (Qwen 3.5 27B) を導入 | DIRECT | [レポート](.docs/research/2026-03-06-7b23f9-220042/final-report.md) |
| 2026-03-10 | タロット占いWebアプリ開発 - Next.js + LLM抽象化層 + 4種スプレッド + Ollama最適化 | DIRECT | [レポート](.docs/research/2026-03-10-1ed7eb-194846/final-report.md) |
| 2026-03-14 | Forge Harness v3.2 全体最適化 — マクロからミクロまで網羅的にワークフロー洗い出し・最適化案精査（信頼性・保守性重点、言語移行含む最新技術検討） | DIRECT | [レポート](.docs/research/2026-03-14-4d6f45-223836/final-report.md) |
| 2026-03-15 | Forge Harness v3.2 全体最適化 — マクロからミクロまで網羅的にワークフロー洗い出し・最適化案精査（信頼性・保守性重点、言語移行含む最新技術検討） | DIRECT | [レポート](.docs/research/2026-03-15-4d6f45-111036/final-report.md) |
| 2026-03-18 | 占いスピリチュアル系サービスのブランド構築リポジトリ設計 — コンセプト・世界観・SNSプロフィール策定を一気通貫で行えるClaude Codeツールキット | DIRECT | [レポート](.docs/research/2026-03-18-2564ee-120028/final-report.md) |
| 2026-03-20 | L3受入テストにエージェント連鎖E2E検証を追加 — Claude Codeエージェントが対話的にファイル生成する利用フローを自動検証する仕組みの設計と実装 | DIRECT | [レポート](.docs/research/2026-03-20-773c87-100000/final-report.md) |
| 2026-03-27 | x-auto-agent 現状テスト・不備洗い出し・品質強化・未完成機能完成・新機能検討 | DIRECT | [レポート](.docs/research/2026-03-27-17add8-185924/final-report.md) |
| 2026-04-03 | コンテンツ資産メタフレーム活用による20000文字以上高精度セールスレター生成アーキテクチャの複数設計・比較・選定 | DIRECT | [レポート](.docs/research/2026-04-03-119449-125056/final-report.md) |
| 2026-04-05 | ツイート生成エージェント: ジャンル別サンプルツイートを素材にClaude Codeで対話的にオリジナルツイートを生成するCLIツール | DIRECT | [レポート](.docs/research/2026-04-05-c85af8-191501/final-report.md) |
| 2026-04-05 | ツイート生成エージェント: ジャンル別サンプルツイートを素材にClaude Codeで対話的にオリジナルツイートを生成するCLIツール | DIRECT | [レポート](.docs/research/2026-04-05-c85af8-191525/final-report.md) |
| 2026-04-06 | uranai-concept リデザイン: 占い・スピ系サービスの購買構造設計スキル実装 | DIRECT | [レポート](.docs/research/2026-04-06-3f0ec9-075426/final-report.md) |
| 2026-04-06 | uranai-concept リデザイン: 占い・スピ系サービスの購買構造設計スキル実装 | DIRECT | [レポート](.docs/research/2026-04-06-3f0ec9-113223/final-report.md) |
| 2026-04-06 | uranai-concept リデザイン: 占い・スピ系サービスの購買構造設計スキル実装 | DIRECT | [レポート](.docs/research/2026-04-06-3f0ec9-172414/final-report.md) |
| 2026-04-09 | make-salesletter HTTPサーバー→Claude Codeスキル完全移行（Express全削除、Phase制御型サブエージェント構成） | DIRECT | [レポート](.docs/research/2026-04-09-bc4729-222516/final-report.md) |
| 2026-04-09 | make-salesletter HTTPサーバー→Claude Codeスキル完全移行（Express全削除、Phase制御型サブエージェント構成） | DIRECT | [レポート](.docs/research/2026-04-09-bc4729-224511/final-report.md) |
| 2026-04-12 | 自己啓発コンテンツエージェント（Claude Code用、20000文字ブログ記事を段階推敲ループで生成） | DIRECT | [レポート](.docs/research/2026-04-12-020193-145956/final-report.md) |
| 2026-04-13 | make-jikok/templates 補完運用ドキュメント10本の生成（G:/マイドライブ/コンテンツ 価値増強/ 配下の6ファイルをソースに、自己啓発ブログ writer/reviser/critic エージェント向け運用資料を翻訳・新規作成。既存3本 style-guide.md / blacklist.md / originality-tactics.md と相互補完） | DIRECT | [レポート](.docs/research/2026-04-13-362c69-215826/final-report.md) |
| 2026-04-15 | make-tweet プロジェクトの実用的改修とデッドコード削除 | DIRECT | [レポート](.docs/research/2026-04-15-2358ce-225938/final-report.md) |
| 2026-04-16 | uranai-concept プロジェクトの建設的な改修とデッドコード調査・削除 | DIRECT | [レポート](.docs/research/2026-04-16-ae599b-174559/final-report.md) |
| 2026-04-17 | make-tweet プロジェクトにアカウント切替機能を追加（アカウントごとにジャンル/メモリ/コンテキスト/参照コンテンツを分離） | DIRECT | [レポート](.docs/research/2026-04-17-bcb3f8-070312/final-report.md) |
| 2026-04-19 | Claude Codeで100%動作する動画コンテンツ作成・編集ハーネスの構築設計 — browser-use/video-use と heygen-com/hyperframes の超精密分析を含む | DIRECT | [レポート](.docs/research/2026-04-19-295b71-005638/final-report.md) |
| 2026-04-21 | make-video v2 ブラッシュアップ — 編集深化・依存方針再評価・スコープ抑制の3軸で improvements を出す | DIRECT | [レポート](.docs/research/2026-04-21-1851dc-064849/final-report.md) |
| 2026-04-23 | Forge Harness 自己改修: Windows 互換性バッチ | DIRECT | [レポート](.docs/research/2026-04-23-a1e6dc-232227/final-report.md) |
| 2026-04-25 | ralph-loop.sh 終了サマリに未完タスク警告を追加し、反復上限到達時の『正常終了』の罠を解消する（自己改修バッチ #2-B） | DIRECT | [レポート](.docs/research/2026-04-25-12d9a2-190342/final-report.md) |
| 2026-04-26 | ralph-loop.sh の execute_layer1_test() / execute_layer2_regression() / execute_layer3() が task-stack.json の timeout_sec を動的に読むように修正し、L1 timeout 200s ハードコード問題を解消する（自己改修バッチ #3） | DIRECT | [レポート](.docs/research/2026-04-26-129a41-074435/final-report.md) |
| 2026-04-29 | 成人向け金融リテラシー教材: 架空銀行 UI で残高・取引履歴・日付を自由編集できる家計シミュレーター（Web アプリ） | DIRECT | [レポート](.docs/research/2026-04-29-dd5420-210813/final-report.md) |
| 2026-05-01 | make-tweet プロジェクトに、ムンク。氏『33→1,000フォロワー4日間達成』ノウハウを統合する機能追加 | DIRECT | [レポート](.docs/research/2026-05-01-166355-215210/final-report.md) |
| 2026-05-06 | 需要が確立された定量取引市場（FX）でバックテスト駆動の強力なトレーディングツールを開発する | DIRECT | [レポート](.docs/research/2026-05-06-f1942f-143817/final-report.md) |
| 2026-05-15 | Kindle等の電子書籍から本文をテキスト抽出するAIエージェント（Windows / Python CLI / 自動化パイプライン） | DIRECT | [レポート](.docs/research/2026-05-15-83abbc-235636/final-report.md) |
| 2026-05-17 | kindle-extract を実戦投入レベルに引き上げる (Kindle取込UX + OCR/本文品質) | DIRECT | [レポート](.docs/research/2026-05-17-280464-113255/final-report.md) |
| 2026-05-18 | 円卓会議エージェント (人間1名 + AI3体) を Claude Code 内で対話的に成立させる実装 | DIRECT | [レポート](.docs/research/2026-05-18-d70590-004224/final-report.md) |
| 2026-05-20 | 「カルト・ブランディング」(雨宮純) の6セオリーを元に、健全ブランディング戦略を提案する Claude Code スキル/エージェント | DIRECT | [レポート](.docs/research/2026-05-20-584cdd-071004/final-report.md) |
| 2026-05-22 | brand-design-agent プロジェクトを雨宮純『カルト・ブランディング』完全版.md に準拠して再構築する。コンセプト/世界観構築の理論を強化し、具体性を高め、理論→適用のトレーサビリティを実装する | DIRECT | [レポート](.docs/research/2026-05-22-32ac52-022551/final-report.md) |
| 2026-05-30 | Claude Code の Dynamic Workflow 機能を現 Forge Harness に補完的に活かせるか（探索的検討・成果物は設計/判断ドキュメント） | DIRECT | [レポート](.docs/research/2026-05-30-33c140-063853/final-report.md) |
| 2026-06-10 | Fable 5 リリースに伴う Forge Harness の自己改修と進化 | DIRECT | [レポート](.docs/research/2026-06-10-0f514a-204641/final-report.md) |
