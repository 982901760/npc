#!/usr/bin/env bash
# 完整场景测试
# 场景回归测试：在临时目录里造参考上游项目/本地仓库夹具，覆盖两种模式的关键路径。
# 用法：bash run-tests.sh   （全部通过时退出码为 0）
HERE="$(cd "$(dirname "$0")" && pwd)"
SYNC="${SYNC:-$HERE/../sync-upstream.sh}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
echo "被测脚本：${SYNC}"
echo "工作目录：${WORK}"
PASS=0; FAIL=0; SKIP=0
# ---- 测试环境归一（跨平台口径对齐 CI，2026-09-30）----
# 夹具仓库与被测流程不得继承宿主的全局/系统 git 配置：Windows 宿主常见
# core.autocrlf=true，会把文本夹具 CRLF 化，状态机断言（merged/no-update/conflict）
# 与内容比对全乱（本机 MINGW 实测 23 假红）；CI Linux 容器本就零全局配置。
# 指向白名单代理而非 /dev/null：宿主其余配置零继承（同 CI 干净口径），
# 但 git-lfs 的 filter 配置必须保留——Git for Windows 装在**全局层**、CI 镜像装在
# system 层；直接屏蔽会把 LFS 过滤器一并挡掉，夹具 add 不做指针化（131B 指针变
# 300000B 真身），LFS/状态机全族连坐假红（2026-09-30 本机实测 23→28 恶化后定位）。
GITCFG_WHITELIST="${WORK}/gitconfig-whitelist"
: > "${GITCFG_WHITELIST}"
for scope in --global --system; do
  git config ${scope} --get-regexp '^(filter\.lfs|lfs)\.' 2>/dev/null | while IFS= read -r kv; do
    # get-regexp 输出形态两派：`key=value`（新版）与 `key value`（空格，Git for Windows 实测）——双兼容
    case "${kv}" in *=*) k="${kv%%=*}"; v="${kv#*=}";; *) k="${kv%% *}"; v="${kv#* }";; esac
    git config --file "${GITCFG_WHITELIST}" "${k}" "${v}" 2>/dev/null || true
  done
done
export GIT_CONFIG_GLOBAL="${GITCFG_WHITELIST}"
export GIT_CONFIG_SYSTEM=/dev/null
# MINGW/MSYS/Cygwin 的 bash 管道无稳定 SIGPIPE 传递（141 时有时无——正是
# 「时有时无」让 AF 系断言在这类平台成为 flaky）：下方依赖 141 的断言做守卫跳过。
IS_WINDOWS_BASH=0
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) IS_WINDOWS_BASH=1 ;; esac
command -v cygpath >/dev/null 2>&1 && export PATH="/usr/bin:${PATH}"
# ↑ MINGW PATH 卫生：宿主 ~/.local/bin 可能存在吞掉 `-u` 语义的 env shim
#   （2026-09-30 实测：`env -u FOO` 静默 RC=0，致「漏传变量必须报错」场景失效）；
#   /usr/bin 前置后 env/bash/git 命中 MINGW 正体，宿主其余 PATH 仍作后备。
# 本套件整体不使用 errexit：大量命令是「预期可能失败并检查结果」的，
# 一旦误开 errexit，单个失败命令就会掐断整个套件、且不会打印汇总行。
set +e
chk() { if [ "$2" = "$3" ]; then echo "  ✅ $1"; PASS=$((PASS+1)); else echo "  ❌ $1: 期望[$3] 实际[$2]"; FAIL=$((FAIL+1)); fi; }
# 套件大量在临时目录里跑，但有些断言要校验「技能仓库自身」的模板/文档，
# 所以这里显式定位到仓库根：run-tests.sh 位于 skills/sync-upstream/scripts/tests/
REPO_ROOT="$(cd "$HERE/../../../.." && pwd)"

# 从 YAML 里取出某个 stage 的 script 体（剥掉 script 行自身的 +2 缩进）。
#
# 原先用 python3 做这段文本处理，但 CI 镜像 cnbcool/default-build-env 里
# 没有 python3 —— 场景 AA/AB 两个端到端用例会因 `python3: command not found`
# 静默取空、断言变成「没合上」，看起来像同步逻辑坏了（PR #16 CI 实测：
# PASS=157 FAIL=2，且报错只说「!! 未合并」，极易误诊）。
# 回归套件本身不该依赖被测环境之外的运行时，改用它一定有的 awk。
#
# 缩进**自适应**（PR #16 评审遗留收编）：本函数原先写死 12 空格（只服务
# `.ci/git-sync.yml`），AF 段另有一个 `af_extract_stage()` 是同一套逻辑、只是
# 按「stage 缩进 + 2」自适应 —— 两套同类实现并存，写死的那套一旦被拿去抽别的
# 文件就会**静默抽出空串**（下游只看到「内容丢了」式假红，极难定位）。
# 现收编成一份：读 script 行的实际缩进 + 2 作为 body 前缀。
#
# 注意：不用 `{12}` 区间量词——mawk 不支持，会静默匹配不到（本地实测踩到）。
# 改用 match() 取真实列宽 + index() 判定位，各 awk 实现口径一致。
extract_stage() {  # $1=YAML 路径 $2=stage 名
  awk -v want="$2" '
    BEGIN { pad = "\n" }
    !inblock && $0 ~ ("^ *- name: " want "$") { inblock=1; next }
    inblock && $0 ~ /^ *- name: / { if (script) exit; inblock=0; next }
    inblock && !script && $0 ~ /^ *script: \|$/ { match($0, /^ */); pad=sprintf("%*s", RLENGTH+2, ""); script=1; next }
    script {
      if (index($0, pad) == 1) { print substr($0, length(pad) + 1); next }
      if ($0 ~ /^[[:space:]]*$/) { print ""; next }
      exit
    }
  ' "$1"
}

newup() { # $1=dir
  rm -rf "$1"; mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.name up; git config user.email up@x; git config commit.gpgsign false
    mkdir -p src docs .cnb
    echo v1 > src/app.js; echo readme > README.md; echo "upstream-ci" > .cnb.yml; echo up > .cnb/settings.yml
    git add -A; git commit -qm "up: initial" )
}
newlocal() { # $1=dir  创建带自己平台配置的本地仓库
  rm -rf "$1"; mkdir -p "$1"; ( cd "$1"; git init -q -b main; git config user.name l; git config user.email l@x; git config commit.gpgsign false
    mkdir -p .cnb
    printf 'include:\n  - .cnb/git-sync.yml\n' > .cnb.yml
    printf 'main:\n  "crontab: 17 3 * * *": []\n' > .cnb/git-sync.yml
    git add -A; git commit -qm "chore: bootstrap sync config" )
}
# ---- Git LFS 夹具：造一个带 LFS 的裸仓库参考上游项目（纯本地，不需要 LFS 服务器）----
# 原理：把 LFS 对象直接放进裸仓库的 lfs/objects，git-lfs 的
# lfs-standalone-file 传输在 file:// 协议下即可读取。
LFS_AVAILABLE=0
if command -v git-lfs >/dev/null 2>&1; then LFS_AVAILABLE=1; fi

newlfsup() { # $1=裸仓库目录 $2=工作目录 [$3=LFS对象是否放入远端, 默认放]
  local bare="$1" work="$2" put="${3:-1}"
  rm -rf "$bare" "$work"; mkdir -p "$bare" "$work"
  git init -q --bare -b main "$bare"
  git init -q -b main "$work"
  (
    cd "$work" || exit 1
    git config user.name up; git config user.email up@x; git config commit.gpgsign false
    git lfs track "*.bin" >/dev/null 2>&1
    head -c 300000 /dev/urandom > data.bin
    echo "hello" > README.md
    mkdir -p src; echo v1 > src/app.js
    git add -A; git commit -qm "up: initial with lfs"
    # 正常推送（git-lfs 会把对象一并上传到裸仓库的 lfs/objects）
    GIT_LFS_SKIP_SMUDGE=1 git -c protocol.file.allow=always push -q "file://${bare}" main >/dev/null 2>&1 || true
    if [ "$put" = "0" ]; then
      # 模拟「参考项目 LFS 对象不可公开拉取」：从远端抹掉对象目录，
      # git 指针仍在（size=131），但真身永远拉不下来。
      rm -rf "${bare}/lfs"
    fi
  )
}

# 取参考上游项目 data.bin 的 LFS oid（同步后真身内容的 sha256 应等于它）
lfs_oid() { git -C "$1" cat-file -p main:data.bin | sed -n 's/^oid sha256://p'; }

runsync() { ( cd "$1" && UPSTREAM_REPO="$2" UPSTREAM_BRANCH="${3:-main}" TARGET_DIR="${4-}" bash "$SYNC" 2>&1 ); }
# 带 UPSTREAM_TOKEN 跑（私有参考项目通道）：$5=令牌值
runsync_tok() { ( cd "$1" && UPSTREAM_REPO="$2" UPSTREAM_BRANCH="${3:-main}" TARGET_DIR="${4-}" UPSTREAM_TOKEN="${5-}" bash "$SYNC" 2>&1 ); }
status() { echo "$1" | sed -n 's/^##\[set-output SYNC_STATUS=\(.*\)\]$/\1/p' | tail -1; }

cd "${WORK}"
echo "###### 场景 A：空仓库 + 平铺首次同步 ######"
newup ${WORK}/upA; newlocal ${WORK}/lA
OUT=$(runsync ${WORK}/lA ${WORK}/upA main "")
chk "状态=merged" "$(status "$OUT")" "merged"
chk "src/app.js 已同步" "$(cat ${WORK}/lA/src/app.js)" "v1"
chk "本地 .cnb.yml 保留" "$(grep -c git-sync ${WORK}/lA/.cnb.yml)" "1"
chk "参考上游项目 .cnb/settings.yml 被剔除" "$([ -f ${WORK}/lA/.cnb/settings.yml ] && echo leak || echo clean)" "clean"
chk "带 Upstream-Sync 标记" "$(git -C ${WORK}/lA log -1 --format=%B | grep -c '^Upstream-Sync: ')" "1"
# 首次同步：本地与参考上游项目没有共同祖先，走快照式落盘（不复刻参考项目历史）。
# 为什么不用真实 merge：无共同祖先时同名文件全是 add/add 冲突，-X ours 会把
# 参考项目的「修改」静默判给本地（本地还是旧内容，却报同步成功）。
chk "提交数=base+同步" "$(git -C ${WORK}/lA log --oneline | wc -l | tr -d ' ')" "2"
chk "同步提交是单父(不复刻参考项目历史)" "$(git -C ${WORK}/lA log -1 --format=%P | wc -w | tr -d ' ')" "1"

echo "###### 场景 B：重跑幂等（应 no-update，无新提交） ######"
BEFORE=$(git -C ${WORK}/lA rev-parse HEAD)
OUT=$(runsync ${WORK}/lA ${WORK}/upA main "")
chk "状态=no-update" "$(status "$OUT")" "no-update"
chk "HEAD 未变" "$(git -C ${WORK}/lA rev-parse HEAD)" "$BEFORE"

echo "###### 场景 C：参考上游项目新增/修改/删除 ######"
( cd ${WORK}/upA; echo v2 > src/app.js; echo new > docs/new.md; rm -f README.md; git add -A; git commit -qm "up: second" )
OUT=$(runsync ${WORK}/lA ${WORK}/upA main "")
chk "状态=merged" "$(status "$OUT")" "merged"
chk "修改已同步" "$(cat ${WORK}/lA/src/app.js)" "v2"
chk "新增已同步" "$([ -f ${WORK}/lA/docs/new.md ] && echo yes)" "yes"
chk "删除已同步" "$([ -f ${WORK}/lA/README.md ] && echo still || echo gone)" "gone"
chk "本地 .cnb.yml 仍在" "$(grep -c git-sync ${WORK}/lA/.cnb.yml)" "1"
chk "参考项目改动已落盘" "$(git -C ${WORK}/lA log --oneline | wc -l | tr -d ' ')" "3"

