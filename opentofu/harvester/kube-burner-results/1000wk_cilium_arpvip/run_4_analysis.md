Ran terminal command: cd opentofu/harvester && ls -la results-api-intensive-4.tgz && D=/Users/tferrandiz/.copilot/session-state/c80e7128-81d6-41fe-8c56-8da630eead04/files/results4; mkdir -p $D && tar xzf results-api-intensive-4.tgz -C $D && ls -la $D/*/ ; cd $D/* && echo "errors: $(grep -c level=error kube-burner.log) warns: $(grep -c level=warn kube-burner.log)"; cat etcd-errors.log 2>/dev/null | head; grep -v level=debug kube-burner.log | grep -E 'Starting|Pre-load|Triggering|took|Ready 99|PodScheduled|ContainersReady|Finished|garbage|Exiting|Waiting up|Verif|level=(warn|error|fatal)' | sed -E 's/time="2026-10-2. //; s/" level=/ /; s/ file="[^"]*"//' | cut -c1-170; grep -m1 Found kube-burner.log | cut -c1-140

Ran terminal command: cd /Users/tferrandiz/.copilot/session-state/c80e7128-81d6-41fe-8c56-8da630eead04/files/results4/* && ls; echo "errors: $(grep -c level=error kube-burner.log) warns: $(grep -c level=warn kube-burner.log)"; [ -f etcd-errors.log ] && wc -l etcd-errors.log && sort etcd-errors.log | sed -E 's/^[^ ]+ //' | uniq -c | head -5; grep -v level=debug kube-burner.log | grep -E 'Starting|Pre-load|Triggering|took|Ready 99|PodScheduled|Finished|garbage|Exiting|Waiting up|Verif|level=(warn|fatal)' | sed -E 's/time="2026-10-2. //; s/" level=/ /; s/ file="[^"]*"//' | cut -c1-150; grep -m1 Found kube-burner.log | cut -c1-140; grep level=error kube-burner.log | sed -E 's/time="[^"]*" //; s/ file="[^"]*"//; s/-[0-9]+/-N/g' | cut -c1-200 | sort | uniq -c | sort -rn | head

kube-burner logged 296 Service deletion timeouts, which is new and would make the runner exit with code 3. Next I'll go through the API-server and etcd metrics.

Ran terminal command: cd /Users/tferrandiz/.copilot/session-state/c80e7128-81d6-41fe-8c56-8da630eead04/files/results4/* && cut -f2 etcd-metrics.tsv | sed -E 's/\{member="([^"]*)".*/ \1/' | sort | uniq -c | awk '{print $2,$3}' | sort -u | awk '{a[$1]=a[$1]" "$2} END{for(k in a)print k":"a[k]}' | sort; cut -f1 etcd-metrics.tsv | sort -u | wc -l; grep -E 'level=error' kube-burner.log | sed -E 's/time="2026-10-23 ([0-9:]+)".*/\1/' | sort | uniq -c | sed -n '1p;$p'

Ran terminal command: cd /Users/tferrandiz/.copilot/session-state/c80e7128-81d6-41fe-8c56-8da630eead04/files/results4/* && grep -E 'level=error' kube-burner.log | sed -E 's/time="2026-10-23 ([0-9:]+)".*/\1/' | sort | uniq -c; cat > /tmp/etcd.py <<'EOF'
import collections,datetime as dt,re,sys
S=collections.OrderedDict()
for l in open("etcd-metrics.tsv"):
    t,s,v=l.rstrip("\n").split("\t"); S.setdefault(t,{})[s]=float(v)
ts=list(S); T=lambda t: dt.datetime.strptime(t,"%Y-%m-%dT%H:%M:%SZ")
M=["bench-cp-01","bench-cp-02","bench-cp-03"]
g=lambda d,n,m: d.get(f'{n}{{member="{m}"}}',0)
def pct(d,p,n,m,q):
    b={}
    for k,v in d.items():
        mm=re.match(n+r'_bucket\{member="'+m+r'",le="([^"]+)"\}',k)
        if mm: b[mm.group(1)]=v-p.get(k,0)
    les=sorted(b,key=lambda x: float("inf") if x=="+Inf" else float(x))
    tot=b.get("+Inf",0)
    if tot<=0: return 0
    for le in les:
        if b[le]>=q*tot: return float(le)*1000 if le!="+Inf" else float("inf")
