# npc · 对齐管家（镜像对齐 NPC 仓）

本仓库是一个 **CNB NPC Agent 项目**，纯配置驱动（零业务代码），核心 NPC 为「对齐管家」，专注**四仓镜像对齐与 tag 同步**，支持多个模型做同一任务的 A/B 实测。

## 触发方式

在仓库任意 **Issue / PR** 评论区 **@ 对应角色名** 即可召唤（已同时绑定 `issue.comment@npc` 与 `pull_request.comment@npc`）。

## NPC 角色

| 角色 | 说明 |
| --- | --- |
| **对齐管家**（默认） | 四仓镜像对齐与 tag 同步的执行管家，默认绑定**最新模型** `deepseek-v4.1-flash` |
| **hy4-preview / deepseek-v4.1-flash / glm-5.3 / glm-5.3-flash / glm-5.2 / kimi-k3** | A/B 实测角色，角色名即模型 ID，触发时动态绑定对应模型跑同一对齐任务 |
| **同步官** | 参考上游项目引入 NPC（参考上游项目 <https://cnb.cool/i.o/sync>，全功能保留 + 私有参考项目令牌单通道）：在任意仓库 @ 即可把参考上游项目（公开开箱即用、私有走环境注入令牌）同步进来并配置定时自动更新 + PR 自动合并（无人值守）；因 imports 密钥不可分享，需完整路径 @ |

> 角色人设见 [`.cnb/settings.yml`](.cnb/settings.yml)，角色名需与 [`.cnb.yml`](.cnb.yml) 顶层事件绑定 key 完全一致。
> 模型清单与思考级别/图片支持口径对齐自参考上游项目 <https://cnb.cool/npc/CodeBuddy>（对齐 `180dd6b`，2026-09-11）。
> 参考项目已下线 `deepseek-v4-pro` / `deepseek-v4-flash` / `deepseek-v4-flash-version`，本仓同步移除。

## 功能矩阵

| 能力 | 对齐管家 | A/B 实测角色 | 说明 |
| --- | :---: | :---: | --- |
| 四仓镜像对齐（CNB） | ✅ | ✅ | `xgzwl/website`、`xgz/website/xgzwl-network`、`xgzwlkj/web`、`hfxgzwl/website` |
| GitHub 镜像同步 | ✅ | ✅ | `github.com/xgzwl/xgzwl-network`，directPush 白名单直推（免费版无分支保护） |
| tag 同步（tag 先行序列） | ✅ | ✅ | 活跃仓打 tag → bump PR → tag 真身推四镜像 → 对齐（L-122/L-123 无红窗序列） |
| 活跃仓实跑判定（活口径） | ✅ | ✅ | `CNB_REPO_SLUG` / `cnb.activerepo` / `ls-remote` 近 7 日落点，禁凭文档快照 |
| 单笔快进对齐提交 | ✅ | ✅ | `commit-tree <活跃树> -p <镜像main> -p <tag提交> -S`——树=活跃仓、父链保 R3 |
| 对齐分支推送（树级路由） | ✅ | ✅ | pre-push 对 `align/mirror-*` 走树级等价判据，无需禁用 hooks |
| 合并回读门禁（merge:pr） | ✅ | ✅ | 成功字段判定 + 409 语义三分 + 合并后回读终态，`MERGE-CONFIRMED` 方算完成 |
| 镜像 open PR 预警 | ✅ | ✅ | 对齐前探测镜像仓驱动器升级 PR，防覆盖竞态转 conflict |
| 发散四分档 + 回灌指引 | ✅ | ✅ | diverged 默认阻断；树级核验零损失才放行；实质独有须回灌 |
| 补丁等价降档（L-117） | ✅ | ✅ | `--cherry-pick --right-only` 剔除 squash 同步产物，实质独有 0 笔自动降 behind |
| 推送闸门链（树级路由+签名闸门） | ✅ | ✅ | pre-push 五道；`align/mirror-*` 走树级等价判据（L-154③）；`%G?` N 拦 E 放（L-162） |
| 多仓会话真身与声明通道 | ✅ | ✅ | `git config cnb.activerepo` 本地声明（L-165）+ 会话所在仓恒判 active（L-161） |
| 合并纪律与落地回读 | ✅ | ✅ | 默认 rebase（squash 400 自动分流）+ `merged: true` 显式判据 + ls-remote 回读真值（L-162/L-121） |
| 任务并发闸门（固定落点） | ✅ | ✅ | 发版/对齐推送前二次回读远端 main，已前进即停（L-128） |
| CI 等价快门禁（活跃仓侧） | ✅ | ✅ | 六连全量 + 口径类自动修复联动，推送瞬间拦截（L-174） |
| 干跑（`--dry-run`） | ✅ | ✅ | 只报告对齐需求不动手 |
| 内置自测（`--selftest`） | ✅ | ✅ | 执行前链路自检（align-mirror 53 例 / merge-pull-verified 17 例） |
| 多模型 A/B 实测 | — | ✅ | @ 不同模型角色跑同一任务对比结果 |
| 模型 | deepseek-v4.1-flash（thinking off） | 角色名对应模型 | 见 [`.cnb.yml`](.cnb.yml) 动态绑定 |
| 密钥注入（imports） | ✅ | ✅ | `CNB_MIRROR_TOKEN` / `GH_TOKEN` 由密钥仓注入 |

