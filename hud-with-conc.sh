#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────
# 状态栏: 仿 ~/.zshrc 的 Powerlevel10k 提示符
#   目录 (dir) | git 分支状态 (vcs) | 模型 | 上下文 | GLM 并发 | 时间
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
_m = d.get("model") or {}
model = _m.get("display_name") or ""
mid   = _m.get("id") or ""
ts = d.get("transcript_path") or ""        # 会话 transcript JSONL, 供算上下文用量
print(cwd)
print(model)
print(mid)
print(ts)
' 2>/dev/null)
cwd="${_p[0]:-$PWD}"
model="${_p[1]:-claude}"
model_id="${_p[2]:-}"
transcript="${_p[3]:-}"

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

ICO_CTX=$''    #  bar chart (上下文用量, 参考 claude-hud)

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

# ── 上下文段: 进度条显示当前上下文占用 (参考 claude-hud) ──
# 用量 = input + cache_creation + cache_read + output (cache_read 是缓存命中的历史 prompt, 同样占窗口)
# 窗口总量动态识别, 不写死: 优先解析 model id/display_name/ANTHROPIC_*_MODEL 里的
#   [1m]/[200k]/[128k] 后缀 (Claude Code 用它标注上下文窗口变体, 如 glm-5.2[1M]); 匹配不到再用
#   已知模型前缀表, 最后兜底 200k
fmt_ctx() {
  [ -z "$transcript" ] && return 0
  [ -f "$transcript" ] || return 0
  local filled track pct used win col
  IFS=: read -r filled track pct used win < <(TSCRIPT="$transcript" MID="$model_id" MNAME="$model" python3 -c '
import os, sys, json, re
path = os.environ.get("TSCRIPT", "")
mid, mname = os.environ.get("MID", ""), os.environ.get("MNAME", "")
def ctx_window():
    # 1) [1m] / [200k] / [128k] 上下文后缀 (如 glm-5.2[1M] -> 1,000,000)
    cands = [mid, mname] + [os.environ.get(k, "") for k in
              ("ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
               "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_FABLE_MODEL",
               "ANTHROPIC_DEFAULT_HAIKU_MODEL")]
    for s in cands:
        m = re.search(r"\[(\d+(?:\.\d+)?)([km])\]", s or "", re.I)
        if m:
            n = float(m.group(1)); u = m.group(2).lower()
            return int(n * (1000 if u == "k" else 1000000))
    # 2) 已知模型前缀 -> 上下文窗口
    t = (mid or mname).lower()
    for k, v in (("claude", 200000), ("glm-4.6", 200000), ("glm-4.5", 128000)):
        if t.startswith(k):
            return v
    return 200000                     # 未知 -> 兜底 200k
mx = ctx_window()
last = None
try:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            if "\"usage\"" not in line:
                continue              # 跳过无 usage 的行 (大的 tool 结果等), 加速扫描
            try:
                o = json.loads(line)
            except Exception:
                continue
            m = o.get("message") or {}
            if m.get("role") == "assistant":
                u = m.get("usage") or {}
                if u:
                    last = u          # 取最后一条 assistant usage (最近一次 API 响应)
except Exception:
    pass
if not last:
    sys.exit()                        # 暂无 assistant 回复 -> 该段不显示
tot = (last.get("input_tokens", 0) + last.get("cache_creation_input_tokens", 0)
       + last.get("cache_read_input_tokens", 0) + last.get("output_tokens", 0))
pct = int(round(tot * 100.0 / mx)) if mx else 0
W = 8                                 # 进度条格数; 1/8 块补一格做亚像素过渡
units = max(0, int(round(pct / 100.0 * W * 8)))
full = min(units // 8, W)
filled = "█" * full              # █
if units % 8 and full < W:
    filled += "▏▎▍▌▋▊▉"[units % 8 - 1]   # ▏..▉
track = "░" * max(0, W - len(filled))   # ░
def human(n):                            # 80000->80k  80500->80.5k  1000000->1M
    if n >= 1000000:
        s = "%.1f" % (n / 1000000.0); return s.rstrip("0").rstrip(".") + "M"
    if n >= 1000:
        s = "%.1f" % (n / 1000.0);    return s.rstrip("0").rstrip(".") + "k"
    return str(n)
print("%s:%s:%d:%s:%s" % (filled, track, pct, human(tot), human(mx)))
' 2>/dev/null)
  [ -z "$pct" ] && return 0
  if   [ "$pct" -ge 80 ] 2>/dev/null; then col="$C_RED"     # 接近满, 该 /compact 了
  elif [ "$pct" -ge 50 ] 2>/dev/null; then col="$C_YEL"
  else                                      col="$C_GREEN"
  fi
  # 进度条 (满段按阈值上色, 空槽暗色) + 用量/总量
  printf '%s%s %s%s%s%s %s%s%s%s/%s%s' \
    "$col" "$ICO_CTX" "$filled" "$DIM" "$track" "$R" "$col" "$used" "$R" "$DIM" "$win" "$R"
}

# ── 组装各段, 用暗色分隔符连接 ──
SEP="${DIM} | ${R}"
seg_dir=$(printf '%s %s' "$ICO_DIR" "$(fmt_dir "$cwd")")
seg_git=$(fmt_git "$cwd")
seg_model=$(printf '%s %s%s%s' "$C_MODEL" "$ICO_MODEL" " $model" "$R")
seg_ctx=$(fmt_ctx)
seg_conc=$(fmt_conc)
seg_time=$(printf '%s %s%s' "$DIM" "$ICO_CLOCK" "$(date +%H:%M)${R}")

out=""
for seg in "$seg_dir" "$seg_git" "$seg_model" "$seg_ctx" "$seg_conc" "$seg_time"; do
  [ -z "$seg" ] && continue
  [ -z "$out" ] && out="$seg" || out="${out}${SEP}${seg}"
done
printf '%s\n' "$out"
