#!/usr/bin/env bash
# bootstrap-skills.sh —— NPC 启动前把所需技能准备到自动加载目录
#
# 背景：NPC 运行时自动加载的只有 ~/.agents/skills、~/.codebuddy/skills
# 以及对应的项目级目录，并不会加载 <repo>/skills/。而 NPC 事件流水线的
# 工作区是「触发 Issue/PR 的目标仓库」，那里没有本仓库的技能文件，
# 所以先从 NPC 所属仓库（CNB_NPC_SLUG）匿名浅克隆取回，再落盘。
#
# 策略：
#   1. 本仓可匿名读（公开仓库）：浅克隆本仓默认分支，取回 skills/
#      与 skills-lock.json；克隆时按 CNB_NPC_SHA 锁定版本（事件触发时
#      注入），保证拿到的就是「@ 到的那个版本」。
#   2. CNB 官方 cnb-* 技能按 skills-lock.json 从官方技能仓库共享仓库拉取，
#      落盘前逐技能校验 computedHash（sha256 of SKILL.md）：hash 不符即
#      拒绝安装并告警（真锁版本，官方技能仓库静默改动进不来）；拉取失败回落到
#      本仓 skills/ 下的内置副本。升级官方技能须同步刷新 skills-lock.json。
#
# 幂等，可重复执行，也可单独用：bash .cnb/bootstrap-skills.sh

set -uo pipefail

# 本仓（NPC 所属仓库）：默认本仓 slug。不直接采用运行时注入的 CNB_NPC_SLUG——
# 本仓角色复用参考上游项目 npc/CodeBuddy 的人设（settings.yml 共享 align_prompt），被 @ 触发时
# 注入的 CNB_NPC_SLUG 可能指向参考上游项目仓（那里没有本仓的 skills/），跨仓自举会静默空载。
# 故以本仓 slug 为准，仅当注入 slug 克隆出的仓库确实带 skills/ 时才采信。
NPC_SLUG="xgzwlkj/npc"
NPC_SLUG_INJECTED="${CNB_NPC_SLUG:-}"
NPC_SHA="${CNB_NPC_SHA:-}"
SKILLS_REF="${SKILLS_REF:-main}"
# 允许覆盖克隆地址（默认由 slug 拼出），便于测试与镜像场景
NPC_REPO_URL="${NPC_REPO_URL:-https://cnb.cool/${NPC_SLUG}.git}"
# 官方技能共享仓库
SKILLS_REPO="${SKILLS_REPO:-https://cnb.cool/cnb/skills/cnb-skill.git}"
SKILLS_UPSTREAM_REF="${SKILLS_UPSTREAM_REF:-main}"
LOCK_FILE="${LOCK_FILE:-skills-lock.json}"

dst="${HOME}/.codebuddy/skills"
mkdir -p "${dst}"

# ---- 1. 取回本仓技能源（工作区是目标仓库，须先克隆本仓）----
# 本仓公开可读，匿名 HTTPS 克隆即可；不依赖当前仓库的 CNB_TOKEN（限地约束下跨仓不可用）。
self_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workdir="$(cd "${self_script_dir}/.." && pwd)"
src_dir=""
if [ -f "${workdir}/skills/sync-upstream/SKILL.md" ]; then
  # 直接执行（本仓自己的流水线，如 watchdog 自检）：工作区即本仓
  src_dir="${workdir}"
else
  tmp="$(mktemp -d)"
  clone_npc_repo() { # $1=slug $2=目标目录：浅克隆并尽量切到 NPC_SHA
    git -c protocol.file.allow=always clone -q --depth 1 --branch "${SKILLS_REF}" \
      "https://cnb.cool/${1}.git" "${2}" 2>/dev/null || return 1
    if [ -n "${NPC_SHA}" ]; then
      git -C "${2}" fetch -q --depth 1 origin "${NPC_SHA}" 2>/dev/null \
        && git -C "${2}" checkout -q "${NPC_SHA}" 2>/dev/null || true
    fi
    # 技能源判据：仓库须带 skills/sync-upstream（参考上游项目 CodeBuddy 仓没有 skills/，不能当技能源）
    [ -f "${2}/skills/sync-upstream/SKILL.md" ]
  }
  if clone_npc_repo "${NPC_SLUG}" "${tmp}/npc"; then
    src_dir="${tmp}/npc"
    echo "✅ 已克隆 NPC 仓库：${NPC_SLUG}@${NPC_SHA:-${SKILLS_REF}}"
  elif [ -n "${NPC_SLUG_INJECTED}" ] && [ "${NPC_SLUG_INJECTED}" != "${NPC_SLUG}" ] \
       && clone_npc_repo "${NPC_SLUG_INJECTED}" "${tmp}/npc-injected"; then
    # 运行时注入的 slug（镜像仓/改名场景）确实带本仓技能时采信
    src_dir="${tmp}/npc-injected"
    echo "✅ 已克隆 NPC 仓库：${NPC_SLUG_INJECTED}@${NPC_SHA:-${SKILLS_REF}}"
  else
    echo "⚠️ 技能源克隆失败：${NPC_REPO_URL} 与 ${NPC_SLUG_INJECTED:-<无注入>} 均不可用，同步官技能将不可用"
  fi