> A/B 实测角色共享同一套 `*align_prompt` 人设，仅模型不同，便于横向对比输出质量与对齐效果。

## 同步官（参考上游项目引入）

参考上游项目 <https://cnb.cool/i.o/sync>（Issue #13，对齐至参考上游项目 `816a4cc`），**其全部功能保留**：在**任意仓库**的 Issue/PR 评论里
`@xgzwlkj/npc(同步官)` 并给出参考项目地址（公开可直接同步；私有走令牌），即可把参考上游项目进当前仓库，并配置定时自动更新——**配一次，之后全程无人值守**（有更新才开 PR，PR 由流水线自动合并）。

```text
@xgzwlkj/npc(同步官) 使用 https://cnb.cool/xgzwlkj/npc ，帮我同步 https://github.com/xxx/yyy
```

能力清单（与源项目一致）：

- **三种落地方式**（脚本自选）：铺源（空仓库/首次上车推荐——浅克隆快照落首个提交，不复刻参考项目历史）/ 快照式（与参考上游项目无共同祖先的老镜像）/ 真实 merge（正常增量，保留参考上游项目完整历史）
- **保护本地配置**：目标仓库 `.cnb.yml`、`.cnb/`、`.ci/` 永不被参考上游项目覆盖；子目录模式剔除参考上游项目自带平台配置
- **定时自动更新**：默认每天 03:17 一次（Asia/Shanghai），cron 可调（每天 N 次/每小时均可）；有更新才提交
- **无人值守自动合并（零前置条件）**：有更新 → 推临时分支 `sync/upstream-auto-<时间戳>` → 开 PR → **同一轮流水线内 `cnb pulls merge-pull` 内联直接合并**（只合本轮自己开的那一个 PR 编号，不抢人工评审），**不需要保护分支、不需要评审人、不需要进仓库设置**。兜底路径 `pull_request.mergeable` 下的 `git:auto-merge` 仅在默认分支恰好是保护分支时才触发（PR 早已合掉，幂等落空）
- **默认分支：空仓库时跟随参考上游项目**：平台机制——空仓库第一个被 push 的分支名即仓库默认分支。旧流程先推 `sync/bootstrap` 会把默认分支带歪；现在模板前置 `resolve-default-branch` + `init-default-branch` 两阶段（同步官初装时也先做同样的事），空仓库上车跟随参考项目默认分支（参考上游项目 `master` 就建 `master`），已有分支的仓库一律沿用不改写。`CNB_DEFAULT_BRANCH` 不直接采信（空仓库 runner 上已预设 `main`）
- **不凭空造分支**：下发脚本不传 `TARGET_BRANCH` 就只在本地提交、不推送，绝不猜分支名（旧版默认推 `main`，空仓库上车会多出一个谁也没要的 `main`，甚至成为默认分支）
- **引导 PR 自我了结**：同步官初装时**建完引导 PR 就地自己合掉**（不留给用户点合并），合并后由 `pull_request.merged` 流水线自动删源分支，不留挂着的 PR / 孤儿分支
- **裸地址即指令**：评论里只有一个参考项目 URL 也直接开工，不反问
- **Git LFS 自动探测与处理**：无需声明，真身还原 + LFS 方式入库；拉不到真身就中止报 conflict，绝不提交指针文件
- **增量同步**：`Upstream-Sync` 标记游标 + merge-base 判定；参考上游项目强推历史可继续；重叠改动列文件不静默
- **只读参考上游项目**：upstream push 地址置 `no-push://disabled`，绝不推回参考上游项目
- **改动走 PR**：分支 `sync/bootstrap` + PR，不直推默认分支
- **私有参考项目（可选令牌通道，单一来源）**：同步官运行环境已由本仓事件流水线 `imports` 密钥仓库注入
  `CNB_MIRROR_TOKEN`（CNB 参考上游项目）/ `GH_TOKEN`（GitHub 参考上游项目），同步脚本自动收编为拉取凭证
  （临时改写 URL、fetch 完立即还原，含失败分支），令牌不落代码不进日志——**多数私有参考项目零配置**。
  目标仓库的定时任务默认零密钥引用；若它也要拉私有参考项目，由引用方自行在 `.cnb/git-sync.yml`
  的 env 段注入 `UPSTREAM_TOKEN`（模板已留注释占位行），来源与写法由引用方决定

