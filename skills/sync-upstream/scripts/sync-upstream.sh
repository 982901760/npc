#!/usr/bin/env bash
# 从参考上游项目引入代码到当前仓库。
#
# 同步模式：
#   - 铺源（空历史 + SEED_SOURCE=<参考项目地址>）：不复刻参考上游项目提交历史，只把参考项目快照
#     落成本仓库的首次提交。新仓库首次上车用它，比真实 merge 快得多。
#     SEED_SOURCE 可以一直留着：已经铺过源的仓库不会被它二次触发。
#   - 平铺 / 子目录：由 TARGET_DIR 决定，正常增量同步走真实 merge。
#
# 以下说明适用于后两种模式：
#   - 空（平铺模式）：参考项目内容铺到仓库根目录，自己的 .cnb.yml / .cnb/ / .ci/ 保留。
#     适合「本仓库就是这个参考上游项目的镜像」的场景。用真实 git merge，
#     参考上游项目完整历史保留，第二次起有共同祖先，可正常三方合并。
#   - 非空（子目录模式）：把参考项目内容 upsert 到 TARGET_DIR/ 下。
#     适合「引用方仓库还有自己的项目」的场景。每次同步是一次整体覆盖式
#     写入：参考上游项目新增/修改的文件写入，参考上游项目删除的文件同步删除，
#     TARGET_DIR 之外的文件一律不动。
#
# 两种模式都会自动处理 Git LFS：
#   - 参考上游项目用 LFS 时**自动探测**（无需用户声明），同步的是真身内容而非
#     131 字节的指针文件，并自动写入 .gitattributes 规则让真身以 LFS 入库。
#   - 只要真身还原不回来（参考项目 LFS 对象不可匿名拉取 / 环境缺 git-lfs），
#     一律**中止本次同步并报 conflict**，绝不提交指针文件冒充成功 ——
#     指针入库等于内容丢失，且下次同步会误判为「已同步」而永不重试。
#
# 私有参考项目支持（可选）：令牌来自运行环境注入（CNB_MIRROR_TOKEN / GH_TOKEN /
# 显式 UPSTREAM_TOKEN），经 UPSTREAM_TOKEN 环境变量传入。
# 令牌只在 fetch 前临时改写 upstream URL、fetch 完立即还原，绝不落代码/日志。
# 无令牌时回落匿名拉取（公开参考项目行为不变）。
#
# 结果通过 SYNC_STATUS 传给后续 Stage：
#   no-update / merged / fetch-failed / conflict / empty / skipped
set -euo pipefail

UPSTREAM_REPO="${UPSTREAM_REPO:?必须指定 UPSTREAM_REPO}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-}"
TARGET_DIR="${TARGET_DIR:-}"
# 铺源模式的参考项目地址；空历史仓库首次上车时用（浅克隆快照，不复刻历史）
SEED_SOURCE="${SEED_SOURCE:-}"
# 1（默认）= 用真实 git merge（保留参考项目历史，做三方合并）；
# 0 = 快照式落盘（整树按参考上游项目替换，不复刻历史）。
# 本地与参考上游项目没有共同祖先时会自动降级为快照式：那种情况下 git merge 只会
# 把参考项目的「修改」静默判给本地（同名文件全是 add/add 冲突 + -X ours）。
USE_REAL_MERGE="${SYNC_REAL_MERGE:-1}"
TARGET_DIR="${TARGET_DIR#/}"
TARGET_DIR="${TARGET_DIR%/}"
BOT_NAME="${SYNC_BOT_NAME:-cnb-sync-bot}"
BOT_EMAIL="${SYNC_BOT_EMAIL:-cnb-sync-bot@users.noreply.cnb.cool}"
# 私有参考项目令牌（可选）：优先显式 UPSTREAM_TOKEN；否则收编运行环境已注入的
# CNB_MIRROR_TOKEN（CNB 参考上游项目）/ GH_TOKEN（GitHub 参考上游项目）——
# 目标仓库零配置即可同步私有参考项目。
UPSTREAM_TOKEN="${UPSTREAM_TOKEN:-${CNB_MIRROR_TOKEN:-${GH_TOKEN:-}}}"
AUTH_FETCH_URL="${UPSTREAM_REPO}"
if [ -n "${UPSTREAM_TOKEN}" ]; then
  # 只改写 https 形态（含已带 user@ 的写法，一并替换为令牌身份）；
  # file:// / scp 形态不注入，行为等同匿名。
  AUTH_FETCH_URL="${UPSTREAM_REPO#ssh://}"
  case "${AUTH_FETCH_URL}" in
    https://*)
      # 剥掉已带的 userinfo（user:pass@ / token@），再统一注入令牌身份
      stripped="${AUTH_FETCH_URL#https://}"
      host_part="${stripped#*@}"          # 无 @ 时剥空为原串，即无 userinfo
      [ "${host_part}" = "${stripped}" ] || stripped="${host_part}"
      AUTH_FETCH_URL="https://x-access-token:${UPSTREAM_TOKEN}@${stripped}"
      ;;
  esac
fi

set_output() { echo "##[set-output SYNC_STATUS=$1]"; }

# LFS 处理结果：0=正常（无 LFS 或已全部还原）1=存在未能还原的指针文件
UPSTREAM_HAS_LFS=0
LFS_INCOMPLETE=0
# 本地 LFS 对象缓存（git lfs fetch 落盘的位置），用于仓库外还原
REPO_ROOT="$(pwd)"
GIT_DIR_ABS="$(cd "$(git rev-parse --git-dir 2>/dev/null || echo .git)" && pwd)"
GIT_LFS_LOCAL_CACHE="${GIT_DIR_ABS}/lfs/objects"

