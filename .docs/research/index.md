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
