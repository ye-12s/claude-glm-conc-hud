#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────
# 状态栏: 仿 ~/.zshrc 的 Powerlevel10k 提示符
#   目录 (dir) | git 分支状态 (vcs) | 模型 | GLM 并发 | 时间
#
# stdin : Claude Code 传入的 session JSON
# 配色  : 取自 ~/.p10k.zsh —— dir FG=31 / anchor=39; git 干净=绿 脏=黄
# 并发  : 沿用原 hud 逻辑 (调用 glm-conc.sh, 阈值 ≥9 红 / ≥7 黄 / 其余青)
# 图标  : Nerd Font v3 (POWERLEVEL9K_MODE=nerdfont-v3)
# ──────────────────────────────────────────────────────────────────
input=$(cat)

# ── 解析 stdin JSON: 取 current_dir 与 model.display_name ──
mapfile -t _p < <(printf '%s' "$input" | python3 -c '
import sys, json
d = {}
try:
    d = json.load(sys.stdin)
except Exception:
    pass
cwd = (d.get("workspace") or {}).get("current_dir") or d.get("cwd") or ""
model = (d.get("model") or {}).get("display_name") or ""
print(cwd)
print(model)
' 2>/dev/null)
cwd="${_p[0]:-$PWD}"
model="${_p[1]:-claude}"

# ── 调色板 (256 色, 与 p10k 一致) ──
R=$'\033[0m'
DIM=$'\033[2m'
C_DIR=$'\033[38;5;31m'      # dir 前段 (p10k POWERLEVEL9K_DIR_FOREGROUND=31)
C_ANCHOR=$'\033[1;38;5;39m' # dir 末段 (p10k POWERLEVEL9K_DIR_ANCHOR_FOREGROUND=39)
C_GREEN=$'\033[38;5;70m'    # git 干净
C_YELLOW=$'\033[38;5;179m'  # git 脏
C_MODEL=$'\033[38;5;141m'   # 模型
C_RED=$'\033[31m'
C_YEL=$'\033[33m'
C_CYAN=$'\033[36m'

# ── 图标 (Nerd Font; git 图标与 POWERLEVEL9K_VCS_BRANCH_ICON= 一致) ──
ICO_DIR=$''   #  folder
ICO_GIT=$''   #  git branch (与 POWERLEVEL9K_VCS_BRANCH_ICON 一致)
ICO_MODEL=$'' #  microchip
ICO_CLOCK=$'' #  clock

# ── 目录段: $HOME→~, 末段高亮, 过长则截断为 …/末段 ──
fmt_dir() {
  local d="${1/#$HOME/~}"
  local last="${d##*/}"
  [ -z "$last" ] && last="$d"
  local parent="${d%"$last"}"
  parent="${parent%/}"
  [ ${#parent} -gt 28 ] && parent="…"
  if [ -n "$parent" ] && [ "$parent" != "$d" ]; then
    printf '%s%s/%s%s%s' "$C_DIR" "$parent" "$C_ANCHOR" "$last" "$R"
  else
    printf '%s%s%s' "$C_ANCHOR" "$last" "$R"
  fi
}

# ── git 段: 分支名 + 脏标记 (p10k vcs) ──
fmt_git() {
  git -C "$1" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  local branch
  branch=$(git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null \
           || git -C "$1" rev-parse --short HEAD 2>/dev/null) || return 0
  [ -z "$branch" ] && return 0
  if [ -n "$(git -C "$1" status --porcelain 2>/dev/null)" ]; then
    printf '%s%s %s*%s' "$C_YELLOW" "$ICO_GIT" "$branch" "$R"
  else
    printf '%s%s %s%s' "$C_GREEN" "$ICO_GIT" "$branch" "$R"
  fi
}

# ── GLM 并发段: 调 glm-conc.sh 取活跃并发, ≥9 红/≥7 黄/其余青 ──
fmt_conc() {
  local conc n
  conc=$(bash "$HOME/.claude/hud/glm-conc.sh" 2>/dev/null) || return 0
  [ -z "$conc" ] && return 0
  n="${conc#GLM:}"
  if [ "$n" -ge 9 ] 2>/dev/null; then
    printf '%s%s (满)%s' "$C_RED" "$conc" "$R"
  elif [ "$n" -ge 7 ] 2>/dev/null; then
    printf '%s%s%s' "$C_YEL" "$conc" "$R"
  else
    printf '%s%s%s' "$C_CYAN" "$conc" "$R"
  fi
}

# ── 组装各段, 用暗色分隔符连接 ──
SEP="${DIM} | ${R}"
seg_dir=$(printf '%s %s' "$ICO_DIR" "$(fmt_dir "$cwd")")
seg_git=$(fmt_git "$cwd")
seg_model=$(printf '%s %s%s%s' "$C_MODEL" "$ICO_MODEL" " $model" "$R")
seg_conc=$(fmt_conc)
seg_time=$(printf '%s %s%s' "$DIM" "$ICO_CLOCK" "$(date +%H:%M)${R}")

out=""
for seg in "$seg_dir" "$seg_git" "$seg_model" "$seg_conc" "$seg_time"; do
  [ -z "$seg" ] && continue
  [ -z "$out" ] && out="$seg" || out="${out}${SEP}${seg}"
done
printf '%s\n' "$out"