# SYNC_QUIET=1：成功路径不刷屏。定时任务的结果由流水线 report 阶段汇报，
# 逐行日志只会撑大流水线日志、增加后续读日志的成本。出错路径（!! 开头）不受影响。
SYNC_QUIET="${SYNC_QUIET:-0}"
log() { [ "${SYNC_QUIET}" = "1" ] || echo "[sync] $*"; }
qecho() { [ "${SYNC_QUIET}" = "1" ] || echo "$*"; }

# ---------- Git LFS 自动探测与处理 ----------
# 设计原则：用户不需要知道自己同步的参考项目是不是 LFS 项目。
# 全部探测都在本地用 git plumbing 完成，不需要额外的 LFS 服务器。

# 判断树中是否存在 LFS 指针文件（$1 = 树/提交）
# LFS 指针文件特征：体积 < 1024 字节，且内容以 Git LFS 规范的 spec 行开头。
detect_lfs_in_tree() {
  local treeish="$1"
  git ls-tree -r "${treeish}" 2>/dev/null | while IFS=$'\t' read -r meta path; do
    set -- ${meta}
    [ "${1:-}" = "100644" ] || [ "${1:-}" = "100755" ] || continue
    local sha="${3:-}"
    [ -n "${sha}" ] || continue
    # 指针文件一定很小，先用体积过滤，避免逐个 cat-file 大文件
    [ "$(git cat-file -s "${sha}" 2>/dev/null || echo 0)" -lt 1024 ] || continue
    if git cat-file -p "${sha}" 2>/dev/null | head -c 43 \
       | grep -q '^version https://git-lfs\.github\.com/spec'; then
      echo "${path}"
    fi
  done
}

# 判断单个文件是否还是 LFS 指针（content 以 spec 行开头）
is_lfs_pointer() {
  [ -f "$1" ] || return 1
  head -c 43 "$1" 2>/dev/null | grep -q '^version https://git-lfs\.github\.com/spec'
}

# 把指针文件还原成真身内容。
#   $1 = 还原发生的目录（工作区根 / 子目录 staging 目录）
#   $2 = 该目录下的相对路径列表（空格分隔；目录路径会被展开）
#
# 关键点：`git lfs` 必须在**当前 git 仓库**里执行（staging 的临时目录不是
# 仓库，在里面跑 checkout 会找不到 filter 而保留指针）。所以流程拆成两步：
#   1. 在仓库里把参考项目 LFS 对象拉到本地缓存（一次即可）
#   2. 用 git lfs checkout 落盘；若对象已缓存但文件仍是仓库外的临时副本，
#      则直接从本地 LFS 缓存里按 oid 拷贝内容
smudge_lfs_files() {
  local base="$1"; shift
  local restored=0 failed=0 f oid src
  # 注意：本函数可能被在**仓库之外**的目录（如 staging 的临时目录）调用，
  # 所以 fetch 必须显式指定仓库（-C）。否则 `git lfs fetch` 在非仓库目录
  # 里会静默失败，导致 LFS 对象永远拉不下来。
  #
  # 另：`git lfs fetch <remote> <ref>` 在只 fetch 了远端分支、本地没有
  # 对应 ref 时会静默「0 objects found」，所以用 --all，对任意 ref 形态都可靠。
  # 同时显式清掉 GIT_LFS_SKIP_SMUDGE —— 该变量会连带禁止 LFS 对象下载。
  env -u GIT_LFS_SKIP_SMUDGE git -C "${REPO_ROOT}" lfs fetch --all upstream >/dev/null 2>&1 || true
  for f in "$@"; do
    local target="${base}/${f}"
    [ -f "${target}" ] || continue
    is_lfs_pointer "${target}" || continue
    # 优先走 git lfs checkout（文件在仓库内时有效）
    git lfs checkout -- "${target}" >/dev/null 2>&1 || true
    # 兜底：直接从本地 LFS 缓存按 oid 取真身（文件在仓库外时走这条）
    if is_lfs_pointer "${target}"; then
      oid="$(sed -n 's/^oid sha256://p' "${target}" | head -1)"
      src="${GIT_LFS_LOCAL_CACHE}/${oid:0:2}/${oid:2:2}/${oid}"
      if [ -n "${oid}" ] && [ -f "${src}" ]; then
        chmod u+w "${target}" 2>/dev/null || true
        cp "${src}" "${target}"
      fi
    fi
    if is_lfs_pointer "${target}"; then
      failed=$((failed + 1))
      echo "   !! LFS 内容还原失败：${f}"
    else
      restored=$((restored + 1))
    fi
  done
  echo "${restored}:${failed}"
}

# 确保仓库启用 LFS 过滤规则：没有 .gitattributes 规则的话，LFS 真身
# 会被当成普通大文件塞进 git 对象库，仓库体积会爆。
ensure_lfs_tracked() {
  local path="$1"
  git lfs track -- "${path}" >/dev/null 2>&1 || true
}

qecho "== 参考上游项目：${UPSTREAM_REPO} =="
qecho "== 模式：$([ -n "$TARGET_DIR" ] && echo "子目录 ${TARGET_DIR}" || echo "平铺（仓库根）") =="
qecho "== 当前分支：${CNB_BRANCH:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)} =="