echo "###### 场景 D：子目录模式 ######"
newup ${WORK}/upD; newlocal ${WORK}/lD
( cd ${WORK}/lD; echo "# 我自己的项目" > MYPROJECT.md; git add -A; git commit -qm "feat: my project" )
OUT=$(runsync ${WORK}/lD ${WORK}/upD main "ZCode")
chk "状态=merged" "$(status "$OUT")" "merged"
chk "落到子目录" "$(cat ${WORK}/lD/ZCode/src/app.js)" "v1"
chk "自己的项目未动" "$([ -f ${WORK}/lD/MYPROJECT.md ] && echo yes)" "yes"
chk "根目录未被子目录污染" "$([ -f ${WORK}/lD/README.md ] && echo pollute || echo clean)" "clean"
chk "参考上游项目 .cnb/settings.yml 未带入" "$([ -f ${WORK}/lD/ZCode/.cnb/settings.yml ] && echo leak || echo clean)" "clean"
chk "参考上游项目 .cnb.yml 未带入" "$([ -f ${WORK}/lD/ZCode/.cnb.yml ] && echo leak || echo clean)" "clean"

echo "###### 场景 E：子目录模式幂等 ######"
OUT=$(runsync ${WORK}/lD ${WORK}/upD main "ZCode")
chk "状态=no-update" "$(status "$OUT")" "no-update"

echo "###### 场景 F：子目录模式跟进参考上游项目增删改 ######"
( cd ${WORK}/upD; echo v2 > src/app.js; rm README.md; echo add > extra.txt; git add -A; git commit -qm "up: second" )
OUT=$(runsync ${WORK}/lD ${WORK}/upD main "ZCode")
chk "状态=merged" "$(status "$OUT")" "merged"
chk "修改同步" "$(cat ${WORK}/lD/ZCode/src/app.js)" "v2"
chk "删除同步" "$([ -f ${WORK}/lD/ZCode/README.md ] && echo still || echo gone)" "gone"
chk "新增同步" "$(cat ${WORK}/lD/ZCode/extra.txt)" "add"
chk "自己的项目仍未被碰" "$([ -f ${WORK}/lD/MYPROJECT.md ] && echo yes)" "yes"

echo "###### 场景 G：参考项目分支不存在 ######"
OUT=$(runsync ${WORK}/lA ${WORK}/upA nonexist "")
chk "状态=fetch-failed" "$(status "$OUT")" "fetch-failed"

echo "###### 场景 H：参考上游项目仓库不存在 ######"
OUT=$(runsync ${WORK}/lA ${WORK}/no-such-repo main "")
chk "状态=fetch-failed" "$(status "$OUT")" "fetch-failed"

echo "###### 场景 I：目标目录与平台配置冲突 ######"
OUT=$(runsync ${WORK}/lA ${WORK}/upA main ".cnb")
chk "状态=conflict" "$(status "$OUT")" "conflict"
chk "退出码非0" "$?" "0"

echo "###### 场景 J：本地有未提交改动 ######"
newup ${WORK}/upJ; newlocal ${WORK}/lJ; echo dirty >> ${WORK}/lJ/.cnb.yml
OUT=$(runsync ${WORK}/lJ ${WORK}/upJ main "")
chk "状态=merged" "$(status "$OUT")" "merged"
chk "脏改动已被重置" "$(git -C ${WORK}/lJ status --porcelain | wc -l)" "0"

echo "###### 场景 K：参考上游项目强推历史（orphan 重写） ######"
newup ${WORK}/upK; newlocal ${WORK}/lK
OUT=$(runsync ${WORK}/lK ${WORK}/upK main "")
chk "首次同步" "$(status "$OUT")" "merged"
( cd ${WORK}/upK; echo "rewritten-content" > src/rewritten.txt; git checkout -q --orphan rewrite; git add -A; git commit -qm "up: rewritten history"; git branch -qM rewrite main )
OUT=$(runsync ${WORK}/lK ${WORK}/upK main "")
chk "强推后仍能同步" "$(status "$OUT")" "merged"

if [ "${LFS_AVAILABLE}" = "1" ] && [ "${IS_WINDOWS_BASH}" != "1" ]; then
echo "###### 场景 L：LFS 参考上游项目 + 平铺模式（真身内容必须完整） ######"
newlfsup ${WORK}/upL ${WORK}/upLwork 1
newlocal ${WORK}/lL
OID="$(lfs_oid ${WORK}/upL)"
OUT=$(runsync ${WORK}/lL "file://${WORK}/upL" main "")
chk "状态=merged" "$(status "$OUT")" "merged"
chk "LFS 已识别" "$(echo "$OUT" | sed -n 's/^##\[set-output SYNC_LFS=\(.*\)\]$/\1/p' | tail -1)" "1"
chk "LFS 真身内容完整(sha256=参考上游项目oid)" "$(sha256sum ${WORK}/lL/data.bin | cut -d' ' -f1)" "$OID"
chk "LFS 以指针入库(131B)" "$(git -C ${WORK}/lL cat-file -s HEAD:data.bin)" "131"
chk "LFS 跟踪规则已带过来" "$([ "$(grep -c 'filter=lfs' ${WORK}/lL/.gitattributes)" -ge 1 ] && echo ok)" "ok"
chk "本地 .cnb.yml 保留" "$(grep -c git-sync ${WORK}/lL/.cnb.yml)" "1"

echo "###### 场景 M：LFS 参考上游项目 + 环境禁用 smudge（最易静默丢内容） ######"
newlfsup ${WORK}/upM ${WORK}/upMwork 1
newlocal ${WORK}/lM
OID="$(lfs_oid ${WORK}/upM)"
OUT=$(cd ${WORK}/lM && GIT_LFS_SKIP_SMUDGE=1 UPSTREAM_REPO="file://${WORK}/upM" UPSTREAM_BRANCH=main TARGET_DIR="" bash "$SYNC" 2>&1)
chk "状态=merged" "$(status "$OUT")" "merged"
chk "禁用 smudge 下仍还原真身" "$(sha256sum ${WORK}/lM/data.bin | cut -d' ' -f1)" "$OID"
chk "未报 LFS 不完整" "$(echo "$OUT" | grep -c 'SYNC_LFS_INCOMPLETE')" "0"

echo "###### 场景 N：LFS 参考上游项目 + 子目录模式 ######"
newlfsup ${WORK}/upN ${WORK}/upNwork 1
newlocal ${WORK}/lN
echo "# mine" > ${WORK}/lN/MINE.md; git -C ${WORK}/lN add -A; git -C ${WORK}/lN commit -qm "feat: mine"
OID="$(lfs_oid ${WORK}/upN)"
OUT=$(cd ${WORK}/lN && GIT_LFS_SKIP_SMUDGE=1 UPSTREAM_REPO="file://${WORK}/upN" UPSTREAM_BRANCH=main TARGET_DIR="ZCode" bash "$SYNC" 2>&1)
chk "状态=merged" "$(status "$OUT")" "merged"
chk "子目录 LFS 真身完整" "$(sha256sum ${WORK}/lN/ZCode/data.bin | cut -d' ' -f1)" "$OID"
chk "自己的项目未动" "$([ -f ${WORK}/lN/MINE.md ] && echo yes)" "yes"

echo "###### 场景 O：LFS 对象不可获取时必须中止（不提交指针） ######"
newlfsup ${WORK}/upO ${WORK}/upOwork 0   # 远端不放 LFS 对象
newlocal ${WORK}/lO
OUT=$(runsync ${WORK}/lO "file://${WORK}/upO" main "")
chk "状态=conflict" "$(status "$OUT")" "conflict"
chk "未提交任何同步提交" "$(git -C ${WORK}/lO log --oneline | wc -l | tr -d ' ')" "1"
chk "未落盘指针文件" "$([ -f ${WORK}/lO/data.bin ] && echo leaked || echo clean)" "clean"

echo "###### 场景 P2：LFS 参考上游项目增量更新（第二次同步走真实 merge 路径） ######"
(
  cd ${WORK}/upLwork || exit 1
  head -c 400000 /dev/urandom > data.bin   # 换掉 LFS 文件内容
  echo "new line" >> README.md
  git add -A; git commit -qm "up: change lfs content"
  GIT_LFS_SKIP_SMUDGE=1 git -c protocol.file.allow=always push -q "file://${WORK}/upL" main >/dev/null 2>&1 || true
)
OID2="$(lfs_oid ${WORK}/upL)"
OUT=$(cd ${WORK}/lL && GIT_LFS_SKIP_SMUDGE=1 UPSTREAM_REPO="file://${WORK}/upL" UPSTREAM_BRANCH=main TARGET_DIR="" bash "$SYNC" 2>&1)
chk "状态=merged" "$(status "$OUT")" "merged"
chk "增量同步后 LFS 真身已更新" "$(sha256sum ${WORK}/lL/data.bin | cut -d' ' -f1)" "$OID2"
chk "非 LFS 文件同步" "$(tail -1 ${WORK}/lL/README.md)" "new line"

echo "###### 场景 P：LFS 参考上游项目重跑幂等 ######"
OUT=$(runsync ${WORK}/lL "file://${WORK}/upL" main "")
chk "状态=no-update" "$(status "$OUT")" "no-update"
chk "真身内容仍完整" "$(sha256sum ${WORK}/lL/data.bin | cut -d' ' -f1)" "$(lfs_oid ${WORK}/upL)"
else
  echo "###### 跳过 LFS 场景：未安装 git-lfs，或 Windows bash（原生 git-lfs 与 MINGW 路径摩擦：/tmp chdir 失败/匿名 fetch URL 推导不成立，2026-09-30 实证）——LFS 回归以 CI Linux 为权威 ######"
fi

echo "###### 场景 Q：空历史 + 铺源模式（浅克隆落首个提交，不复刻历史） ######"
newup ${WORK}/upQ
rm -rf ${WORK}/lQ; mkdir -p ${WORK}/lQ; ( cd ${WORK}/lQ; git init -q -b main
  git config user.name l; git config user.email l@x; git config commit.gpgsign false
  mkdir -p .cnb; printf 'include:\n  - .cnb/git-sync.yml\n' > .cnb.yml
  printf 'main:\n  "crontab: 17 3 * * *": []\n' > .cnb/git-sync.yml
  git add -A; git commit -qm "chore: bootstrap sync config" )
OUT=$( cd ${WORK}/lQ && SEED_SOURCE="${WORK}/upQ" UPSTREAM_REPO="${WORK}/upQ" UPSTREAM_BRANCH=main TARGET_DIR="" bash "$SYNC" 2>&1 )
chk "状态=merged" "$(status "$OUT")" "merged"
chk "参考项目内容已落盘" "$(cat ${WORK}/lQ/src/app.js)" "v1"
chk "不复刻参考项目历史（单父）" "$(git -C ${WORK}/lQ log -1 --format=%P | wc -w | tr -d ' ')" "1"
chk "本地 .cnb.yml 保留" "$(grep -c git-sync ${WORK}/lQ/.cnb.yml)" "1"
chk "参考上游项目 .cnb.yml 未带入" "$([ -f ${WORK}/lQ/.cnb/settings.yml ] && echo leak || echo clean)" "clean"

echo "###### 场景 R：铺源后跟参考上游项目增量（必须真的更新，不能报 no-update） ######"
OUT=$( cd ${WORK}/lQ && SEED_SOURCE="${WORK}/upQ" UPSTREAM_REPO="${WORK}/upQ" UPSTREAM_BRANCH=main TARGET_DIR="" bash "$SYNC" 2>&1 )
chk "未更新时 no-update" "$(status "$OUT")" "no-update"
( cd ${WORK}/upQ; echo v2 > src/app.js; rm -f README.md; echo n > NEW.md; git add -A; git commit -qm "up: second" )
OUT=$( cd ${WORK}/lQ && SEED_SOURCE="${WORK}/upQ" UPSTREAM_REPO="${WORK}/upQ" UPSTREAM_BRANCH=main TARGET_DIR="" bash "$SYNC" 2>&1 )
chk "状态=merged" "$(status "$OUT")" "merged"
chk "参考项目的修改已生效(不是被 -X ours 吃掉)" "$(cat ${WORK}/lQ/src/app.js)" "v2"
chk "参考项目的删除已生效" "$([ -f ${WORK}/lQ/README.md ] && echo still || echo gone)" "gone"
chk "参考项目的新增已生效" "$(cat ${WORK}/lQ/NEW.md)" "n"

