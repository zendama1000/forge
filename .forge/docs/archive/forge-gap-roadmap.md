# Forge Research Harness — v3.1/v3.2 設計書との差分解消ロードマップ

**作成日:** 2026-02-13
**対象:** forge-research-harness-v1 実装（v1.3）
**参照設計書:** forge-architecture-v3.1.md, forge-architecture-v3.2.md

---

## 前提判断

- **ゼロ仮説検証（Forge vs 単体Opus）:** スキップ。3セッション（うち2件GO完走）の実績と、ブートストラップフェーズの自己発見（フィードバック・チェーン、ABORT閾値、DA自己確証バイアス検出）が十分な判断材料。
- **cost perspective修正（Researcher権限拡張）:** 後回し。外部テーマの運用頻度が上がった時点で再評価。
- **OS通知（リサーチ完了通知）:** 後回し。現状のターミナル監視で運用可能。

---

## 差分全件一覧（16件 + バグ3件）

### v3.1由来（Research System改善）

| ID | 項目 | 設計書の意図 | 現状 |
|----|------|------------|------|
| G1 | metrics.jsonl | ステージ実行時間・parse成功率・サイクル統計の自動記録 | 未実装 |
| G2 | validation-stats.jsonl | JSON検証のリカバリ段階記録（none/crlf/fence/extraction） | 未実装 |
| G3 | research.json config | モデル名・視点構成・フィードバック注入モード等の外部化 | 未実装（circuit-breakerのみ） |
| G4 | index.md自動更新 | リサーチ完了時にテーマ・verdict・レポートパスを自動追記 | テンプレのまま |
| G5 | must_fix構造化 | id, category, carried_over_from, resolution_criteria, carry_count | 文字列配列のまま |
| G6 | Preflight Check | リサーチ開始前の「直接回答で十分か」判定ゲート | 未実装 |
| G7 | フィードバック圧縮・balanced注入 | 視点ごとの関連度判定、注入量上限制御 | 全Researcherに一律注入 |
| G8 | decisions要約注入 | 要約化して注入、原文は参照パスのみ | tail -n 30で原文注入 |
| G9 | DAサブエージェント検索委譲 | Sonnetサブエージェントに裏取り検索を委譲 | disallowed-toolsで検索全面禁止のみ |

### v3.2由来（Development System + 接続）

| ID | 項目 | 設計書の意図 | 現状 |
|----|------|------------|------|
| G10 | ralph-loop.sh | task-stack駆動の自律開発ループ | スタブ存在、非稼働 |
| G11 | Investigatorオーケストレーション | 3回失敗→ミニリサーチ→scope判定 | agent定義のみ |
| G12 | implementation-criteria.json生成 | Research→Development接続の3層成功条件 | **実装済み** |
| G13 | テスト3層実行基盤 | Layer 1自動/Layer 2分離/Layer 3人間判断 | 設計のみ |
| G14 | Phase 2→1逆流パス | RESEARCH_REMAND判定でresearch-loop再実行 | 未実装 |
| G15 | investigation-log.jsonl | Investigator起動・判定の累積ログ | 未実装 |

### 既存バグ/運用課題

| ID | 項目 | 現状 | あるべき姿 |
|----|------|------|----------|
| B1 | errors.jsonl resolution全件null | 更新フローなし | 解決時にresolutionを書き込む仕組み |
| B2 | current-research.json stuck | 手動リセットのみ | 異常終了時のtrapでクリーンアップ |
| B3 | DA自己確証バイアス構造修正 | 未着手 | DA過去指摘のResearcher質問除外 or balanced injection |

---

## 優先順位

### Tier 1: 今すぐ（計 ~3h）— 既存Research Systemの信頼性直結

| 順 | ID | 項目 | 工数 | 根拠 |
|----|----|------|------|------|
| 1 | B2 | current-research.jsonクリーンアップ | 30min | 今この瞬間、6feb90がstatus=runningで放置されており次のリサーチ起動をブロックする。trapでEXIT/ERR時にstatus更新 |
| 2 | G1 | metrics.jsonl（最小版） | 1h | run_claudeの前後にdate +%sを取得、validate_jsonの結果と合わせてjq -nでappend。完全版は不要、duration_secとparse_successの2フィールドで開始 |
| 3 | G4 | index.md自動更新 | 30min | record_decisionの直後にecho 1行。v3.1設計書にbashコード例あり |
| 4 | B1 | errors.jsonl resolution更新 | 1h | validate_jsonの成功パス（リカバリ後含む）で、同一stage/research_dirのエントリにresolutionを書く |