适配本仓的关键改造（源项目 → 本仓）：

| 项 | 源项目 i.o/sync | 本仓 xgzwlkj/npc |
| --- | --- | --- |
| 技能装载 | 工作区即本仓，`cnbcool/default-npc:latest` 直接 `npc:go` | NPC 事件工作区是**目标仓库**，`bootstrap-skills.sh` 先匿名浅克隆本仓（`CNB_NPC_SHA` 锁版本）再装技能，然后 `npc:go` |
| 脚本/模板取源 | `i.o/sync` | 本仓 slug 硬编码为 `xgzwlkj/npc`（注入的 `CNB_NPC_SLUG` 可能指向参考上游项目 CodeBuddy 仓——那里没有 skills/；仅在注入 slug 克隆结果带技能时采信） |
| 私有参考项目令牌 | 不支持（公开参考项目限定） | 环境令牌单通道：本仓事件流水线 imports 密钥仓注入的 `CNB_MIRROR_TOKEN`/`GH_TOKEN` 收编为 `UPSTREAM_TOKEN` |
| 运行镜像 | `cnbcool/default-npc:latest` | 复用本仓自建镜像（预装 cnb cli / git / git-lfs / gpg / gh） |
| 每日自检 | `.ci/watchdog.yml`（04:23） | 同款自检（04:23）+ 同步官角色/事件绑定校验 + 跨仓自举路径自检 + 锁文件过期检测与自动跟进 |
| PR CI | 无 | 目标分支为 main 的 PR 跑同款自检四 stage（`!reference` 复用，防两处漂移） |
| 既有角色 | 仅同步官 | 与既有 7 个对齐类角色共存，互不影响 |

### 私有参考上游项目（可选令牌通道）

公开参考项目零配置可用。私有参考项目的拉取凭证来自**运行环境注入的环境变量**（单一通道）：

- 同步官执行同步时：环境已注入 `CNB_MIRROR_TOKEN` / `GH_TOKEN`（本仓事件流水线 `imports`
  密钥仓库 `<密钥文件>`），脚本自动收编——**零配置**，令牌只在 fetch 时
  临时改写 URL、fetch 完（含失败分支）立即还原，提交信息/本地引用/日志永远不带凭证
- 目标仓库的定时任务默认**不含任何令牌**（模板零密钥引用）。若定时任务也需要拉私有参考项目，
  由引用方自行在 `.cnb/git-sync.yml` 的 `env` 段注入 `UPSTREAM_TOKEN`（模板 env 段已留
  注释占位行）——来源不限（如密钥仓库 `imports`），写法由引用方决定
- 环境无令牌时按私有仓库无权限处理：同步官评论给出指引，不硬闯、不输出任何凭证

> 该 NPC 因 imports 密钥仓库文件**不可分享**（不进 NPC 榜单）；本仓保持公开可读，
> 外部用户仍可按完整路径 `@xgzwlkj/npc(同步官)` 触发，服务不受影响。

### 无人值守与默认分支（跟进参考上游项目 49658d0 → 816a4cc）

本轮跟进参考上游项目这批改动（Issue #13 后续）：

