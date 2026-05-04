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

---

## 静态站点部署遗留(优先级 P3,部署稳定后清理)

### Broken link 清单(2026-05-04 部署 4 站发现)
JS 对象 `href:` 数据渲染为 `<a href>`,**不阻塞页面加载**,但点击会 404。

- **tangzhihong.com**:
  - `app.js` line 456/462 → `privacy.html`(产物缺失)
  - `brand.js` line 14/16/18/379/381 → voicebee/jotbee/brand.html
- **jotbee.app**:
  - `jotbee.js` line 136/138/406/422/424 → 跨产品导航
  - `jotbee.js` line 434/440 → `privacy.html`
- **voicebee.tangzhihong.com**:
  - `voicebee.js` line 117/122/366/368/378/384 → 跨产品导航
- **freejournal.app**:无 broken link ✅

**修法**:
1. 跨产品导航 → 改用绝对 URL(`https://jotbee.app/...`)
2. `privacy.html` → 补一个简单的隐私政策页面,或从 JS 里删掉链接

### Stash 备份清理
部署稳定运行 1-2 周后可 drop:
- `~/Developer/tangzhihong.com`:`stash@{0}: pre-redesign-snapshot 2026-05-04`
- `~/Developer/freejournal-site`:`stash@{0}: pre-redesign-snapshot 2026-05-04`

**验证命令**:`git stash list`
**清理命令**:`git stash drop stash@{0}`

---

## Cloudflare 收尾(优先级 P2,本周内做)

### 验证 voicebee 子域 CNAME 指向
2026-05-04 切换部署平台:GitHub Pages → Cloudflare Pages。
Cloudflare Pages "激活域" 时**应自动**把 `voicebee` CNAME 从 `answer2023.github.io` 改为 `voicebee.pages.dev`。
**待验证**:登录 Cloudflare → tangzhihong.com 区域 → DNS → 记录,确认 voicebee CNAME 现在指向 `voicebee.pages.dev`。如仍指向 GitHub,手动改。

### 清理今天上午加的旧 DNS 记录
部署 GitHub Pages 路线时加的 TXT 验证记录(2026-05-04):
- `_github-pages-challenge-answer2023` TXT 记录

**现状**:GitHub 已 verified,但已不再用 GitHub Pages 部署 voicebee。
**是否删**:留着无害(不影响任何东西),但属于"已废弃配置"。强迫症患者可删;懒人可留。

### GitHub OAuth 授权收紧
2026-05-04 配置 Cloudflare Pages 时,授予了 **All 28 repositories** 访问权限。**实际只需要 VoiceBee 一个**。
**修法**:
1. GitHub → Settings → Applications → Authorized OAuth Apps → Cloudflare Pages
2. 改 Repository access → Only select repositories → 只勾 VoiceBee
3. 验证 Cloudflare Pages 部署仍正常(push 一次 gh-pages 测试)

---

## 协作工作流改进(优先级 P3,纪律性)

### 跨 session 上下文存储路径
**不要用** `/tmp/`(macOS 重启清空),**不要写在项目内**(跨分支会丢)。
**正确路径**:`~/Developer/notes/{project}/` 或 `~/Developer/docs/`(项目外、持久、跨分支可见)。

### 跨分支调试时的临时文件路径
不同分支目录结构不同,临时文件**绝不要**写到项目内任何路径。
**永远安全**:`~/` 下的项目外路径。

2026-05-04 教训:`doc/sessions/2026-05-04-deploy.md` 写在了项目内,后续手动迁移到 `~/Developer/docs/`。

### `cp -R` 幽灵重复执行(根因未明)
2026-05-04 部署 gh-pages 分支时,`cp -R src ./assets` 出现 `./assets/` + `./assets/assets/` 两层副本,mtime 差 60 秒。
前 3 站用 `cp -R src .` 语法**未触发**,只有 voicebee 这一次出现。

**怀疑**:Claude Code hook 行为(可能 `~/.claude/settings.json` 有钩子)。
**下次查**:
1. `cat ~/.claude/settings.json | grep -A 5 hook`
2. 查 `~/.claude/hooks/` 目录
3. 复现问题(故意再跑一次相同命令)
4. 找到 hook 后决定保留/移除