fi

# 招牌技能（sync-upstream）直接落盘
if [ -n "${src_dir}" ] && [ -d "${src_dir}/skills" ]; then
  for d in "${src_dir}"/skills/*/; do
    [ -f "${d}SKILL.md" ] || continue
    name="$(basename "${d}")"
    rm -rf "${dst:?}/${name}"
    cp -R "${d}" "${dst}/${name}"
    echo "✅ 本地技能：${name}"
  done
fi

# ---- 2. CNB 官方技能：按 skills-lock.json 从共享仓库拉取并校验 hash（真锁版本）----
# 每个技能的 computedHash 是其 SKILL.md 的 sha256。拉下来先算 hash，
# 与锁文件不符 = 参考项目内容变了，拒绝安装并逐个告警——锁的是「内容版本」
# 而不是分支路径；升级官方技能须显式刷新 skills-lock.json（watchdog 自检兜底）。
lock_path="${src_dir}/${LOCK_FILE}"
if [ "${src_dir}" = "${workdir}" ]; then lock_path="${workdir}/${LOCK_FILE}"; fi
if [ -f "${lock_path}" ] && command -v jq >/dev/null 2>&1; then
  tmp2="$(mktemp -d)"
  if git clone -q --depth 1 --branch "${SKILLS_UPSTREAM_REF}" "${SKILLS_REPO}" "${tmp2}/repo" 2>/dev/null; then
    n=0
    hash_fail=0
    while IFS=$'\t' read -r name path expected_hash; do
      [ -n "${name:-}" ] || continue
      src="${tmp2}/repo/${path}"
      src_dir2="$(dirname "${src}")"
      [ -f "${src}" ] || { echo "⚠️ 官方技能仓库缺技能文件：${name}（${path}）"; continue; }
      actual_hash="$(sha256sum "${src}" | awk '{print $1}')"
      if [ -n "${expected_hash}" ] && [ "${actual_hash}" != "${expected_hash}" ]; then
        echo "❌ 技能 ${name} hash 不符（锁 ${expected_hash:0:12}… 实际 ${actual_hash:0:12}…），拒绝安装——参考上游项目已变更，请刷新 skills-lock.json 后升级"
        hash_fail=$((hash_fail + 1))
        continue
      fi
      rm -rf "${dst:?}/${name}"
      cp -R "${src_dir2}" "${dst}/${name}"
      n=$((n + 1))
    done < <(jq -r '.skills | to_entries[] | [.key, .value.skillPath, (.value.computedHash // "")] | @tsv' "${lock_path}")
    echo "✅ 官方技能：${n} 个（${SKILLS_REPO}@${SKILLS_UPSTREAM_REF}，sha256 校验通过）"
    if [ "${hash_fail}" -gt 0 ]; then
      echo "⚠️ ${hash_fail} 个技能因 hash 不符被拒装；本仓 skills/ 内置副本兜底"
    fi
  else
    echo "⚠️ 官方技能仓库拉取失败，回落到本仓副本：${SKILLS_REPO}"
  fi
  rm -rf "${tmp2}"
fi

# ---- 3. 兜底：本仓 skills/ 里上面没装上的补上（离线保底）----
if [ -n "${src_dir}" ] && [ -d "${src_dir}/skills" ]; then
  for d in "${src_dir}"/skills/*/; do
    [ -f "${d}SKILL.md" ] || continue
    name="$(basename "${d}")"
    [ -d "${dst}/${name}" ] || cp -R "${d}" "${dst}/${name}"
  done
fi

# 清理克隆临时目录（src_dir 是克隆产物时）
if [ -n "${tmp:-}" ] && [ -d "${tmp}/npc" ]; then rm -rf "${tmp}"; fi

echo "—— 已加载技能（${dst}）——"
ls -1 "${dst}" | sed 's/^/  - /'
