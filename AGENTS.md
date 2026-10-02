# AGENTS.md · npc 仓操作约定（面向 AI Agent / NPC）

本仓库是 **CNB NPC Agent 项目**（纯配置驱动，零业务代码），仓库内不存在 `scripts/` 镜像脚本本体——
实际执行脚本位于**实跑判定的活跃开发仓**（如 xgzwl/website），本仓是 NPC 人设与触发流水线的宿主。

## 你是哪个角色

本仓已注册 8 个 NPC 角色：默认「对齐管家」+ 6 个 A/B 实测角色
（`hy4-preview / deepseek-v4.1-flash / glm-5.3 / glm-5.3-flash / glm-5.2 / kimi-k3`）
+ 1 个「同步官」（参考上游项目引入，参考上游项目 i.o/sync，全功能保留，见下文专节）。

- 全部角色共享同一份 `*align_prompt` 人设，仅在模型绑定上不同。
- 你被 @ 触发的角色名决定本次运行绑定模型：
  - 角色名 = 模型 ID（A/B 实测角色）→ 动态绑定该模型；
  - 「对齐管家」→ 写死**最新模型** `deepseek-v4.1-flash`（thinking off、支持图片）。
- 思考级别与图片支持按模型动态判定（`set model` stage 导出 `NPC_THINKING` / `NPC_SUPPORT_IMAGE`）：
  `hy4-preview` → high；`deepseek-v4.1-flash` → off；其余 medium；
  `deepseek-v4.1-flash`、`glm-5.3-flash` → supportImage true。
- 对齐自参考上游项目 <https://cnb.cool/npc/CodeBuddy> `180dd6b`（2026-09-11）：参考项目已下线
  `deepseek-v4-pro` / `deepseek-v4-flash` / `deepseek-v4-flash-version`，本仓同步移除（角色 9 → 7）。
- 角色人设是**唯一权威口径**，本文件是其可读速查，冲突时以 `.cnb/settings.yml` 角色 `prompt` 为准。

## 关键配置速查

| 文件 | 作用 |
| --- | --- |
| `.cnb/settings.yml` | NPC 角色、slogan、人设 prompt（`*align_prompt` 锚点复用） |
| `.cnb.yml` | 镜像构建流水线 + NPC 触发事件（角色名 = 顶层 key，与 settings.yml 完全一致；模型清单对齐自参考上游项目 npc/CodeBuddy） |
| `Dockerfile` | NPC 运行镜像（预装 cnb cli / git / git-lfs / gpg / gh） |
| `assets/avatar.png` | NPC 头像 |

`.cnb.yml` 顶层 key 须与 `.cnb/settings.yml` 的 `roles[].name` **逐字一致**，否则 @ 角色无法触发对应流水线。

## 对齐执行逻辑速查（2026-09-30 口径，源 = 活跃仓 xgzwl/website）

四仓同步执行的最新机器化口径（人设已内嵌，此处为速查；细节见活跃仓 AGENTS.md §3.2/§3.3 与 `.learnings/`）：

- **推送闸门链**：活跃仓 pre-push 五道——分支卫生（L-104）/ 基点+**树级路由**（对齐分支与直推白名单走
  树级等价，L-154③）/ 任务并发（L-128）/ **签名闸门**（`%G?` N 拦截 E 放行，L-162）/ CI 等价快门禁
  （六连+口径类自动修复，L-174）+ pre-commit 字体联动预检（L-166⑥）。
- **多仓会话**：本地四仓开发必设 `git config cnb.activerepo <活跃仓>`（L-165）；镜像仓触发的会话
  推送目标 = 会话所在仓时闸门恒判 active（L-161 会话真身，免声明）。
- **合并纪律**：默认 rebase；squash 裸 400 自动分流降级；成功判据 = 显式 `merged: true`；409 2009014
  退避重试；合并后回读 `is_merged` + `ls-remote` main 真值——**落地提交以回读为准**（L-121/L-162）。
- **发散处置**：四分档（behind/diverged 默认阻断回灌/ahead 只报/unrelated 人工）+ 补丁等价降档
  （`countSubstantiveCommits` 剔除同步产物，实质独有 0 笔即 behind，L-115/L-117）；孤儿 tag 走
  活跃仓发版真身 tag 覆盖推四镜像（tag 先行序列，L-122/L-123）。

## 同步官（参考上游项目引入 NPC，2026-09-23 参考上游项目 i.o/sync，2026-09-25 对齐至参考上游项目 `816a4cc`）

