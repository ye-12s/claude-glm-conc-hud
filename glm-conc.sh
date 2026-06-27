#!/usr/bin/env bash
# GLM API 当前"活跃"并发请求数 (mihomo unix socket 查询)
# 只数"正在处理中"的请求(下行/上行在涨 或 新建)，排除空闲 keep-alive
# 经实测 + 官方文档(docs.bigmodel.cn/cn/api/rate-limit)确认:
#   - 并发配额(错误码1302)按"同一时刻正在处理中的请求数"计，空闲 socket 不占
# 输出: GLM:<n>
SOCK="/tmp/verge/verge-mihomo.sock"
STATE="/tmp/glm-conc.state"
API_HOST="bigmodel"   # 只匹配 open.bigmodel.cn (你的 ANTHROPIC_BASE_URL)；api.z.ai 不计入
STALE=5               # 两次采样间隔 >5s 则退化为当前总连接数

[ -S "$SOCK" ] || { echo "GLM:?"; exit 0; }
now=$(date +%s)
prev_ts=0; prev=""
[ -f "$STATE" ] && IFS=$'\t' read -r prev_ts prev < "$STATE" 2>/dev/null
snap=$(curl -sS --max-time 2 --unix-socket "$SOCK" http://localhost/connections 2>/dev/null)

n=$(NOW="$now" PTS="$prev_ts" PREV="$prev" HOST="$API_HOST" STALE="$STALE" STATE="$STATE" python3 -c '
import os,sys,json
now=int(os.environ.get("NOW") or 0); pts=int(os.environ.get("PTS") or 0)
stale=int(os.environ.get("STALE") or 5); host=os.environ.get("HOST","bigmodel")
prev=os.environ.get("PREV",""); state=os.environ.get("STATE","")
P={}                                  # 上次状态 {id:[dl,up,stale计数]}
for p in prev.split("|"):
    f=p.split(",")
    if len(f)==4:
        try: P[f[0]]=[int(f[1]),int(f[2]),int(f[3])]
        except: pass
try: d=json.load(sys.stdin)
except Exception: print("?"); sys.exit()
cur={}
for x in d.get("connections",[]):
    h=(x.get("metadata",{}).get("host") or x.get("metadata",{}).get("destinationIP") or "").lower()
    if host in h: cur[x.get("id","")]=[x.get("download",0),x.get("upload",0)]
fresh = 0 < (now-pts) <= stale
active=0; nxt={}
if cur and P and fresh:
    for cid,(dl,up) in cur.items():
        pdl,pup,pst = (P.get(cid) or [None,None,None])
        grew = (cid not in P) or (pdl is not None and (dl>pdl or up>pup))
        st = 0 if grew else ((pst or 0)+1)
        if st <= 1: active += 1            # 当帧在涨计入; 涨后留1帧宽限(覆盖GLM思考/TTFT冻结)
        nxt[cid]=[dl,up,st]
else:
    active=len(cur)                        # 退化: 无有效上次样本，按总数报
    for cid,(dl,up) in cur.items(): nxt[cid]=[dl,up,0]
if state:
    try:
        with open(state,"w") as f:
            f.write("%d\t%s"%(now,"|".join("%s,%d,%d,%d"%(c,a[0],a[1],a[2]) for c,a in nxt.items())))
    except OSError: pass
print(active)
' <<< "$snap")

echo "GLM:${n:-?}"
