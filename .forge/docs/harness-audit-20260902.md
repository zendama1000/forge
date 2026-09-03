# Forge Harness v3.2 最適化監査（2026-09-02〜03）

対象: 本 worktree（contents-make-setup = master + 2 commits）、直近本番ラン make-salesletter4.5f（2026-08-19〜21、28 タスク）。
方法: Claude Code Workflow による 2 段構成の多エージェント監査（第 1 段 13 体: トレンド 6 視点 + コード/テレメトリ精読 7 領域、第 2 段 40 体: 4 視点評価 → 構想 5 案 → 統合 → 3 レンズ反証 → 統合 → 欠落批評）。反証担当は Windows Git Bash 上で `git merge-tree`、`claude -p --worktree`、`--settings` deny hook、`--session-id`/`--resume`、封筒コストを実行して確認した。ハーネス本体は変更していない。
完全版（表・出典 URL 付き）は Artifact「Forge ハーネス監査」。生データはセッションのスクラッチパッド `auditA/`（13 JSON）と `auditB/`。

## 1. 結論

1. 損失の主因はハーネス自身。best-of-N の patch 適用が `DEV_LOG_DIR` 相対パス（ralph-loop.sh:46、apply は :1364）のため 2 案件通算 9/9 ENOENT。候補生成のたびに task_checkpoint_restore（common.sh:1289-1323、`git checkout -- .` + 未追跡削除。.untracked は 28 件中 26 件が空）が作業ツリーを消し、L1 合格済み成果物 5 件（diff 953〜5,285 行）を破壊。Investigator 3/3 が「ハーネスが消した」と正診断。ハーネス欠陥起因の浪費は LLM 時間の 13〜32%（182〜426 分 / 1,352 分）。
2. batch#10（2026-08-02）は feature/thin-harness-batch10 に未マージのまま、本番ランは同日 master から切ったブランチで走った。3-way マージの衝突は generate-tasks.sh（1004-1028）と test-plan-gate.sh（55-74）の 2 ハンクのみで、ralph-loop.sh は自動マージされ f7b11d0 の has() 修正は生存する（第 1 段の「巻き戻る」は誤り）。batch#10 も bon 相対パス（1430 行）は未修正、content.json は best_of_n=true / qa=false。
3. 判定者は主戦場ではない。LLM 判定者は LLM 時間の 15.5%。QA fail 13 件中 11 件は L1/L3 をすり抜けた実欠陥。逆に決定論ゲートが空洞: Implementer は Bash 禁止（development.json safety_profiles.implementation）で一度もテストを実行せず、walking skeleton は warn_and_continue で素通り、L2 は Planner が cmd:claude 不在を読んで全て deferred + Phase 3 集計（phase3.sh:155）が v2 を数えず 0/28 表示。
4. 削除できるもの: Mutation Auditor（11 回 54 分、発見 0、timeout 6 回無言 pass）、Checklist Verifier（出力 .md.pending 未昇格、参照 0）、Sprint Contract、Approach Explorer/RESEARCH_REMAND（全期間 0 発火）= 約 2,200 行。条件付き: UX 判定 2,150 行（CLI 案件 2 連続 0 発火）、simulator ≈1,800 行（本番 0 利用、replay は Phase 2 の副作用を再現できない）。docs 3,736 行、直下残骸 201 ファイル、.docs/research 13MB。
5. 業界の収斂点（決定論ゲートで block、LLM レビューは単段 advisory、価値はランタイム、無人実行はコンテナ/VM 内）に対し Forge は逆転している。ただし品質債務台帳・test sanctity・walking skeleton・record/replay は業界に無い先行資産。

計器: metrics.jsonl の cost_usd 131/131 が 0（debug ログに usage 行は無く、封筒は rm される）。封筒はサブスク認証でも total_cost_usd/usage/session_id を返すことを実測。総時間ブレーカー（600 分）発火後 495 分の空白、人間介入 6 件、通知 22 件未読。

## 2. 最初の 3 手（今週）

