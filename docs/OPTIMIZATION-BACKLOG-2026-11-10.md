# DPD 优化潜力清单（2026-11-10）

基于当前 ABI 20 数据面（`dpd_fastpath.bpf.c`）与 N5000 实测数据。按"预期收益 / 风险"
排序，每条给出依据、做法、验证方式。

## 0. 当前每包成本模型（命中路径）

一个已接管的 v4 TCP NAT 流，每包依次做：

1. 解析 L2/L3/L4，构造 `dpd_flow_key`；
2. `bpf_map_lookup_elem(dpd_flows)`（LRU hash，40B key）；
3. TTL/epoch 判断（两条比较）；
4. 每流计数：`packets++`、`bytes += len`（两次 64 位 RMW）；
5. TCP FIN/RST 判断（一次头解析）；
6. priming 判断；
7. `DPD_INC(flow_hit)` → 每 CPU 统计块一次 RMW；
8. `dpd_touch()`：每 250 ms 才写一次 `last_seen_ms`；
9. VLAN 策略判断；
10. **NAT 闸门**：`bpf_map_lookup_elem(dpd_nat)`（仅上行 NAT 流，约一半流量）；
11. `skb->priority` 恢复；
12. TTL-1 + 增量校验和；
13. `DPD_INC(bytes_hit_v4)` + `DPD_INC(l2_v4)` → 两次每 CPU RMW；
14. 写 L2 头 + `bpf_redirect()`。

结论：**每包 2 次 map 查找、3–4 次每 CPU 计数、1 次 `bpf_ktime_get_ns`**。
优化空间主要在第 2、10、12 步和"谁来触发失效"。

## 1. 实测基线

| 指标 | 值 | 来源 |
|---|---|---|
| 累计命中率 | 96.9%（94.8M hit / 3.07M miss） | 重启后 4 h |
| 空闲瞬时 | ~52 hit/s vs ~37 miss/s | 重启后 3 min 采样 |
| epoch bump | 258 次 / 8036 s ≈ **1 次/31 s** | flowd.json |
| 邻居事件 | 6503 次 / 8036 s ≈ 0.8/s | flowd.json |
| 流表 | 8039 → 680 条（r8 prune 后） | dpdctl status |
| fib_fail | 1.78M（vs fib_ok 1.03M） | 累计 |
| nat_gone | ~186 | 累计 |
| ct 事件 | 15 new/s、4.5 destroy/s | flowd.json |

**关键推论**：邻居事件以 0.8/s 的频率持续触发，30 s 冷却被顶满；每次 bump 让整张表
逻辑失效，所有活跃流都要重新走 8 个包的 priming。空闲时 37 miss/s 里绝大部分是重学，
不是新流。

## 2. 优化项

### P0 邻居事件的 epoch 策略（收益最大，已量化）

现在：任何 `RTM_NEWNEIGH/DELNEIGH`（限频 30 s）都会 bump 全局 epoch。
目标：只在**邻居状态真的变坏**时失效（`NUD_FAILED/INCOMPLETE`，或同一 IP 的 `lladdr`
变了），普通 REACHABLE 刷新不 bump；保留 5 min 兜底 bump。

- 预期：epoch bump → 接近 0；miss/s 降到"新流 + 短流"水平，命中率 99%+；
  `flow_write` 从 36/s 降到个位数。
- 风险：交换机/AP 漫游导致的静默 dmac 变化最长 5 min 黑洞；可接受，且比现在
  "每 30 s 全表重学"代价小。
- 实现：`dpdfwd.c` 的 `neigh` 分支解析 `ndm_state`/`lladdr`，维护小哈希表；
  `NEIGH_BUMP_MS` 改 300000。
- 验证：`flow_miss` 增量、`epoch_bumps`、命中率。

### P1 NAT 闸门按时间重新验证，而不是每包查

上行 NAT 流每包都要 `dpd_nat` 查一次，只为确认 einat 绑定还在。加一个
`nat_checked_ms`（或复用 flags 高位），**每 250 ms 只查一次**。

