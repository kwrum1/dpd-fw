# N5000 加速平面巡检（2026-11-09 晚）

设备：N5000，ImmortalWRT SNAPSHOT，6.18.55，4 核；ABI 20；`mode=stateful`；
`auto_tune=1`；einat 持有 SNAT；honk 在环。

## 1. 计数器快照

```
pkt_total   1683486   bytes        3775620337
flow_hit     370188   flow_miss     1205824   flow_write 25067
bytes_v4  800237093   bytes_hit_v4  110572490   (13.8%)
bytes_v6 2974013426   bytes_hit_v6 2811855158   (94.5%)
nat_dnat 1033  nat_snat 6196  nat_alloc 26  nat_gone 0  nat_exhaust 0
flows: 2919 entries (v4 2327, v6 592)
gate: stateful / ok；checks uplink/einat/einat_on_uplink/honk/honk_p1 全 true
```

## 2. v4 命中率低的结论：不是 v4 路径故障

强制走 IPv4 从 NAS 下载（`curl -4 --resolve tuna:443:101.6.15.130`，20 s）：

| 项 | 之前 | 之后 | 增量 |
|---|---|---|---|
| bytes_v4 | 1 078 548 903 | 1 739 079 978 | 660 531 075 |
| bytes_hit_v4 | 111 623 334 | 768 192 576 | **656 569 242（99.4%）** |
| flow_hit | 375 586 | 588 968 | +213 382 |
| flow_miss | 1 263 937 | 1 274 074 | +10 137 |

单条 v4 大流接管率 99.4%，说明 v4 快速路径、einat NAT 闸门、PPPoe 出口都正常。
13.8% 是**启动以来的累计值**：这段时间的大流量测试实际走了 IPv6
（curl 优先 v6），v4 侧积累的多是 DNS/TLS 短连接，达不到 `accel_after`
（自动调参已降到 8）就被判为短流。

## 3. 真正的问题：邻居事件每秒一次地清空流表

`flowd.json` 20 秒采样：`neigh` +20、`epoch_bumps` +10（约每 2 秒一次全表
失效）。`dpdfwd` 把 `RTM_NEWNEIGH/RTM_DELNEIGH` 和链路/地址/路由变化同等
对待；IPv6 NUD（REACHABLE/STALE/DELAY/PROBE）本身就会持续产生事件。

影响：

- 大流每次失效后重新 prime（`accel_after=8` 包/方向），字节命中率仍能保持
  很高（实测 99.4%）；
- 短流几乎永远等不到接管，`flow_hit/(flow_hit+flow_miss)` 只有 23%，看起来
  “命中率很低”；
- `dpd_flows` 表里大量 `pkt=0` 的旧 epoch 条目，占着 2919/16384 个槽位。

建议修复（待做）：`neigh` 事件不再触发全表 epoch bump，只在
link/addr/route 变化时 bump；若确实需要处理 MAC 变化，限定到受影响接口，
或给 neigh bump 加 ≥30 s 冷却。

## 4. 自动调参过于抖动

10 秒窗口内 TCP TTL 在 120 s ↔ 450 s 之间来回跳（`short_ratio` 2% ↔ 25%）。
建议：对 TTL 变化做每轮限幅（例如单次最多 ±20%）或把窗口拉长到 30–60 s，
避免同一批流一会儿 2 分钟过期、一会儿 7 分钟不过期。

## 5. NAPI 低延迟/自适应已生效

`dpd-napi 0.1.0-r9`，`mode=adaptive`：

| 状态 | profile | budget | gro/defer | RPS/XPS |
|---|---|---|---|---|
| 空闲 | low | 300 | 0 / 0 | 0 |
| 4×`yes` 压满 CPU 36 s | throughput | 1000 | 20000 / 2 | f |
| 停压 66 s | low | 300 | 0 / 0 | 0 |

`switches` 0→1→2，切回正常。`netdev_budget_usecs` 在本内核写 2000 返回
EINVAL（下限 20000），脚本现在回报实际值，不再虚报。

## 6. NAS IPv6 Web 外网访问：已修好

现象：页面加规则后从公网访问超时；路由器 tcpdump 显示 SYN 到达
`pppoe-wan` 后由路由器直接回 RST。

两个原因：

1. 遗留的 `firewall.ebpf999`（WAN→LAN 全 REJECT）排在 fw4 自动的
   `ct status dnat accept` **前面**，所有端口转发先被它拒掉。默认拒绝已经由
   `defaults`/WAN zone 的 REJECT 策略保证，这条规则多余且有害。它会被
   `ebpf-posture`（S26）和 `99-luci-ebpf-trim` 在每次启动时重建，所以 r5
   把这两个脚本改成**删除**该规则、不再创建。
2. IPv6 端口转发用 DNAT 是空操作：报文本来就发往 NAS 地址，
   “dnat 到同一地址:同一端口”不会让 nf_nat 标记 conntrack 为 dnat，
   于是 `ct status dnat accept` 不匹配，继续落到 WAN reject。

修复（页面 r4 逻辑）：目标是 IPv6 且公网端口=目标端口（或公网端口留空）时，
生成**纯转发放行**（`src=wan dest=lan dest_ip=<IP> proto tcp dest_port=<port>
target=ACCEPT`），不做 DNAT。验证：

```
curl -6 http://[2408:824c:8030:99b0:0:ff:fe22:a01]:5666/
-> 200, 0.035 s（公网侧）
```

`5666` 是 fnOS 的 HTTP 端口；`80` 未放行，所以只开 5666（需要 HTTPS 再放
5667）。

## 7. 现场当前状态

- `luci-app-ebpf 0.7.0-r5`：name 前缀归属、目标/目标端口/公网端口、
  IPv6 同端口走纯放行；posture/uci-defaults 不再重建 `ebpf999`。
- `dpd-napi 0.1.0-r9`：adaptive 低延迟默认。
- `dpd-fw`：`a3a4257` + 本次巡检改动。
- 遗留：两条重复的 `Allow-Agent-SSH`（测试用，收尾时删一条）。