1. batch#10 を 3-way マージ + phase3.sh:519 の `.blocking // true` を has() 化 + profiles/content.json best_of_n=false（test-workflow-profiles.sh:42/68/110 も更新）→ HEAD でフル回帰のベースライン → マージ後フル回帰 → master FF → push。development.json の無言変更 5 点（evidence_da/checklist OFF、session $10→120、hard limit 30→60、task_author_validation）を PR に明記。以後「ハーネス修正は 7 日以内に master、案件 worktree は `gtr new --from origin/master`」。
2. 破壊経路を止める: best-of-N OFF（batch#10 で届く）、QA fail を handle_task_fail に流さず既存 qa_fail_count のみ（ralph-loop.sh:1620-1623）、QA diff を `git diff $(cat checkpoints/<task>.ref)` + `git add -N`、Implementer/Fixer に Bash を返し（development.json:76、ralph-loop.sh:1028-1031、fixer.md:15-22）、run_claude に `--settings` で PreToolUse deny hook を注入（`--dangerously-skip-permissions` 下で有効、hook 内でバックスラッシュを `/` に正規化）、採点系（.forge/**、phase-tests、task-stack validation、quality-debts）を protected に追加、WORK_DIR==PROJECT_ROOT の auto-commit/checkpoint を拒否。
3. 止まっても戻れる: circuit-breaker.json max_duration_minutes 600→1440、per_call_guards.max_budget_usd 15→0（即日）。封筒からコスト/usage/session_id を rm 前に抽出（common.sh:602 / :561,577）、record_error に exit code（143=interrupted → pending、21=budget）、forge-flow.sh:371 を追記に、アーカイブ対象に quality-debts.jsonl / costs.jsonl、run_claude 内で heartbeat を touch。

## 3. コンポーネント別合意

| 合意 | コンポーネント | 根拠 |
|---|---|---|
| remove | best-of-N（OFF 即時、削除か 1 行修正復活はカナリア後）/ Mutation Auditor / Checklist Verifier / Sprint Contract / Approach Explorer+REMAND / forge-architecture-v3.2.md（archive）/ .forge/docs 陳腐化 3,736 行 / 直下残骸 201 ファイル | 0 発火・出力未消費・全視点一致 |
| replace | task_checkpoint（復帰点は commit、ツリーを消さない）/ handle_task_fail の fail_count 合算 / Implementer Bash 禁止 / walking skeleton ゲート（kind 別 block）/ criteria exit_criteria.command（intent 不変・command 後書き・usage-probe）/ 総時間ブレーカー（再開可能に）/ コスト計器 / run_claude / monitor+dashboard（RUN-REPORT）/ calibration 意味論 / 出荷プロセス / 無人実行環境 | 直近ランの損失に直結 |
| keep | QA Evaluator（合否権限だけ外す）/ Investigator / L1 v2 checks / test sanctity+protected / quality-ledger+HANDOFF / heartbeat・session-counters・hot-reload・rate_limit_recovery / Ralph Loop 骨格 | 真陽性・実際に落とした・唯一の計器 |
| split | Evidence DA（batch#10 で OFF、ON に戻すなら escalate→best-of-N 抑止配線）/ UX 3 チャネル（server=none で skip、次 Web 案件で判定）/ Fixer（制約廃止、fixer.md 存廃は次ラン）/ simulator（今決める、推奨は削除） | 視点が割れた |
| simplify | research-loop（resume、DA→criteria 注入、final_report timeout 配線）/ generate-tasks ゲート群（初回出力保存、legacy 削除）/ forge-flow / validate_json はしご / errors・heartbeat / probe-env（cmd:claude・jq・git）/ CRLF 層 + jq `//` 12 箇所 / tests（除外 27 本の整理）/ 常時ロード文書 | 死経路・重複 |
| add | eval 基盤（runs.jsonl / カナリア / gold set）/ ワークフロー・プロファイル（content は再定義）/ L2 の実体（集計 v2 対応 + 機械ゲート） | 存在しない |

## 4. バックログ（反証済み、修正版）

