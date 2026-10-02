#!/usr/bin/env bash
# refresh-skills-lock.sh —— 官方技能仓库技能自动跟进：检测 + 刷新 skills-lock.json
#
# 背景（PR #14 评审遗留）：bootstrap-skills.sh 按 skills-lock.json 的
# computedHash 真锁版本（hash 不符拒装），官方技能仓 cnb/skills/cnb-skill 静默
# 更新后本仓不会自动跟进，锁文件会「过期」——参考项目可达但技能装不上。
# 本脚本补齐自动跟进：每日自检（.ci/watchdog.yml）先检测，过期即刷新
# 锁文件并经分支 skills/auto-update 开 PR，人工评审合并后生效。
#
# 两种模式：
#   检测（默认）：克隆官方技能仓库、逐技能 sha256 比对，只报告不改动。
#     输出 ##[set-output SKILLS_LOCK_STATUS=up-to-date|stale|fetch-failed
#     及 SKILLS_STALE_COUNT / SKILLS_STALE_LIST / SKILLS_MISSING_LIST
#   刷新（--refresh）：把过期技能的 computedHash 重算为官方技能仓库当前值，
#     原地写回锁文件。只改 hash、不动其他字段；官方技能仓库已删除的技能
#     条目不自动移除（人工裁决），仅列入 SKILLS_MISSING_LIST 告警。
#
# 设计约束：
#   - 纯文件操作：不 git commit / push / 建 PR（由流水线 stage 负责），
#     便于本地与自检沙箱离线实测
#   - 不引入新的官方技能仓库信任：刷新后的锁文件仍须走 bootstrap 的 hash 校验，
#     PR 合并是人工评审——自动跟进只省「重算 hash」的体力活，
#     「参考项目内容进本仓」这道门仍由人把守
#   - 官方技能仓库新增而锁文件未收录的技能不自动采纳（收录清单是刻意选择），
#     仅提示数量

set -uo pipefail

SKILLS_REPO="${SKILLS_REPO:-https://cnb.cool/cnb/skills/cnb-skill.git}"
SKILLS_UPSTREAM_REF="${SKILLS_UPSTREAM_REF:-main}"
LOCK_FILE="${LOCK_FILE:-skills-lock.json}"
# 刷新模式逐技能变更摘要输出文件（可选；流水线用它拼 PR 描述）
SKILLS_REFRESH_SUMMARY_FILE="${SKILLS_REFRESH_SUMMARY_FILE:-}"

REFRESH=0
[ "${1:-}" = "--refresh" ] && REFRESH=1

command -v jq >/dev/null 2>&1 || { echo "❌ 缺 jq，无法解析 ${LOCK_FILE}"; exit 1; }
[ -f "${LOCK_FILE}" ] || { echo "❌ 锁文件不存在：${LOCK_FILE}"; exit 1; }

