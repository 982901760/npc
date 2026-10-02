#!/usr/bin/env bash
#
# 将参考上游项目引入到当前仓库。
#
# 设计要点：
#   - 参考上游项目优先：参考项目内容覆盖到当前仓库工作树。
#   - 保护本地：只保护平台配置文件 .cnb.yml / .cnb/ / .ci/，其余内容按参考上游项目覆盖。
#     **本脚本自身留在仓库里**（它由同步官初装那次提交进来）：如果它已被跟踪就
#     保持跟踪；否则（本脚本自己同步进来的）从索引摘掉、工作树文件保留 —— 总之
#     每次同步结束后它都要在工作树里，下一次定时任务才拿得到它。
#   - 有更新才提交：无差异则直接退出，不产生空提交。
#
# 依赖环境变量：
#   UPSTREAM_URL   参考上游项目地址（**必填**，没有默认值）
#
#                  这里**故意不设默认地址**。早先它默认成了某个示例仓库，
#                  结果是：变量漏传时不报错，而是**默默去同步另一个仓库**，
#                  把用户自己的仓库覆盖成别的内容 —— 而且看起来「同步成功」。
#   SYNC_DIR       同步到本仓库的子目录；留空表示全量平铺到根目录
#   TARGET_BRANCH  推送目标分支。**不传就不推**（见下）。
#   SEED_SOURCE    仅用于空仓库首次上车：非空且本仓库还没有提交时，用浅克隆
#                  直接把参考项目快照落成首个提交（不复刻参考项目历史）。仓库有提交后忽略。
#   SYNC_QUIET     置 1 时成功路径不刷屏（定时任务用；结果看流水线 report 阶段）
#   SYNC_NO_PUSH   置 1 时只提交不推送。定时任务跑在临时分支上时用它，
#                  推送与开 PR 交给流水线后续阶段（这样同一个脚本既能直推、
#                  也能走「临时分支 + 自动合并 PR」）。
#   UPSTREAM_TOKEN 私有参考项目拉取令牌（可选）。本脚本自身不引入任何密钥引用，
#                  令牌由引用方按需注入环境变量；没有则匿名拉取（公开参考项目）。
#
# Git LFS 参考上游项目：自动探测、自动还原真身，用户无需声明（与采集版脚本同一口径）。
#   参考上游项目树里检出 LFS 指针即判定为 LFS 项目；真身拉不回来时**中止**（status=conflict），
#   绝不把 131 字节的指针文件当「同步成功」落进首个提交。
#
set -euo pipefail

UPSTREAM_URL="${UPSTREAM_URL:?必须指定 UPSTREAM_URL（这是要同步的参考上游项目地址，没有默认值）}"
SYNC_DIR="${SYNC_DIR:-}"
SEED_SOURCE="${SEED_SOURCE:-}"
SYNC_QUIET="${SYNC_QUIET:-0}"
# 私有参考项目令牌（可选）：只用于临时改写拉取 URL，绝不落代码/日志
UPSTREAM_TOKEN="${UPSTREAM_TOKEN:-}"
AUTH_CLONE_URL="${UPSTREAM_URL}"
if [ -n "${UPSTREAM_TOKEN}" ]; then
  # 只改写 https 形态（含已带 user@ 的写法，一并替换为令牌身份）；
  # file:// / scp 形态不注入，行为等同匿名
  AUTH_CLONE_URL="${UPSTREAM_URL#ssh://}"
  case "${AUTH_CLONE_URL}" in
    https://*)
      # 剥掉已带的 userinfo（user:pass@ / token@），再统一注入令牌身份
      stripped="${AUTH_CLONE_URL#https://}"
      host_part="${stripped#*@}"
      [ "${host_part}" = "${stripped}" ] || stripped="${host_part}"
      AUTH_CLONE_URL="https://x-access-token:${UPSTREAM_TOKEN}@${stripped}"
      ;;
  esac
