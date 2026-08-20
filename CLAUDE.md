# CLAUDE.md

## 言語

- コード・コメント・ドキュメント・コミットメッセージ・PR/issue本文は英語
    - `.language` = `english`

## 整形

- luaファイルの手動整形は不要
    - `stylua.toml`でstylua、GitHub Actionsでの自動整形を予定

## テスト・動作確認

- テストフレームワークなし。実ホスト(`setup()`の`host`)向けの手動スモークテストで確認する
    - チェックリストは`README.md`のDevelopment
- エージェント自身では転送の検証は完結できないため、動作確認はヒトが行う

## 実装方針

- 依存は`telescope.nvim`のみ。新規依存は追加しない
- 外部コマンド(`ssh`/`scp`)は`vim.system`で非同期実行、引数はリスト形式(シェルクォート問題の回避)
- Windows first-class: ローカルパスの変換は`vim.fn.has("win32")`でゲートする
- 転送フローは`README.md`のFlow、今後の機能は同Roadmapを参照