- **触发**：任意仓库 Issue/PR 评论 `@xgzwlkj/npc(同步官)` + 参考项目地址（**裸地址即指令**，不反问）；NPC 在**目标仓库**干活。
- **能力**（源项目全功能保留 + 私有参考项目令牌通道）：铺源/平铺/子目录三模式（脚本自选：空仓库铺源、无共同祖先快照式、正常增量真实 merge）、
  保护本地 `.cnb*` 配置、定时增量同步（默认每天 03:17，cron 可调）、
  **无人值守自动合并（零前置条件）**（有更新才推临时分支 `sync/upstream-auto-<时间戳>` 开 PR，
  再**同一轮流水线内 `cnb pulls merge-pull` 内联直接合并**，只合本轮 PR 编号；不需要保护分支 / 评审人 / 仓库设置。
  兜底路径 `pull_request.mergeable` 下的 `git:auto-merge` 仅在默认分支恰好是保护分支时触发，PR 早已合掉属幂等落空）、
  **空仓库默认分支跟随参考上游项目**（平台机制：空仓库第一个 push 的分支名即默认分支；模板前置 `resolve-default-branch` +
  `init-default-branch` 两阶段，同步官初装也先做同样的事；`CNB_DEFAULT_BRANCH` 不直接采信——空仓库 runner 上已预设 `main`）、
  **不凭空造 `main`**（下发脚本不传 `TARGET_BRANCH` 就只在本地提交、不推送）、**引导 PR 自我了结**（初装时建完即自合并，
  合并后 `pull_request.merged` 流水线自动删源分支）、LFS 自动探测与真身还原（拉不到就中止、不提交指针文件）、
  `Upstream-Sync` 增量游标、只读参考上游项目、改动走 PR。
- **令牌单通道**（owner 决策 2026-09-23 Issue #13 引入双通道，2026-09-24 Issue #13 收敛为单通道）：同步官事件流水线直接
  imports 本仓密钥仓库 `dev-signing-secrets.yml`，注入的 `CNB_MIRROR_TOKEN`/`GH_TOKEN` 由同步脚本收编为
  `UPSTREAM_TOKEN`（显式变量优先），fetch 前临时改写 URL、fetch 后（含失败分支）立即还原，令牌不落代码不进日志。
  目标仓库定时任务默认零密钥引用；若需拉私有参考项目由引用方自行在模板 env 段注入 `UPSTREAM_TOKEN`（模板已留注释占位行）。
  同步官因此**不可分享**（不进 NPC 榜单，本仓保持公开、完整路径 @ 仍可触发）。
- **与对齐类角色的区别**：对齐管家管四仓镜像拓扑对齐；同步官管「任意参考上游项目（公开/私有带令牌） → 任意仓库」的搬运与定时跟进，二者独立。
- **本轮参考上游项目跟进**（`49658d0` → `816a4cc`，Issue #13 后续）：铺源模式、无人值守内联合并（免保护分支）、
  空仓库默认分支跟随参考上游项目（`resolve-default-branch`/`init-default-branch`）、引导 PR 自我了结、裸地址即指令、下发版脚本
  `sync-upstream-target.sh`；并修掉「`set -e` × 命令替换静默失败」与「脚本凭空造 `main`」两个实测坑（watchdog 均有防回退断言）。
- **关键适配**：NPC 事件工作区是目标仓库（无本仓文件），`.cnb/bootstrap-skills.sh` 先匿名浅克隆本仓
  （`CNB_NPC_SHA` 锁版本；slug 硬编码本仓，不直接采信注入的 `CNB_NPC_SLUG`——本仓角色复用参考上游项目
  CodeBuddy 人设，注入值可能指向参考上游项目仓，那里没有 skills/）再装技能到 `~/.codebuddy/skills`；
  目标仓库用的同步脚本与流水线模板从本仓取（本仓须保持公开可读）。
- **自检**：`.ci/watchdog.yml` 每日 04:23 校验文件完整性、约定占位符、场景回归（含私有参考项目令牌 3 例、下发脚本 × LFS 4 组 23 例、
  空仓库默认分支跟随参考上游项目、内联合并免保护分支、命令替换不吃 errexit、**守护断言禁写管道 grep** 等）、跨仓自举路径、省 token 与无人值守约定守卫。