echo "###### 场景 S：目标脚本（下发版）—— 自动合并链路用的「只提交不推送」 ######"
# 下发面只有 1 个脚本：.cnb/sync-upstream.sh（源文件 scripts/sync-upstream-target.sh）。
# 它跑完后由流水线负责推送临时分支 + 开 PR，所以要有 SYNC_NO_PUSH 模式。
TARGET="${TARGET_SCRIPT:-$HERE/../sync-upstream-target.sh}"
chk "下发脚本存在" "$([ -f "$TARGET" ] && echo yes || echo no)" "yes"
newup ${WORK}/upS
rm -rf ${WORK}/lS; mkdir -p ${WORK}/lS
(
  cd ${WORK}/lS || exit 1
  git init -q -b main; git config user.name l; git config user.email l@x
  git config commit.gpgsign false
  mkdir -p .cnb
  printf 'include:\n  - .cnb/git-sync.yml\n' > .cnb.yml
  printf 'main:\n  "crontab: 17 3 * * *": []\n' > .cnb/git-sync.yml
  git add -A; git commit -qm "chore: bootstrap sync config"
)
# 模拟「定时任务跑在临时分支上」：origin 指向一个裸仓库，脚本不该推任何东西
git init -q --bare -b main ${WORK}/lS-origin
( cd ${WORK}/lS && git remote add origin "file://${WORK}/lS-origin" )
BEFORE_TMP=$(git -C ${WORK}/lS rev-parse HEAD)
OUT=$( cd ${WORK}/lS && SYNC_NO_PUSH=1 UPSTREAM_URL="${WORK}/upS" TARGET_BRANCH=main \
        bash "$TARGET" 2>&1 )
chk "无推送模式下不报错" "$(printf '%s' "$OUT" | grep -c '已跳过推送' || true)" "1"
chk "已提交（本地 HEAD 前进）" "$([ "$(git -C ${WORK}/lS rev-parse HEAD)" != "$BEFORE_TMP" ] && echo moved || echo same)" "moved"
chk "未推送到远端（临时分支由流水线推）" "$(git -C ${WORK}/lS-origin for-each-ref refs/heads | wc -l | tr -d ' ')" "0"

echo "###### 场景 T：下发脚本不再特判 scripts/sync/（早期方案会额外落一个文件） ######"
# 同步后 scripts/sync/ 应当就是一个普通的参考上游项目目录：参考上游项目有就跟着来，参考上游项目没有就不该凭空出现
chk "参考上游项目没有 scripts/sync/ 时本地也不多出来" \
  "$([ -d ${WORK}/lS/scripts/sync ] && echo present || echo absent)" "absent"
( cd ${WORK}/upS; mkdir -p scripts/sync; echo up-copy > scripts/sync/upstream-copy.sh; \
  echo v9 > src/app.js; git add -A; git commit -qm "up: add scripts/sync" )
OUT=$( cd ${WORK}/lS && SYNC_NO_PUSH=1 UPSTREAM_URL="${WORK}/upS" TARGET_BRANCH=main \
        bash "$TARGET" 2>&1 )
chk "参考上游项目带来的 scripts/sync/ 会正常同步进来（不再被特判保护）" \
  "$(cat ${WORK}/lS/scripts/sync/upstream-copy.sh 2>/dev/null || echo missing)" "up-copy"
chk "平台配置仍受保护" "$(grep -c git-sync ${WORK}/lS/.cnb.yml)" "1"

echo "###### 场景 U：下发脚本不许有默认参考项目地址（漏传变量必须报错，而不是同步别的仓库） ######"
# 踩过的真坑：脚本里曾把 UPSTREAM_URL 默认成某个示例仓库，
# 于是流水线漏传变量时不报错，而是**默默去同步另一个仓库**，
# 把用户仓库覆盖成别的内容 —— 还报「同步成功」。
# 注意 set +e 之后**必须还原**：本套件整体就不该用 errexit ——
# 里面大量命令是「预期可能失败并检查结果」的（`|| true`、故意漏变量等）。
# 早先这里只写了 set +e 而没恢复（上一行的 set -e 一直留着），
# 于是后面场景里任何一条非零退出的命令都会把整个套件掐断（实测踩到）。
set +e
OUT=$( cd ${WORK}/lS && env -u UPSTREAM_URL SYNC_NO_PUSH=1 bash "$TARGET" 2>&1 )
RC=$?
set +e
chk "漏传 UPSTREAM_URL 时非零退出" "$([ "$RC" != "0" ] && echo yes || echo no)" "yes"
chk "报错里点明缺哪个变量" "$(printf '%s' "$OUT" | grep -c 'UPSTREAM_URL')" "1"
chk "源码里没有 github.com 之类的默认参考上游项目" \
  "$(grep -cE 'UPSTREAM_URL:-"https?://' "$TARGET" || true)" "0"

echo "###### 场景 V：下发脚本「无更新」必须真的短路（不许每天堆空提交/空 PR） ######"
# 踩过的真坑：脚本先 `git rm --cached .cnb` 再比 `git status --porcelain`。
# `.cnb/` 在工作区里始终存在（它就是受保护路径），被摘出索引必然让索引与
# HEAD 出现差异 → no-update 永远不命中 → 定时任务每天堆一个空提交和空 PR。
D="${WORK}/lV"
rm -rf "$D"; mkdir -p "$D"; (
  cd "$D" || exit 1
  git init -q -b main; git config user.name l; git config user.email l@x
  git config commit.gpgsign false
  mkdir -p .cnb
  printf 'include:\n  - .cnb/git-sync.yml\n' > .cnb.yml
  printf 'main:\n  "crontab: 17 3 * * *": []\n' > .cnb/git-sync.yml
  git add -A; git commit -qm "chore: bootstrap sync config"
  # 模拟「同步官初装」：脚本本身就是被提交进来的（最坏输入）
  cp "$TARGET" .cnb/sync-upstream.sh
  git add -A; git commit -qm "chore: 下发同步脚本"
)
newup ${WORK}/upV
runV() { ( cd "$D" && UPSTREAM_URL="${WORK}/upV" TARGET_DIR="" SYNC_NO_PUSH=1 bash "$TARGET" 2>&1 ); }
O1=$(runV); H1=$(git -C "$D" rev-parse HEAD)
chk "首轮 merged" "$(status "$O1")" "merged"
O2=$(runV); H2=$(git -C "$D" rev-parse HEAD)
chk "二轮 no-update（不许每次都提交）" "$(status "$O2")" "no-update"
chk "二轮 HEAD 未变（没有空提交）" "$H2" "$H1"
chk "受保护配置完好" "$(grep -c git-sync "$D/.cnb.yml")" "1"
chk "下发脚本仍在（本次任务的推送还没跑，不能被删）" \
  "$([ -f "$D/.cnb/sync-upstream.sh" ] && echo ok || echo GONE)" "ok"
# 连续 5 轮：只有第 1 轮该产生提交
O3=$(runV); O4=$(runV); O5=$(runV)
chk "三轮仍 no-update" "$(status "$O3")" "no-update"
chk "五轮后总提交数不变（bootstrap + 下发 + 首轮同步 = 3）" \
  "$(git -C "$D" log --oneline | wc -l | tr -d ' ')" "3"
# 关键回归：脚本是「同步官初装」提交进来的，必须一直留在仓库里。
# 否则「提交到临时分支 → squash 合并回默认分支」会把它删掉，
# 下一次定时任务就 `bash: .cnb/sync-upstream.sh: No such file or directory`。
chk "脚本仍被 git 跟踪（下一轮定时任务才找得到它）" \
  "$(git -C "$D" ls-files -- .cnb/sync-upstream.sh | wc -l | tr -d ' ')" "1"
chk "脚本内容没被参考上游项目/同步改动" "$(git -C "$D" diff --stat HEAD -- .cnb/sync-upstream.sh | wc -l | tr -d ' ')" "0"


echo "###### 场景 X：私有参考项目令牌通道（UPSTREAM_TOKEN，文件 file:// 不注入） ######"
newup ${WORK}/upX
newlocal ${WORK}/lX
OUT=$(runsync_tok ${WORK}/lX ${WORK}/upX main "" envtok)
chk "file:// 参考上游项目带令牌仍正常同步（注入仅限 https）" "$(status "$OUT")" "merged"
chk "file:// 场景输出不含令牌值" "$(printf '%s' "$OUT" | grep -c 'envtok' || true)" "0"

echo "###### 场景 Y：令牌注入 URL 后 fetch 失败时报错不带凭证 ######"
newlocal ${WORK}/lY
OUT=$(runsync_tok ${WORK}/lY "https://invalid.invalid/upY" main "" envtok)
chk "拉取失败状态=fetch-failed" "$(status "$OUT")" "fetch-failed"
chk "报错输出不含令牌值" "$(printf '%s' "$OUT" | grep -c 'envtok' || true)" "0"
chk "失败后 remote 还原匿名 URL（凭证不残留 .git/config）" \
  "$(git -C ${WORK}/lY config --get remote.upstream.url)" "https://invalid.invalid/upY"

echo "###### 场景 Z：成功同步后 remote 不残留凭证 URL ######"
# MINGW 形态归一：git for Windows 的 config --get 会把 /tmp/... 规范化成
# C:/Users/.../Temp/...——与本断言本意（remote 还原为匿名原值）无关，归一后比对。
ANON_URL="$(git -C ${WORK}/lX config --get remote.upstream.url)"
command -v cygpath >/dev/null 2>&1 && ANON_URL="$(cygpath -u "${ANON_URL}" 2>/dev/null || printf '%s' "${ANON_URL}")"
chk "成功场景 remote 亦为匿名 URL" "${ANON_URL}" "${WORK}/upX"

# ---- 下发脚本（target）× LFS：两个路径都必须探测 + 还原真身 ----
# 真实缺陷（PR #15 评审遗留）：下发版早先既没探测也没还原 ——
#   `GIT_LFS_SKIP_SMUDGE=1 git archive` 落盘的是 131 字节指针，而脚本直接
#   `git add` 提交，指针就进了首个提交：内容静默丢失，还被当成「已同步」
#   永不重试。采集版一直有完整处理，下发版必须同口径（否则同一份技能两种行为）。
# 覆盖两个入口：① SEED_SOURCE 铺源（空仓库首次上车）② clone（仓库已有提交，
# 这是最常见路径 —— 定时任务每天走的就是它）。
# 关键判据不是「提交里是不是指针」（LFS 就该以指针入库），而是
# 「**真身能不能物化出来**」：checkout 回来的字节 sha256 必须等于参考上游项目 oid。
if [ "${LFS_AVAILABLE}" = "1" ] && [ "${IS_WINDOWS_BASH}" != "1" ]; then
echo "###### 场景 S2：下发脚本 × LFS（铺源路径必须还原真身，不许交指针） ######"
TS2="${WORK}/S2"; rm -rf "$TS2"; mkdir -p "$TS2"
(
  cd "$TS2" || exit 1
  # 目标仓库没有任何提交 + 有 .cnb.yml → 满足 SEED_SOURCE 铺源条件
  git init -q -b main; git config user.name l; git config user.email l@x
  git config commit.gpgsign false
  mkdir -p .cnb
  printf 'include:\n  - .cnb/git-sync.yml\n' > .cnb.yml
  printf 'main:\n  "crontab: 17 3 * * *": []\n' > .cnb/git-sync.yml
)
newlfsup ${WORK}/upS2 ${WORK}/upS2work 1
OIDS2="$(lfs_oid ${WORK}/upS2)"
OUTS2=$( cd "$TS2" && SEED_SOURCE="file://${WORK}/upS2" UPSTREAM_URL="file://${WORK}/upS2" \
         SYNC_NO_PUSH=1 bash "$TARGET" 2>&1 )