P0: R01 batch#10 出荷 / R02 best-of-N OFF / R04 QA fail 分離 + diff 基準 / R05 Bash 返却 + deny hook + 採点系 protected / R06 ブレーカー再開可能化（即日は 1440 分） / R07a 計器・exit code・ログ追記 / R08a exit_criteria の CLI 契約部分だけを Implementer に注入 / R20a WORK_DIR 未指定 exit 1 + 自己書込み拒否。
P1: R03 ツリーを消さない（第 1 段: untracked rm 廃止 + auto_revert false）/ R07b 封筒コスト・heartbeat・lessons 誤分類・judge metrics / R08b usage-probe / R09 mutation+checklist を config OFF（物理削除は P2）/ R11 Evidence DA は OFF で 1 カナリア / R12 walking skeleton block / R13 probe-env cmd:claude + Phase 3 集計 v2 対応 + 誤繰延の自動回収 / R14 RUN-REPORT / R15 runs.jsonl / R16a jq `//` 12 箇所 has() 化 / R18a calibration 意味論修正 / R19a research 小修正 + `/sc:research` の config 未渡し修正 / R25a `--append-system-prompt` 共通 2 文 + サブエージェント上限 env。
P2/P3: R10 UX skip / R17 死コード −600〜850 行 / R21 テスト整理（12 本未更新、green 7 本復帰、3 本削除、一回性 1,863 行削除）/ R22 衛生（.docs/research は追跡解除ではなく RESEARCH_DIR を案件側へ）/ R23 文書目次化（project 側 370→250）/ R24 simulator は今決める（推奨 A 削除）/ R25b テンプレ重複除去 / R26 `--fallback-model` 追加のみ、debug ログは残す、`--bg` 不採用 / R27 計画ゲート初回出力保存 1 行 / R28 → R07 併合 / R29 content プロファイルを task 粒度で再定義 / R31 Phase 0 clarify 型 + Phase 4 突合表（反証未実施）/ R32 fix ループ終端意味論 + クォータ枯渇（反証未実施）。
撤回: R11 原案、R30 hacker-fixer、R28 の budget 1.5 倍、R03 の forge/* ブランチ、R14 の status.sh 統合、R16 の tr 47 箇所除去。

## 5. 方向性

1. 判定者からランタイムへ（復帰点は commit、ツリーを消さない、停止は再開可能な状態遷移）。
2. 可視テストから held-out へ（受入基準は計画側不変、command は実装後、phase-tests/L3 は Implementer から遮断し protected）。強モデルほど evaluation hack が増える（METR 2026-05）ので緩めない。
3. 計測できないものは改善できない（runs.jsonl、ablation、アンカー集合）。
4. 出荷は 7 日以内、案件は master から。
5. トレンドに逆らう点: QA を全廃しない、best-of-N を強化しない、コアを --bg / /goal / Workflow / Temporal に載せ替えない、TS 書き直しを Windows 互換の理由で始めない、多 worktree 並列でスループットを上げない（Phase 4 の人間がボトルネック）。
6. コンテンツ領域では検証モデルが最も弱い。盲検 A/B を汎用プリミティブに。隔離は Bash 解禁と同時に前提条件。

## 6. 別ハーネス

5 構想（ネイティブ再ホスト / TS 書き直し / Kernel+プロファイル / Eval-first / コックピット）は全て反証を生存したが、価値の大半は「第 1 週の止血」に縮退。独立した別ハーネスは不要。足りないのは (1) Eval Bench 縮退版（collect.sh + 遡及 runs.jsonl、2 日）と (2) コンテンツ用検証プロファイル（task 粒度、決定論不変条件 + human_check + 盲検ペア比較）。3 番目にコックピット Tier 0/1（通知の到達保証と dedupe）。

## 7. 次カナリアの KPI

cli-lib 型、20〜30 タスク、master から切った worktree、forge-docker か WSL2: 人間介入 0、空白 0 分、bon_apply_failed 0、errors unknown 0、cost_usd > 0、ハーネス欠陥起因の浪費 < 10%（基準 13〜32%）、attempts/task < 1.4（基準 1.86）。batch#10 Stage 4（validation authoring、6〜10 タスク粒度）の実効果もここで観測。

## 8. 第 1 段の誤りで第 2 段が訂正したもの

「マージで f7b11d0 が巻き戻る」（誤、自動マージで生存）/「rollback は git reset --hard」（誤、checkout -- . + 未追跡削除。reflog の reset は ralph-loop.sh:1305-1311 の候補保存シーケンス）/「QA 出力 77 ファイルに NUL」（grep 誤検知）/「.untracked 全 0 バイト」（26/28）/「walking skeleton で −180 秒」（daemon 下の read -t は即 EOF）/「loops+lib −1,500 行」（−600〜850）。