print("leader per sample:",collections.Counter(next((m for m in M if g(S[t],"etcd_server_is_leader",m)==1),"none") for t in ts))
for m in M: print(m,"leader changes", g(S[ts[-1]],"etcd_server_leader_changes_seen_total",m)-g(S[ts[0]],"etcd_server_leader_changes_seen_total",m), "failed", g(S[ts[-1]],"etcd_server_proposals_failed_total",m)-g(S[ts[0]],"etcd_server_proposals_failed_total",m),"slow_apply",g(S[ts[-1]],"etcd_server_slow_apply_total",m)-g(S[ts[0]],"etcd_server_slow_apply_total",m))
print("time     prop/s pend(max) | cpu cp1 cp2 cp3 | rssMiB cp1 | fsync p99 ms cp1/2/3 | commit p99 ms cp1/2/3 | rtt ms | db MiB/inuse | put/s del/s range/s")
mx=collections.defaultdict(float)
for i in range(1,len(ts)):
    t,p=ts[i],ts[i-1]; d,q=S[t],S[p]; sec=(T(t)-T(p)).total_seconds() or 1
    lead=next((m for m in M if g(d,"etcd_server_is_leader",m)==1),M[0])
    prop=(g(d,"etcd_server_proposals_committed_total",lead)-g(q,"etcd_server_proposals_committed_total",lead))/sec
    pend=max(g(d,"etcd_server_proposals_pending",m) for m in M)
    cpu=[(g(d,"process_cpu_seconds_total",m)-g(q,"process_cpu_seconds_total",m))/sec for m in M]
    fs=[pct(d,q,"etcd_disk_wal_fsync_duration_seconds",m,.99) for m in M]
    bc=[pct(d,q,"etcd_disk_backend_commit_duration_seconds",m,.99) for m in M]
    n=sum(g(d,"etcd_network_peer_round_trip_time_seconds_count",m)-g(q,"etcd_network_peer_round_trip_time_seconds_count",m) for m in M)
    rtt=sum(g(d,"etcd_network_peer_round_trip_time_seconds_sum",m)-g(q,"etcd_network_peer_round_trip_time_seconds_sum",m) for m in M)/n*1000 if n else 0
    r=lambda k:(g(d,k,lead)-g(q,k,lead))/sec
    for k,v in (("prop",prop),("pend",pend),("cpu",max(cpu)),("fs",max(fs)),("bc",max(bc)),("rtt",rtt),("db",g(d,"etcd_mvcc_db_total_size_in_bytes",lead)/2**20),("rss",max(g(d,"process_resident_memory_bytes",m) for m in M)/2**20)): mx[k]=max(mx[k],v)
    print(f"{t[11:19]} {prop:6.0f} {pend:4.0f} | {cpu[0]:4.2f} {cpu[1]:4.2f} {cpu[2]:4.2f} | {g(d,'process_resident_memory_bytes',M[0])/2**20:5.0f} | {fs[0]:5.0f} {fs[1]:5.0f} {fs[2]:5.0f} | {bc[0]:5.0f} {bc[1]:5.0f} {bc[2]:5.0f} | {rtt:5.1f} | {g(d,'etcd_mvcc_db_total_size_in_bytes',lead)/2**20:5.0f}/{g(d,'etcd_mvcc_db_total_size_in_use_in_bytes',lead)/2**20:5.0f} | {r('etcd_mvcc_put_total'):5.0f} {r('etcd_mvcc_delete_total'):5.0f} {r('etcd_mvcc_range_total'):6.0f}")
print("max",{k:round(v,1) for k,v in mx.items()})
# whole run fsync/commit percentiles
a,b=S[ts[0]],S[ts[-1]]
for m in M: print(m,"run fsync p50/p99 %.0f/%.0f ms commit p50/p99 %.0f/%.0f ms"%(pct(b,a,"etcd_disk_wal_fsync_duration_seconds",m,.5),pct(b,a,"etcd_disk_wal_fsync_duration_seconds",m,.99),pct(b,a,"etcd_disk_backend_commit_duration_seconds",m,.5),pct(b,a,"etcd_disk_backend_commit_duration_seconds",m,.99)),
  "mean fsync %.1f ms"%((g(b,"etcd_disk_wal_fsync_duration_seconds_sum",m)-g(a,"etcd_disk_wal_fsync_duration_seconds_sum",m))/max(1,g(b,"etcd_disk_wal_fsync_duration_seconds_count",m)-g(a,"etcd_disk_wal_fsync_duration_seconds_count",m))*1000))