set_output() { echo "##[set-output $1=$2]"; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

# ---------- 拉取官方技能仓库（匿名浅克隆，公开仓库） ----------
if ! git clone -q --depth 1 --branch "${SKILLS_UPSTREAM_REF}" "${SKILLS_REPO}" "${tmp}/repo" 2>/dev/null; then
  echo "⚠️ 官方技能仓库拉取失败：${SKILLS_REPO}@${SKILLS_UPSTREAM_REF}"
  set_output SKILLS_LOCK_STATUS fetch-failed
  set_output SKILLS_UPSTREAM_SHA ""
  set_output SKILLS_STALE_COUNT 0
  set_output SKILLS_STALE_LIST ""
  set_output SKILLS_MISSING_LIST ""
  exit 0
fi
UPSTREAM_SHA="$(git -C "${tmp}/repo" rev-parse HEAD)"
UPSTREAM_SUBJECT="$(git -C "${tmp}/repo" log -1 --format=%s)"
set_output SKILLS_UPSTREAM_SHA "${UPSTREAM_SHA}"
echo "== 官方技能仓库：${SKILLS_REPO}@${SKILLS_UPSTREAM_REF} ${UPSTREAM_SHA:0:8}（${UPSTREAM_SUBJECT}）=="

# ---------- 逐技能比对 ----------
stale_list=""
missing_list=""
stale_count=0
summary=""
while IFS=$'\t' read -r name path expected_hash; do
  [ -n "${name:-}" ] || continue
  src="${tmp}/repo/${path}"
  if [ ! -f "${src}" ]; then
    echo "⚠️ 技能 ${name} 在官方技能仓库已不存在（${path}），刷新模式不自动移除条目，请人工裁决"
    missing_list="${missing_list}${missing_list:+,}${name}"
    continue
  fi
  actual_hash="$(sha256sum "${src}" | awk '{print $1}')"
  if [ "${actual_hash}" = "${expected_hash}" ]; then
    continue
  fi
  stale_count=$((stale_count + 1))
  stale_list="${stale_list}${stale_list:+,}${name}"
  echo "⏳ ${name}：锁 ${expected_hash:0:12}… → 官方技能仓库 ${actual_hash:0:12}…"
  summary="${summary}- ${name}：${expected_hash:0:12}… → ${actual_hash:0:12}…"$'\n'
  if [ "${REFRESH}" = "1" ]; then
    # 只改 computedHash，不动 source / skillPath 等字段；写临时文件再原子换名，
    # 避免中途失败留下半截 JSON
    jq --arg k "${name}" --arg h "${actual_hash}" \
      '.skills[$k].computedHash = $h' "${LOCK_FILE}" > "${LOCK_FILE}.tmp" \
      && mv "${LOCK_FILE}.tmp" "${LOCK_FILE}" \
      || { echo "❌ 刷新 ${name} 失败，锁文件保持原状"; rm -f "${LOCK_FILE}.tmp"; exit 1; }
    echo "✅ 已刷新 ${name} 的 computedHash"
  fi
done < <(jq -r '.skills | to_entries[] | [.key, .value.skillPath, (.value.computedHash // "")] | @tsv' "${LOCK_FILE}")

# 官方技能仓库新增而锁文件未收录的技能：只提示，不自动采纳
if [ -d "${tmp}/repo/skills" ]; then
  new_count=0
  while IFS= read -r d; do
    name="$(basename "${d}")"
    jq -e --arg k "${name}" '.skills[$k] // empty' "${LOCK_FILE}" >/dev/null 2>&1 || new_count=$((new_count + 1))
  done < <(find "${tmp}/repo/skills" -mindepth 1 -maxdepth 1 -type d)
  [ "${new_count}" -gt 0 ] && echo "ℹ️ 官方技能仓库有 ${new_count} 个未收录的新技能（不自动采纳，需要时手工加锁）"
fi

if [ -n "${SKILLS_REFRESH_SUMMARY_FILE}" ] && [ "${REFRESH}" = "1" ]; then
  printf '%s' "${summary}" > "${SKILLS_REFRESH_SUMMARY_FILE}"
fi

set_output SKILLS_STALE_COUNT "${stale_count}"
set_output SKILLS_STALE_LIST "${stale_list}"
set_output SKILLS_MISSING_LIST "${missing_list}"

if [ "${stale_count}" -gt 0 ] || [ -n "${missing_list}" ]; then
  if [ "${REFRESH}" = "1" ]; then
    echo "锁文件已刷新：${stale_count} 个技能 hash 更新$( [ -n "${missing_list}" ] && echo "，${missing_list} 官方技能仓库缺失待人工处理" )"
  else
    echo "⏳ 锁文件过期：${stale_count} 个技能落后官方技能仓库$( [ -n "${missing_list}" ] && echo "，${missing_list} 官方技能仓库缺失" )"
  fi
  set_output SKILLS_LOCK_STATUS stale
else
  echo "✅ 锁文件与官方技能仓库一致（up-to-date）"
  set_output SKILLS_LOCK_STATUS up-to-date
fi
exit 0