- **自动合并零前置条件**：合并动作内联进定时流水线（`merge-pr-inline` 阶段，开完 PR 就地
  `cnb pulls merge-pull`），不再依赖 `pull_request.mergeable` + 保护分支 + 评审人。
  原因：NPC token **无 `repo-manage:rw`**（实测 403），无法替用户建保护分支规则；
  而「要用户先去设置里点几下」本身就不是无人值守。
  三个实现细节：`--commit-title` 必填（缺了 400）；刚开的 PR 可能还在 `checking`，
  退避重试；只合本轮自己的 PR 编号。
- **空仓库默认分支跟随参考上游项目**：模板前置 `resolve-default-branch`（算分支名，写
  `.git/sync-default-branch`）+ `init-default-branch`（仅在「远端无任何分支」时把它建出来）；
  已有分支的仓库两阶段直接跳过，绝不改写。同步官初装时在建 `sync/bootstrap` 前先做同样的事。
- **不凭空造 `main`**：下发脚本 `TARGET_BRANCH` 不再默认成 `main`——不传就只在本地提交、不推送。
- **合并后源分支由平台自动删除**（实测），临时分支不会堆积；无需配 `removeSourceBranch`。
- **`set -e` × 命令替换的静默失败防线**：`X="$(cmd | awk ...)"` 里 cmd 失败时会让整个阶段
  静默退出（日志空白）；信息性探测段用 `set -uo pipefail` 或 `|| true`，需要重试的命令写
  `out="$(cmd 2>&1 || true)"`。watchdog 已加对应防回退断言。

目录结构（同步官相关）：

```text
skills/sync-upstream/             招牌技能（SKILL.md + 同步脚本×2 + 183 例场景测试）
skills-lock.json                  官方 cnb-* 技能锁版本（sha256 校验，hash 不符拒装；过期自动跟进）
.ci/refresh-skills-lock.sh        官方技能锁文件检测/刷新（watchdog 每日调用，stale 时刷锁开 PR）
.cnb/bootstrap-skills.sh          跨仓自举：克隆本仓 → 装技能到 ~/.codebuddy/skills
.ci/git-sync.yml                  同步流水线模板（定时同步 + 自动开 PR + 自动合并 + 引导 PR 收口）
.ci/watchdog.yml                  每日自检 + PR CI（文件完整性 / 约定 / 场景回归 / 自举 / 锁文件过期检测与自动跟进；自检 stage 经 .skill-selftest 锚点供 .cnb.yml PR CI 复用）
```

开发自测：

```bash
bash skills/sync-upstream/scripts/tests/run-tests.sh   # 同步脚本场景测试（含默认分支/内联合并/静默失败防线）
bash -n .cnb/bootstrap-skills.sh                       # shell 语法
bash .cnb/bootstrap-skills.sh                          # 技能装载（幂等）
bash .ci/refresh-skills-lock.sh                        # 锁文件过期检测（stale 时 --refresh 刷锁）
```


## 快速开始

### 场景 1：召唤对齐管家做一次全量镜像对齐

在任一 Issue / PR 评论区 @ **对齐管家** 并说明目标（如"对齐四仓到最新"）：

```text
@对齐管家 请对齐 xgzwl/website 四仓镜像与 tag 到最新 main
```

对齐管家将自动：①实跑判定活跃仓 → ②`pnpm align:mirror` selftest + 干跑判需 → ③推 `align/mirror-<yyyymmdd>` 签名快进分支 → ④建 PR → ⑤轮询 CI → ⑥`pnpm merge:pr` 合并（回读门禁）→ ⑦终态树比对通报。

### 场景 2：多模型 A/B 实测同一对齐任务

用不同模型角色各召唤一次，对比同一任务的执行质量：

```text
@deepseek-v4.1-flash 请分析当前四仓对齐差距并给出执行结论
@glm-5.3 请分析当前四仓对齐差距并给出执行结论
```

两个角色跑同一 `*align_prompt`，便于横向比对不同模型的对齐判断与实操表现。

### 场景 3：定向/干跑/自测

```text
@对齐管家 请定向对齐 xgzwl/website 到 xgz/website/xgzwl-network（--dry-run 先只看差距）
```

对齐管家支持 `--remote <名>` 定向、`--dry-run` 只报告需求、`--selftest` 链路自检。