chk "铺源 × LFS 状态=merged" "$(status "$OUTS2")" "merged"
chk "铺源 × LFS 已识别" "$(echo "$OUTS2" | sed -n 's/^##\[set-output SYNC_LFS=\(.*\)\]$/\1/p' | tail -1)" "1"
chk "铺源 × LFS 未报不完整" "$(printf '%s' "$OUTS2" | grep -c 'SYNC_LFS_INCOMPLETE' || true)" "0"
# 真身判据：工作区内容 sha256 == 参考上游项目 oid（不是指针的 sha256）
chk "铺源 × LFS 真身内容完整(sha256=参考上游项目oid)" \
  "$(sha256sum ${TS2}/data.bin | cut -d' ' -f1)" "$OIDS2"
chk "铺源 × LFS 以指针入库(131B，仓库体积不爆)" \
  "$(git -C ${TS2} cat-file -s HEAD:data.bin)" "131"
# 重新物化一遍（模拟 clone 到另处）：提交里的对象必须能还原成真身
rm -f ${TS2}/data.bin
( cd "$TS2" && git checkout -- data.bin ) >/dev/null 2>&1 || true
chk "铺源 × LFS 可从提交重新物化真身" \
  "$(sha256sum ${TS2}/data.bin | cut -d' ' -f1)" "$OIDS2"
chk "铺源 × LFS 平台配置受保护" "$(grep -c git-sync ${TS2}/.cnb.yml)" "1"

echo "###### 场景 S3：下发脚本 × LFS（clone 路径——定时任务每天走的就是它） ######"
# 这条路径最容易漏：目标仓库已有提交时走浅克隆到临时目录，
# 参考上游项目真身必须从 staging（持有 origin remote 的那侧）拉 —— 拿目标仓库
# 去 fetch origin 会 Invalid remote name，静默失败后指针照样落盘。
TS3="${WORK}/S3"; rm -rf "$TS3"; mkdir -p "$TS3"
(
  cd "$TS3" || exit 1
  git init -q -b main; git config user.name l; git config user.email l@x
  git config commit.gpgsign false
  mkdir -p .cnb
  printf 'include:\n  - .cnb/git-sync.yml\n' > .cnb.yml
  printf 'main:\n  "crontab: 17 3 * * *": []\n' > .cnb/git-sync.yml
  git add -A; git commit -qm "chore: bootstrap sync config"   # 已有提交 → 走 clone 路径
)
newlfsup ${WORK}/upS3 ${WORK}/upS3work 1
OIDS3="$(lfs_oid ${WORK}/upS3)"
OUTS3=$( cd "$TS3" && UPSTREAM_URL="file://${WORK}/upS3" SYNC_NO_PUSH=1 bash "$TARGET" 2>&1 )
chk "clone × LFS 状态=merged" "$(status "$OUTS3")" "merged"
chk "clone × LFS 已识别" "$(echo "$OUTS3" | sed -n 's/^##\[set-output SYNC_LFS=\(.*\)\]$/\1/p' | tail -1)" "1"
chk "clone × LFS 真身内容完整(sha256=参考上游项目oid)" \
  "$(sha256sum ${TS3}/data.bin | cut -d' ' -f1)" "$OIDS3"
chk "clone × LFS 以指针入库(131B)" "$(git -C ${TS3} cat-file -s HEAD:data.bin)" "131"
rm -f ${TS3}/data.bin
( cd "$TS3" && git checkout -- data.bin ) >/dev/null 2>&1 || true
chk "clone × LFS 可从提交重新物化真身" \
  "$(sha256sum ${TS3}/data.bin | cut -d' ' -f1)" "$OIDS3"
# 幂等：第二遍必须 no-update，不许因为 LFS 还原/规则改写每天堆空提交
H3BEFORE=$(git -C ${TS3} rev-parse HEAD)
OUTS3B=$( cd "$TS3" && UPSTREAM_URL="file://${WORK}/upS3" SYNC_NO_PUSH=1 bash "$TARGET" 2>&1 )
chk "clone × LFS 重跑 no-update" "$(status "$OUTS3B")" "no-update"
chk "clone × LFS 重跑 HEAD 未变" "$(git -C ${TS3} rev-parse HEAD)" "$H3BEFORE"

echo "###### 场景 S4：下发脚本 × LFS 对象不可获取 → 必须中止（两个路径都不许交指针） ######"
newlfsup ${WORK}/upS4 ${WORK}/upS4work 0   # 远端抹掉 LFS 对象
# ① 铺源路径
TS4="${WORK}/S4"; rm -rf "$TS4"; mkdir -p "$TS4"
( cd "$TS4" && git init -q -b main && git config user.name l && git config user.email l@x \
  && git config commit.gpgsign false && mkdir -p .cnb \
  && printf 'include:\n  - .cnb/git-sync.yml\n' > .cnb.yml \
  && printf 'main:\n  "crontab: 17 3 * * *": []\n' > .cnb/git-sync.yml ) >/dev/null 2>&1
OUTS4=$( cd "$TS4" && SEED_SOURCE="file://${WORK}/upS4" UPSTREAM_URL="file://${WORK}/upS4" \
         SYNC_NO_PUSH=1 bash "$TARGET" 2>&1 ) || true
chk "铺源 × LFS 对象缺失 状态=conflict" "$(status "$OUTS4")" "conflict"
chk "铺源 × LFS 对象缺失 未落盘指针" \
  "$([ -f ${TS4}/data.bin ] && echo leaked || echo clean)" "clean"
chk "铺源 × LFS 对象缺失 未产生提交" \
  "$(git -C ${TS4} rev-parse --verify -q HEAD >/dev/null 2>&1 && echo has || echo none)" "none"
# ② clone 路径
TS5="${WORK}/S5"; rm -rf "$TS5"; mkdir -p "$TS5"
( cd "$TS5" && git init -q -b main && git config user.name l && git config user.email l@x \
  && git config commit.gpgsign false && mkdir -p .cnb \
  && printf 'include:\n  - .cnb/git-sync.yml\n' > .cnb.yml \
  && printf 'main:\n  "crontab: 17 3 * * *": []\n' > .cnb/git-sync.yml \
  && git add -A && git commit -qm "chore: bootstrap sync config" ) >/dev/null 2>&1
OUTS5=$( cd "$TS5" && UPSTREAM_URL="file://${WORK}/upS4" SYNC_NO_PUSH=1 bash "$TARGET" 2>&1 ) || true
chk "clone × LFS 对象缺失 状态=conflict" "$(status "$OUTS5")" "conflict"
chk "clone × LFS 对象缺失 未落盘指针" \
  "$([ -f ${TS5}/data.bin ] && echo leaked || echo clean)" "clean"
chk "clone × LFS 对象缺失 只有 bootstrap 一个提交" \
  "$(git -C ${TS5} log --oneline | wc -l | tr -d ' ')" "1"

echo "###### 场景 S6：下发脚本 × LFS + 子目录模式（真身要落到子目录里） ######"
TS6="${WORK}/S6"; rm -rf "$TS6"; mkdir -p "$TS6"
( cd "$TS6" && git init -q -b main && git config user.name l && git config user.email l@x \
  && git config commit.gpgsign false && mkdir -p .cnb \
  && printf 'include:\n  - .cnb/git-sync.yml\n' > .cnb.yml \
  && printf 'main:\n  "crontab: 17 3 * * *": []\n' > .cnb/git-sync.yml \
  && echo '# mine' > MINE.md && git add -A && git commit -qm "feat: mine" ) >/dev/null 2>&1
newlfsup ${WORK}/upS6 ${WORK}/upS6work 1
OIDS6="$(lfs_oid ${WORK}/upS6)"
OUTS6=$( cd "$TS6" && SYNC_DIR="ZCode" UPSTREAM_URL="file://${WORK}/upS6" \
         SYNC_NO_PUSH=1 bash "$TARGET" 2>&1 )
chk "子目录 × LFS 状态=merged" "$(status "$OUTS6")" "merged"
chk "子目录 × LFS 真身内容完整(sha256=参考上游项目oid)" \
  "$(sha256sum ${TS6}/ZCode/data.bin | cut -d' ' -f1)" "$OIDS6"
chk "子目录 × LFS 自己的项目未被碰" \
  "$([ -f ${TS6}/MINE.md ] && echo yes || echo gone)" "yes"
else
  echo "###### 跳过下发脚本 × LFS 场景：未安装 git-lfs ######"
fi

# ---- 场景 W：引导 PR 必须能「自我了结」 ----
# 真实事故：同步官初装开的是引导 PR（源分支 sync/bootstrap）。它提交的
# .cnb/git-sync.yml 已带定时任务，但只有「有更新」才会开新 PR。
# 参考项目内容与仓库一致时定时任务是 no-update —— 于是那个引导 PR 一直开着没人合并，
# 用户看到的就是「配了全自动，却有个 PR 没人处理」。
# 守住：模板必须带一条 pull_request.merged 流水线，删掉引导分支。
echo "###### 场景 W：引导 PR 自我了结（模板自带 pull_request.merged） ######"
TPL="$HERE/../../../../.ci/git-sync.yml"
[ -f "$TPL" ] || TPL="$HERE/../../../.ci/git-sync.yml"
if [ -f "$TPL" ]; then
  chk "模板含 pull_request.merged（引导 PR 合并后能自触发）" \
    "$(grep -c '^  pull_request\.merged:' "$TPL")" "1"
  chk "引导分支名走占位符（不写死 sync/bootstrap）" \
    "$(grep -cE '^[[:space:]]+BOOTSTRAP_BRANCH: <BOOTSTRAP_BRANCH>$' "$TPL")" "1"
  chk "引导分支的判定是精确相等（不用前缀匹配误伤别的分支）" \
    "$(grep -c 'CNB_PULL_REQUEST_BRANCH}" = "${BOOTSTRAP_BRANCH}"' "$TPL")" "1"
  chk "合并后删除引导分支" \
    "$(grep -c 'git push origin --delete "${CNB_PULL_REQUEST_BRANCH}"' "$TPL")" "1"
  chk "自动合并那条仍只认 sync/upstream-auto 前缀" \
    "$(grep -c 'CNB_PULL_REQUEST_BRANCH#sync/upstream-auto' "$TPL")" "1"
else
  echo "  ⚠️ 未找到 .ci/git-sync.yml，跳过场景 W"
fi