- **守护断言禁写管道 grep（SIGPIPE 竞态，PR #16 实证）**：断言写成 `A | grep -q <词>` 时，下游 `grep -q`
  命中即退出、参考上游项目 `A` 尚未写完就吃 SIGPIPE(141)，在 `set -o pipefail` 下被放大成整条管道的结果——
  **已经命中的断言反而报红**，报错口吻还把人往「内容丢了」上引（连误诊两轮）。实测 29KB 真模板
  `grep -vE | head -1` 100 轮里 18 轮吃 141，同一份代码本地绿、CI 红，是假阴性式 flaky。
  修法：结果**先物化到变量**，断言只对变量做单进程 grep（`has()` 用 here-string，无参考上游项目进程即无 SIGPIPE）。
  场景 AF（`run-tests.sh`，17 例）三重守卫：① 大输入 + 提前退出的下游把 141 逼成确定性事实，
  并复现「命中数>0 却退出码 141」的误诊形态；② 全仓扫描 `| grep` 形态（含命令替换内嵌）禁止复发；
  ③ 抽出 watchdog 的 convention-selftest **原样跑**（非测试复刻），确保修的是 stage 本体。
  另加 AF-0 **场景自守**：AF 段断言点个数钉死（`chk` 调用 == 17）——此前删掉一条断言只会让
  末尾 PASS 总数静默下降，无人拦；现在删一条即报红，逼人同步本文件口径。
- **AF-2b 判据订正（PR #17 CI 实证）**：AF-2b 原先断言「29KB 真模板 100 轮里 141 与正常**两种结果
  都出现过**」，把「旧写法是时序竞态」的论证押在了两种结果的分布上——而分布随机器与负载剧烈漂移：
  本跑点 14 轮 × 200 次采样每轮都有 141（最少 180/200），「正常」却可以低到 0/200，CI runner 上
  100 轮全 141 即 `AF_SMALL_GOOD=0` → 报红。**只有 141 恰恰是它要论证的现象**，却成了套件第二处
  假阴性式 flaky。现判据只保留「现象必然存在」：至少出现一次 141 即过，「也出现过正常」降级为
  信息性输出。确定性侧由 AF-2a（大输入 3/3 必 141）+ AF-2d（命中数>0 却 141）承担，论证不变弱。
  另加 AF-5 两条**反向守卫**（AF 段 15 → 17 例）：只提取 AF-2b 的 `chk` 调用本体来判——断言参数里
  不许再出现 `AF_SMALL_GOOD`，断言文案仍须含「至少出现一次」；想退回旧判据必须先改掉守卫。
  （提取只能认断言调用：AF-2b 注释为讲清历史**必须**提到 `AF_SMALL_GOOD`，整段扫会自己判红——实测踩到。）
- **恒假守卫订正（PR #16 评审遗留）**：「不许把保护分支当无人值守前置」原先靠
  `has '不是保护分支。$' -E` 判定，而模板那行以「…直接合并。」的引号结尾，`。$` **永不命中** ——
  守卫恒假，挡住退化靠的是「永不命中」而非「模板里真没有」，等于没守（`run-tests.sh` 同源断言同病）。
  现改守更本质的判据：`设置路径：仓库「设置」`（曾引导用户去开保护分支的痕迹）与 `逼用户去设置`
  两条文案命中数必须为 0；既真能报红，又不会被无害的只读探测说明（`不是保护分支` 全仓仅 1 处）误伤。
- **抽 stage 函数收编为一份**（PR #16 评审遗留）：`run-tests.sh` 原有两套同类实现 ——
  `extract_stage()` 写死 12 空格（只服务 `git-sync.yml`）、`af_extract_stage()` 自适应缩进（AF 段自用）。
  实测把写死版拿去抽 `watchdog.yml`（体缩进 10）会**静默抽出 0 行**，下游只看到「内容丢了」式假红。
  现收编为顶部唯一 `extract_stage`（读 script 行实际缩进 + 2，自适应任意 YAML 层级）。
- **场景 AG 扫描范围扩到守护脚本本体**：AG（不许硬依赖 python3）原先只扫 `run-tests.sh`，
  `watchdog.yml` 自身的 shell 从没被扫过（AF-3 的扫描目标自己就是盲区）——现扫
  `.ci/watchdog.yml` + `run-tests.sh` 两份。
  自检前四 stage 经 `.skill-selftest` 锚点供 `.cnb.yml` `main` 分支 PR CI（目标分支匹配口径）复用（`!reference` 引用，防两处漂移）；
  PR CI 的 `SKILLS_REF` 指向 PR 源分支——skills/ 等新文件未合并前 main 上没有，克隆 main 必失败。
