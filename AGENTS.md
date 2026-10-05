# 项目要求

## 提交要求

- Codex 创建新提交时，必须通过仅对当前命令生效的环境变量 `GIT_AUTHOR_NAME` 和 `GIT_COMMITTER_NAME`，将作者（Author）和提交者（Committer）的名称均设置为 `codex6`。
- 邮箱地址及其他身份、签名设置均沿用现有 Git 配置，不得修改用户的全局 Git 身份配置。
- 每次提交都必须在 `git commit` 命令中传入 `-S`，使用已配置的 GPG 密钥签名。签名失败时，不得改为无签名提交。
- 提交后，必须执行 `git verify-commit HEAD` 验证签名，并核对作者和提交者的身份信息，确认无误后再推送。