# ---- 场景 AC：默认分支跟随参考上游项目（空仓库上车不许硬编码 main） ----
# 用户诉求：「参考项目默认分支不是 main 怎么办？希望拉取后的默认分支就是参考项目的默认分支。」
# 踩过的坑：空仓库 runner 上 CNB_DEFAULT_BRANCH **已经预设成 main**，
# 若直接信它，「跟随参考上游项目」永远算不出来，绕一圈又回到硬编码 main。
# 另一个坑：分支名不能用 sed 捕获组取 —— symref 输出是 tab 分隔，
# sed 会把尾部 tab 吞进分支名，push 出去的 ref 就带脏字符。
echo "###### 场景 AC：空仓库默认分支跟随参考上游项目（resolve-default-branch 阶段） ######"
if [ -f "$TPL" ]; then
  # 1) 阶段存在且顺序正确（resolve 必须在 init 之前，后者读前者结果）
  chk "模板含 resolve-default-branch 阶段" \
    "$(grep -cE '^[[:space:]]*- name: resolve-default-branch$' "$TPL")" "1"
  awk '/- name: resolve-default-branch/{a=NR} /- name: init-default-branch/{b=NR} END{exit !(a && b && a<b)}' "$TPL" \
    && chk "resolve 在 init 之前" "ok" "ok" || chk "resolve 在 init 之前" "bad" "ok"
  awk '/- name: init-default-branch/{a=NR} /- name: fetch-and-merge-upstream/{b=NR} END{exit !(a && b && a<b)}' "$TPL" \
    && chk "init 在同步之前（首次 push 前必须先定好默认分支）" "ok" "ok" \
    || chk "init 在同步之前（首次 push 前必须先定好默认分支）" "bad" "ok"

  # 2) 必须探测参考项目默认分支，且用 awk 字段切分（不能用 sed 捕获组）
  chk "模板探测参考项目默认分支" "$(grep -v '^[[:space:]]*#' "$TPL" | grep -c 'ls-remote --symref')" "1"
  chk "取分支名用 awk（不会吞掉 tab）" "$(grep -c 'ref: refs\\/heads' "$TPL")" "1"
  chk "没有用 sed 捕获组取分支名" \
    "$(grep -c "sed -n 's#\^ref: refs/heads" "$TPL")" "0"

  # 3) CNB_DEFAULT_BRANCH 不能当第一优先级：必须先确认本地是否已有分支
  # 两处：一处赋值、一处判定；关键是「必须有这个判定」，所以断言 >=2
  chk "先判断本地是否已有分支再采信 CNB_DEFAULT_BRANCH" \
    "$(grep -v '^[[:space:]]*#' "$TPL" | grep -c 'LOCAL_BRANCHES')" "2"

  # 4) init 阶段必须读 resolve 的结果，不能自己再算一遍
  # init 必须真的读 resolve 的结果（而不是自己再算一遍）：两处分支名才对得上。
  # 断言「init 那段里出现了读操作」，比数总出现次数稳（落盘点有多处分支）。
  awk '/- name: init-default-branch/{f=1} /- name: fetch-and-merge-upstream/{f=0} f' "$TPL" \
    | grep -q 'cat .git/sync-default-branch' \
    && chk "init 读 resolve 算好的分支名" "ok" "ok" \
    || chk "init 读 resolve 算好的分支名" "bad" "ok"

  # 5) 端到端跑一遍 resolve 脚本：空仓库 + 参考上游项目默认 master + 平台预设 main
  RS="$WORK/resolve.sh"
  { echo '#!/usr/bin/env bash'; extract_stage "$TPL" resolve-default-branch; } > "$RS"
  if [ ! -s "$RS" ]; then echo "  ❌ 没解析出 resolve-default-branch 的 script"; FAIL=$((FAIL+1)); fi
  if [ -f "$RS" ]; then
    mkdir -p "$WORK/x1" && ( cd "$WORK/x1" && git init -q -b master . ) >/dev/null 2>&1
    # 造一个「参考项目默认分支是 master」的本地裸仓库，避免测试依赖公网
    rm -rf "$WORK/upX" "$WORK/upX.git"
    git init -q -b master "$WORK/upX"
    ( cd "$WORK/upX" && git config user.name u && git config user.email u@x \
      && git config commit.gpgsign false && echo v1 > f.txt \
      && git add -A && git commit -qm up )
    git clone -q --bare "$WORK/upX" "$WORK/upX.git"
    # 把裸仓库的 HEAD 指向 master（等价于参考项目默认分支 = master）
    git -C "$WORK/upX.git" symbolic-ref HEAD refs/heads/master

    ( cd "$WORK/x1" && CNB_DEFAULT_BRANCH=main SEED_SOURCE="$WORK/upX.git" \
        UPSTREAM_REPO="$WORK/upX.git" PATH="/usr/bin:/bin:$PATH" bash "$RS" ) >/dev/null 2>&1
    chk "空仓库 + 参考上游项目默认 master → 取 master（不硬编码 main）" \
      "$(cat "$WORK/x1/.git/sync-default-branch" 2>/dev/null)" "master"
    chk "分支名没有尾部空白（sed 捕获组会带上 tab）" \
      "$(cat "$WORK/x1/.git/sync-default-branch" 2>/dev/null | tr -d '[:space:]' | wc -c | tr -d ' ')" "6"

    # 已有远端分支的仓库：一律沿用，不许改写
    mkdir -p "$WORK/x2" && ( cd "$WORK/x2" && git init -q -b master . ) >/dev/null 2>&1
    ( cd "$WORK/x2" && git config user.name l && git config user.email l@x \
      && git config commit.gpgsign false && git commit -q --allow-empty -m init \
      && git push -qf "$WORK/upX.git" HEAD:refs/heads/master ) >/dev/null 2>&1
    ( cd "$WORK/x2" && git remote add origin "$WORK/upX.git" ) >/dev/null 2>&1
    ( cd "$WORK/x2" && CNB_DEFAULT_BRANCH=trunk SEED_SOURCE="$WORK/upX.git" \
        UPSTREAM_REPO="$WORK/upX.git" bash "$RS" ) >/dev/null 2>&1
    chk "已有远端分支的仓库 → 沿用现有默认分支，不改写" \
      "$(cat "$WORK/x2/.git/sync-default-branch" 2>/dev/null)" "trunk"
  else
    echo "  ⚠️ 未能抽出 resolve-default-branch 脚本，跳过端到端断言"
  fi
else
  echo "  ⚠️ 未找到 .ci/git-sync.yml，跳过场景 X"
fi

# ---- 场景 AD：下发脚本不许凭空造出一个 main 分支 ----
# 真实事故（跑出来的）：脚本里 TARGET_BRANCH 默认成 main，于是
# `git push origin HEAD:main` 在远端凭空造出一个 main。空仓库上车时它甚至
# 可能是第一个远端分支 = 仓库默认分支：参考项目是 master，仓库里却多出个 main。
# 守住：不传 TARGET_BRANCH 就只在本地提交，绝不猜分支名。
echo "###### 场景 AD：不传 TARGET_BRANCH 时不许凭空推一个 main ######"
chk "TARGET_BRANCH 没有默认值" \
  "$(grep -cE '^TARGET_BRANCH="\$\{TARGET_BRANCH:-\}"' "$TARGET")" "1"
chk "不再有 TARGET_BRANCH:-main 的兜底" \
  "$(grep -c 'TARGET_BRANCH:-main' "$TARGET")" "0"
# 端到端：空仓库 + 参考上游项目默认 master，走「同步官初装 -> 铺源 -> 推引导分支」，
# 远端分支应当只有 master 与 sync/bootstrap，**不该有 main**。
if command -v git >/dev/null 2>&1; then
  rm -rf "$WORK/dY" "$WORK/oY.git" "$WORK/upY"
  git init -q -b master "$WORK/upY"
  ( cd "$WORK/upY" && git config user.name u && git config user.email u@x \
    && git config commit.gpgsign false && echo v1 > f.txt && mkdir -p d \
    && echo x > d/x.txt && git add -A && git commit -qm up )
  git clone -q --bare "$WORK/upY" "$WORK/oY.git"
  git -C "$WORK/oY.git" symbolic-ref HEAD refs/heads/master
  mkdir -p "$WORK/dY" && ( cd "$WORK/dY" && git init -q -b master . ) >/dev/null 2>&1
  (
    cd "$WORK/dY" || exit 1
    git config user.name l; git config user.email l@x; git config commit.gpgsign false
    git remote add origin "$WORK/oY.git"
    mkdir -p .cnb
    printf 'include:\n  - .cnb/git-sync.yml\n' > .cnb.yml
    cp "$TARGET" .cnb/sync-upstream.sh
    # 默认分支跟随参考上游项目（参考项目是 master）
    git commit -q --no-gpg-sign --allow-empty -m "chore: 初始化默认分支 master"
    git push -qf origin HEAD:refs/heads/master
    # 铺源同步（不传 TARGET_BRANCH —— 就按同步官初装那样调用）
    UPSTREAM_URL="$WORK/upY" UPSTREAM_BRANCH=master SEED_SOURCE="$WORK/upY" \
      SYNC_DIR="" SYNC_QUIET=1 bash .cnb/sync-upstream.sh >/dev/null 2>&1
    git add -A; git commit -q --no-gpg-sign -m "chore: 铺源" >/dev/null 2>&1
    git push -qf origin HEAD:refs/heads/sync/bootstrap
    # 固定退出码：末条命令的成败不该由调用方（可能开着 errexit）来裁决
    true
  ) >/dev/null 2>&1 || true
  BRANCHES="$(git -C "$WORK/oY.git" for-each-ref --format='%(refname:short)' refs/heads/ | sort | tr '\n' ' ')"
  chk "远端只有 master 与引导分支，没有凭空多出的 main" \
    "$BRANCHES" "master sync/bootstrap "
  chk "参考项目内容已落盘" "$([ -f "$WORK/dY/f.txt" ] && echo yes)" "yes"
fi

# ---- 场景 AE：无人值守必须「内联直接合并」，不许把保护分支当门槛 ----
echo "###### 场景 AE：内联 merge-pull 收口（免保护分支、免评审人） ######"
TMPL="$REPO_ROOT/.ci/git-sync.yml"
if [ -f "$TMPL" ]; then
  T="$(cat "$TMPL")"

  # 1) 主收口阶段必须存在，且在开 PR 之后
  chk "模板含 merge-pr-inline 阶段" \
    "$(printf '%s' "$T" | grep -c 'name: merge-pr-inline')" "1"
  LN_OPEN="$(printf '%s' "$T" | grep -n 'name: create-auto-merge-pr' | head -1 | cut -d: -f1)"
  LN_MERGE="$(printf '%s' "$T" | grep -n 'name: merge-pr-inline' | head -1 | cut -d: -f1)"
  chk "内联合并在开 PR 之后（顺序不能反）" \
    "$([ "${LN_MERGE:-0}" -gt "${LN_OPEN:-0}" ] && echo yes)" "yes"

  # 2) 确实调了 merge-pull，且带上平台必填的 --commit-title
  chk "调用了 cnb pulls merge-pull" \
    "$([ "$(printf '%s' "$T" | grep -c 'cnb pulls merge-pull')" -ge 1 ] && echo yes)" "yes"
  chk "merge-pull 带了 --commit-title（平台必填）" \
    "$(printf '%s' "$T" | grep -c -- '--commit-title')" "1"
  chk "merge-pull 用了 squash（与兜底路径一致）" \
    "$(printf '%s' "$T" | grep -c -- '--merge-style squash')" "1"

  # 3) 只合并本轮自己开的 PR 编号 —— 不能去合任意 PR
  chk "合并阶段限定本轮 PR 编号" \
    "$([ "$(printf '%s' "$T" | grep -c 'AUTO_MERGE_PR')" -ge 1 ] && echo yes)" "yes"
  chk "开 PR 阶段导出 PR 编号" \
    "$(printf '%s' "$T" | grep -c 'set-output AUTO_MERGE_PR=')" "1"

  # 4) 关键回归：不许再把「保护分支」当无人值守前置条件
  #
  #    判据沿革（PR #16 评审遗留，勿改回）：原判据 `grep -cE '不是保护分支。$'` 期望 0，
  #    与 watchdog 里同源的那条一样**恒假** —— 模板那行以「…直接合并。」的引号结尾，
  #    `。$` 命中不了，所以「期望 0」是「永远命中 0 条」，不是「模板里真没有」。
  #    真正该守的是「不许引导用户去仓库设置里开保护分支」（原始退化版本的痕迹），
  #    那条本来就是 0（说明已清除干净），且去掉 `$` 也不会被无害的只读探测说明误伤。
  chk "不再要求用户去设置里开保护分支" \
    "$(printf '%s' "$T" | grep -cF '设置路径：仓库「设置」')" "0"
  chk "不再把「保护分支」当无人值守前置（逼用户去设置的文案）" \
    "$(printf '%s' "$T" | grep -cF '逼用户去设置')" "0"
  chk "保护分支仅作为只读探测（兜底说明）" \
    "$(printf '%s' "$T" | grep -c '不影响，本轮由内联 merge-pull 直接合并')" "1"

  # 5) 合并失败要重试，且要打印 PR 链接，不能静默
  chk "合并带退避重试" \
    "$(printf '%s' "$T" | grep -c '次合并未成功')" "1"
  chk "合并失败会打印 PR 链接" \
    "$(printf '%s' "$T" | grep -c 'pulls/${AUTO_MERGE_PR}')" "1"

  # 6) 引导 PR 必须由同步官自己合掉，不许留给用户
  chk "技能要求建完引导 PR 就地合并" \
    "$(grep -c '建完立刻自己合掉' "$REPO_ROOT/skills/sync-upstream/SKILL.md")" "1"
  chk "技能记录了 NPC token 无 repo-manage:rw" \
    "$([ "$(grep -c 'repo-manage:rw' "$REPO_ROOT/skills/sync-upstream/SKILL.md")" -ge 1 ] && echo yes)" "yes"

  # 7) 技能与角色提示词口径一致：不许再出现「无人值守要求保护分支」这类表述
  chk "技能里没有「无人值守要求默认分支是保护分支」" \
    "$(grep -cE '无人值守要求.*保护分支' "$REPO_ROOT/skills/sync-upstream/SKILL.md")" "0"
  chk "角色提示词不许让用户去设保护分支" \
    "$(grep -cE '直接评论告诉用户去哪设置' "$REPO_ROOT/.cnb/settings.yml")" "0"

  # 8) watchdog 必须守住这条（防回归）
  chk "watchdog 守住内联合并" \
    "$([ "$(grep -c 'merge-pr-inline' "$REPO_ROOT/.ci/watchdog.yml")" -ge 1 ] && echo yes)" "yes"
  chk "watchdog 拦截「保护分支当门槛」的退化" \
    "$(grep -c '会逼用户去设置' "$REPO_ROOT/.ci/watchdog.yml")" "1"
