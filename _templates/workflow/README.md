# workflow ディレクトリ

マルチエージェント実装ワークフローの状態・設定の正本。

## config.json

| キー | 説明 | デフォルト |
|------|------|-----------|
| `child_agent.command_template` | 子エージェントCLIのコマンドテンプレート。`{prompt}` がタスクプロンプトに展開される | `opencode run "{prompt}"` |
| `child_agent.timeout_seconds` | 子エージェント実行のタイムアウト(秒) | `1800` |
| `test_command` | 子エージェントに実行させるテストコマンド。空ならタスクごとに親が指定 | `""` |
| `verify_before_commit` | コミット直前に親がテストコマンドを1回実行する最終ゲート | `false` |
| `max_fix_retries` | レビュー不合格時の子エージェントへの再依頼上限。超過で親のサブエージェントにフォールバック | `2` |
| `comprehension_check.enabled` | タスク合格時に理解確認質問を生成するか | `false` |
| `comprehension_check.questions_per_task` | タスクあたりの質問数 | `3` |
| `upstream.url` | upstream リポジトリの URL。`workflow-update` skill で使用 | `https://github.com/Musasaby/multi-ai-agents-workflow.git` |
| `upstream.branch` | upstream 追従ブランチ名 | `main` |

## tasks.md(/agent-task-plan が生成)

タスク定義の正本。子エージェントもこのファイルを参照する。フォーマット:

```markdown
# タスク一覧: <計画ソース(Issue #N またはドキュメントパス)>

## T1: <タスクタイトル>
- **目的**: 何を達成するか
- **対象**: 変更が想定されるファイル・モジュール
- **受け入れ基準**:
  - [ ] 基準1(検証可能な形で記述)
  - [ ] 基準2
- **依存**: なし | T<n>
```

## state.json(/agent-task-plan が生成、各skillが更新)

機械可読な進捗状態。中断後の再開はこのファイルを起点にする。

```json
{
  "source": "Issue #12 | docs/plan.md",
  "branch": "develop/xxx",
  "updated_at": "2026-06-12T10:00:00+09:00",
  "tasks": [
    {
      "id": "T1",
      "title": "...",
      "status": "pending",
      "retries": 0,
      "commit": null
    }
  ]
}
```

`status` の遷移: `pending` → `in_progress`(dispatch) → `in_review`(子の完了報告)
→ `done`(レビュー合格・コミット済み、`commit` にハッシュを記録) / 不合格は `in_progress` に戻し `retries` をインクリメント。
回復不能な失敗は `failed`(ユーザーへエスカレーション)。
