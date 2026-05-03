# Backlog

## release.yml validation error（待修）

**现象**：每次 master push 触发一次 failed run，validation 阶段就失败，从未真正执行

**GitHub 报错**：Invalid workflow file: .github/workflows/release.yml#L1
(Line: 169, Col: 14): An expression was expected

**事实**：
- Line 169 是 `run: |`，本身无 `${{ }}` 表达式
- 前面 line 165-168 是 env 块，4 个 step output 引用：version / tag / dmg.size / sparkle.signature
- GitHub 报错行号疑似不准，真凶在前面某个 step output 引用

**下次处理建议**：
- 用 actionlint 工具本地校验（`brew install actionlint && actionlint .github/workflows/release.yml`）
- 或查 GitHub Actions 文档关于 step outputs 在 env 块里引用的静态校验规则
- 修法等真正诊断完成后再决定

**不影响**：CI workflow（绿）、代码运行、未来发版前的修复机会

**不修的代价**：Actions 页面每次 push 多一条红色 failed run，可能发垃圾邮件