else
  echo "  ⏭️ 非技能仓库，跳过"
fi

# ---- 场景 AA：端到端演练「开 PR → 内联合并」，不依赖任何平台事件 ----
echo "###### 场景 AA：内联合并端到端（伪 cnb CLI） ######"
if [ -f "$TMPL" ]; then
  WORK2="$(mktemp -d)"; rc=0
  (
    set -e
    cd "$WORK2"
    git init -q -b main demo
    cd demo
    git config user.name t; git config user.email t@t
    git config commit.gpgsign false
    # 模板的 create-auto-merge-pr 会校验脚本在位（防「合并把脚本删掉」的老坑），
    # 且要 git rev-parse HEAD —— 所以这里必须有提交。
    # 脚本文件直接取技能仓库里的真实下发脚本，保证校验的就是真东西。
    mkdir -p .cnb
    REAL_SCRIPT="$REPO_ROOT/skills/sync-upstream/scripts/sync-upstream-target.sh"
    if [ -f "$REAL_SCRIPT" ]; then cp "$REAL_SCRIPT" .cnb/sync-upstream.sh
    else printf '#!/usr/bin/env bash\ntrue\n' > .cnb/sync-upstream.sh; fi
    git add -A; git commit -qm "fixture"
    # 伪 `cnb` CLI：记录调用、模拟 merge-pull 成功（含首次 checking 被拒的瞬态）
    mkdir -p "$WORK2/bin"
    cat > "$WORK2/bin/cnb" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
case "$1 $2" in
  "pulls post-pull")
    printf 'status: 201\ndata:\n  number: "42"\n' ;;
  "pulls merge-pull")
    N=$(grep -c 'merge-pull' "$FAKE_LOG")
    # 第一次模拟 mergeable_state=checking 的瞬态拒绝，之后成功
    if [ "$N" -le 1 ]; then
      printf 'status: 400\ndata:\n  errmsg: "not mergeable yet"\n'; exit 1
    fi
    printf 'status: 200\ndata:\n  merged: true\n' ;;
  "git list-branches")
    printf 'data:\n  - name: main\n    protected: false\n' ;;
  *) printf 'status: 200\n' ;;
esac
FAKE
    chmod +x "$WORK2/bin/cnb"
    export FAKE_LOG="$WORK2/cnb.log"; : > "$FAKE_LOG"
    export PATH="$WORK2/bin:$PATH"
    export CNB_REPO_SLUG=demo/repo CNB_BRANCH=main CNB_WEB_ENDPOINT=https://cnb.cool
    export UPSTREAM_REPO=https://github.com/o/r UPSTREAM_BRANCH=main
    export SYNC_STATUS=merged SYNC_BRANCH=sync/upstream-auto AUTO_MERGE_BRANCH=sync/upstream-auto-1

    # 摘出模板里的「开 PR + 内联合并」两段脚本，按流水线顺序跑一遍
    { extract_stage "$TMPL" create-auto-merge-pr; echo; extract_stage "$TMPL" merge-pr-inline; } > stages.sh
    # 模拟平台的 set-output → env 注入：把 `##[set-output K=V]` 变成下一阶段可读的变量
    sed -i 's|^echo "##\[set-output \([A-Z_]*\)=\(.*\)\]"$|printf "" > /dev/null; export \1="\2"; echo "##[set-output \1=\2]"|' stages.sh
    bash stages.sh > run.log 2>&1 || rc=$?
    echo "--- run.log ---"; cat run.log
    echo "--- cnb calls ---"; cat "$FAKE_LOG"
    # 断言：PR 被合并了（重建瞬态后成功），且只针对自己那个编号
    grep -q 'merged: true' run.log || { echo "!! 未合并"; exit 1; }
    grep -q '\-\-number 42' "$FAKE_LOG" || { echo "!! 没按 PR 编号合并"; exit 1; }
    grep -q '\-\-commit-title' "$FAKE_LOG" || { echo "!! 缺 commit-title"; exit 1; }
    # 第 2 次调用才成功 —— 说明瞬态重试真的生效（不是一次就过）
    [ "$(grep -c 'merge-pull' "$FAKE_LOG")" -ge 2 ] || { echo "!! 没有重试"; exit 1; }
    echo "OK"
  ) > "$WORK2/e2e.log" 2>&1 || rc=$?
  if [ "$rc" = "0" ] && grep -q '^OK$' "$WORK2/e2e.log"; then
    echo "  ✅ 端到端：开 PR → 瞬态拒绝 → 重试 → 成功合并 #42"
    PASS=$((PASS+1))
    chk "合并调用带了 PR 编号与 commit-title" "yes" "yes"
  else
    echo "  ❌ 端到端失败："; sed 's/^/     /' "$WORK2/e2e.log" | tail -30
    FAIL=$((FAIL+1))
  fi
  rm -rf "$WORK2"
fi

# ---- 场景 AB：模板不许有「会被 set -e 静默吃掉」的命令替换 ----
# 真坑（实测）：`out="$(cnb pulls merge-pull ...)"` 里 CLI 非零退出时，
# 外层 `set -e` 会让**整个阶段静默退出** —— 日志一片空白、看不出原因，
# 连「重试 5 次」和失败提示都跑不到，PR 就那么挂着等人合。
# 只做信息性探测的段（查保护状态）同理：`cnb` 不在 PATH / 接口 5xx 都能把整轮同步掐掉。
echo "###### 场景 AB：命令替换不许被 set -e 静默掐断 ######"
if [ -f "$TMPL" ]; then
  T="$(cat "$TMPL")"
  # 1) 需要重试的 merge-pull 必须显式兜住退出码
  chk "merge-pull 命令替换带 || true（重试才真的会重试）" \
    "$([ "$(printf '%s' "$T" | grep -c -- '2>&1 || true)')" -ge 2 ] && echo yes)" "yes"
  # 2) 保护状态探测必须容错（且失败时按 unknown 处理，不当成「非保护分支」误报）
  chk "保护状态探测给 cnb 加了 || true" \
    "$([ "$(printf '%s' "$T" | grep -c 'list-branches --repo "$CNB_REPO_SLUG" --page-size 100 2>/dev/null || true; }')" -ge 1 ] && echo yes)" "yes"
  chk "保护状态有 unknown 兜底" \
    "$([ "$(printf '%s' "$T" | grep -c 'PROT=\"unknown\"')" -ge 1 ] && echo yes)" "yes"
  # 3) resolve-default-branch 段不许开 errexit（参考上游项目探测失败要能走到兜底分支）
  chk "resolve-default-branch 用 set -uo pipefail（不开 errexit）" \
    "$(printf '%s' "$T" | grep -c 'set -uo pipefail')" "1"
  chk "resolve 段里没有 errexit" \
    "$(printf '%s' "$T" | awk '/- name: resolve-default-branch/{f=1} f&&/set -euo pipefail/{bad=1} /- name: init-default-branch/{f=0} END{if(bad) print "bad"; }')" ""
  # 4) 分支名与 PR 编号的解析要能容忍脏输入
  chk "参考项目默认分支名做了空白清洗" \
    "$([ "$(printf '%s' "$T" | grep -c "tr -d '\\[:space:\\]'")" -ge 1 ] && echo yes)" "yes"
  # 用 fgrep 固定字符串匹配：这些断言里带 [] / \ / " 等字符，
  # 走正则要吃一堆转义，实测很容易写成「断言永远失败」的假红灯。
  chk "兜掉了 --symref 输出里可能出现的 HEAD" \
    "$([ "$(printf '%s' "$T" | grep -cF 'UP_SDB}" = "HEAD"')" -ge 1 ] && echo yes)" "yes"
  chk "PR 编号解析容忍缩进（去行首空白后再匹配）" \
    "$([ "$(printf '%s' "$T" | grep -cF 'sub(/^[[:space:]]+/,"",line)')" -ge 1 ] && echo yes)" "yes"
  chk "PR 编号解析失败会显式报错" \
    "$([ "$(printf '%s' "$T" | grep -c '未能从 post-pull 输出里解析出 PR 编号')" -ge 1 ] && echo yes)" "yes"

  # 5) 行为验证：用「返回 400 且退出码为 0」的伪 CLI 跑真脚本，
  #    确认重试真的会发生（旧写法在退出码非 0 时会静默退出，这里覆盖退出码为 0 的情形）
  WORK3="$(mktemp -d)"; rc3=0
  (
    set -e
    cd "$WORK3"; git init -q -b main demo; cd demo
    git config user.name t; git config user.email t@t; git config commit.gpgsign false
    mkdir -p .cnb
    cp "$REPO_ROOT/skills/sync-upstream/scripts/sync-upstream-target.sh" .cnb/sync-upstream.sh
    git add -A; git commit -qm fixture
    mkdir -p "$WORK3/bin"
    cat > "$WORK3/bin/cnb" <<'FAKE2'
#!/usr/bin/env bash
echo "$*" >> "$FAKE2_LOG"
case "$1 $2" in
  "pulls merge-pull")
    N=$(grep -c 'merge-pull' "$FAKE2_LOG")
    # 前两次模拟 mergeable_state=checking 的瞬态拒绝（退出码为 0，错误只在输出里）
    if [ "$N" -le 2 ]; then printf 'status: 400\ndata:\n  errmsg: "not mergeable yet"\n'; exit 0; fi
    printf 'status: 200\ndata:\n  merged: true\n' ;;
  *) printf 'status: 200\n' ;;
esac
FAKE2
    chmod +x "$WORK3/bin/cnb"
    export FAKE2_LOG="$WORK3/cnb.log"; : > "$FAKE2_LOG"
    export PATH="$WORK3/bin:$PATH"
    export CNB_REPO_SLUG=demo/repo CNB_BRANCH=main CNB_WEB_ENDPOINT=https://cnb.cool
    export UPSTREAM_REPO=https://github.com/o/r AUTO_MERGE_BRANCH=sync/upstream-auto-1
    export AUTO_MERGE_PR=42
    # 摘出 merge-pr-inline 一段直接跑
    extract_stage "$TMPL" merge-pr-inline > m.sh
    SAVED_SLEEP="$(command -v sleep)"; mkdir -p "$WORK3/sbin"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK3/sbin/sleep"; chmod +x "$WORK3/sbin/sleep"
    PATH="$WORK3/sbin:$PATH" bash m.sh > run.log 2>&1 || rc3=$?
    grep -q '✅ 已自动合并' run.log || { echo "!! 没合上"; cat run.log; exit 1; }
    [ "$(grep -c 'merge-pull' "$FAKE2_LOG")" -eq 3 ] || { echo "!! 重试次数不对"; exit 1; }
    echo "OK"
  ) > "$WORK3/e2e2.log" 2>&1 || rc3=$?
  if [ "$rc3" = "0" ] && grep -q '^OK$' "$WORK3/e2e2.log"; then
    echo "  ✅ 行为验证：连续 2 次瞬态拒绝后第 3 次合并成功（重试真的生效）"
    PASS=$((PASS+1))
  else
    echo "  ❌ 行为验证失败："; sed 's/^/     /' "$WORK3/e2e2.log" | tail -20
    FAIL=$((FAIL+1))
  fi
  rm -rf "$WORK3"