EOF
python3 /tmp/etcd.py

Read tool output
Completed with input: {
  "forceReadLargeFiles": true,
  "path": "/var/folders/0n/vxjjv39d1hn91p1dqb3pxr9c0000gp/T/1792751974741-copilot-tool-output-45628-87fbc85b-7fbe-4b6d-9773-97be5b3bd7ee.txt"
}

Ran terminal command: cd /Users/tferrandiz/.copilot/session-state/c80e7128-81d6-41fe-8c56-8da630eead04/files/results4/* && awk -F'\t' '$2~/(proposals_failed|slow_apply|leader_changes)/ && $2~/bench-cp-01|bench-cp-03/{k=$2; if(k in p && $3!=p[k]) print substr($1,12,8), k, $3-p[k]; p[k]=$3}' etcd-metrics.tsv | head -40

Ran terminal command: cd /Users/tferrandiz/.copilot/session-state/c80e7128-81d6-41fe-8c56-8da630eead04/files/results4/* && python3 - <<'EOF'
import collections,datetime as dt
S=collections.OrderedDict()
for l in open("apiserver-metrics.tsv"):
    t,s,v=l.rstrip("\n").split("\t"); S.setdefault(t,{})[s]=float(v)
ts=list(S); T=lambda t: dt.datetime.strptime(t,"%Y-%m-%dT%H:%M:%SZ")
def lat(pfx,key,lab,t,p):
    s=f'{pfx}_sum{{{key}="{lab}"}}'; c=f'{pfx}_count{{{key}="{lab}"}}'
    n=S[t].get(c,0)-S[p].get(c,0); return ((S[t].get(s,0)-S[p].get(s,0))/n*1000 if n>0 else 0, n)
ops=sorted({k.split('operation="')[1].split('"')[0] for k in S[ts[-1]] if k.startswith("etcd_request_duration_seconds_count")})
print("ops",ops)
print("time     cpu  rss  mut/ro exec inq rej  req/s | apiserver ms POST DELETE LIST | etcd-client ms create update delete get list (n) | etcdErr | objects dbMiB")
a,b=S[ts[0]],S[ts[-1]]
for i in range(1,len(ts)):
    t,p=ts[i],ts[i-1]; d,q=S[t],S[p]; sec=(T(t)-T(p)).total_seconds() or 1
    cpu=(d["process_cpu_seconds_total"]-q["process_cpu_seconds_total"])/sec
    rej=sum(d[k]-q.get(k,0) for k in d if "rejected" in k)
    req=sum(d[k]-q.get(k,0) for k in d if k.startswith("apiserver_request_total"))/sec
    ex=sum(v for k,v in d.items() if "executing" in k); inq=sum(v for k,v in d.items() if "inqueue" in k)
    mu=d.get('apiserver_current_inflight_requests{request_kind="mutating"}',0); ro=d.get('apiserver_current_inflight_requests{request_kind="readOnly"}',0)
    api=[lat("apiserver_request_duration_seconds","verb",v,t,p)[0] for v in ("POST","DELETE","LIST")]
    et=[lat("etcd_request_duration_seconds","operation",o,t,p) for o in ("create","update","delete","get","list")]
    err=sum(d[k]-q.get(k,0) for k in d if k.startswith("etcd_request_errors_total"))
    print(f"{t[11:19]} {cpu:4.1f} {d['process_resident_memory_bytes']/2**30:4.1f} {mu:3.0f}/{ro:<3.0f} {ex:4.0f} {inq:3.0f} {rej:4.0f} {req:5.0f} | {api[0]:6.0f} {api[1]:6.0f} {api[2]:5.0f} | "+" ".join(f"{x[0]:5.0f}" for x in et)+f" ({sum(x[1] for x in et)/sec:4.0f}/s) | {err:4.0f} | {d.get('apiserver_storage_objects',0):7.0f} {d.get('apiserver_storage_size_bytes',0)/2**20:5.0f}")
codes=collections.Counter(); bad=collections.Counter()
for k in b:
    if k.startswith("apiserver_request_total"):
        dl=b[k]-a.get(k,0); c=k.split('code="')[1].split('"')[0]; v=k.split('verb="')[1].split('"')[0]; codes[c]+=dl
        if c[0] in "45" and dl>0: bad[f"{v} {c}"]+=dl
print("total",sum(codes.values()),dict(bad.most_common()))
print("rejected",{k.split('flow_schema="')[1].split('"')[0]+"/"+k.split('reason="')[1].split('"')[0]:b[k]-a.get(k,0) for k in b if "rejected" in k and b[k]-a.get(k,0)>0})
print("etcd errors",{k:b[k]-a.get(k,0) for k in b if k.startswith("etcd_request_errors") and b[k]-a.get(k,0)>0})
for o in ops:
    m,n=lat("etcd_request_duration_seconds","operation",o,ts[-1],ts[0])
    if n: print(f"  etcd-client {o:18s} n={n:8.0f} mean={m:6.1f}ms")
for v in ("POST","PUT","PATCH","DELETE","LIST","GET"):
    m,n=lat("apiserver_request_duration_seconds","verb",v,ts[-1],ts[0]); print(f"  api {v:6s} n={n:8.0f} mean={m:6.1f}ms")
EOF

Read tool output
Completed with input: {
  "forceReadLargeFiles": true,
  "path": "/var/folders/0n/vxjjv39d1hn91p1dqb3pxr9c0000gp/T/1792751999826-copilot-tool-output-45628-fcd57440-39b3-4802-bd4a-07851f8cc991.txt"
}

Ran terminal command: cd /Users/tferrandiz/.copilot/session-state/c80e7128-81d6-41fe-8c56-8da630eead04/files/results4/* && awk -F'\t' '$1>="2026-10-23T10:04" && $1<="2026-10-23T10:08" && ($2=="process_cpu_seconds_total"||$2=="go_goroutines"||$2=="process_resident_memory_bytes"||$2~/request_total\{verb="PUT",code="200"/||$2~/inflight/){print substr($1,12,8),$2,$3}' apiserver-metrics.tsv; echo; awk '/^20[0-9][0-9]-/{ts=substr($1,12,8);next} /^bench-cp/{if(ts>="10:04" && ts<="10:08:30") printf "%s %s cpu=%s(%s) mem=%s\n", ts,$1,$2,$3,$5}' node-usage.txt

Ran terminal command: cd /Users/tferrandiz/.copilot/session-state/c80e7128-81d6-41fe-8c56-8da630eead04/files && for d in results/*/ results2/*/ results3/*/ results4/*/; do printf "%s gor=%s rss=%s\n" "$(basename $d | cut -c23-40)" "$(awk -F'\t' '$2=="go_goroutines"{print $3; exit}' $d/apiserver-metrics.tsv)" "$(awk -F'\t' '$2=="process_resident_memory_bytes"{printf "%.2f", $3/2^30; exit}' $d/apiserver-metrics.tsv)"; done; cd results4/*; grep -c '<unknown>' after.txt; grep -c '^bench' after.txt; jq -r '[.items[]|select(.status.conditions[]|select(.type=="Ready" and .status!="True"))]|length' nodes.json; echo; awk -F'\t' '$2~/db_total_size_in_use_in_bytes\{member="bench-cp-02"/{v=$3/2^20; if(p && v<p-5) print substr($1,12,8), "compaction: in-use", int(p), "->", int(v), "MiB"; p=v}' etcd-metrics.tsv; awk -F'\t' 'NR==1{print "first sample", $1}' etcd-metrics.tsv; awk -F'\t' '$2~/db_total_size_in_bytes/ {last[$2]=$3; if(!($2 in first)) first[$2]=$3} END{for(k in last) printf "%s %.0f -> %.0f MiB\n", k, first[k]/2^20, last[k]/2^20}' etcd-metrics.tsv

Ran terminal command: rm -f /tmp/etcd.py /tmp/an.py; ls /tmp/*.py 2>/dev/null | head

## Run 4 analysis: 2000 iterations at QPS 200, with etcd metrics

All objects were created, read, patched and deleted, and every node stayed Ready (1003 nodes). The runner still exited **3** because of a burst of **296 Service-delete timeouts** between 10:05:48 and 10:05:50. Those Services were cleaned up later by namespace deletion.

### Comparison with run 3

| | Run 3 | Run 4 |
|---|---|---|
| Total duration | ~40 min | 41.5 min |
| API-server goroutines / RSS at start | 50k / 5.6 GiB | **65k / 6.9 GiB** |
| POST latency during create | 113 → 712 ms | 88 → 939 ms |
| API-server CPU during create | ~7 cores | 6.2–6.5 cores |
| remove-services | ~13 s, no errors | **50 s, 296 timeouts** |
| WATCH 429s | 1,881 | 1,640 |
| Node heartbeat (`PUT`) 429s | – | **2,174** |
| Namespace cleanup | 13 min | 14 min |

Creation saturates at the same point as in run 3: about 6 cores of API-server CPU on bench-cp-01, with in-flight mutating requests reaching 193.

### What happened at 10:05:36 (Service deletion)

These numbers come from the API server on bench-cp-01:
- **Requests in flight:** 506 mutating requests and 180 queued. There were 3,152 APF rejections, of which 2,273 were in `system-node-high`, so kubelet heartbeats were being dropped.
- **Errors:** `DELETE 504` ×315, `PUT 504` ×233 and `GET 500` ×207. etcd client errors: 235 updates and 77 gets.
- **API server to etcd latency:** gets averaged 883 ms to 1,026 ms, updates about 700 ms and deletes about 550 ms.
- **etcd server side:** commit p99 was only 64 ms and fsync stayed healthy. The bench-cp-01 member logged **2,651 slow applies and 224 failed proposals**; bench-cp-03 had 106 slow applies and 3 failed proposals.
- **Goroutines dropped from 71k to 22k and RSS from 7.7 to 5.4 GiB** without a restart (the CPU counter kept counting), meaning about 50k watches were closed at once.
- **Node CPU was not the limit:** bench-cp-01 was at only 18–50% CPU.

My interpretation (not proven):
- Deleting 2,000 Services and their EndpointSlices fans out to every watcher of those resources, including the Cilium agents on all ~1000 nodes.
- With 65k watches open, the API server on bench-cp-01 fell behind. Its local etcd member (the API server talks to `127.0.0.1:2379`) built an apply backlog. Requests then hit their 60 s timeout, and the API server dropped the slow watchers.
- The extra 15k goroutines at the start of the run probably explain why this run broke and run 3 didn't. They likely date from the rolling `rke2-server` restarts done to enable etcd metrics, with all watchers then reconnecting to bench-cp-01 through the VIP.

### etcd conclusions

- **Disk is fine:** fsync p99 is 8–16 ms and backend commit p99 is 16–32 ms.
- **CPU is fine:** etcd used only 0.3–0.7 cores per member.
- **Leaders are on different nodes:** the etcd leader was bench-cp-02 for the whole run (no leader changes), while the VIP and the busy API server are on bench-cp-01. The degraded member is the one sharing a node with the overloaded API server.
- **Compaction works but the database file doesn't shrink:** compaction runs every 5 min, and in-use data fell back to 124 MiB. The database file grew from 112 to **469 MiB** and stays that size until defragmented. That is well below the 2 GiB quota.
- **LIST latency during patch:** it rose from about 40 ms to about 200 ms between 09:59 and 10:04, as the database peaked at about 466 MiB in use.

### Recommendations

1. **Restart the API servers (or the whole cluster) before each run** so the runs start from the same baseline. Record `go_goroutines` in `baseline.txt`.
2. **Add control-plane CPU,** or spread clients so they don't all hit bench-cp-01. kube-vip in ARP mode sends everything to one node.
3. **Lower delete QPS,** for example `qps: 50` on `remove-services`, if you want a run that exits 0. Otherwise treat these timeouts as a real finding at 2000 iterations and QPS 200.
4. **Defragment between runs:** `etcdctl defrag --cluster`, one member at a time.
5. **Optionally move etcd leadership to bench-cp-02 or bench-cp-03 deliberately** (`etcdctl move-leader`) so the VIP node only runs the API server's load.