git config user.name  "${BOT_NAME}"
git config user.email "${BOT_EMAIL}"

# ---------- 拉取参考上游项目（只读） ----------
git remote remove upstream 2>/dev/null || true
git remote add upstream "${UPSTREAM_REPO}"
git remote set-url --push upstream "no-push://disabled"   # 杜绝误推回参考上游项目

log "拉取参考上游项目 ..."
if [ -n "${UPSTREAM_TOKEN}" ]; then
  # 只给 fetch 走带凭证的 URL；auth 串绝不进本地引用、绝不被打印
  git remote set-url upstream "${AUTH_FETCH_URL}"
fi
# 注意：这里必须显式 fetch 目标分支，且后续一律用 FETCH_HEAD 作为权威快照。
# 只用 upstream/<branch> 有风险：参考上游项目若切换了默认分支或 rebase 掉了旧历史，
# 本地残留的 remote-tracking ref 会指向陈旧提交，导致同步结果悄悄偏旧。
if ! git fetch --no-tags --prune upstream ${UPSTREAM_BRANCH:+"$UPSTREAM_BRANCH"}; then
  echo "!! 参考项目拉取失败：${UPSTREAM_REPO}（网络不通 / 仓库不存在 / 私有仓库无权限）"
  # 失败分支同样还原匿名 URL：无论 fetch 成败，凭证 URL 都不残留在 .git/config
  if [ -n "${UPSTREAM_TOKEN}" ]; then
    git remote set-url upstream "${UPSTREAM_REPO}"
  fi
  set_output fetch-failed
  exit 0
fi
if [ -n "${UPSTREAM_TOKEN}" ]; then
  # fetch 完成立即还原匿名 URL：后续 remote show 等命令与提交信息都不带凭证
  git remote set-url upstream "${UPSTREAM_REPO}"
fi

# 解析参考项目默认分支与最新 commit
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-$(git remote show upstream 2>/dev/null | sed -n 's/.*HEAD branch: //p' | head -1)}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
TARGET="upstream/${UPSTREAM_BRANCH}"
if ! git rev-parse --verify -q "${TARGET}" >/dev/null; then
  echo "!! 参考上游项目不存在分支 ${UPSTREAM_BRANCH}"
  set_output fetch-failed
  exit 0
fi
# FETCH_HEAD 是本次 fetch 的真实结果，优先级最高
if git rev-parse --verify -q FETCH_HEAD >/dev/null \
   && git merge-base --is-ancestor FETCH_HEAD "${TARGET}" 2>/dev/null; then
  UPSTREAM_SHA="$(git rev-parse FETCH_HEAD)"
  git update-ref "refs/remotes/upstream/${UPSTREAM_BRANCH}" "${UPSTREAM_SHA}"
else
  UPSTREAM_SHA="$(git rev-parse "${TARGET}")"
fi
UPSTREAM_SUBJECT="$(git log -1 --format=%s "${TARGET}")"
log "参考项目分支：${UPSTREAM_BRANCH} @ ${UPSTREAM_SHA:0:8}  (${UPSTREAM_SUBJECT})"

# ---------- 自动探测参考项目是否使用 Git LFS ----------
# 不需要用户声明，也不依赖远端 LFS 服务器的 capabilities 接口：
# 直接看参考上游项目树里有没有 LFS 指针文件即可。
UPSTREAM_LFS_FILES="$(detect_lfs_in_tree "${TARGET}" || true)"
if [ -n "${UPSTREAM_LFS_FILES}" ]; then
  UPSTREAM_HAS_LFS=1
  LFS_COUNT="$(printf '%s\n' "${UPSTREAM_LFS_FILES}" | grep -c . || true)"
  log "检测到参考项目使用 LFS：${LFS_COUNT} 个文件"
else
  UPSTREAM_HAS_LFS=0
  log "参考上游项目未使用 LFS（或无可同步的 LFS 文件）"
fi

