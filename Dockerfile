# NPC 自定义运行镜像（docs.cnb.cool/zh/build/npc.md#自定义运行环境）
# 预装：cnb cli(@cnbcool/cnb-cli + skills)、git、git-lfs、gpg(gnupg)、GitHub CLI(gh)
FROM node:22-bookworm-slim

# 系统依赖：git / git-lfs / gpg / curl / jq 等基础工具
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates git git-lfs curl jq gnupg ripgrep \
    && rm -rf /var/lib/apt/lists/* \
    && git lfs install

# CNB CLI + skills 运行时，并预装官方 cnb-skill（含 CNB 平台全部交互能力）
# 版本策略：装最新版（不锁旧版）；镜像随 main push 重建即滚动升级。
# 2026-09-23 实测最新：@cnbcool/cnb-cli@1.16.15 / skills@1.7.0（官方技能 hash 见 skills-lock.json）。
RUN npm install -g @cnbcool/cnb-cli@latest skills@latest \
    && npx skills add https://cnb.cool/cnb/skills/cnb-skill.git -g -y

# GitHub CLI（gh）：经官方 apt 源安装，提供 GPG 公钥校验
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*