- **官方技能仓库自动跟进**（PR #14 评审遗留补齐）：`computedHash` 真锁版本后官方技能仓库静默更新本仓不会跟进——
  watchdog 每日检测锁文件过期（`.ci/refresh-skills-lock.sh`），stale 即自动重算 hash 刷锁，
  经分支 `skills/auto-update` 开 PR，**人工评审合并后生效**（up-to-date 零噪音）；
  自动跟进只省「重算 hash」的体力活，「参考项目内容进本仓」这道门仍由人把守。
  改回「只告警不刷」：把 watchdog stage `auto-update-skills-lock` 的 if 改成 `SKILLS_AUTO_UPDATE=0`。
- **改同步行为**：改 `skills/sync-upstream/`（脚本+SKILL.md）与 `.ci/git-sync.yml`（模板），勿在目标仓库手改生成物。

---

## 四仓对齐纪律（2026-09-12 终版口径，全部实跑实证）

> 本节是对齐任务的**完整操作纪律**。你 clone 到的是**触发本次任务的 Issue/PR 所属仓库**，需先判定活跃仓再动手，勿凭文档快照认仓。
> 活跃仓脚本链路（`align:mirror` / `merge:pr` / `release` 等）持续演进，执行前先看活跃仓 `AGENTS.md` 与 `scripts/*.mjs` 实跑自测，不凭本文件记忆推断脚本行为。

### 一、判定与前提（动手前必做）

1. **活跃仓活口径**：`$CNB_REPO_SLUG`（云端会话权威）→ `git config cnb.activerepo`（本地声明，L-150）→ `git ls-remote <四仓> refs/heads/main` 比对近 7 日落点 + Issue/PR/流水线活动侧证。**禁止**凭文档快照或历史记忆声称活跃仓（轮换以周计，静态快照 5 天内过期有实证）。
2. **拓扑成员**：CNB 四仓 `xgzwl/website`、`xgz/website/xgzwl-network`、`xgzwlkj/web`、`hfxgzwl/website` 互为对等轮换镜像；GitHub `xgzwl/xgzwl-network` 为 directPush 直推白名单（免费版私有仓无分支保护）。**身份判定禁用裸子串**（`hfxgzwl/website` 包含子串 `xgzwl/website` 已实际踩坑——活跃仓解析须段边界匹配 + 运行时声明权威）。
3. **密钥可达性**：先实跑 `git ls-remote` 四仓 + GitHub。密钥不可达（PAT 未补 / allow_slugs 未覆盖 / gh 未登录）→ 明确报告缺口，指引 owner Web 端补录，**不臆测不硬闯**。密钥仓 `allow_events`「声明即收紧」——新增事件须同笔补白名单。
4. **环境前提**：GPG 签名链须 `GNUPGHOME` 环境变量显式注入子进程链（CNB 服务端 pre-receive 强制签名，无签提交必拒；签名探测走 `gpg.program` 原生路径）；客户端 hooks 防线已随 `pnpm install` 的 `prepare` 生命周期强制启用（任何环境装依赖即生效，无需手工 setup）。

### 二、对齐序列（发版与 tag 同步）

5. **tag 先行（L-122/L-123）**：发版正确序列 = 活跃仓先打 GPG tag（tag_push 流水线重签兜底）→ bump PR 合并 → **tag 真身推四镜像** → 镜像对齐。V6 判据双向严格相等（`pkgVersion === 最新 tag`），bump 先于 tag 必红；镜像侧 V6 取**各仓自己的**最新 tag，tag 未先行落位镜像必红。
6. **孤儿 tag 处置**：镜像侧存在活跃仓没有的 tag 先 `merge-base --is-ancestor` 分类——非祖先即孤儿 tag（平台 auto_tag 产物），该仓 V6 持久红重跑不绿；处置 = 活跃仓正式发版 → 真身 tag **覆盖推**镜像（禁止删除 tag，不可逆）。
7. **发版 = 改动**：bump / 对齐 / 文档一律走「功能分支 → PR → 平台合并」，不直推 main（平台合并与重签兜底两类既有链路除外）。

### 三、构造与推送