## 核心能力：四仓镜像对齐

- **四仓拓扑**：`xgzwl/website`、`xgz/website/xgzwl-network`、`xgzwlkj/web`、`hfxgzwl/website`（CNB 四仓）+ GitHub 私有镜像 `github.com/xgzwl/xgzwl-network`。AI 积分轮换制，任一仓随时可成活跃开发仓。
- **执行链路**：以实跑判定的活跃仓为基线，走 `pnpm align:mirror` 全自动链路（selftest → 干跑判需 → 逐镜像构造签名快进提交 → 推对齐分支 → 建 PR → 轮询 CI → 合并 → 回读落地真值）；tag 同步随链路推送。
- **镜像口径**：仓库级（分支 + tag）树级对齐——镜像 main 的**树**与活跃仓逐字一致即达成（分发形态合法，不要求历史同构）；CNB 三镜像 main 受平台保护禁直推一律 PR 通道，GitHub 走直推白名单。
- **密钥通道**：跨根组织通过 `imports` 注入密钥仓库 `<私有密钥仓>` 的 `CNB_MIRROR_TOKEN` / `GH_TOKEN`（见 `.cnb.yml`）。

## 合并策略（2026-09-12 终版口径）

两套合并场景别混谈：**功能 PR → 活跃仓 main** 优先 rebase（保留逐笔提交与 GPG 签名）；**镜像对齐 PR → 镜像仓 main** 用 **rebase 或 merge 式，禁用 squash**：

1. **对齐提交是单笔 `commit-tree` 快进提交**（树=活跃仓、父链=镜像 main + tag 提交），不存在「rebase 重放 N 笔」的旧风险——rebase 对单笔基于 base 的提交是无操作，原提交对象与签名完整保全。
2. **squash 会丢父2（tag 提交）链破坏 R3 门禁**——R3 判 `tag 提交 ∈ 镜像 main 历史`，合并后 push 门禁依赖此父链转绿（2026-09-12 三镜像全链实证）。
3. **squash 产物为平台代签**（`%G?`=E 豁免）vs 本地构造 `-S` 签名 + rebase 保全（`%G?`=U/G）——后者签名链更确定。
4. 平台差异实测：`xgzwlkj/web` 曾硬拒 squash（400）；align:mirror 已内置 rebase 优先 + 自动降级链。

详细纪律全景（判定前提 / tag 先行序列 / 构造推送 / 合并门禁 / 验证回读 / 发散与竞态处置 / 红线）见 [`AGENTS.md`](AGENTS.md)「四仓对齐纪律」一节（2026-09-12 终版，全部实跑实证）。

## 目录结构

```
.cnb/settings.yml   NPC 角色与人设定义
.cnb.yml            流水线：镜像构建 + NPC 事件触发（多模型动态绑定）
Dockerfile          NPC 自定义运行镜像（预装 cnb cli / git / gpg / gh）
assets/avatar.png   NPC 头像
README.md           本文件
AGENTS.md           面向 AI Agent 的仓库约定与四仓对齐纪律（2026-09-12 终版）
```

## 开发 / 维护

- 新增角色：在 `.cnb/settings.yml` 的 `roles:` 末尾追加角色（含 `name`/`slogan`/`prompt`），并在 `.cnb.yml` 顶层补同名事件绑定（角色名 = 模型 ID 时用 `${CNB_NPC_NAME}` 动态绑定）。
- 模型清单对齐参考上游项目 `npc/CodeBuddy`：新增/下线模型时同步 `settings.yml` 的 `roles` 与 `.cnb.yml` 顶层 key，两者必须逐字一致，否则 @ 角色无法触发。
- 密钥缺口（PAT 未补录 / allow_slugs 未覆盖 / gh 未登录）一律由 owner 到密钥仓库 Web 端补录，禁止本地克隆或落代码。
- 变更仓库操作约定时，同步刷新 `AGENTS.md`，避免活跃仓轮换后文档快照过期；四仓对齐纪律节随活跃仓对齐链路演进同步更新（当前基于 xgzwl/website main `116a5a3` 证据链）。

## 安全

所有令牌、凭证一律脱敏，不落代码、不进日志；密钥文件仅 Web 端编辑（带审计与水印）。
