---
name: distribute-template
description: テンプレートリポジトリの設定ファイルを対象リポジトリと比較し、差分を表示する。テンプレート変更の配布状況を確認する場合に使用。
argument-hint: "[repo-name]"
user-invocable: true
allowed-tools: Read, Bash(diff *), AskUserQuestion
---

## Context

- Template repository: this repository (current working directory)
- Target config: [distribute-targets.json](distribute-targets.json)

## Your task

Arguments: $ARGUMENTS

### Step 1: 設定の読み込み

Read ツールで `${CLAUDE_SKILL_DIR}/distribute-targets.json` を読み込む。

- Arguments にリポジトリ名が指定されている場合 → そのリポジトリのみを対象にする
- Arguments が空の場合 → 全対象リポジトリを処理する

`basePath` の `~` はホームディレクトリに展開すること。

### Step 2: 各リポジトリのファイル比較

`files` 配列の各エントリは2つの形式をサポートする:

- **文字列**: テンプレートと対象リポジトリで同一パス（例: `"renovate.json"`）
- **オブジェクト**: テンプレート側の `source` を対象リポジトリの複数 `targets` と比較
  ```json
  { "source": ".dockerignore", "targets": ["crawler/.dockerignore", "health_check/.dockerignore"] }
  ```

対象リポジトリごとに、各エントリについて:

1. **テンプレート側**: 現在のリポジトリ内の `source`（文字列の場合はそのパス）を Read ツールで読む
2. **対象リポジトリ側**: `{basePath}/{repo}/{target}` のファイルを Read ツールで読む（オブジェクト形式の場合は `targets` の各パスについて繰り返す）
3. **比較**: `diff` コマンドで差分を取得する

ファイルの状態に応じた処理:
- **差分なし** → スキップ（一覧にのみ記載）
- **差分あり** → diff を表示
- **対象リポジトリにファイルが存在しない** → 「新規ファイル」として報告
- **テンプレート側にファイルが存在しない** → 警告として報告

可能な限り Read を並列で呼び出してパフォーマンスを最適化すること。

### Step 3: 結果のサマリー

全リポジトリの比較結果を以下の形式でまとめる:

```
## {repo-name}

### ✅ 同期済み
- file1
- file2

### 📝 差分あり
#### {filename}
\`\`\`diff
(diff output)
\`\`\`

### 🆕 新規（対象リポジトリに未配置）
- file3

### ⚠️ 警告
- file4: テンプレートに存在しない
```

### Step 4: 次のアクション確認

差分があるファイルが1つ以上ある場合、AskUserQuestion で次のアクションを確認する:

- 「確認のみ（終了）」— ここで終了
- 「差分の詳細を見たい」— 指定ファイルの詳細 diff を表示