8. **对齐提交构造（核心）**：一律 `git commit-tree <活跃仓树> -p <镜像main> -p <tag提交> -S` 的**单笔快进提交**——树 = 活跃仓（内容零差异）、父链 = 镜像 main + tag 提交。**父2（tag 提交）不可省**：R3 门禁判 `tag 提交 ∈ 镜像 main 历史`，合并后镜像 main 须含 tag 提交，push 门禁才能正常判定转绿。禁推活跃仓 HEAD 作 PR 分支（分发形态必 conflict）。
9. **签名必须**：快进提交构造时 `-S` 签名（`GNUPGHOME` 在位）；无签快进提交会被服务端 pre-receive 拒绝。
10. **pre-push 树级路由（闸门适配，非禁用）**：`align/mirror-*` 分支推送与 directPush 直推走树级等价判据（推送树 == 活跃仓 main 树 → 放行；不等 → 拦 +「重跑 align:mirror」指引）；tag 推送 SKIP（防线在服务端 tag_push 流水线）；删除推送全零豁免。**无需任何 hooks 禁用操作**（旧口径「临时清空 hooksPath」已废止）。
11. **幂等覆盖语义**：`align/mirror-*` 分支重复推送用 `--force-with-lease`；lease 期望值须取**当前远端真值**（写构造前旧值必 stale），降级 `--force` 前先 `ls-remote` 回读确认远端是自己的上一笔产物。

### 四、合并纪律

12. **手动合并一律走 `pnpm merge:pr`**（活跃仓 `scripts/merge-pull-verified.mjs`）：内置三件套——成功字段判定（输出须显式 `merged: true`；**grep 过滤为空 ≠ 成功**，曾致 PR 漏合挂起一整天）+ 409 语义三分 + 合并后回读终态（`is_merged` + `ls-remote` main 真值）。exit 0 输出 `MERGE-CONFIRMED` 方算合并完成。**裸 `cnb pulls merge-pull` 禁止在流程中使用**。
13. **409 `2009014` 语义三分**（一码多因）：① CI 重排队（连续合 PR 时每合一个 → main 前进 → 下一 PR 的 CI 重跑 ~5 分钟）→ 等 CI 终态再合（工具内置轮询，`--ci-wait-min` 默认 12 分钟）② 上报传播延迟（CI 已 success 仍 409）→ 短间隔重试 ③ CI 失败 → 直接停（重试无意义）。**`--force` 不绕 status_check**（只管 conflict 类）；409 时 `get-pull` 的 `blocked_on` 可分流。
14. **merge style 与父链**：对齐提交已含正确父链（见 §8），rebase（单笔基于镜像 main，重放为无操作，原提交对象与签名保全）或 merge 式皆可；**squash 会丢父2 链破坏 R3——禁用 squash 合并对齐 PR**（另 xgzwlkj 仓历史上硬拒过 squash 400）。功能 PR 场景的合并策略不受本条约束。
15. **云端 NPC 合并边界（FR-006/L-081）**：云端主体创建/合并 PR 默认须 owner 人工评审；owner 在场明确指令时可执行——执行前 `get-pull` 回读 `author.is_npc` / `mergeable_state` / `reviewers` 核验，以平台数据为准不凭自述。合并命令 `commit_title`/`commit_message` 一次组装完整，**禁占位值**。
16. **R3 分发形态豁免（结构性死锁的唯一出口）**：对齐 PR 的 CI 里 R3 判「tag ∈ main 历史」读的是**未合并的镜像 main**，历史不相交必红（合并前必红 × 合并要 CI 绿 = 死锁）；活跃仓门禁对 `align/mirror-*` 源分支豁免（判据取 `CNB_PULL_REQUEST_BRANCH`——PR 事件下 `CNB_BRANCH` 是 target=main，取错变量豁免不生效）。合并后镜像 main 含 tag 提交，push 门禁天然绿。

### 五、验证与回读

17. **落地回读（L-121）**：一切「落地提交」= 写操作后 `ls-remote` 回读的远端真值；构造值（commit-tree 产物、merge 返回 sha）只是中间态，会被 rebase 重放 / 并发推送 / 平台重签改写——与回读不等即告警「以回读真值为准」。人工留痕写 SHA 前同源核验。
18. **每轮对齐后终态回读**：四仓 + GitHub 的 main **树逐字比对**（`rev-parse <sha>^{tree}`）+ R3 判定（`merge-base --is-ancestor <tag提交> <镜像main>`）+ V6（version == 各仓最新 tag）。树一致（SHA 相等或树等价）= 已对齐（分发形态合法，不要求历史同构）。
19. **签名差异豁免口径**：rebase / 原样保留 → 本地 GPG（`%G?` = U/G）；squash → 平台代签（committer `cnb <cnb@cnb.local>`，`%G?` = E）——平台已验证签名，豁免补签。

