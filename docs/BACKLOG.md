# Backlog

## release.yml YAML validation error(待修)

**现象**:每次 master push 触发一次 failed run,validation 阶段就失败,从未真正执行。

**GitHub UI 报错**:
Invalid workflow file: .github/workflows/release.yml#L1
(Line: 169, Col: 14): An expression was expected

**actionlint 实际定位**(更准):
line 169 col 226: unexpected end of input while parsing variable access,
function call, null, bool, int, float or string

**诊断**:line 169 col 226 附近某个 `${{ ... }}` 表达式缺闭合(`}}` 或 `)` 之类)。GitHub UI 报的 col 14 是误导,真实位置在 col 226。

**下次处理建议**:
1. `cat -n .github/workflows/release.yml | sed -n '169p'` 看 line 169 完整内容
2. 数到 col 226 看是哪个 `${{ }}` 表达式
3. 修闭合
4. 跑 `actionlint .github/workflows/release.yml` 验证
5. 修通过后 commit + push

**不影响**:CI workflow(绿)、代码运行、未来发版前的修复机会

**不修的代价**:Actions 页面每次 push 多一条红色 failed run,可能发垃圾邮件