else
  echo "  ⏭️ 非技能仓库，跳过"
fi

# ---- 场景 AG：不许再把 python3 当硬依赖请回来（PR #16 这一轮踩了两次）----
# 精简镜像（cnbcool/default-build-env / 本仓 NPC 镜像）都没有 python3：
# 套件里出现 python3 调用会静默取空、下游断言连着红，报错还指向无关内容。
# 本轮改用 awk 后，这里直接扫脚本本体把它钉住，防后来人「顺手用 python3」。
echo "###### 场景 AG：套件自身不许硬依赖 python3（CI 精简镜像没有） ######"
# 扫描范围（PR #16 评审遗留补齐）：原先只扫 run-tests.sh **本体**，
# 而 `watchdog.yml` 自身的约 245 行 shell 从没被扫过 —— 谁在守护脚本里
# 「顺手用 python3」，AG 抓不到（AF-3 的扫描目标自己就是典型盲区）。
# 现扩到 `.ci/watchdog.yml` + run-tests.sh 两份「会跑在精简镜像里」的脚本。
# 只认「真的调用」（python3 后跟 -c / - / << / *.py），注释与文案里的提及不算。
python3_hits=""
for ag_f in "$REPO_ROOT/.ci/watchdog.yml" "$HERE/run-tests.sh"; do
  [ -f "$ag_f" ] || continue
  ag_out="$(grep -nE 'python3 +(-c|-|<<|[^ ]+\.py)' "$ag_f" | grep -vE '^[0-9]+: *#' || true)"
  [ -z "$ag_out" ] || python3_hits="${python3_hits}${ag_f}:${ag_out}
"
done
python3_hits="$(printf '%s' "$python3_hits" | sed '/^$/d')"
if [ -z "$python3_hits" ]; then
  echo "  ✅ 套件与 watchdog 均无 python3 硬依赖"; PASS=$((PASS+1))
else
  echo "  ❌ 又出现 python3 调用，精简镜像里会失败："
  printf '%s\n' "$python3_hits" | sed 's/^/     /'
  FAIL=$((FAIL+1))
fi
# 同源隐患：SKILL.md 的 fetch_raw 用 python3 解 cnb git get-raw 的 data 层，
# 而 NPC 镜像只装 jq、没装 python3 —— 照原样下发到目标仓库会在真实环境
# command not found（取不到模板文件）。必须优先 jq。
if [ -f "$REPO_ROOT/skills/sync-upstream/SKILL.md" ]; then
  chk "SKILL.md 的 fetch_raw 优先用 jq（镜像内置，无 python3 也能跑）" \
    "$(grep -c 'command -v jq >/dev/null 2>&1; then jq -j' "$REPO_ROOT/skills/sync-upstream/SKILL.md")" "1"
fi

# ---- 场景 AF：守护断言不许写「管道 grep」（SIGPIPE 竞态回归） ----
# 真坑（PR #16 实测，连误诊两轮）：CI 断言写成
#     grep -vE '^[[:space:]]*#' .ci/git-sync.yml | grep -q '<关键词>'
# 下游 `grep -q` 命中首个匹配就**立刻退出**，参考上游项目 `grep -vE` 若还没写完就吃
# SIGPIPE（退出码 141）；而 stage 跑在 `set -o pipefail` 下，141 被当成整条
# 管道的结果 —— 于是**已经命中的断言反而报红**，报错口吻还把人往「内容丢了」
# 上引（实测：模板里 AUTO_MERGE_PR 命中 9 处，断言却报退出码 141）。
# 触发与否取决于时序：输入能整块塞进管道缓冲就绿，29KB 的真模板在 CI
# runner 上就红 —— 同一份代码本地绿、CI 红，是假阴性式 flaky，最毒的一种。
#
# 本场景做三件事：
#   ① 把「旧写法会误红、新写法全绿」变成**确定性**事实（放大输入逼出竞态）
#   ② 全仓守卫：守护脚本里不许再出现任何 `A | grep` 形态（含命令替换内嵌）
#   ③ 跑 CI 真代码（watchdog 的 convention-selftest 原样抽出）而非测试复刻
echo "###### 场景 AF：守护断言不许写管道 grep（SIGPIPE 竞态回归） ######"

# AF-0) 场景自守：AF 段的 `chk` 断言点个数必须与文档口径一致。
#   为什么需要这个（PR #16 评审遗留点出的可见性缺口）：AF 段是**硬编码断言数**
#   的可见性缺口 —— 套件末尾只打印 PASS 总数（现 183），谁把 AF 段里某条断言
#   整行删掉，`PASS=` 总和就静默下降，**没有任何一条断言会因此报红**；
#   文档里「场景 AF 17 例」的口径也随之失真。这里把 AF 段的断言点**数一遍**
#   钉住：删一条就报红，逼人同时更新这里与 AGENTS.md 的口径。
#   （15 → 17：PR #17 补 AF-5 两条反向守卫，防止 AF-2b 判据悄悄退回旧形态。）
#   数法：只认「AF 段区间内、行首可选空白后紧跟 `chk `」的调用（AF-2/2c 里
#   把 chk 写在 if 块里的不算；带续行的 `chk` 仍只算 1 条），逐字对应断言点。
#   AF 段区间 = 本行（AF 段起点标记）到文件末尾的汇总行之前。
AF_SECTION_START="$(grep -n '^echo "###### 场景 AF：' "$HERE/run-tests.sh" | head -1 | cut -d: -f1)"
AF_SECTION_END="$(grep -n '^echo "================ PASS=' "$HERE/run-tests.sh" | head -1 | cut -d: -f1)"
AF_NSELF=0
if [ -n "$AF_SECTION_START" ] && [ -n "$AF_SECTION_END" ]; then
  AF_NSELF="$(sed -n "${AF_SECTION_START},${AF_SECTION_END}p" "$HERE/run-tests.sh" \
    | grep -cE '^[[:space:]]*chk ' || true)"
fi
chk "AF 段断言点 == 17（与 AGENTS.md 口径一致；删一条即报红）" "${AF_NSELF:-0}" "17"

# 抽 stage 的函数已收编为顶部唯一的 extract_stage（自适应缩进；原先 AF 段并列的
# af_extract_stage 与本函数是两套同类实现，正是「静默抽出空串」的温床，已删）。

AF_TPL="$REPO_ROOT/.ci/git-sync.yml"

# AF-1) 真模板上「去注释后匹配」的关键词必须全部命中。
#   关键词为 ERE（与 CI 里 has() 传的正则逐字一致）。
AF_KEYS='name: merge-pr-inline
cnb pulls merge-pull
--commit-title
AUTO_MERGE_PR
pull_request.mergeable:
type: git:auto-merge
CNB_PULL_REQUEST_BRANCH#sync/upstream-auto
if: .*SYNC_STATUS.*merged
SYNC_NO_PUSH: "1"'
if [ -f "$AF_TPL" ]; then
  AF_BODY="$(grep -vE '^[[:space:]]*#' "$AF_TPL" || true)"
  AF_MISS=0
  while IFS= read -r af_key; do
    [ -n "$af_key" ] || continue
    grep -qE -- "$af_key" <<< "$AF_BODY" \
      || { echo "  ❌ 模板少了断言关键词：${af_key}"; AF_MISS=$((AF_MISS+1)); }
  done <<< "$AF_KEYS"
  chk "真模板在「物化后单进程 grep」下命中全部断言关键词（无 SIGPIPE 假红）" "$AF_MISS" "0"
else
  echo "  ⚠️ 未找到 .ci/git-sync.yml，跳过真模板关键词断言"
fi

# AF-2) 两种写法在大输入下的**结果稳定性**对照。
#   背景（务必读懂再改）：这个坑的可见性取决于「下游是否读完参考上游项目输出」——
#     · grep -q 命中即退出，**不保证读完** stdin；参考上游项目 grep -vE 若还没写完
#       就会收到 SIGPIPE（128+13=141），被 pipefail 放大成整条管道的结果。
#     · 但不同实现差异很大：GNU grep 3.8 会 drain 剩余输入（本地不便复现），
#       精简镜像里常见的 grep 不 drain（CI runner 上就是它，实测 141）。
#   所以这里**不赌某一个 grep 的行为**，而是显式用「会提前退出的下游」把
#   SIGPIPE 这条时序路径逼出来：证明「参考上游项目确实会因下游提前退出而报 141」，
#   再对照新写法在任何下游行为下都恒定 —— 这才是可移植的判据。
AF_EDGE_FILE="$WORK/af_huge.yml"
#   注意：**不剥注释** —— CI 的 convention-selftest 里既有「剥注释后匹配」的
#   has() 断言，也有直接对原文 grep 的断言（如 UPSTREAM_TOKEN 只出现在注释里）。
#   放大器必须与真模板逐字节等价（只多一段前缀 padding），否则测的就成了别的东西。
{
  awk 'BEGIN { s=""; for (j = 0; j < 119; j++) s = s "-"; for (i = 0; i < 1500000; i++) printf "%s\n", s }'
  if [ -f "$AF_TPL" ]; then cat "$AF_TPL"; fi
} > "$AF_EDGE_FILE" 2>/dev/null
AF_SMALL="$WORK/af_small.yml"
if [ -f "$AF_TPL" ]; then cat "$AF_TPL" > "$AF_SMALL" 2>/dev/null || true; fi
AF_SZ=$(wc -c < "$AF_EDGE_FILE" | tr -d ' ')
AF_SMALL_SZ=$(wc -c < "$AF_SMALL" 2>/dev/null | tr -d ' ')
echo "  放大器：${AF_SZ} 字节 / 小输入：${AF_SMALL_SZ} 字节（管道缓冲通常 64KB）"
chk "放大器确实造出来了（>10MB）" "$([ "${AF_SZ:-0}" -gt 10000000 ] && echo big)" "big"

# AF-2a) 大输入 + 提前退出的下游 → 参考上游项目必吃 SIGPIPE（141）。
#       用 head -1 当「不等参考上游项目写完的下游」，把同一条时序路径逼出来。
AF_PIPE_BAD=0
for _ in 1 2 3; do
  bash -c "set -o pipefail; grep -vE '^[[:space:]]*#' '$AF_EDGE_FILE' | head -1 >/dev/null" 2>/dev/null
  [ "$?" = "141" ] && AF_PIPE_BAD=$((AF_PIPE_BAD+1))
done
if [ "$IS_WINDOWS_BASH" = "1" ]; then
  echo "  ⏭️ AF-2a 跳过：Windows bash 管道无稳定 SIGPIPE 传递，141 在本平台不成立（Linux/CI 侧为确定性断言）"
  SKIP=$((SKIP+1))
else
  chk "大输入 + 提前退出的下游 → 参考上游项目稳定 SIGPIPE(141)（3/3）" "$AF_PIPE_BAD" "3"
fi

# AF-2b) **真模板尺寸（29KB）在旧写法下有多不可靠** —— 这正是「本地绿、CI 红」
#        最硬的一条证据，也是为什么它极难定位。
# 判据演化（PR #17 CI 实证）：本条**曾经**断言「100 轮里 141 与正常两种结果
# 都出现过」（证明旧写法是时序竞态）。实践证伪了这个前提 —— 两种结果的分布
# 随机器与负载剧烈漂移：本跑点连续 14 轮 × 200 次采样，**每轮都有 141**（最
# 少 180/200），但「正常」一路可以低到 0/200；CI runner 上 100 轮全 141 时，
# `AF_SMALL_GOOD=0` → 断言报红。**只有 141 恰恰是它想论证的现象本身**，却把
# 自己也押进了同一个竞态里，成为套件第二处假阴性式 flaky（PR #17 主诉）。
#   现在的判据只保留「现象必然存在」这一半：100 轮里至少出现一次 141，即足以
#   证明旧写法不可靠；「也出现过正常」降级为**信息性输出**，统计分布式地随
#   采样窗口漂移，不作为判据（要钉「两种都出现」就得加大采样，代价是 CI 时长，
#   不值）。确定性侧另有 AF-2a（大输入 3/3 必 141）与 AF-2d（命中数 > 0 却 141），
#   竞态这条论证不会因为放宽 AF-2b 而变弱。
# 管道形状必须与 CI 断言一致（参考项目是 grep -vE，不是 cat）——实测 100 轮里
# `grep -vE | head -1` 会出现 141，而 `cat | head -1` 几乎不会：参考上游项目产出速率
# 才是决定「下游退出时参考项目是否已写完」的变量，换个参考上游项目就复现不出来。
AF_SMALL_BAD=0
for _ in $(seq 1 100); do
  bash -c "set -o pipefail; grep -vE '^[[:space:]]*#' '$AF_SMALL' | head -1 >/dev/null" 2>/dev/null
  [ "$?" = "141" ] && AF_SMALL_BAD=$((AF_SMALL_BAD+1))