### 六、发散与竞态处置

20. **发散四分档（judgeDivergence）**：`behind`（镜像独有 0 笔）可直接对齐 / `diverged`（双向各有独有）**默认阻断**——须先树级核验「镜像 main 树 == 活跃仓历史某树」证零内容损失，才可 `--allow-diverged`（人工裁决放行并留痕）；镜像独有**实质改进**（补丁等价比对 `--cherry-pick --right-only` 后非空）必须先回灌活跃仓（cherry-pick 出 PR）再对齐，**禁止覆盖**（会静默吞掉改进）/ `ahead`（活跃仓独有 0 笔）方向异常只报告 / `unrelated` 阻断人工裁决。
21. **镜像驱动器 PR × 对齐覆盖竞态（会复发的结构性场景）**：每日巡检 crontab 四仓各自运行——镜像驱动器开的升级 PR 会因活跃仓对齐覆盖而转 `code_conflict` 且**零有效增量**。对齐前查镜像仓 open PR（align:mirror 已内置预警）；命中升级类 PR → 核验「PR head 的 package.json 依赖 == 镜像 main」证零增量 → **关闭留痕**（引对齐实证；合并零增量 PR 是噪音）。
22. **引用规范**：跨仓引用 Issue/PR/流水线一律写完整仓库路径（`xgzwlkj/web PR #88` ≠ `xgzwl/website PR #88`——同号不同物，已实际踩到）；首次引用先 `get-pull` / `get-issue` 回读存在性。
23. **留痕不删**：镜像侧 `align/mirror-*` 与 `auto/*` 历史分支为对齐留痕，不随对齐顺手删。

### 红线（对齐任务适用）

- 令牌、凭证一律脱敏，不落代码、不进日志；密钥文件仅 owner 在密钥仓 Web 端编辑。
- CNB 三镜像 main 受平台保护**禁直推**（服务端 hook 拒绝），一律 PR 通道；GitHub 直推仅限 directPush 白名单。
- 不 `--force` 覆盖双向实质独有内容（diverged 阻断的意义所在）；孤儿 tag 禁删除（覆盖推真身）。
- 禁用 squash 合并对齐 PR（破坏 R3 父链，见 §14）。
- 裸 `merge-pull` 禁止（一律 `pnpm merge:pr`，见 §12）；写/合并类命令输出必须确认成功字段，**空输出 ≠ 成功**。
- 写操作后必须回读落地真值（L-121）；平台对象引用先回读存在性。

---

## 四仓拓扑与平台指称

- CNB 四仓：`xgzwl/website`、`xgz/website/xgzwl-network`、`xgzwlkj/web`、`hfxgzwl/website`。
- GitHub 镜像：`github.com/xgzwl/xgzwl-network`（代码仓库级镜像，非新增仓；网络间歇窗口期时挂账，恢复后 `align:mirror` 一键补齐，不制造追平提交）。
- 未标注平台默认 CNB；指 GitHub 须显式「GitHub xxx」；跨仓引用 Issue/PR 写完整仓库路径，避免活跃仓轮换歧义。

## 维护约定

- 新增/调整角色：只改 `.cnb/settings.yml` 的 `roles:` 与 `.cnb.yml` 顶层事件绑定，**禁止**新建子目录配置。
- 同步官的技能与脚本（`skills/sync-upstream/`、`.ci/git-sync.yml`）随参考上游项目 i.o/sync 演进可整体替换，
  取源指向须保持本仓 slug（`${CNB_NPC_SLUG:-xgzwlkj/npc}`）。
- 人设口径变更后同步刷新 `README.md` 与 `AGENTS.md`，避免快照过期。
- 本仓为纯配置仓，不含镜像脚本；涉及镜像同步口径请到活跃仓核对 `scripts/*.mjs` 实跑证据，不凭记忆。
- 本「四仓对齐纪律」节随活跃仓对齐链路演进同步更新（2026-09-12 版基于 xgzwl/website main `116a5a3` 的实跑证据链：align-mirror selftest 53 例 / merge-pull-verified selftest 17 例 / pre-push 树级路由 19 例）。