# ---------- 校验目标目录 ----------
if [ -n "${TARGET_DIR}" ]; then
  case "${TARGET_DIR}" in
    .cnb|.cnb/*|.ci|.ci/*|.git|.git/*|.cnb.yml)
      echo "!! 目标目录 ${TARGET_DIR} 与平台配置目录冲突，拒绝同步。"
      set_output conflict
      exit 1
      ;;
  esac
fi

# 上次已同步到的参考上游项目提交（两个来源，按可靠性排序）：
#
# 1) HEAD 能不能直接追到参考上游项目提交 —— 用 merge-base 判定。这是最可靠的依据：
#    只要参考上游项目提交真在本地历史里，三方合并自然就正确，根本不依赖任何标记。
#    早先只认标记，结果踩了坑：runner 检出时先 fetch 了 origin，把「同名但无关」
#    的参考项目历史带进了本地对象库；标记一旦没命中（历史被参考上游项目强推重写、标记被
#    人工改动），合并就退化成 add/add，于是「删除」类改动会被 -X ours 静默吃掉。
# 2) 同步提交里的 Upstream-Sync 标记 —— 参考上游项目强推历史后（本地已没有共同祖先）
#    靠它判断「是否真的换了 commit」，避免每次都被判成有更新而空跑。
BASE_SHA=""
# 本地历史里是否真的含参考上游项目提交（决定能否做三方合并）
HAS_COMMON_ANCESTOR=0
if git rev-parse --verify -q HEAD >/dev/null 2>&1; then
  MB="$(git merge-base HEAD "${TARGET}" 2>/dev/null || true)"
  if [ -n "${MB}" ]; then
    BASE_SHA="${MB}"
    HAS_COMMON_ANCESTOR=1
    log "本地历史中包含参考上游项目提交，按增量合并。"
  else
    BASE_SHA="$(set +eo pipefail; git log --format=%B -n 200 HEAD 2>/dev/null \
      | sed -n 's/^Upstream-Sync: //p' | head -1)" || BASE_SHA=""
    git cat-file -e "${BASE_SHA:-none}^{commit}" 2>/dev/null || BASE_SHA=""
  fi
fi
log "上次同步至：${BASE_SHA:0:8}"

# 只有当本地历史里确实有参考上游项目提交时，标记才能当「已同步」用：
# 标记来自铺源/快照式提交，此时本地并没有参考上游项目那个 commit，不能据此下结论。
if [ "${HAS_COMMON_ANCESTOR}" = "1" ] && [ -n "${BASE_SHA}" ] && [ "${BASE_SHA}" = "${UPSTREAM_SHA}" ]; then
  log "参考项目无更新，忽略本次同步。"
  set_output no-update
  exit 0
fi

# =========================================================
# 铺源模式：空仓库的首次上车
# 只在「给了 SEED_SOURCE + 本地还没有任何提交」时生效，
# 所以流水线里一直留着 SEED_SOURCE 也不会影响后续增量同步。
# =========================================================
if [ -n "${SEED_SOURCE}" ] && ! git rev-parse --verify -q HEAD >/dev/null 2>&1; then
  qecho "== 铺源模式：落首个提交（不复刻参考项目历史） =="
  qecho "== 铺源参考上游项目：${SEED_SOURCE} =="
  git remote remove seed 2>/dev/null || true
  git remote add seed "${SEED_SOURCE}"
  git remote set-url --push seed "no-push://disabled"
  # 浅克隆：不拉参考项目历史，只取快照。大仓库能省下可观的下载量。
  if ! git fetch --depth 1 --no-tags seed ${UPSTREAM_BRANCH:+"$UPSTREAM_BRANCH"}; then
    echo "!! 铺源拉取失败：${SEED_SOURCE}（网络不通 / 仓库不存在 / 私有仓库无权限）"
    set_output fetch-failed
    exit 0
  fi
  SEEDED_SHA="$(git rev-parse FETCH_HEAD)"

  TMP="$(mktemp -d)"
  trap 'rm -rf "${TMP}"' EXIT
  # 同平铺模式：用 SKIP_SMUDGE 稳定导出指针文件，真身交给 smudge_lfs_files
  GIT_LFS_SKIP_SMUDGE=1 git archive "${SEEDED_SHA}" | tar -x -C "${TMP}"
  for p in .cnb.yml .cnb .ci; do rm -rf "${TMP:?}/${p}"; done

  SEED_LFS="$(detect_lfs_in_tree "${SEEDED_SHA}" || true)"
  if [ -n "${SEED_LFS}" ]; then
    UPSTREAM_HAS_LFS=1
    log "还原 LFS 真身内容 ..."
    OLD_PWD="$(pwd)"
    cd "${TMP}"
    LFS_RESULT="$(smudge_lfs_files "${TMP}" ${SEED_LFS} | tail -1)"
    cd "${OLD_PWD}"
    log "LFS 还原：成功 ${LFS_RESULT%%:*} 个，失败 ${LFS_RESULT##*:} 个"
    [ "${LFS_RESULT##*:}" = "0" ] || LFS_INCOMPLETE=1
  fi
  if [ "${LFS_INCOMPLETE}" = "1" ]; then
    echo "!! 有 LFS 文件未能还原为真身内容，已中止本次同步（不会提交指针文件）。"
    echo "   可能原因：参考项目 LFS 对象不可公开拉取 / 网络受限 / 目标环境缺 git-lfs。"
    set_output conflict
    exit 1
  fi

  cp -a "${TMP}/." .
  [ "${UPSTREAM_HAS_LFS}" = "1" ] && ensure_lfs_tracked "*"
  git add -A
  if git diff --cached --quiet; then
    log "参考项目快照为空，无内容可提交。"
    set_output empty
    exit 0
  fi
  # 父提交必须是「铺源前的工作区提交」（CNB_BRANCH 上有意义的那个），
  # 不能是 runner 检出时带进来的 FETCH_HEAD —— 否则会把参考项目历史挂成本地祖先，
  # 既污染历史，也让下次同步误以为有共同祖先。
  PRE_HEAD="$(git rev-parse --verify -q HEAD || true)"
  # 空历史仓库这里没有 HEAD，不需要也不该动索引
  if [ -n "${PRE_HEAD}" ] && [ "${PRE_HEAD}" != "${SEEDED_SHA}" ]; then
    git reset -q --soft "${PRE_HEAD}"
  fi
  git commit -q \
    -m "chore: 初始化参考上游项目 ${SEEDED_SHA:0:8}（铺源）" \
    -m "参考上游项目仓库：${SEED_SOURCE}" \
    -m "参考项目分支：${UPSTREAM_BRANCH}" \
    -m "Upstream-Sync: ${SEEDED_SHA}"
  [ "${SYNC_QUIET}" = "1" ] || git --no-pager show --stat --oneline -1 HEAD | head -30
  echo "##[set-output SYNC_LFS=${UPSTREAM_HAS_LFS}]"
  set_output merged
  exit 0
fi

# =========================================================
# 无共同祖先的历史（多为首版把参考上游项目写成单个提交、后来才换用真实 merge 的仓库）
# 不能走 git merge：无共同祖先时同名文件全是 add/add 冲突，-X ours 会把
# 参考项目的**修改**一律判给本地 —— 参考上游项目改了、本地还是旧内容，合并却报成功。
# 这里降级为「快照式」：按参考项目快照整树替换（受保留路径除外），与铺源语义一致。
#
# 只处理「本地与参考上游项目各有一批提交、但从未真正合过」的历史（老镜像大多如此）。
# 空历史（本地还没有提交）不在这里处理 —— 那种情况交给铺源模式，走浅克隆更快。
# =========================================================
if [ -z "${TARGET_DIR}" ] && [ "${HAS_COMMON_ANCESTOR}" = "0" ] \
   && [ -n "$(git rev-parse --verify -q HEAD || true)" ] \
   && [ "$(git rev-parse HEAD)" != "$(git rev-parse --verify -q "${TARGET}" || echo none)" ]; then
  log "本地历史与参考上游项目没有共同祖先，本次按快照式同步（不做三方合并）。"
  USE_REAL_MERGE=0
fi

# ---------- 兜底：工作区有未提交改动先重置 ----------
if git rev-parse --verify -q HEAD >/dev/null 2>&1 \
   && [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  log "工作区存在未提交改动，重置为当前提交。"
  git reset --hard HEAD
fi

# =========================================================
# 模式一：平铺 —— 用 git merge 保留参考上游项目完整历史
# 仅当 TARGET_DIR 为空时进入；非空则落到下面的「模式二：子目录」
# =========================================================
if [ -z "${TARGET_DIR}" ]; then

# 本仓库自己的平台配置，任何时候都不许被参考上游项目覆盖
PROTECTED_PATHS=(".cnb.yml" ".cnb" ".ci")

# 把参考项目的文件从索引里摘掉，并让工作区回到「本地版本」。
# 注意顺序：先 reset 索引（撤销 merge 暂存的 add/add），再 checkout/clean 工作区。
restore_protected() {
  for p in "${PROTECTED_PATHS[@]}"; do
    git reset -q HEAD -- "${p}" 2>/dev/null || true
    if git rev-parse --verify -q "HEAD:${p}" >/dev/null 2>&1; then
      # 本地有该路径：整棵子树回滚到本地版本，参考项目的改动一律丢弃
      git checkout HEAD -- "${p}" 2>/dev/null || true
      if [ -d "${p}" ]; then
        git clean -fdq -- "${p}" 2>/dev/null || true
      fi
    else
      # 本地本来就没有这个路径，参考上游项目带进来的一律丢掉
      rm -rf "${p}"
    fi
  done
}

HAS_HEAD=0
git rev-parse --verify -q HEAD >/dev/null 2>&1 && HAS_HEAD=1

if [ "${HAS_HEAD}" = "0" ]; then
  # ---- 空仓库：没有历史可合并，直接把参考项目快照落成首个提交 ----
  log "空历史仓库，按首次同步处理（落首个提交）。"
  TMP="$(mktemp -d)"
  trap 'rm -rf "${TMP}"' EXIT
  BACKUP="$(mktemp -d)"
  for p in "${PROTECTED_PATHS[@]}"; do
    [ -e "${p}" ] && cp -a "${p}" "${BACKUP}/"
  done
  # 用 GIT_LFS_SKIP_SMUDGE=1 导出：让 archive 稳定产出「指针文件」，
  # 避免 git-lfs filter 在归档中途失败（Unexpected EOF）把整个同步炸掉。
  # 真身内容统一交给下面的 smudge_lfs_files 还原。
  GIT_LFS_SKIP_SMUDGE=1 git archive "${TARGET}" | tar -x -C "${TMP}"
  for p in "${PROTECTED_PATHS[@]}"; do rm -rf "${TMP:?}/${p}"; done

  # git archive 在 GIT_LFS_SKIP_SMUDGE=1 或未配置 filter 时，会把 LFS
  # 指针文件（131 字节）原样写盘 —— 真身内容静默丢失。这里统一从本地
  # LFS 缓存还原真身；还原不到就明确告警，绝不假装成功。
  if [ "${UPSTREAM_HAS_LFS}" = "1" ]; then
    log "还原 LFS 真身内容 ..."
    OLD_PWD="$(pwd)"
    cd "${TMP}"
    LFS_RESULT="$(smudge_lfs_files "${TMP}" ${UPSTREAM_LFS_FILES} | tail -1)"
    cd "${OLD_PWD}"
    LFS_OK="${LFS_RESULT%%:*}"; LFS_BAD="${LFS_RESULT##*:}"
    log "LFS 还原：成功 ${LFS_OK} 个，失败 ${LFS_BAD} 个"
    if [ "${LFS_BAD}" != "0" ]; then
      LFS_INCOMPLETE=1
    fi
  fi

  # LFS 真身没拿到就中止，绝不能把指针文件当「同步成功」提交（内容丢失）
  if [ "${LFS_INCOMPLETE}" = "1" ]; then
    echo "!! 有 LFS 文件未能还原为真身内容，已中止本次同步（不会提交指针文件）。"
    echo "   可能原因：参考项目 LFS 对象不可公开拉取 / 网络受限 / 目标环境缺 git-lfs。"
    set_output conflict
    exit 1
  fi

  cp -a "${TMP}/." .
  for p in "${PROTECTED_PATHS[@]}"; do
    if [ -e "${BACKUP}/${p}" ]; then rm -rf "${p}"; cp -a "${BACKUP}/${p}" "${p}"; fi
  done
  rm -rf "${BACKUP}"

  # 让 LFS 真身以 LFS 方式入库（否则会被当普通大文件，仓库体积会爆）
  if [ "${UPSTREAM_HAS_LFS}" = "1" ] && [ "${LFS_INCOMPLETE}" = "0" ]; then
    ensure_lfs_tracked "*"
  fi

  git add -A

  # 空历史仓库必须自己落首个提交，否则工作区只有未跟踪文件、HEAD 依旧是 unborn
  if git diff --cached --quiet; then
    log "参考项目快照为空，无内容可提交。"
    set_output empty
    exit 0
  fi
  git commit -q \
    -m "chore: 跟进参考上游项目 ${UPSTREAM_SHA:0:8}（首次）" \
    -m "参考上游项目仓库：${UPSTREAM_REPO}" \
    -m "参考项目分支：${UPSTREAM_BRANCH}" \
    -m "参考上游项目最新提交：${UPSTREAM_SUBJECT}" \
    -m "Upstream-Sync: ${UPSTREAM_SHA}"
fi   # end 空历史分支（模式一：平铺首次）

# =========================================================
# 模式一之二：快照式 —— 本地与参考上游项目没有共同祖先时按整树替换
# 不能走 git merge：无共同祖先时同名文件全是 add/add 冲突，
# -X ours 会把参考项目的「修改」静默判给本地（本地还是旧内容，却报成功）。
# 多为「首版把参考上游项目写成单个提交、后来才换用真实 merge」的仓库。
# =========================================================
if [ -z "${TARGET_DIR}" ] && [ "${USE_REAL_MERGE}" = "0" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "${TMP}"' EXIT
  GIT_LFS_SKIP_SMUDGE=1 git archive "${TARGET}" | tar -x -C "${TMP}"
  for p in "${PROTECTED_PATHS[@]}"; do rm -rf "${TMP:?}/${p}"; done

  if [ "${UPSTREAM_HAS_LFS}" = "1" ]; then
    log "还原 LFS 真身内容 ..."
    OLD_PWD="$(pwd)"
    cd "${TMP}"
    LFS_RESULT="$(smudge_lfs_files "${TMP}" ${UPSTREAM_LFS_FILES} | tail -1)"
    cd "${OLD_PWD}"
    log "LFS 还原：成功 ${LFS_RESULT%%:*} 个，失败 ${LFS_RESULT##*:} 个"
    [ "${LFS_RESULT##*:}" = "0" ] || LFS_INCOMPLETE=1
  fi
  if [ "${LFS_INCOMPLETE}" = "1" ]; then
    echo "!! 有 LFS 文件未能还原为真身内容，已中止本次同步（不会提交指针文件）。"
    echo "   可能原因：参考项目 LFS 对象不可公开拉取 / 网络受限 / 目标环境缺 git-lfs。"
    set_output conflict
    exit 1
  fi

  # 整树按参考项目快照替换：先把索引清空（受保留路径摘出来），再把快照落盘。
  # 这样参考上游项目删除的文件也会真的消失，不会残留成「本地文件」。
  BACKUP="$(mktemp -d)"
  for p in "${PROTECTED_PATHS[@]}"; do [ -e "${p}" ] && cp -a "${p}" "${BACKUP}/"; done
  git rm -r -q --cached --ignore-unmatch . >/dev/null 2>&1 || true
  find . -mindepth 1 -maxdepth 1 -not -name .git -exec rm -rf {} +
  cp -a "${TMP}/." .
  for p in "${PROTECTED_PATHS[@]}"; do
    if [ -e "${BACKUP}/${p}" ]; then rm -rf "${p}"; cp -a "${BACKUP}/${p}" "${p}"; fi
  done
  rm -rf "${BACKUP}"
  [ "${UPSTREAM_HAS_LFS}" = "1" ] && ensure_lfs_tracked "*"

  git add -A
  # 用全工作区状态判断有无变化：刚从索引里摘过文件，diff --cached 会误报
  if [ -z "$(git status --porcelain)" ]; then
    log "参考项目内容与本地一致，无需变更。"
    set_output no-update
    exit 0
  fi
  git commit -q \
    -m "chore: 跟进参考上游项目 ${UPSTREAM_SHA:0:8}" \
    -m "参考上游项目仓库：${UPSTREAM_REPO}" \
    -m "参考项目分支：${UPSTREAM_BRANCH}" \
    -m "参考上游项目最新提交：${UPSTREAM_SUBJECT}" \
    -m "Upstream-Sync: ${UPSTREAM_SHA}"
fi   # end 快照式

# ---- 真实合并：保留参考项目历史 ----
if [ "${USE_REAL_MERGE}" = "1" ]; then
  # ---- 已有共同祖先：真实合并，保留参考项目历史 ----
  #
  # 三个关键点，缺一不可：
  #   1. 必须**真实 merge**（不加 --squash）。squash 不建立共同祖先，
  #      下次合并时所有同名文件都退化成 add/add，git 无从三方合并。
  #   2. 必须带 -X ours：本地对同一文件有并发改动时判给本地（本地不该被参考上游项目
  #      覆盖掉自己的提交）。**前提是已有共同祖先** —— 无共同祖先的仓库
  #      不会走到这里（走快照式），否则 -X ours 会把参考项目的「修改」也一并吃掉。
  # --no-commit：先只做合并、不进提交，便于检查结果并写入同步标记
  MERGE_OPTS="--no-edit --no-commit -X ours"

  # 记录合并前的 HEAD，用于判定「合并是否带来实际变更」
  PRE_MERGE_HEAD="$(git rev-parse HEAD 2>/dev/null || echo '')"

  if ! git merge ${MERGE_OPTS} "${TARGET}" >/dev/null 2>&1; then
    echo "---- 冲突文件 ----"
    git diff --name-only --diff-filter=U || true
    git reset -q --hard HEAD >/dev/null 2>&1 || true
    git clean -fdq >/dev/null 2>&1 || true
    echo "!! 合并冲突，已回滚到同步前状态，需人工介入。"
    echo "   本地排查：git fetch ${UPSTREAM_REPO} ${UPSTREAM_BRANCH} && git merge upstream/${UPSTREAM_BRANCH}"
    set_output conflict
    exit 1
  fi

  # 合并成功后清理平台配置：
  # -X ours 已保证同名冲突判给本地（本地 .cnb.yml 不被改）；
  # 但参考上游项目**新增**的 .cnb/* 文件不构成冲突，会被正常合并进来，需在此剔除。
  #
  # 注意：这里**不能**再跑 git add -A —— 那会把 merge 暂存的内容整体清掉，
  # 导致后续 diff 全空、白白误报 no-update。restore_protected 内部已经
  # 只针对 .cnb.yml / .cnb / .ci 做 reset，其余暂存区保持 merge 的结果。
  restore_protected

  # 真实 merge 会把参考上游项目 blob 写进索引与工作区。若参考上游项目用 LFS，工作区里
  # 拿到的同样可能是指针文件（smudge filter 未启用时），需要还原真身。
  # 这里直接作用于工作区根目录（"."），不是 staging 临时目录。
  if [ "${UPSTREAM_HAS_LFS}" = "1" ]; then
    LFS_RESULT="$(smudge_lfs_files "." ${UPSTREAM_LFS_FILES} | tail -1)"
    LFS_OK="${LFS_RESULT%%:*}"; LFS_BAD="${LFS_RESULT##*:}"
    log "LFS 还原：成功 ${LFS_OK} 个，失败 ${LFS_BAD} 个"
    if [ "${LFS_BAD}" != "0" ]; then
      LFS_INCOMPLETE=1
      echo "!! 有 LFS 文件未能还原为真身内容，已中止本次同步。"
      git merge --abort >/dev/null 2>&1 || git reset -q --hard HEAD >/dev/null 2>&1 || true
      git clean -fdq >/dev/null 2>&1 || true
      echo "   可能原因：参考项目 LFS 对象不可公开拉取 / 网络受限 / 目标环境缺 git-lfs。"
      set_output conflict
      exit 1
    fi
  fi

  # "Already up to date" 时 git 不进入合并状态，MERGE_HEAD 不存在
  if ! git rev-parse --verify -q MERGE_HEAD >/dev/null 2>&1; then
    log "参考上游项目无新内容可合并（Already up to date），视为无更新。"
    set_output no-update
    exit 0
  fi

  # 合并结果相对合并前若无任何净变化，说明参考上游项目这次带来的改动全部被
  # 「本地版本」吃掉了（-X ours + 本地有并发提交）。这有两种可能：
  #   a) 参考上游项目只改了我们保护或不采纳的文件 → 确实无需动作
  #   b) 本地对同一文件有并发提交，参考项目改动被静默丢弃 → 必须让人知道
  # 用 upstream 相对 BASE_SHA 的改动文件与本地改动文件求交集来区分。
  if git diff --quiet "${PRE_MERGE_HEAD}" 2>/dev/null \
     && [ -z "$(git diff --name-only --diff-filter=U)" ]; then
    git merge --abort >/dev/null 2>&1 || git reset -q --hard "${PRE_MERGE_HEAD}" >/dev/null 2>&1 || true
    UPSTREAM_CHANGED=""
    if [ -n "${BASE_SHA}" ]; then
      UPSTREAM_CHANGED="$(git diff --name-only "${BASE_SHA}" "${TARGET}" 2>/dev/null || true)"
    fi
    LOCAL_CHANGED=""
    if [ -n "${BASE_SHA}" ]; then
      LOCAL_CHANGED="$(git diff --name-only "${BASE_SHA}" "${PRE_MERGE_HEAD}" 2>/dev/null || true)"
    fi
    OVERLAP="$(printf '%s\n' "${UPSTREAM_CHANGED}" | grep -Fx -f <(printf '%s\n' "${LOCAL_CHANGED}") 2>/dev/null | grep -v '^$' || true)"
    if [ -n "${OVERLAP}" ]; then
      echo "!! 参考项目改动的以下文件与本地并发改动重叠，本地版本优先、参考项目改动被跳过："
      printf '   - %s\n' ${OVERLAP}
      echo "   如需采纳参考项目版本，请先撤销本地对这些文件的改动后重跑。"
      set_output skipped
      exit 0
    fi
    log "参考上游项目本次只改动被保留/不采纳的文件，视为无更新。"
    set_output no-update
    exit 0
  fi

  git commit -q --no-edit \
    -m "chore: 跟进参考上游项目 ${UPSTREAM_SHA:0:8}" \
    -m "参考上游项目仓库：${UPSTREAM_REPO}" \
    -m "参考项目分支：${UPSTREAM_BRANCH}" \
    -m "参考上游项目最新提交：${UPSTREAM_SUBJECT}" \
    -m "Upstream-Sync: ${UPSTREAM_SHA}"
fi   # end 真实合并路径

log "同步完成。"
echo "##[set-output SYNC_LFS=${UPSTREAM_HAS_LFS}]"
[ "${LFS_INCOMPLETE}" = "1" ] && echo "##[set-output SYNC_LFS_INCOMPLETE=1]"
[ "${SYNC_QUIET}" = "1" ] || git --no-pager show --stat --oneline -1 HEAD | head -30
set_output merged
exit 0
fi   # end 模式一（TARGET_DIR 为空）

# =========================================================
# 模式二：子目录 —— 把参考项目内容 upsert 到 TARGET_DIR/
# =========================================================
log "将参考项目快照导出到 ${TARGET_DIR}/"

TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# 导出参考上游项目该 commit 的完整文件树（不含 .git）
# 同平铺模式：用 SKIP_SMUDGE 稳定产出指针文件，真身由 smudge_lfs_files 还原
GIT_LFS_SKIP_SMUDGE=1 git archive "${TARGET}" | tar -x -C "${TMP}"

# 同平铺模式：archive 落盘的可能是指针文件，统一还原真身内容
if [ "${UPSTREAM_HAS_LFS}" = "1" ]; then
  log "还原 LFS 真身内容 ..."
  OLD_PWD="$(pwd)"
  cd "${TMP}"
  LFS_RESULT="$(smudge_lfs_files "${TMP}" ${UPSTREAM_LFS_FILES} | tail -1)"
  cd "${OLD_PWD}"
  LFS_OK="${LFS_RESULT%%:*}"; LFS_BAD="${LFS_RESULT##*:}"
  log "LFS 还原：成功 ${LFS_OK} 个，失败 ${LFS_BAD} 个"
  if [ "${LFS_BAD}" != "0" ]; then
    LFS_INCOMPLETE=1
  fi
fi

# LFS 真身没拿到就中止，理由同平铺模式：绝不写入指针文件冒充同步成功
if [ "${LFS_INCOMPLETE}" = "1" ]; then
  echo "!! 有 LFS 文件未能还原为真身内容，已中止本次同步（不会写入指针文件）。"
  echo "   可能原因：参考项目 LFS 对象不可公开拉取 / 网络受限 / 目标环境缺 git-lfs。"
  set_output conflict
  exit 1
fi

# 参考上游项目自带的平台配置一律不带进来，避免污染本仓库
rm -rf "${TMP}/.cnb" "${TMP}/.cnb.yml" "${TMP}/.ci" "${TMP}/.github/workflows" 2>/dev/null || true

if [ -z "$(ls -A "${TMP}")" ]; then
  log "参考项目内容为空（导出后无文件），忽略。"
  set_output empty
  exit 0
fi

mkdir -p "${TARGET_DIR}"
# 整体替换目标目录：先清空再写入，保证参考上游项目删除的文件同步删除
find "${TARGET_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
cp -a "${TMP}/." "${TARGET_DIR}/"
# 若参考上游项目根目录有一个同名目录，做一次摊平，避免 TARGET_DIR/TARGET_DIR 套娃
if [ -d "${TARGET_DIR}/$(basename "${TARGET_DIR}")" ] \
   && [ "$(ls -A "${TARGET_DIR}" | wc -l)" = "1" ]; then
  log "检测到参考上游项目内层同名目录，摊平一层。"
  mv "${TARGET_DIR}/$(basename "${TARGET_DIR}")"/* "${TARGET_DIR}/" 2>/dev/null || true
  rm -rf "${TARGET_DIR:?}/$(basename "${TARGET_DIR}")"
fi

# 让 LFS 真身以 LFS 方式入库，而不是被当成普通大文件（否则仓库体积会爆）
if [ "${UPSTREAM_HAS_LFS}" = "1" ] && [ "${LFS_INCOMPLETE}" = "0" ]; then
  ensure_lfs_tracked "${TARGET_DIR}/**"
fi

git add -A -- "${TARGET_DIR}"
if git diff --cached --quiet; then
  log "目标目录内容与参考上游项目一致，无需变更。"
  set_output no-update
  exit 0
fi

git commit --no-edit \
  -m "chore: 跟进参考上游项目 ${UPSTREAM_SHA:0:8} → ${TARGET_DIR}/" \
  -m "参考上游项目仓库：${UPSTREAM_REPO}" \
  -m "参考项目分支：${UPSTREAM_BRANCH}" \
  -m "参考上游项目最新提交：${UPSTREAM_SUBJECT}" \
  -m "Upstream-Sync: ${UPSTREAM_SHA}" >/dev/null

log "已写入 ${TARGET_DIR}/"
echo "##[set-output SYNC_LFS=${UPSTREAM_HAS_LFS}]"
[ "${LFS_INCOMPLETE}" = "1" ] && echo "##[set-output SYNC_LFS_INCOMPLETE=1]"
git --no-pager show --stat --oneline -1 HEAD | head -30
set_output merged