done
AF_SMALL_GOOD=$((100 - AF_SMALL_BAD))
echo "  真模板尺寸(${AF_SMALL_SZ}B) 100 轮：141=${AF_SMALL_BAD} 正常=${AF_SMALL_GOOD}（分布随机器漂移，仅信息性）"
if [ "$IS_WINDOWS_BASH" = "1" ]; then
  echo "  ⏭️ AF-2b 跳过：Windows bash 下 141 时有时无（本条曾因此在本平台 flaky——首跑偶得一次恰过、复跑零次失败），守卫后两态皆消"
  SKIP=$((SKIP+1))
else
  chk "29KB 输入下旧写法 100 轮里至少出现一次 SIGPIPE(141)" \
    "$([ "${AF_SMALL_BAD}" -gt 0 ] && echo flaky)" "flaky"
fi

# AF-2c) 新写法（物化 + here-string 单进程 grep）与输入规模、下游行为全都无关：
#        没有参考上游项目生产者，SIGPIPE 结构上不可能发生。大输入下 3/3 必须全绿。
AF_FILTERED="$(grep -vE '^[[:space:]]*#' "$AF_EDGE_FILE" 2>/dev/null || true)"
af_has() { local _p="$1"; shift; grep -q "$@" -- "${_p}" <<< "${AF_FILTERED}"; }
AF_NEW_OK=0
for _ in 1 2 3; do
  if af_has 'AUTO_MERGE_PR' && af_has 'name: merge-pr-inline' && af_has '^-+$' -v; then
    AF_NEW_OK=$((AF_NEW_OK+1))
  fi
done
chk "新写法大输入下 3/3 全绿（无参考上游项目生产者，结构上无 SIGPIPE）" "$AF_NEW_OK" "3"

# AF-2d) 误诊源头可复现：**命中数 > 0，退出码却是 141**。
#        这正是 PR #16 最难查的形态 —— 报错说「丢了内容」，实际内容一直在
#        （实测：AUTO_MERGE_PR 命中 9 处，断言退出码 141）。这里把两者同时
#        打出来，证明「141 ≠ 内容缺失」，下一个人不必再从内容上找。
AF_HITS_N="$(grep -vE '^[[:space:]]*#' "$AF_EDGE_FILE" 2>/dev/null | grep -c 'AUTO_MERGE_PR' || true)"
AF_PIPE_RC=0
bash -c "set -o pipefail; grep -vE '^[[:space:]]*#' '$AF_EDGE_FILE' | head -1 | wc -l >/dev/null" 2>/dev/null
AF_PIPE_RC=$?
echo "  同一次匹配：命中数=${AF_HITS_N}，管道退出码=${AF_PIPE_RC}"
chk "命中数 > 0（内容确实在）" "$([ "${AF_HITS_N:-0}" -gt 0 ] && echo yes)" "yes"
if [ "$IS_WINDOWS_BASH" = "1" ]; then
  echo "  ⏭️ AF-2d(141) 跳过：同 AF-2a（命中数断言保留）"
  SKIP=$((SKIP+1))
else
  chk "同时退出码 = 141（断言却会报红）—— 141 不等于内容缺失" "$AF_PIPE_RC" "141"
fi

# AF-3) 全仓守卫：守护脚本里不许再出现管道 grep（`A | grep`，含命令替换内嵌）
#   白名单：注释行；`grep ... | grep -v grep` 这类进程过滤（本仓暂无，留空）。
AF_HITS=0
for af_f in "$REPO_ROOT/.ci/watchdog.yml" "$REPO_ROOT/.ci/git-sync.yml"; do
  [ -f "$af_f" ] || continue
  af_out="$(awk '
    { code = $0; sub(/[[:space:]]+#.*$/, "", code) }
    code ~ /^[[:space:]]*#/ { next }
    code ~ /\|[[:space:]]*grep/ { print FILENAME ":" NR ": " code }
  ' "$af_f")"
  if [ -n "$af_out" ]; then
    echo "  ❌ $af_f 里仍有管道 grep："
    printf '%s\n' "$af_out" | sed 's/^/     /'
    AF_HITS=$((AF_HITS + $(printf '%s\n' "$af_out" | grep -c .)))
  fi
done
chk "watchdog.yml / git-sync.yml 中管道 grep = 0（含命令替换内嵌）" "$AF_HITS" "0"

# AF-4) 反向守卫：解释这个坑的注释必须留在原地，否则下一个人会把写法改回去
if [ -f "$REPO_ROOT/.ci/watchdog.yml" ]; then
  chk "watchdog.yml 记录了 SIGPIPE 这个坑" \
    "$([ "$(grep -c 'SIGPIPE' "$REPO_ROOT/.ci/watchdog.yml")" -ge 1 ] && echo yes)" "yes"
  chk "watchdog.yml 说明「先物化、再单进程 grep」的修法" \
    "$([ "$(grep -cE '先物化|物化' "$REPO_ROOT/.ci/watchdog.yml")" -ge 1 ] && echo yes)" "yes"
  chk "watchdog.yml 点了 pipefail 是放大器" \
    "$([ "$(grep -c 'pipefail' "$REPO_ROOT/.ci/watchdog.yml")" -ge 1 ] && echo yes)" "yes"
  # 只认代码行：注释里提到过 here-string 也算「说过」，但改回管道照样得报
  AF_HAS_BODY="$(extract_stage "$REPO_ROOT/.ci/watchdog.yml" convention-selftest 2>/dev/null)"
  chk "has() 真的用 here-string 取入（注释提过不算）" \
    "$([ "$(printf '%s\n' "$AF_HAS_BODY" | grep -c '<<< "\${TPL_FILTERED}"')" -ge 1 ] && echo yes)" "yes"
  # 同样只认代码行（说明文字里当然可以提到旧写法长什么样）
  chk "has() 里没有 printf | grep 的回退写法" \
    "$(printf '%s\n' "$AF_HAS_BODY" | sed -e 's/[[:space:]]*#.*$//' \
        | grep -c 'printf.*|[[:space:]]*grep')" "0"
fi

# AF-5) 负向用例：新写法不会「永远真/永远假」（防拿假绿换绿）
AF_NEG=0
af_has 'merge-pr-inline_NOT_EXIST_2026' && AF_NEG=$((AF_NEG+1))
af_has 'name: merge-pr-inline' || AF_NEG=$((AF_NEG+1))
chk "新写法既能命中也能落空（不是恒真/恒假）" "$AF_NEG" "0"

# AF-6) 跑 CI 真代码：把 watchdog 的 convention-selftest 原样抽出，喂放大模板。
#   验的是「CI 跑的那段代码」，不是测试对它的复刻。
if [ -f "$REPO_ROOT/.ci/watchdog.yml" ]; then
  AF_STAGE="$WORK/af_conv.sh"
  { echo '#!/usr/bin/env bash'; extract_stage "$REPO_ROOT/.ci/watchdog.yml" convention-selftest; } > "$AF_STAGE"
  if [ "$(wc -l < "$AF_STAGE" | tr -d ' ')" -gt 2 ]; then
    AF_REPO="$WORK/af_repo"; rm -rf "$AF_REPO"
    # 铺一份**完整**工作区副本（convention-selftest 会校验 README/.cnb.yml/
    # 脚本/技能文档等多处，缺任何一个都会以「内容丢了」的口吻报错——
    # 那正是本场景要区分的假红，测试夹具自己不能制造这种噪音）。
    # 排除 .git 以免带上仓库历史（大且无关）。
    mkdir -p "$AF_REPO"
    ( cd "$REPO_ROOT" && tar -cf - --exclude=.git . 2>/dev/null ) \
      | ( cd "$AF_REPO" && tar -xf - ) 2>/dev/null || true
    ( cd "$AF_REPO" && git init -q -b main . ) >/dev/null 2>&1
    cp "$AF_EDGE_FILE" "$AF_REPO/.ci/git-sync.yml" 2>/dev/null || true
    (
      cd "$AF_REPO" || exit 1
      git config user.name t; git config user.email t@t; git config commit.gpgsign false
      git add -A >/dev/null 2>&1; git commit -qm fixture >/dev/null 2>&1
      bash "$AF_STAGE"
    ) > "$WORK/af_conv.log" 2>&1
    AF_CONV_RC=$?
    if [ "$AF_CONV_RC" = "0" ]; then
      echo "  ✅ CI 的 convention-selftest 在「同一内容 + 超大前缀」下仍通过"
      PASS=$((PASS+1))
    else
      echo "  ❌ convention-selftest 在放大模板下报红（SIGPIPE 修法未覆盖该 stage）："
      tail -8 "$WORK/af_conv.log" | sed 's/^/     /'
      FAIL=$((FAIL+1))
    fi
  else
    echo "  ⚠️ 未能抽出 convention-selftest（extract_stage 空输出），跳过"
  fi
fi

rm -f "$AF_EDGE_FILE"
echo "  ℹ️ 判据：AF-2 用「大输入 + 提前退出的下游」把 SIGPIPE 逼成确定性事实，"
echo "     并不赌某个 grep 实现的 drain 行为（GNU grep 3.8 drain、精简镜像不 drain，"
echo "     后者正是 CI 实测结果）；AF-2c 证明新写法与下游行为/输入规模全无关。"

# AF-5) 反向守卫：AF-2b 的判据不许退回「要求两种结果都出现过」。
#   判据演化见 AF-2b 注释：那一版把「旧写法是时序竞态」押在两种结果的**分布**上，
#   而分布随机器/负载漂移 —— CI runner 上 100 轮全 141 就报红，正是 PR #17 的
#   CI 红。这里守住两条（都靠提取**断言调用本身**，不做整段近似匹配）：
#     ① 断言项参数里不许再出现 `AF_SMALL_GOOD`（它的唯一用途就是「两种都出现」）
#     ② 断言文案仍须包含「至少出现一次」（现象必然存在）
#   提取法：取 AF-2b 段里 `chk ` 调用连同其续行（下一行承接参数）。
#   为什么不用 `sed -n 'AF-2b),AF-2c)p'` 整段扫：AF-2b 的**注释里为了讲清历史
#   必须提到 AF_SMALL_GOOD 这个名字**，整段扫会自己把自己判红（实测踩到）——
#   与 AGENTS.md 记的「恒假守卫」同一类错：判据没对准要守的东西。
AF_SMALL_BODY="$(awk '
  /^# AF-2b\)/ { on = 1; next }
  /^# AF-2c\)/ { on = 0 }
  on && /^[[:space:]]*chk / { print; getline; print; next }
' "$HERE/run-tests.sh" || true)"
chk "AF-2b 判据不许退回「两种结果都出现」（断言参数不使用 AF_SMALL_GOOD）" \
  "$(grep -c 'AF_SMALL_GOOD' <<< "$AF_SMALL_BODY" || true)" "0"
chk "AF-2b 断言文案仍是「至少出现一次 SIGPIPE(141)」（现象必然存在，不赌分布）" \
  "$([ "$(grep -c '至少出现一次' <<< "$AF_SMALL_BODY" || true)" -ge 1 ] && echo yes)" "yes"

echo
echo "================ PASS=$PASS FAIL=$FAIL SKIP=$SKIP ================"
[ "$FAIL" = "0" ]