- 预期：上行每包省一次 hash 查找（约 20–30 ns/包，按 2 Gbit/s 小包约 3–5% CPU）。
- 风险：einat 绑定被回收后最多 250 ms 内仍放行 → 极少量的错包（einat 侧也会丢）。
- 需要 ABI 21（`struct dpd_flow_val` 加字段）。

### P2 用 `bpf_jiffies64()` 代替每包 `bpf_ktime_get_ns()`

TTL 是秒级、refresh 250 ms，10 ms 分辨率足够。

- 预期：省一次 ktime 读（约 10–20 ns/包）。
- 风险：低；`last_seen_ms` 分辨率降到 10 ms，不影响任何判断。
- 实现：数据面 4 处取时间的地方统一。

### P3 dpdfwd 每秒 fork 一次 `dpdctl delete -f`

`ct_flush()` 每秒无条件 `system("dpdctl delete -f ...")`，即使文件为空。

- 预期：省 86k 次 fork+exec/天（约 0.5–1% CPU）。
- 实现：文件不存在或为空时直接返回；或改成每 2 s 批量。

### P4 统计计数器瘦身

命中路径有 3–4 次每 CPU RMW。两个方案：

- 把 `bytes_hit_v4`/`l2_v4` 从每包累加改为 `dpdfwd` 每 60 s 遍历流表求和（它已经在
  遍历做 prune）→ 每包省 2 次 RMW；
- 或默认 `flow_counters=2`（1/16 采样）。

- 预期：小包场景 2–5% CPU。
- 代价：首页数字从实时变成 60 s 粒度；`dpdctl stats` 的口径要写清楚。

### P5 LRU hash 换成普通 hash + 显式淘汰

r8 已经有"过期即删 + 60 s 扫表"，LRU 的每次访问记账可能是纯开销。

- 先测：`bpftool prog profile id <id> duration 10` 看 cycles/包，A/B 两个 map 类型。
- 风险：普通 hash 满后插入失败 → 需要"满了删最老"或直接不学，行为要定义。

### P6 miss 路径的 FIB 成本

`fib_fail` 1.78M 仍高于 `fib_ok`。先测当前 `fib_fail` 增量（r8 之后），
如果仍高，说明还有大量无法转发的目标（组播/黑洞地址），可以：

- 对同一 /24 的连续失败做 1 s 负缓存（per-CPU 小表）；
- 或在 FIB 前先判本地子网/保留地址。

- 预期：取决于剩余比例，先测再定。

### P7 上行 ppp 的 `bpf_redirect_neigh`

L3OUT + NH4 每包走 `bpf_redirect_neigh`（内核里做一次 neigh 查找）。
没有安全的 BPF 侧缓存手段；可以测 `neigh_ok` 与 `redirect_ok` 的每包成本，
决定是否值得把 ppp 流整体留在协议栈（只加速下行）。

### P8 TTL 上限 600 s → 900 s

有了"过期即删 + 扫表"，长 TTL 不再堆积死条目。长连接（视频、游戏）少一次重学。

- 风险：绑定变化后最长 15 min 才自然过期（但 delete-on-lookup 会在下次查到时删）。

### P9 GRO/IRQ 的剩余空间

`irq_spread` 已开、RPS/XPS 关、`gro_flush_timeout=0`。可测：

- 开了 `gro_flush_timeout` 后 TCP 吞吐/延迟的拐点（当前低延迟档）；
- XPS 在 ppp 单队列上的影响（大概率无意义）。

## 3. 建议顺序

1. **P0**（唯一有"数量级"收益的项，已量化）
2. **P1 + P2**（一起做一次 ABI 21，顺带 P4 的口径调整）
3. **P3**（一行判断，零风险）
4. 测 P5/P6 再决定，P7/P8/P9 属于微调。

## 4. 测量方法

- 每包成本：`bpftool prog profile id <id> duration 10`（cycles、instructions），
  对比改动前后；没有 bpftool 时用 `perf stat -e cycles,instructions` 跑 netns 打流。
- 命中率/重学：`dpdctl status -j` 的 `flow_hit/flow_miss/flow_write` 30 s 增量。
- 失效：`/var/run/dpd/flowd.json` 的 `epoch_bumps`、`neigh`。
- 小包 PPS：`tests/bench/small-packet-*.sh`（netns，`-b 0`）。