fi

# 定时任务无人值守：成功路径没必要刷屏（会被流水线日志原样留存）。
# 出错路径用 err，不受静默影响。
log() { [ "${SYNC_QUIET}" = "1" ] || echo "$*"; }
err() { echo "$*" >&2; }

# ---------- Git LFS 自动探测与处理 ----------
# 与采集版（scripts/sync-upstream.sh）同一口径：探测 → 拉真身 → 还原不到就中止。
# 差异只在「参考上游项目怎么进本地」：目标仓库里没有 upstream remote，参考上游项目经
# `git fetch <URL|路径> HEAD` 直接进当前仓库对象库（SEED_SOURCE 路径），
# 或先浅克隆到临时目录（clone 路径），两处都要探测与还原。
UPSTREAM_HAS_LFS=0
LFS_INCOMPLETE=0
# 本地 LFS 对象缓存（git lfs fetch 落盘的位置），用于仓库外文件的还原兜底
REPO_ROOT="$(pwd)"
GIT_DIR_ABS="$(cd "$(git rev-parse --git-dir 2>/dev/null || echo .git)" && pwd)"
GIT_LFS_LOCAL_CACHE="${GIT_DIR_ABS}/lfs/objects"

# 判断树中是否存在 LFS 指针文件。
# 指针文件特征：体积 < 1024 字节，且内容以 Git LFS 规范的 spec 行开头。
#   $1 = 树/提交   $2 = 仓库目录（可选；clone 路径下参考上游项目在 staging 目录里，
#        而目标仓库的 HEAD 与参考上游项目无关 —— 不指定就会拿目标仓库的历史去探测，永远探不到）
detect_lfs_in_tree() {
  local treeish="$1" repo="${2:-}"
  local -a gc=()
  [ -n "${repo}" ] && gc=(-C "${repo}")
  git "${gc[@]}" ls-tree -r "${treeish}" 2>/dev/null | while IFS=$'\t' read -r meta path; do
    set -- ${meta}
    [ "${1:-}" = "100644" ] || [ "${1:-}" = "100755" ] || continue
    local sha="${3:-}"
    [ -n "${sha}" ] || continue
    # 指针文件一定很小，先用体积过滤，避免逐个 cat-file 大文件
    [ "$(git "${gc[@]}" cat-file -s "${sha}" 2>/dev/null || echo 0)" -lt 1024 ] || continue
    if git "${gc[@]}" cat-file -p "${sha}" 2>/dev/null | head -c 43 \
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

# 探测参考项目是否用 LFS，并把结果写进 UPSTREAM_HAS_LFS / LFS_FILES
#   $1 = 树/提交   $2 = 仓库目录（可选，见 detect_lfs_in_tree 的说明）
detect_upstream_lfs() {
  local treeish="$1" repo="${2:-}"
  LFS_FILES="$(detect_lfs_in_tree "${treeish}" "${repo}" || true)"
  if [ -n "${LFS_FILES}" ]; then
    UPSTREAM_HAS_LFS=1
    log "==> 检测到参考上游项目使用 Git LFS：$(printf '%s\n' "${LFS_FILES}" | grep -c . || true) 个文件"
  else
    UPSTREAM_HAS_LFS=0
    log "==> 参考上游项目未使用 LFS（或无可同步的 LFS 文件）"
  fi
}

# 把指针文件还原成真身内容。
#   $1 = 执行 git lfs 的仓库目录（**必须**是持有 upstream remote 的那一侧：
#        clone 路径 = staging 参考上游项目克隆；SEED_SOURCE 路径 = 本仓库自身。
#        传错会报 `Invalid remote name "origin"` 或静默 0 objects）
#   $2 = remote 名（具名 remote）或仓库地址/路径
#   $3 = 该次 fetch 对应的引用（分支名或 SHA）
#   $4 = 还原发生的目录（工作区根 / staging 临时目录）
#   $5 = 该目录下的相对路径列表（空格分隔）
#
# 关键点（沙箱实测，别改回去）：
#   1) `git lfs fetch <名字> <ref>` —— 名字必须是**具名 remote**，或地址形态；
#      传裸 ref 会报 `Invalid remote name`。地址形态只有配上显式 <ref> 才真的
#      下载对象（`git lfs fetch <URL>` 单参数会静默「0 objects found」）。
#      所以这里一律带 ref。
#   2) 文件在**仓库之外**（staging 临时目录）时，`git lfs checkout <路径>` 不生效
#      （实测：外路径 checkout 后仍是 131 字节指针）。真身的取法只有两条：
#      a) 文件所在目录本身就是仓库（clone 路径的 staging）时，在里面 checkout；
#      b) 其余（仓库外临时目录）只能直接从 LFS 缓存按 oid 拷贝 —— 必须有这条兜底。
#   3) 必须清掉 GIT_LFS_SKIP_SMUDGE，该变量会连带禁止 LFS 对象下载
#      （本脚本导出快照时正是开着它）。
smudge_lfs_files() {
  local fetch_repo="$1" remote="$2" ref="$3" base="$4"; shift 4
  local restored=0 failed=0 f oid src
  env -u GIT_LFS_SKIP_SMUDGE git -C "${fetch_repo}" lfs fetch "${remote}" "${ref}" >/dev/null 2>&1 || true
  for f in "$@"; do
    local target="${base}/${f}"
    [ -f "${target}" ] || continue
    is_lfs_pointer "${target}" || continue
    # 优先 git lfs checkout：只在「文件所在目录就是那个仓库」时有效
    # （clone 路径的 staging 是仓库；仓库外的临时目录必然无效，靠下面兜底）
    if git -C "${base}" rev-parse --git-dir >/dev/null 2>&1; then
      git -C "${base}" lfs checkout -- "${f}" >/dev/null 2>&1 || true
    fi
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
      err "   !! LFS 内容还原失败：${f}"
    else
      restored=$((restored + 1))
    fi
  done
  echo "${restored}:${failed}"
}

# 还原真身并汇总；拿到就置 LFS_INCOMPLETE=1
#   $1=fetch 仓库  $2=remote 名/地址  $3=引用  $4=目录  $5...=相对路径
restore_lfs() {
  local fetch_repo="$1" remote="$2" ref="$3" base="$4"; shift 4
  [ "${UPSTREAM_HAS_LFS}" = "1" ] || return 0
  log "==> 还原 LFS 真身内容 ..."
  local result
  result="$(smudge_lfs_files "${fetch_repo}" "${remote}" "${ref}" "${base}" "$@" | tail -1)"
  log "==> LFS 还原：成功 ${result%%:*} 个，失败 ${result##*:} 个"
  [ "${result##*:}" = "0" ] || LFS_INCOMPLETE=1
}

# 真身没拿到就中止，绝不把指针文件当「同步成功」提交（内容丢失）
abort_if_lfs_incomplete() {
  [ "${LFS_INCOMPLETE}" = "1" ] || return 0
  err "!! 有 LFS 文件未能还原为真身内容，已中止本次同步（不会提交指针文件）。"
  err "   可能原因：参考项目 LFS 对象不可拉取 / 网络受限 / 目标环境缺 git-lfs。"
  printf '##[set-output SYNC_STATUS=conflict]\n'
  printf '##[set-output SYNC_LFS_INCOMPLETE=1]\n'
  exit 1
}

# 让 LFS 真身以 LFS 方式入库（否则会被当普通大文件，仓库体积会爆）
ensure_lfs_tracked() {
  local path="$1"
  git lfs track -- "${path}" >/dev/null 2>&1 || true
}

WORKSPACE="$(pwd)"
# 推送目标分支：**故意不给默认值**。
#
# 早先这里默认成 main，于是 `git push origin HEAD:main` 会在远端凭空造出一个
# main 分支 —— 空仓库上车时它还可能是第一个远端分支，也就是仓库的默认分支。
# 场景：参考项目默认分支是 master，同步官按「跟随参考上游项目」把默认分支建成 master，
# 脚本又顺手推了个 main，仓库里就多出一个谁也没要的 main。
#
# 现在不传 TARGET_BRANCH 就只在本地提交、不推送。两条既有链路恰好都满足：
#   - 流水线：模板里设了 SYNC_NO_PUSH=1，推送与开 PR 由后续阶段负责
#   - 同步官初装：在引导分支 sync/bootstrap 上跑，随后自己推该分支
TARGET_BRANCH="${TARGET_BRANCH:-}"

# 完整保留的一级路径：既不被参考上游项目覆盖，也不被清理。
KEEP_TOP=(".git" ".cnb" ".ci" ".cnb.yml")

keep_top() {
  local name="$1"
  for p in "${KEEP_TOP[@]}"; do
    if [ "${name}" = "${p}" ]; then
      return 0
    fi
  done
  return 1
}

log "==> 参考上游项目: ${UPSTREAM_URL}"
log "==> 目标子目录: ${SYNC_DIR:-<仓库根目录>}"

# ---------- 空仓库铺源：只落首个提交，不复刻参考项目历史 ----------
# 目的：让「新仓库 + 大型参考项目」的首次上车也很快。已在跟踪的仓库不会走这里。
if [ -n "${SEED_SOURCE}" ] && ! git rev-parse --verify -q HEAD >/dev/null 2>&1; then
  log "==> 空仓库：按铺源模式落首个提交（${SEED_SOURCE}）"
  SEED_TMP="$(mktemp -d)"
  trap 'rm -rf "${SEED_TMP}"' EXIT
  if ! git fetch --depth 1 --no-tags "${SEED_SOURCE}" HEAD; then
    err "!! 铺源拉取失败：${SEED_SOURCE}（网络不通 / 仓库不存在 / 私有仓库无权限）"
    exit 1
  fi
  SEED_SHA="$(git rev-parse FETCH_HEAD)"
  # 参考项目是不是 LFS 项目：看树里有没有指针文件（此时对象库已含参考项目快照）
  detect_upstream_lfs "${SEED_SHA}"
  # 用 SKIP_SMUDGE 稳定导出（避免 LFS filter 中途失败把同步炸掉）；
  # 这样落盘的是 131 字节指针，真身由 restore_lfs 还原 —— 漏了那一步
  # 指针就会直接落进首个提交（内容丢失，且此后当成「已同步」永不重试）。
  GIT_LFS_SKIP_SMUDGE=1 git archive "${SEED_SHA}" | tar -x -C "${SEED_TMP}"
  # 还原 LFS 真身；拉不到就中止（绝不提交指针）
  restore_lfs "${REPO_ROOT}" "${SEED_SOURCE}" "${SEED_SHA}" "${SEED_TMP}" ${LFS_FILES:-}
  abort_if_lfs_incomplete
  # 参考上游项目自带的平台配置不写进来
  rm -rf "${SEED_TMP}/.cnb" "${SEED_TMP}/.cnb.yml" "${SEED_TMP}/.ci" "${SEED_TMP}/.github/workflows"
  cp -a "${SEED_TMP}/." .
  # 真身以 LFS 入库，而不是当普通大文件塞进对象库（否则仓库体积会爆）
  if [ "${UPSTREAM_HAS_LFS}" = "1" ] && [ "${LFS_INCOMPLETE}" = "0" ]; then
    ensure_lfs_tracked "*"
  fi
  rm -rf "${SEED_TMP}"
  git add -A
  if git diff --cached --quiet; then
    err "!! 参考项目快照为空，未做任何提交"
    exit 1
  fi
  git commit -q --no-gpg-sign -m "sync: 初始化参考上游项目 ${UPSTREAM_URL} @ ${SEED_SHA:0:8}（铺源）"
  log "==> 已铺源: $(git rev-parse --short HEAD)"
  printf '##[set-output SYNC_LFS=%s]\n' "${UPSTREAM_HAS_LFS}"
  # 铺源也是成功同步：必须给出 merged，否则流水线无从区分「铺源成功」与
  # 「脚本半途死掉」，report 阶段会把成功当失败、或反过来把失败当成功。
  printf '##[set-output SYNC_STATUS=merged]\n'
  exit 0
fi

STASH="$(mktemp -d)"
trap 'rm -rf "${STASH}"' EXIT

# 1. 拉取参考上游项目（浅克隆即可，同步不关心参考项目历史）
#    私有参考项目：clone 命令行临时带凭证 URL（不写入任何 remote 配置），
#    凭证只出现在这一条命令里，之后所有操作与输出都是匿名形态。
#
#    关掉 smudge（GIT_LFS_SKIP_SMUDGE=1）：
#    - 参考项目是 LFS 且对象拉不到时，带 filter 的 checkout 会在 clone 中途
#      `smudge filter lfs failed` 硬失败（退出码 128），脚本因 set -e 直接死掉 ——
#      既没有可读的结论，也不是我们想要的「中止」语义；
#    - 目标环境缺 git-lfs 时同理（filter 命令找不到）。
#    统一改成「先只拿指针，再由 restore_lfs 还原真身、拿不到就中止」，
#    与采集版脚本同一口径。
log "==> 克隆参考上游项目（浅克隆）"
if ! GIT_LFS_SKIP_SMUDGE=1 git clone --depth 1 "${AUTH_CLONE_URL}" "${STASH}/upstream"; then
  err "!! 参考上游项目克隆失败：${UPSTREAM_URL}（网络不通 / 仓库不存在 / 私有仓库无权限）"
  exit 1
fi
# 参考上游项目真身在 staging 里物化：探测/checkout 都必须在那个仓库里做
# （目标仓库的 HEAD 与参考上游项目毫无关系，拿本仓历史探测永远探不到 LFS）。
detect_upstream_lfs "HEAD" "${STASH}/upstream"
restore_lfs "${STASH}/upstream" "origin" "HEAD" "${STASH}/upstream" ${LFS_FILES:-}
abort_if_lfs_incomplete

# 2. 计算落地目录
if [ -n "${SYNC_DIR}" ]; then
  DEST="${WORKSPACE}/${SYNC_DIR}"
  mkdir -p "${DEST}"
else
  DEST="${WORKSPACE}"
fi

# 3. 清掉目标目录里来自参考项目的旧内容
log "==> 清理旧的参考项目内容"
shopt -s dotglob nullglob
for entry in "${DEST}"/*; do
  name="$(basename "${entry}")"
  keep_top "${name}" && continue
  rm -rf "${entry}"
done
shopt -u dotglob nullglob

# 4. 拷贝参考项目内容（排除参考上游项目 .git 与受保护的一级路径）
#    先确保 LFS 过滤规则在位：规则不在时真身会被当普通大文件入库（仓库体积会爆）。
#    参考上游项目 .gitattributes 里的 filter=lfs 规则随后会一起同步过来（保留路径除外）。
if [ "${UPSTREAM_HAS_LFS}" = "1" ]; then
  ensure_lfs_tracked "*"
fi
log "==> 写入参考项目内容"
shopt -s dotglob nullglob
for entry in "${STASH}/upstream"/*; do
  name="$(basename "${entry}")"
  [ "${name}" = ".git" ] && continue
  keep_top "${name}" && continue
  cp -a "${entry}" "${DEST}/"
done
shopt -u dotglob nullglob

# 6. 提交（有差异才提交）
#
# 判定顺序很重要，这里踩过坑，别改回去：
#   1) 先把工作区整体 add 进索引（参考上游项目新增/修改/删除都在这一步落到索引）
#   2) 再把「不该被跟踪的本地文件」（本脚本自己）从索引里摘掉，工作树保留
#   3) 最后比**索引与 HEAD** —— 只有两者一致才算「没有更新」
#
# 反例：早先是「先 git rm --cached .cnb，再比 git status --porcelain」。
# `.cnb/` 在工作区里始终存在（它就是受保护路径），`git rm --cached .cnb`
# 必然让索引与 HEAD 出现差异，于是**每次同步都多出一个「删除 .cnb」的空提交**，
# `no-update` 永远不会命中 —— 定时任务会每天堆一个无意义的提交和 PR。
cd "${WORKSPACE}"
git add -A

# 本脚本必须留在仓库里：它是同步官初装那次提交进来的，之后每次同步都要在工作树里
# 留着它 —— 否则「提交到临时分支 → 合并回默认分支」会把工作树里的它删掉，
# 下一次定时任务就 `bash: .cnb/sync-upstream.sh: No such file or directory` 了。
#
# 分两种情况：
#   a) 它已经被 git 跟踪（初装那次提交的）→ 什么都不做，保持跟踪
#   b) 它没被跟踪（本脚本自己同步进来的）→ 从索引摘掉，只保留工作树文件
# 参考上游项目本来就没有 `.cnb/` 这个路径，所以这里只针对这一个文件，不碰 `.cnb/` 下别的。
if [ -n "$(git ls-files -- .cnb/sync-upstream.sh)" ]; then
  log "==> .cnb/sync-upstream.sh 已跟踪，保留（下次定时任务还要用它）"
else
  git ls-files -z -- .cnb/sync-upstream.sh 2>/dev/null | xargs -0 -r \
    git rm -q --cached --ignore-unmatch -- >/dev/null 2>&1 || true
fi

if git diff --cached --quiet --exit-code 2>/dev/null; then
  log "==> 参考项目无更新，跳过提交"
  printf '##[set-output SYNC_STATUS=no-update]\n'
  exit 0
fi

UPSTREAM_REV="$(git -C "${STASH}/upstream" rev-parse --short HEAD)"
UPSTREAM_DATE="$(git -C "${STASH}/upstream" log -1 --format=%cd --date=short)"

git commit --no-gpg-sign -m "sync: 跟进参考上游项目 ${UPSTREAM_URL} @ ${UPSTREAM_REV}

参考上游项目提交: ${UPSTREAM_REV} (${UPSTREAM_DATE})
同步目标: ${SYNC_DIR:-<仓库根目录>}
源仓库: ${UPSTREAM_URL}"

log "==> 已提交: $(git rev-parse --short HEAD)"
printf '##[set-output SYNC_LFS=%s]\n' "${UPSTREAM_HAS_LFS}"
printf '##[set-output SYNC_STATUS=merged]\n'

# 7. 推送。三条规则，按顺序判断：
#   a) SYNC_NO_PUSH=1 → 不推（流水线会用临时分支推 + 开 PR 自动合并）
#   b) TARGET_BRANCH 非空 → 推到该分支（显式调用者指定了目标）
#   c) TARGET_BRANCH 为空 → 不推，只在本地提交。**不猜分支名**：
#      猜错就会在远端造出一个谁也没要的分支，空仓库里甚至会成为默认分支。
if [ "${SYNC_NO_PUSH:-0}" = "1" ]; then
  log "==> 已跳过推送（SYNC_NO_PUSH=1）"
elif [ -n "${TARGET_BRANCH}" ]; then
  log "==> 推送到 ${TARGET_BRANCH}"
  git push origin "HEAD:${TARGET_BRANCH}"
else
  log "==> 未指定 TARGET_BRANCH，仅在本地提交（由调用方决定推到哪里）"
fi