### Tier 2: 次回リサーチ前に（計 ~4h）— 外部テーマ運用の質向上

| 順 | ID | 項目 | 工数 | 根拠 |
|----|----|------|------|------|
| 5 | G2 | validation-stats.jsonl | 1h | G1と同時にやれる。validate_json内の各リカバリ段階でjq -n append |
| 6 | G5 | must_fix構造化 | 2h | DAテンプレート＋feedback-queue.jsonスキーマ変更。フィードバック・チェーンの繰越検証が文字列目視→IDベース機械追跡に変わる |
| 7 | G3 | research.json config | 1h | モデル名、max_decisions等をcircuit-breaker.jsonと同パターンで外出し |

### Tier 3: 構造的改善（計 ~7h）— 急がないが重要

| 順 | ID | 項目 | 工数 | 根拠 |
|----|----|------|------|------|
| 8 | B3 | DA自己確証バイアス修正 | 2h | G7の前提条件。SCのinvestigation-plan生成時にDA過去must_fixを質問に混入させない仕組み |
| 9 | G7 | フィードバック圧縮・選択的注入 | 3h | 視点ごとにmust_fixの関連度を判定して注入。ルールベース or LLM判定の設計判断が必要 |
| 10 | G8 | decisions要約注入 | 2h | 現在16件でtail -n 30なら全件入る。50件超で必須。今は仕組みだけ作れる |

### Tier 4: Development System着手（計 ~16h+）— Research Systemが安定してから

| 順 | ID | 項目 | 工数 | 根拠 |
|----|----|------|------|------|
| 11 | G10 | ralph-loop.sh実装 | 8h+ | implementation-criteria.json生成（G12）が接続口として実装済み |
| 12 | G11 | Investigatorオーケストレーション | 3h | ralph-loop.sh内のretry失敗→Investigator起動 |
| 13 | G13 | テスト3層実行基盤 | 5h+ | Layer 1テストランナー統合。プロジェクト固有要素大 |

### Tier 5: あると良いが後回し

| 順 | ID | 項目 | 工数 | 根拠 |
|----|----|------|------|------|
| 14 | G6 | Preflight Check | 2h | CLAUDE.mdで人間が判断している現状で自動化の価値は限定的 |
| 15 | G9 | DAサブエージェント検索委譲 | 3h+ | Claude CodeのTask tool制御の技術調査が先 |
| 16 | G14 | Phase 2→1逆流パス | G10依存 | Development Systemが稼働してから |
| 17 | G15 | investigation-log.jsonl | G11依存 | Investigatorが稼働してから |

---

## 判断基準

優先順位は以下の4軸で評価した。

| 軸 | 説明 |
|---|------|
| リサーチ品質への直接影響 | 出力の正確性・網羅性・批判性が上がるか |
| 運用信頼性 | ループが止まる・壊れる・放置されるリスクを減らすか |
| 次ステップの前提条件 | Development System着手や外部テーマ運用に必須か |
| 実装コスト | 時間と複雑さ |

Tier 1は「運用信頼性」が最重要（B2は今リサーチ起動をブロック中）。
Tier 2は「リサーチ品質」と「観測性」のバランス。
Tier 3は「構造的正しさ」で、現状でも動くが長期的に品質を毀損する。
Tier 4以降は前段の安定が前提条件。

---

## スキップした項目の記録

| 項目 | スキップ理由 | 再評価条件 |
|------|------------|----------|
| ゼロ仮説検証 | 3セッション実績＋自己発見で判断材料十分 | Forgeの出力品質に疑問が出た場合 |
| cost perspective修正 | 現時点で外部テーマ運用頻度が低い | ローカルコードベース対象のリサーチが月3回以上になった場合 |
| OS通知 | ターミナル監視で運用可能 | バックグラウンド実行が常態化した場合 |
| CC#8 Windows互換性 | v1.3で網羅対応済み（validate_json, record_error, render_template全てにCRLF除去）。直近セッション（6feb90）でCRLF起因エラーなし | 新たなCRLF起因エラーが発生した場合 |
