# 数据面加速架构研究：TC/TCX 快路径的剩余每包成本与可选机制

> 日期：2026-11-02
> 范围：**只做研究与方案评估，不改代码**。目标是在不换硬件、不做第二套 NAT、不破坏
> “honk 在 TCX 先跑”排序的前提下，找出还能降低每包延迟、提高转发效率的开源实现与内核机制。
> 证据等级沿用项目习惯：**实测**＝本项目镜像/真机/源码树看到的；**上游**＝内核源码、项目文档、
> 公开 benchmark；**估算**＝基于成本模型的推算，必须用第 8 节的测量方法验证后才可上线。

---

## 0. 结论先行

1. **最大的剩余开销不在 BPF 程序里，而在出口路径。** `bpf_redirect()` 之后仍然要走
   `skb_do_redirect()` → `dev_queue_xmit()` → 出口 TCX → qdisc → BQL → 驱动；下载方向还要
   过 `br-lan` 和网口两层 qdisc。**未整形时把 CAKE/`fq` 换成 `pfifo`/`pfifo_fast`（或只在
   真正整形时保留 CAKE）是零代码、可回滚、收益最大的一项**：估算吞吐 +3–10%（CPU 受限时），
   p99 改善 0.1–0.5 ms。成本 2–3 人日，风险低。
2. **dpd 提到 TCX 可行，但必须“挂在 honk 之后 + 用 `DIRECT_UNSPEC_MARK` 门控”。**
   p1 核心已经给 direct 流打 `0x2000_0000` 并返回 `TC_ACT_UNSPEC`；把 dpd 用
   `BPF_F_AFTER` 挂到 honk 的 link 之后，顺序正确时收益是 **1–3%**（64B 高 pps 更明显），
   顺序错了则“零加速”而不会偷走代理流——这是 **fail-safe**。成本 4–6 人日，风险中
   （honk 重启后 link id 变化，必须看门狗重挂）。
3. **dpd 命中路径还能再减 1–3%**：去掉每包 `bpf_ktime_get_ns()`（改用 cfg 里 1 Hz 更新的
   `now_ms`）、把 `dpd_cfg` 与 `dpd_stats` 合并成一次 per-CPU lookup、TTL 校验和改为内联
   增量更新。合计约 20–60 ns/包，成本 3–4 人日，风险低，但需要 ABI 12。
4. **VLAN 出口是当前最大的“隐藏回退”。** 代码里 `l2_ok = !tagged`，任何带 802.1Q 的流都
   退回 `bpf_redirect_neigh()`，等于**每包一次完整 FIB + 邻居查找**。用
   `bpf_skb_vlan_push/pop` + 直发父设备可把这部分拿回来；对 VLAN WAN/IPTV 用户估算
   +5–15%。成本 3–5 人日，风险中（tag/MTU/stacked device 的正确性）。
5. **XDP、AF_XDP、DPDK、VPP、Snabb、PF_RING/ZC、netmap 全部不做。** 它们要么在 TCX
   之前接管（破坏 honk 优先），要么独占 RX 队列（einat/honk/conntrack 看不到包），要么
   与 OpenWrt 的集成成本远超家用收益。AF_XDP **copy 模式**在 2.5G 的 64B 线速（约
   3.7 Mpps）上已接近单核上限，zero-copy 又要求队列隔离——都不解决我们的问题。
6. **测量必须先于优化。** `ping` 和大包 iperf3 会把 1–3% 的差异完全埋掉。用
   `bpftool prog run/profile` 算 BPF 程序自身 cycles/run，用 `perf stat` 算整机
   cycles/packet，用 `SO_TIMESTAMPING`/`irtt`/`sockperf` 量 p99，固定速率 A/B，才有决策价值。

> **如果只能做一件事**：先做 W1 的 qdisc A/B（零代码、可回滚）。
> **如果做两件**：加 XPS（1 人日）。**如果要结构性改善**：TCX-after-honk。
> ABI 12 放在测量台稳定之后，不要和 qdisc 改动同一周上线。

---

## 1. 基线与每包成本模型

### 1.1 项目内已实测事实（用于校准，不重复测量）

| 事实 | 数字 | 来源 |
|---|---|---|
| x86 2 vCPU 下载，dpd 关闭 → 开启 | 2.72 → 3.44 Gbit/s | 项目实测（任务描述） |
| honk p1 直连回交 classic 后 | 3.77–4.18 Gbit/s | 项目实测（任务描述） |
| 固定 2 Gbit/s 转发 CPU（stock → eBPF） | 44% → 28% | `src/docs/bench-3way.md`（ESXi/vmxnet3） |
| 固定 3 Gbit/s | 61% vs 63%，单核 72–74% | 同上 |
| 小包（MSS 56） | 32.3 万 → 36.3 万 pps，0% 丢包 | 同上 |
| 内核能力 | `RPS=y XPS=y BQL=y NET_RX_BUSY_POLL=y PAGE_POOL=y GRO_CELLS=y`，`NET_SCH_CAKE=m NET_SCH_FQ_CODEL=y`；6.12.87 树里 `NET_SCH_FQ=m`（6.18.55 按上一轮文档需 `kmod-sched` 才有 `sch_fq`，上线前 `modinfo sch_fq` 确认）；`NET_SCH_ETF` 未开 | `lab/.../linux-6.12.87/.config`（实测） |

> **重要校准**：上面的 CPU 数字来自 ESXi + vmxnet3 虚拟机，2–3 Gbit/s 时成本主要花在
> vSwitch、vmxnet3、软中断和 skb 分配上，**不是**真实 i211/i226 的比例。真机上每包成本
> 会低一个档，因此本报告所有百分比都是“CPU 受限时的相对收益”，不是绝对吞吐承诺。

### 1.2 每包成本分解（裸金属 x86 3 GHz、1500B、无 GSO 时的**估算**）

| 阶段 | 典型 cycles/包 | 说明 |
|---|---:|---|
| NIC RX + 描述符 + skb 分配（`napi_alloc_skb`/`build_skb`） | 250–500 | 驱动与内存带宽决定，eBPF 改不了 |
| NAPI + GRO + `netif_receive_skb` | 150–300 | GRO 聚合后每包摊薄 |
| honk TCX（代理在跑时） | 100–250 | 判定 + map + mark；代理/阻断终态 |
| einat TCX（WAN egress/ingress） | 150–400 | NAT binding + CT + 校验和；NAT 唯一归属，省不掉 |
| classic `tcf_classify` + dpd | 150–350 | 含一次间接调用；TCX 化可省一部分 |
| `bpf_fib_lookup` + 邻居（仅 miss / VLAN 回退） | 400–1000 | 命中路径不应有 |
| `dpd_flows` LRU 查找 | 40–100 | LLC miss 时可到 200+ |
| TTL 校验和 helper + `bpf_ktime_get_ns` + cfg/stats lookup | 60–120 | 本次可削减 20–60 |
| `dev_queue_xmit` + 出口 TCX + qdisc（`fq`/CAKE） | 150–600 | **最大可控项** |
| 桥 `br_dev_xmit` + FDB + 端口 qdisc | 100–400 | 下载方向独有，可尝试绕过 |
| 驱动 TX + BQL | 80–200 | 驱动决定 |

合计约 **1.2k–3.0k cycles/包 ≈ 0.4–1.0 µs**（3 GHz）。在 30 万 pps 下就是单核的
12–30%。这就是为什么“再优化一次 map lookup”最多只有 1–2%，而 qdisc/桥/出口路径能到
5–10%。

> 虚拟机里同一套路径会被 vSwitch 放大 3–10 倍，所以 `bench-3way.md` 里 3 Gbit/s 就撞到
> 单核 72%。**在真机上做 A/B，不要用虚拟机的绝对 CPU 百分比推断真机。**

### 1.3 三条结构性判断

1. **单流天花板 = 一个 RX 队列 + 一个 TX 队列。** RSS 把不同流分到不同队列，但 iperf3
   单流只会落在一个队列；RPS 只能把“这个队列的软中断”挪到另一个核，不能让一个流并行。
   单流唯一的杠杆是 **GRO/GSO 聚合**（把每包成本摊到 64KB）和**减少每包固定开销**。
2. **任何在 TCX 之前接管包的机制都不安全。** XDP、TCX-BEFORE、`bpf_redirect(..., BPF_F_INGRESS)`
   都可能让 honk 看不到本应代理的流；本项目已经有 p1 的 `DIRECT_UNSPEC_MARK`，正确做法是
   **只消费 honk 已经判定为 direct 的包**。
3. **任何独占队列的机制都不安全。** AF_XDP/XSK、DPDK、PF_RING ZC、netmap 都会让内核
   协议栈看不到这些包，einat 的 conntrack-free NAT 和 honk 的 TCX 就都失效了。

---

## 2. 机制逐项判定（覆盖题目要求）

### 2.1 内核数据面

| 机制 | 事实/结论 | 对本项目 |
|---|---|---|
| `bpf_redirect()` 的剩余路径 | helper 只写 `bpf_redirect_info` 并返回 `TC_ACT_REDIRECT`；真正的重定向在 `skb_do_redirect()`：`dev_get_by_index_rcu()` → `skb->dev = dev` → `dev_queue_xmit()`。后者含 `netdev_pick_tx()`（XPS）、`sch_handle_egress()`（出口 TCX）、qdisc enqueue、`__qdisc_run()/sch_direct_xmit()`、BQL、`ndo_start_xmit()`。**BPF 无法跳过 qdisc。** | 出口 qdisc 是本报告第一杠杆；不要幻想用 helper 绕过 |
| `dev_queue_xmit()` 的锁与队列 | 单流单队列时 `HARD_TX_LOCK` 基本无竞争；`sch_direct_xmit()` 在队列空时可直发，但 `fq`/CAKE 仍需先 enqueue 再 dequeue。`mq` 只是把锁分到多个叶子。 | 换 `pfifo` 可去掉分类/哈希/定时器；`mq` 对多流有帮，对单流无帮 |
| `BPF_F_INGRESS` | `bpf_redirect(ifindex, BPF_F_INGRESS)` → `dev_forward_skb()`，把包注入目标设备的 **RX/ingress**，会再走一遍该设备的 ingress 路径（并可能再触发 TC）。 | **不用**：会重复 ingress、可能成环，还会让 honk/einat 二次处理 |
| tc-bpf `direct-action` | `tc filter ... bpf da` 让程序直接返回 `TC_ACT_*`，不分配 `tcf_exts`/不返回 classid。项目已经用了 `da`。 | 保持；这是 classic 链里唯一必须的优化 |
| `skb->tc_at_ingress` | `sch_handle_ingress()` 置位、`sch_handle_egress()` 清零，供 tc 核心判断方向；不是可调杠杆。 | 不需要动 |
| GRO / `napi_gro_receive()` | GRO 在 TC ingress **之前**聚合，dpd 看到的是 GSO skb；ABI 9 已按 `ihl + l4h + gso_size` 算单段长度，修好了 `FRAG_NEEDED`。`bpf_redirect()` 在出口支持 GSO 时保留聚合，否则 `validate_xmit_skb()` 分段。 | 保持 GRO 开；**不要为了“看到更多包”关 GRO**（实测关 GRO 吞吐 4.5→0.95 Gbit/s） |
| `gro_flush_timeout` / `napi_defer_hard_irqs` | 软件 IRQ 合并：空轮询 `napi_defer_hard_irqs` 次后挂一个 `gro_flush_timeout` 定时器再开中断。大值省 IRQ、增延迟；小值低延迟、IRQ 多。 | 做**双档 profile**：吞吐档 20–50 µs / defer 2；延迟档 0/0。不要全局默认大值 |
| `netdev_budget` / `netdev_budget_usecs` | 一次 NAPI poll 的包数/时间上限。项目已按内存档设 300/600/900。 | 2 vCPU 上不建议再抬；抬了只会增加单次软中断占用，p99 变差 |
| RPS / RFS / XPS | RPS 把 RX 软中断移到别的 CPU；RFS 只对**本机 socket** 的流表有意义（转发流量不参与）；XPS 决定 TX 队列由哪个 CPU 发。上游 `packet_steering` 已铺 RPS/IRQ，**不碰 XPS**。 | XPS 是真正的补位点：让处理 RX 的 CPU 发同一个 TX 队列，减少跨核 free/缓存抖动。估算 +2–5% pps |
| `SO_BUSY_POLL` / `net.core.busy_poll` | 需要 `CONFIG_NET_RX_BUSY_POLL=y`（已有）。按 socket 设置，忙轮询最多几十 µs，**烧一个核**。 | 只对 honk 的本地 socket 有意义；2 vCPU 上不可接受。4 核 ARM 可实验，不作为默认 |
| `SO_REUSEPORT` 与 RPS | `SO_REUSEPORT` 让多个 listener 分散 accept；RPS 分散 RX 软中断；两者一起才能让代理多核扩展。需要 `SO_INCOMING_CPU`/流亲和才不乱序。 | 属于 honk 侧；我们不改。可作为给上游的建议 |
| `skb_shared_info` / `build_skb` | `build_skb()` 用现成缓冲区构 skb（零拷贝），`napi_alloc_skb()` 分配+拷贝；`skb_shared_info` 在缓冲区尾部，存 frags/GSO 信息。 | 驱动选择，eBPF 层无法改变；不要为此改驱动 |
| `page_pool` | RX 页回收池，典型与 XDP/page_pool 驱动一起用；纯 TC 转发路径上 skb 已经存在，page_pool 不改变每包成本。 | 无收益；可开 `CONFIG_PAGE_POOL_STATS` 做可观测性，但不为性能 |
| `bpf_xdp_adjust_*` | 仅 XDP 上下文可用；TC 里对应的是 `bpf_skb_adjust_room()`，用于 encap/decap。 | 不适用；我们不做隧道 encap |
| `build_skb` + `page_pool` 的“零拷贝” | 只在驱动 RX 分配阶段；转发路径的 skb 仍要过 qdisc/驱动。 | 不是我们的杠杆 |

### 2.2 可编程 / 可卸载

| 机制 | 事实/结论 | 对本项目 |
|---|---|---|
| `bpf_redirect_peer()` | 5.10+；只对 veth/netkit 有效，直接投递到 peer 的 RX，省一次 `enqueue_to_backlog` 软中断。物理口/桥不可用。 | 不适用。若将来加速 `dae0`/netkit 容器流才考虑 |
| `bpf_redirect_neigh()` 的替代 | 它返回后会在 `__bpf_redirect_neigh()` 里做 `ip_route_output_flow()` + 邻居解析；dpd ABI 6 已改为“FIB 给的 dmac/smac + `bpf_redirect()`”。 | 已做。**剩余缺口是 VLAN/stacked 设备**仍退回 `redirect_neigh()` |
| `tcx` 与 classic 的排序 | 6.6+；`sch_handle_ingress()` 先 `tcx_run()`，任何非 `TC_ACT_UNSPEC` 判决跳过整条 classic 链；TCX 支持 `BPF_F_BEFORE/AFTER` + `relative_id` + `expected_revision`，`TCX_NEXT`/`TCX_PASS` 是新的链语义。 | **可以把 dpd 提到 TCX，但只能 after honk + mark 门控**（见 §5）。无 p1 时不要动 |
| `bpf_fib_lookup` 的 `SKIP_NEIGH` | 跳过邻居查找，`dmac/smac` 不填；ppp/tunnel 的 `NO_NEIGH` 重试已用。 | 已用；保持 |
| `BPF_FIB_LOOKUP_DIRECT` | 跳过 FIB rules，直接查设备关联表/主表。 | **多 WAN 下不能用**：会绕过 `ip rule fwmark`，选错 WAN。仅 downlink（无策略）可考虑 |
| `BPF_FIB_LOOKUP_MARK` | 把 `skb->mark` 带进 FIB 查找（2023 bpf-next，6.7/6.8 线）。einat 用它做 `FIB_LOOKUP_SRC`。 | dpd 自己设 mark 后不再查 FIB，命中路径用不到；miss 路径可用来保证“选 WAN 与慢路径一致” |
| `BPF_FIB_LOOKUP_TABLE/TBID` | 内核 commit `8ad77e72caae`（2023 bpf-next，mainline 6.5；部分 vendor 6.1 有 backport）；`params.tbid` 指定路由表，需与 `DIRECT` 同用；`tbid` 与 VLAN 输出字段是 union，用完清零。 | 多 WAN 首包可绕过 `ip rule` 链直接查该 WAN 的表。收益只在 miss，估算 <1%；可实验 |
| `BPF_MAP_TYPE_LPM_TRIE` | 前缀匹配，O(log n)，比 hash 慢；适合 CIDR/geo 策略，不适合五元组流表。 | Tier 2 “声明直连 CIDR”用它；每包只在 miss 时查一次，可接受 |
| `BPF_MAP_TYPE_HASH_OF_MAPS` | 多一次 map-in-map 查找；适合 per-WAN 子表。 | 当前 `dpd_wans` 一个 array entry 装整表，一次 lookup 更优；**不换** |
| per-CPU 与 cache line | `dpd_stats` 已是 `PERCPU_ARRAY`，每个 CPU 独立 cache line，无争用；`dpd_cfg` 只读；`dpd_flows` 是共享 LRU，查找无锁、更新才拿桶锁。 | 结构正确。**不要把流表改成 per-CPU**：反向流可能落到另一个 CPU，会双份学习/漏命中 |
| `__always_inline` vs tail call | x86 上内联更好（无间接跳转、无 prog array 查找）；ARM A55 上大程序会挤 i-cache，命中路径拆成“小首程序 + tail call 慢路径”可能更省。tail call 约 10–30 ns。 | x86 保持内联；RK 上做 A/B（仅 ARM 有意义） |
| `bpf_loop` / `bpf_for_each_map_elem` | `bpf_loop` 5.17，einat 已用它做端口搜索；`for_each_map_elem` 5.13。回调有调用开销。 | 只用于 MSS option walk / WAN 表展开等冷路径；热路径不用 |
| `bpf_timer` | 5.15；einat 用它做 CT/分片超时。 | dpd 用 `last_seen` 比较更便宜；**不用** |
| `bpf_dynptr` | 6.1；`bpf_dynptr_slice()` 可安全访问变长偏移，越界返回 NULL。 | MSS option walk 可少几次 `bpf_skb_load_bytes`；只影响 SYN，收益 <1% |
| 硬件卸载（TC flower/switchdev） | i211/i226 不支持 switchdev TC offload；IPQ 的 NSS/PPE 是厂商 datapath，不走本项目 eBPF。 | 不适用；不要试图 `tc flower ... hw` |

### 2.3 用户态旁路

| 机制 | 事实/结论 | 对本项目 |
|---|---|---|
| AF_XDP copy 模式 | 每个包内核→用户拷贝一次；单核 64B 通常 1–3 Mpps 量级（估算，取决于内存带宽）。2.5G 线速 64B ≈ 3.72 Mpps，copy 模式已接近上限；1500B 只需 ~0.2 Mpps，CPU 上“够用”但没意义。 | 只能做测量/打流；**不能做生产转发**（见 §7） |
| AF_XDP zero-copy | 需要驱动支持 + 独占队列 + UMEM；igc 有 ZC，igb 的 ZC 补丁在 2023 年才到 v4（是否合入随内核版本），而且队列被 XSK 拿走，内核协议栈看不到。 | 与 einat/honk 冲突；**放弃** |
| XDP + XSK 与 TC/PPPoE/einat 共存 | XDP 在 TC 之前；`XDP_PASS` 才进 TC。PPPoE 帧在 XDP 里没有 IP 头（偏移 0 是 PPPoE），要自己解析；XDP 里也拿不到 skb mark。 | 技术上能共存，但会绕过 honk；PPPoE 还要第二套解析；**放弃** |
| DPDK | 独占网卡、UIO/VFIO、hugepage、自带协议栈/NAT；1–2 核常驻。 | 与 OpenWrt netifd/fw4/einat/honk 不兼容；**放弃** |
| VPP（`af_xdp` plugin） | 可用 XSK 共享网卡，但仍需 XDP 程序 + 队列隔离；VPP 自带 NAT/转发图，等于第二套数据面。 | 同上；**放弃** |
| Snabb | LuaJIT + 自带驱动；master 最后提交 `f327292`（2024-08-30，“Garmin” release），之后只有零散维护；主力是 lwAFTR。 | 维护状态不足以做家用路由数据面；**放弃** |
| PF_RING / ZC | 树外内核模块、独占队列、许可证；OpenWrt 无包。 | **放弃** |
| netmap | 树外、独占队列、VALE 交换机；无 OpenWrt 集成。 | **放弃** |
| `AF_PACKET` TPACKET_V3 / PACKET_MMAP | 块式 ring，减少 syscall，但仍逐包拷贝；适合抓包/测量，不适合转发。 | 只用于测量/抓包 |
| `io_uring` + `IORING_OP_*` | `SEND_ZC` 6.0+；**io_uring zero-copy Rx 已在 6.16 文档中**（`IORING_OP_RECV_ZC`，需 header/data split + flow steering + 应用重写）。6.12 没有。 | honk 用 tokio，重写成本高；且只优化代理 payload 拷贝，不是转发。**观察，不做** |
| `MSG_ZEROCOPY` | 发送大 buffer 时省拷贝；小于 ~10KB 往往不划算；TLS 分帧后更不划算。 | 不改 honk；**不做** |
| `tcp_zerocopy_receive` | 接收零拷贝，有对齐/生命周期约束；代理要解密/转发，仍要碰数据。 | **不做** |
| `SO_TXTIME` / `tc-etf` | 按 PHC 的 launch time 发包；需要 `sch_etf`（当前 `CONFIG_NET_SCH_ETF` 未开）+ 硬件时间戳。 | 只用于**测量**（单向延迟）；生产不用，ETF 会引入排队 |
| PTP 硬件时间戳 | i211(igb)/i226(igc) 支持 PHC；`ethtool -T` 可查。 | 测量用；`phc2sys`/`ptp4l` 同步后做单向延迟 |

### 2.4 OpenWrt 生态里已有但本项目未用的

| 机制 | 结论 | 对本项目 |
|---|---|---|
| `flowtable`（软件/硬件 offload） | `nf_flow_table` 依赖 conntrack；einat 是 conntrack-free，加速流的 reply 没有 conntrack 状态，flowtable 接不住；硬件 offload 只对 NSS/PPE 目标有意义。 | **不做**（第二套 fastpath + 与 einat 冲突） |
| `nftables flow add` | 同上，conntrack 驱动。 | **不做** |
| `tc act_ct` | 在 TC 里做 conntrack，等于第二套 conntrack；与 einat 的“NAT 唯一归属”冲突。 | **不做** |
| `clsact` + `direct-action` | 已在用；`clsact` 是唯一支持 ingress/egress 且不绑定 classful qdisc 的钩子。 | 保持 |
| `sch_fq` / `fq_codel` pacing | `fq` 对本地 TCP（BBR）有用；对**转发**流量只是额外哈希/定时器。`fq_codel` 比 CAKE 便宜。 | WAN 保留 `fq`（BBR）；LAN/br-lan 改 `pfifo`/`fq_codel`（见 §4） |
| `cake` 的 `nat` / `dual-srchost` | `nat` 需要 conntrack 查内网地址；加速流绕过 conntrack → 分错 host；`dual-srchost` 增加哈希成本。 | 加速开启时 **`nat` 必须关**；`dual-srchost` 按需 |
| `irqbalance` / `tuned` | irqbalance 会与上游 `packet_steering` 抢 IRQ 亲和；tuned 不在 OpenWrt。 | **不做**；沿用 `packet_steering` |

### 2.5 参考实现：能借鉴什么、不能直接用什么

| 项目 | 关键代码位置 | 可借鉴 | 不能直接用 |
|---|---|---|---|
| Cilium `v1.20.4` | `bpf/bpf_lxc.c`（`handle_xgress`、`tail_handle_ipv4`）、`bpf/bpf_host.c`、`bpf/lib/l3.h`（`ipv4_local_delivery`）、`bpf/lib/local_delivery.h`（`redirect_ep`） | **tail call 分层**（首程序只做分类，冷路径 tail call）、**mark 命名空间**（`MARK_MAGIC_*` 只做内部状态，不与其他组件抢位）、**TCX 迁移**（classic → link-based，Cilium 已迁移） | DSR（L4LB 的 direct server return）不是我们的场景；XDP/容器 endpoint 模型也不适用 |
| Katran `623234e` | `katran/bpf/balancer_kern.c`、`katran/lib/` | LRU 流表容量/健康检查/`bpf_fib_lookup` 的写法；它的“每包只做少量 map”与 dpd 同构 | XDP L4LB 前置；我们没有 VIP/L4 服务 |
| AF_XDP / libxdp / xdp-tools `v1.6.3` | `xdpsock`、`xdp-trafficgen`、`libxdp` | 用 `xdp-trafficgen`/`xdpsock` 做**无用户态偏差**的打流与 pps 上限测量 | 不作为生产转发（见 §7） |
| DPDK / VPP | `vpp/src/plugins/af_xdp`、DPDK `drivers/net/igb`/`igc` | 只借鉴“批量收发包/一次处理多个描述符”的思路（GRO/GSO 已经在做类似的事） | 独占队列、自带协议栈/NAT、OpenWrt 集成 |
| Snabb / PF_RING / netmap | `snabb/src/apps/intel/`、`PF_RING/userland` | 无 | 维护状态/树外模块/独占队列 |

> Cilium 的 **DSR** 值得单独说一句：它的本质是“回程包不经过 LB”，与我们把
> direct 流从 honk 手里交回 dpd 是同一类“按流分区”的思想；但 DSR 依赖 L4 VIP/IPIP
> 封装，我们没有 VIP，也不做 L4LB，所以只借思想、不借实现。

---

## 3. 候选清单（按“收益 / 集成成本 / 风险”排序）

> 收益为 **CPU 受限时的相对值（估算）**；成本以 1 人日 ≈ 1 个熟悉本项目的工程师一天计。
> “冲突”一列只写与本项目红线的冲突，不写通用工程风险。

| # | 方向 | 具体机制/项目 | 预期收益（吞吐/延迟/p99） | 集成成本 | 与本项目约束的冲突 | 建议 |
|---:|---|---|---|---|---|---|
| 1 | 出口队列 | 未整形时 CAKE/`fq` → `pfifo`/`pfifo_fast`；整形时才装 CAKE | 吞吐 +3–10%；p99 改善 0.1–0.5 ms | 2–3 人日 | 与“CAKE 无限速也做公平/AQM”目标冲突，需要 profile 开关 | **立即做 A/B** |
| 2 | 桥出口 | 下载方向直接 redirect 到 bridge port，跳过 `br_dev_xmit` + 一层 qdisc | 下载 +3–8% | 5–8 人日 | 绕过 bridge FDB/ebtables；VLAN/STP 要 epoch 失效 | 实验（第 4 周） |
| 3 | 中断/队列 | XPS：RX CPU → 同号 TX 队列 | pps +2–5% | 1 人日 | 上游 `packet_steering` 不碰 XPS，属于补位 | **立即做** |
| 4 | NAPI | `gro_flush_timeout`/`napi_defer_hard_irqs` 双档 | pps +5–15%；吞吐档 p99 变差 20–100 µs | 1–2 人日 | 延迟 vs 吞吐；不能全局默认大值 | 实验（双档） |
| 5 | NAPI | `netdev_budget`/`usecs` 细调 | +1–3% | 0.5 人日 | 2 vCPU 上抬 budget 会恶化 p99 | 实验 |
| 6 | 挂载方式 | dpd 从 classic 提到 TCX-after-honk，`DIRECT_UNSPEC_MARK` 门控 | +1–3%；顺序确定性/可维护性 | 4–6 人日 | 必须 p1 核心；honk 重启 link id 变化 | 实验→做（第 3 周） |
| 7 | BPF 命中路径 | `cfg->now_ms`、cfg+stats 合并、内联 TTL 校验和 | +1–3%（20–60 ns/包） | 3–4 人日 | ABI 12；时间粒度 1 s | **做**（第 2 周） |
| 8 | VLAN 出口 | `bpf_skb_vlan_push/pop` + 直发父设备，缓存 tag | VLAN 场景 +5–15% | 3–5 人日 | tag/MTU/stacked device 正确性 | 实验（第 2/4 周） |
| 9 | 流表 | v4 独立 16B key / 拆分 v4+v6 map | +1–2% | 2–3 人日 | ABI；v6 兼容 | 实验 |
| 10 | FIB | 多 WAN miss 用 `DIRECT` + `TBID` 直查表 | miss-only <1% | 2 人日 | `DIRECT` 不能用于有 `ip rule` 的路径 | 可选 |
| 11 | 策略 | `LPM_TRIE` 做 Tier 2 声明直连 CIDR | 功能，不是吞吐 | 2–3 人日 | 需要 p1 + 运维声明责任 | 以后 |
| 12 | BPF 冷路径 | `bpf_loop` 展开 MSS/ WAN 表；`bpf_dynptr` 读 option | <1% | 1 人日 | 回调开销；只影响 SYN/miss | 可选 |
| 13 | ARM | 命中路径拆小首程序 + tail call 慢路径 | RK 上 1–3% | 2–3 人日 | x86 无收益 | 实验（需 RK 板） |
| 14 | 代理 socket | `SO_BUSY_POLL`（honk 侧） | 代理 RTT −10–50 µs | 3–5 人日（honk）+ 1 核 | 2 vCPU 不可承受 | 实验（4 核 ARM） |
| 15 | 代理 socket | `SO_REUSEPORT` 多 worker | 代理吞吐 | honk 侧 | 不改我们的代码 | 给 honk 上游建议 |
| 16 | 代理拷贝 | `MSG_ZEROCOPY` / `tcp_zerocopy_receive` | <2% | 高（honk 重写） | TLS 分帧 | 放弃 |
| 17 | 代理拷贝 | io_uring ZC RX（6.16+） | 10–30% 拷贝成本 | 高 + 硬件 split | honk 重写；不是转发 | 观察 |
| 18 | 测量 | `tc-etf` + PTP 硬件时间戳 | 无（测量） | 1 人日 | `sch_etf` 未编译 | 测量用 |
| 19 | 重定向 | `bpf_redirect_peer` | veth/netkit only | — | 物理口/桥不适用 | 放弃 |
| 20 | 重定向 | `bpf_redirect(..., BPF_F_INGRESS)` | 负收益 | — | 重复 ingress/成环 | 放弃 |
| 21 | 多 WAN | `HASH_OF_MAPS` | 负收益（多一次查找） | — | 当前单 array 已更优 | 放弃 |
| 22 | 流表 | per-CPU flow hash | 负收益（双向漏命中） | — | 反向流 CPU 亲和不确定 | 放弃 |
| 23 | 流表 | `bpf_timer` 做过期 | 负收益（比时间戳比较贵） | — | — | 放弃 |
| 24 | 统计 | per-CPU stats | 已做 | — | — | 保持 |
| 25 | OpenWrt | `flowtable` / `nft flow add` / `act_ct` | 与本项目重复 | — | conntrack vs einat | 放弃 |
| 26 | OpenWrt | `irqbalance` / `tuned` | 与 `packet_steering` 抢 | — | 抢所有权 | 放弃 |
| 27 | 用户态 | AF_XDP copy | 2.5G 64B 接近上限 | 15–30 人日 | 独占队列/看不到 NAT | 放弃（仅测量） |
| 28 | 用户态 | AF_XDP ZC / DPDK / VPP | 线速 | 30+ 人日 | 独占队列 + 第二套栈 | 放弃 |
| 29 | 用户态 | Snabb / PF_RING ZC / netmap | — | — | 维护/集成/许可 | 放弃 |
| 30 | 参考 | Cilium / Katran | 模式借鉴 | 0 | XDP/容器场景 | 只读参考 |

---

## 4. 深挖一：出口队列与桥的双层入队（最值得先做）

### 4.1 路径事实

一个被 dpd 接管的下载包，从 WAN 进入到客户端，实际路径是：

```
NIC RX → NAPI/GRO → TCX(eth1 ingress: einat rev_snat, honk wan_ingress)
      → classic(eth1 ingress: acl, dpd)  [dpd 在这里 bpf_redirect]
      → skb_do_redirect() → dev_queue_xmit(br-lan)
          → br-lan 出口 TCX（honk lan_egress_l2）
          → br-lan root qdisc（默认 fq / 或 CAKE）
          → br_dev_xmit() → br_fdb_find() → dev_queue_xmit(eth0)
              → eth0 出口 TCX（honk lan_egress_l2 的 slave 视角）
              → eth0 root qdisc（默认 fq）
              → igb/igc ndo_start_xmit
```

也就是说，**下载方向每包至少两次 qdisc enqueue/dequeue**（br-lan 一次、eth0 一次），
如果 `net.core.default_qdisc=fq`（`router-tuning` 设的），两次都是 `fq` 的哈希 + rb-tree +
EDT 逻辑；如果用户在 WAN 装了 CAKE，上传方向还要再算一次 CAKE。

### 4.2 方案

**原则：队列只放在“真的会排队”的地方。**

1. **WAN（上传瓶颈）**：保留 CAKE（有限速时）或 `fq`（BBR 需要 pacing 时）。这是唯一需要
   AQM/整形的方向。
2. **LAN / br-lan（下载出口）**：LAN 不是瓶颈（2.5G 线速，WAN 通常 ≤1G/2G），不需要 AQM。
   改成 `pfifo`（classless，limit 1000）或 `pfifo_fast`；**不要用 `fq`/CAKE**。
3. **桥端口（eth0）**：同样 `pfifo`；如果桥 master 已经 `pfifo`，端口这层仍存在，但成本很低。
4. **`noqueue`**：只对 veth/netkit 等虚拟设备可用；物理口/桥不要试。
5. **CAKE 的 `nat`**：加速开启时关闭（加速流没有 conntrack，`cake nat` 会分错 host，且多一次
   conntrack 查表）。`dual-srchost` 同理，按需。
6. **`txqueuelen`**：`pfifo` 的 limit 与 `txqueuelen` 解耦；设 1000 足够，别用 5000 养 bufferbloat。

实现位置：`src/ci/ebpf/router-dataplane` 不负责 qdisc；改 `mydist/router-qos` 与
`mydist/router-tuning` 的 qdisc 选择逻辑（本轮只读，不写代码）。建议新增一个 profile：

```
option qos_mode 'auto'    # auto | shape | fairness
# auto: 只有 upload>0 才装 CAKE；否则 LAN/br-lan pfifo，WAN fq
# shape: 保持今天的 CAKE
# fairness: LAN 用 fq_codel（要 AQM 但不要 CAKE 的成本）
```

内核配置：`pfifo`/`pfifo_fast` 属于 `CONFIG_NET_SCH_FIFO`/内置 `sch_generic`，不需要新模块；
`sch_fq` 在 6.12.87 是 `=m`，6.18.55 按上一轮文档要 `kmod-sched` 才有，装之前先
`modinfo sch_fq`。**所有权**：WAN 的 qdisc 归 `router-qos`，`router-tuning` 只设
`net.core.default_qdisc`（开机时生效）；本方案只改 LAN/br-lan/桥端口，不碰 WAN 的 CAKE。

### 4.3 验证

A/B 四组，同一台机、同一次启动、每组 3×30 s，固定 2 Gbit/s 与线速各一轮：

| 组 | br-lan | eth0 | WAN |
|---|---|---|---|
| A（现状） | `fq` | `fq` | CAKE/fq |
| B | `pfifo` | `pfifo` | CAKE/fq |
| C | `pfifo` | `pfifo` | `fq` |
| D | `fq_codel` | `fq_codel` | CAKE/fq |

指标：TCP 单流/4 流吞吐、64B pps、`perf stat` cycles/packet、`sockperf under-load` p99、
`tc -s qdisc` 的 drops/backlog/requeues、`nstat` 的 retrans。判据：**吞吐 ≥ +3% 或 p99 ≥ −10%，
且另一项不回退 >1%**；`tc -s qdisc` 不得出现持续 drop/backlog。

### 4.4 回退与风险

- 回退：`router-qos` 保存原 qdisc，`--restore` 原样 `tc qdisc replace`；profile 改回 `shape`。
- 风险：`pfifo` 在 LAN 侧遇到突发（多流同时下载）可能尾 drop；用 limit 1000 + BQL 可接受。
  若出现 LAN 侧丢包，回 `fq_codel`（比 CAKE 便宜，仍有 AQM）。
- **不要**在 WAN 去掉 CAKE 而不做别的整形：上传 bufferbloat 会回来。

---

## 5. 深挖二：把 dpd 提到 TCX（after honk + mark 门控）

### 5.1 明确判断

**可以，但有三个硬条件，缺一不可：**

1. 运行的是 **p1 核心**（`/usr/share/honk/direct-unspec` 存在），direct 出口返回
   `TC_ACT_UNSPEC` 并带 `DIRECT_UNSPEC_MARK`（`0x2000_0000`）。
2. dpd 以 **`BPF_F_AFTER` + `relative_id`** 挂在 honk 的 `lan_ingress_l2` link **之后**；
   不能“默认 append”就假设顺序——honk 重启后新 link 会 append 到 dpd 后面。
3. dpd 在 LAN 侧**只加速带 mark 的包**：
   `if (cfg->require_direct_mark && !(skb->mark & DPD_DIRECT_UNSPEC_MARK)) return TC_ACT_UNSPEC;`
   这样即使顺序反了，dpd 也一个包都不接管（**fail-safe**），只是“零加速”，不会代理泄漏。

**收益判断**：TCX 去掉的是 classic `tcf_classify()` 的 `tcf_proto` 链遍历 + `cls_bpf_classify`
的间接调用 + `direct-action` 的返回处理。按 50–150 cycles/包估算，30 万 pps 下是单核
0.5–1.5%；64B 高 pps（100 万 pps）可到 2–5%。**它不是吞吐大招，价值在“确定性排序 +
不再依赖‘TCX 非 UNSPEC 就跳过 classic’这条隐式规则”。**

**不做的情况**：没有 p1 核心时，dpd 只能留在 classic；此时把它提到 TCX 前面会抢走 honk
的代理流，提到后面又永远看不到包（honk 返回 `TC_ACT_OK` 直接终止整条链）。所以
**p1 是前提，不是可选项**。

### 5.2 实现草图（函数级）

> 路径约定：本节的 `src/...`、`files/...` 均相对
> `src/ci/ebpf/router-dataplane/`（即 `src/dpd_fastpath.bpf.c` =
> `src/ci/ebpf/router-dataplane/src/dpd_fastpath.bpf.c`）。

**A. `src/dpd_common.h`**

```c
#define DPD_ABI_VERSION 12
#define DPD_DIRECT_UNSPEC_MARK 0x20000000u  /* must equal honk's DIRECT_UNSPEC_MARK */
#define DPD_ATTACH_CLASSIC 0
#define DPD_ATTACH_TCX     1

struct dpd_config {
    ...
    __u32 attach_mode;       /* 0 classic, 1 tcx-after-honk */
    __u32 require_direct_mark; /* 1: LAN hook only accelerates marked packets */
};
```

**B. `src/dpd_fastpath.bpf.c`（程序入口最前面，越早越好）**

```c
cfg = dpd_get_cfg();
if (!cfg) return TC_ACT_UNSPEC;

/* TCX-after-honk: only touch what honk already classified as direct.
 * If we are accidentally ordered before honk, no packet carries the mark,
 * so we yield everything -- a zero-acceleration failure, never a proxy leak. */
if (cfg->attach_mode == DPD_ATTACH_TCX && cfg->require_direct_mark &&
    !(skb->mark & DPD_DIRECT_UNSPEC_MARK))
    return TC_ACT_UNSPEC;
```

注意：这个检查必须在 `ST_PKT_TOTAL` 计数之前还是之后？建议**之后**，这样
`pkt_total` 仍能回答“TCX 链有没有把包送到我们这里”；另加 `ST_MARK_SKIP` 计数。

**mark 位不能撞车**：honk 用 `CLASSIFIED_MARK=0x4000_0000`、`DIRECT_UNSPEC_MARK=0x2000_0000`，
日志里还有 `tproxy_mark=0x800_0000`；dpd 多 WAN 的 `dpd_wan.mark` 是用户/daemon 生成的
fwmark，**必须避开这些位**（建议约束在 `0x0000_00ff`–`0x00ff_ffff` 且与 honk 的
`tproxy_mark` 不重叠）。`mydist-mwan` 写 `dpd_wans` 时应校验，冲突就拒绝启动多 WAN，
而不是让两个组件互相改 mark。

**顺带发现一个现存 bug**：`dpd_fastpath.bpf.c` 里多 WAN 新流用的是
`skb->mark = w.mark`（覆盖写）。在 p1 下这会把 honk 的 `CLASSIFIED_MARK |
DIRECT_UNSPEC_MARK` 一起抹掉，包到 bridge master 时 honk 会**重新分类**，轻则多一次
判定，重则把 direct 流改判成 proxy。TCX 化之前应先改成
`skb->mark = (skb->mark & (CLASSIFIED_MARK | DIRECT_UNSPEC_MARK)) | w.mark`
（或保存/恢复），并加一个单测：多 WAN + honk p1 下 `dpdctl stats` 的 `pkt_total`
不应因 bridge master 的二次分类而出现“先 direct 后 proxy”的抖动。

**C. `src/dpdctl.c` 新增 `attach-tcx`**

```c
/* pseudo, libbpf 1.x */
struct bpf_tcx_opts opts = {
    .sz = sizeof(opts),
    .relative_id = honk_link_id,
    .flags = BPF_F_AFTER | BPF_F_LINK | BPF_F_ID,
    .expected_revision = 0,          /* 0 = don't care; set if racing */
};
link = bpf_program__attach_tcx(prog, ifindex, &opts);
```

> 字段名/flags 组合以镜像 `staging_dir/.../include/bpf/bpf.h` 里的 `struct bpf_tcx_opts`
> 为准（6.18 已有 `relative_fd/relative_id/expected_revision`）；关键语义是
> **`BPF_F_AFTER` + 一个有效的 relative link id + expected_revision**，其余按头文件填。

- 先 `bpftool net show -j`（或文本）解析 honk 的 `link <id>`；没有 `-j` 就按
  `^<dev>\(.*tcx/ingress.*lan_ingress_l2.*link ([0-9]+)` 取。
- 若 `bpf_program__attach_tcx` 失败（内核/libbpf 不支持），回退 classic，并在 gate 里记
  `code=tcx-attach-failed`。
- 每个设备单独挂：`br-lan`、`eth0`（桥从设备）、以及 `downlink=1` 时的 WAN 设备。

**D. `files/dpd-fastpath.sh`**

```sh
# new: after honk, only when p1
dpd_attach_tcx() {
    local dev="$1" link
    link="$(dpd_honk_link_id "$dev")" || return 1
    "$DPD_CTL" attach-tcx "$dev" --after-link "$link" || return 1
}

# gate: order check (every watchdog tick)
dpd_tcx_order_ok() {
    local dev="$1"
    # honk must come before dpd in tcx/ingress
    bpftool net show dev "$dev" 2>/dev/null |
        awk '/tcx\/ingress/ {print $3}' |
        grep -n . | ...
}
```

`dpd_gate_mode()` 增加：

- `honk_owns && !honk_p1` → `observe`（已有）
- `honk_owns && honk_p1 && attach_mode=tcx` → 要求 `dpd_tcx_order_ok`，否则 `observe` +
  `code=order-inverted`（**不要**在顺序错时“猜”）
- `!honk_owns && attach_mode=tcx` → 允许（dpd 是唯一 TCX），`require_direct_mark=0`

**E. 看门狗**

`files/dpd-gate-watchdog` 已有 20 s 轮询；增加：

- honk link id 变化 → 重新 attach（detach 旧 link，按新 id after）。
- 顺序反转 → detach + 重新 after；连续 3 次失败 → 降 `observe`。
- `honk stop` → 切回 classic 或留在 TCX（`require_direct_mark=0`），由 gate 决定。

### 5.3 验证

1. `bpftool net show dev br-lan`：顺序必须是 `lan_ingress_l2` → `dpd_fastpath`。
2. `tc filter show dev br-lan ingress`：classic 链上**没有** dpd（证明真的在 TCX）。
3. 代理流：`curl https://ipinfo.io/ip` 出口仍是节点 IP；`dpdctl stats` 的 `pkt_total`
   不因代理流增长（mark 门控有效）。
4. 直连流：`curl https://ifconfig.me/ip` 出口是本地 IP；`dpdctl stats` 的 `redirect_ok`
   增长；对端可达。
5. honk 重启：`honk stop/start` 后 20 s 内顺序恢复；若未恢复，`gate` 必须是 `observe`，
   不能是“看起来在加速”。
6. 顺序反转演练：手动把 dpd 挂到 honk 前面，确认 `mark_skip` 增长、`redirect_ok` 不增长、
   代理仍正常——这是 fail-safe 的证明。
7. 性能：同一流量下 classic vs TCX，`bpftool prog profile id <dpd> duration 10 cycles`
   对比；整机 `perf stat` cycles/packet。

### 5.4 回退

- 配置 `option attach 'classic'` 即回到今天的路径；`dpd-fastpath.sh` 的 `dpd_attach_if()`
  原样保留。
- 回退不需要换镜像；`dpdctl detach-tcx` + `tc filter add ...` 在同一个 gate refresh 内完成。
- 最坏情况：TCX link 残留但顺序错 → mark 门控保证零接管；`observe` 是安全落点。

---

## 6. 深挖三：dpd 命中路径减负（ABI 12）

> 目标不是“再省一次 map lookup”，而是把每包 20–60 ns 的固定开销拿掉，并顺手修掉
> VLAN 出口的隐藏回退。以下改动都在 `src/dpd_fastpath.bpf.c` / `src/dpd_common.h`，
> 不碰 einat/honk。

### 6.1 去掉每包 `bpf_ktime_get_ns()`

**现状**：stateful 命中路径每个包都调用 `bpf_ktime_get_ns()/1e6`（`dpd_fastpath.bpf.c:959`），
只为了判断 `age < ttl`。

**改法**：让用户态每秒把单调毫秒写进 `dpd_cfg.now_ms`，BPF 只读 cfg：

```c
/* dpd_common.h */
struct dpd_config {
    ...
    __u32 now_ms;      /* CLOCK_MONOTONIC ms, refreshed by the watchdog every 1 s */
    __u32 now_valid;   /* 0 until the first refresh */
};

/* bpf */
__u32 now = cfg->now_valid ? cfg->now_ms
                           : (__u32)(bpf_ktime_get_ns() / 1000000ULL);
```

- TTL 粒度从 1 ms 变成 1 s；`flow_ttl_ms` 本来就是秒级，无影响。
- 用户态停摆（procd 挂了）时 `now_ms` 不前进 → 条目不过期。对策：`now_valid` 由 watchdog
  每次刷新置 1；`dpdctl` 退出/服务停止时 dpd 也停止；另加 `cfg->now_ms == 0` 时回退 helper。
- 收益：省一次 helper 调用（估算 20–40 cycles/包）。

### 6.2 合并 `dpd_cfg` 与 `dpd_stats`

**现状**：每包 2 次 array lookup（`dpd_cfg` + `dpd_stats`），虽然都是 per-CPU/只读，但仍是
两次 helper 调用 + 两次边界检查。

**改法**：新增 `dpd_cpu`（`PERCPU_ARRAY`，1 entry，value = `{ struct dpd_config cfg; struct dpd_stat_val st; }`）。
用户态改配置时遍历所有 CPU key 写入；BPF 只 lookup 一次，拿 `&cpu->cfg` 和 `&cpu->st`。

- 注意：`bpf_map_update_elem` 对 per-CPU map 的 value 是“每个 CPU 的副本”，用户态要
  `libbpf_num_possible_cpus()` 循环。
- 配置变更频率很低（秒级），成本可忽略。
- ABI 12；旧的 `dpd_cfg`/`dpd_stats` 可以保留为只读镜像，方便 `dpdctl` 兼容。

### 6.3 VLAN 出口：把 `redirect_neigh()` 的回退拿回来

**现状**（`dpd_emit_l2()` 调用点）：`l2_ok = !tagged`。只要 ingress 带 802.1Q/802.1ad，
`dpd_emit_class()` 就返回 0（neigh 类），命中路径每包走 `bpf_redirect_neigh()`，即
**每包一次 `ip_route_output_flow()` + 邻居查找**。这在 VLAN WAN/IPTV/多 SSID 划分的家庭
里很常见。

**改法（分两步，先做安全的）**：

1. **只处理“ingress 带 tag、egress 是普通以太网”的情况**：在 learn 时记 `vlan_id` +
   `vlan_proto`，命中时先 `bpf_skb_vlan_pop(skb)`，再写 L2 头 + `bpf_redirect()`。
   这要求 egress 真的不打 tag；用 `dpd_iface` 的 `DPD_IF_F_LOWER`/VLAN 标志判断。
2. **ingress 不带 tag、egress 是 VLAN 子接口**：`bpf_skb_vlan_push(skb, proto, tci)` 后
   写父设备的 L2 头 + `bpf_redirect(parent_ifindex)`；tag 存在 flow value 里。
3. 不确定的情况继续 `redirect_neigh()`，**fail-open**，并计数 `ST_VLAN_NEIGH`。

- flow value 从 24B 扩到 32B（`vlan` 字段），ABI 12；pinned map 升级时需要重建
  （`dpd-fastpath.sh` 已有“value size 变了就删 pin”的逻辑，确认一下）。
- `bpf_skb_vlan_push/pop` 会改 `skb->len`/校验和；测试要覆盖 1500/1492/1514 三种帧。
- 收益：VLAN 场景每包省 300–800 cycles（估算），+5–15%；非 VLAN 用户无变化。

### 6.4 内联 TTL 校验和（可选，收益小但便宜）

**现状**：每包 `bpf_l3_csum_replace()` 一次 helper。

**改法**：直接改 `iph->check`：

```c
/* ip_decrease_ttl(): iph->check += htons(0x0100), with end-around carry */
__u32 c = (__u16)iph->check;
c += bpf_htons(0x0100);          /* exactly what net/ipv4/ip_forward.c does */
c = (c & 0xffff) + (c >> 16);
iph->check = (__u16)c;
iph->ttl--;
```

- 只在“完整 IPv4 头、非 CHECKSUM_PARTIAL”的转发包上做；如果不确定，保留 helper 分支。
- 风险：ones-complement 进位边界（0xffff → 0x0000）要单测；用 `tcpdump -vv` 验证
  `bad ip csum` 为 0，客户端 `ping`/`curl` 正常。
- 收益：20–40 cycles/包；如果时间紧可以不做。

### 6.5 流键缩小（v4 独立 key）

**现状**：`dpd_flow_key` 实际是 **44B**（源码注释写 48B，以 `sizeof` 为准：
`4+1+1+2+16+16+2+2`），v4 只用了 `saddr[3]`/`daddr[3]`，map 的 jhash 仍要遍历 44B 并把
6 个零地址字混进去（自定义的 `dpd_flow_hash()` 只读 `saddr[3]/daddr[3]`，所以它不受影响）。

**改法**：拆成 `dpd_flow4`（约 20B：saddr/daddr/sport/dport/proto/ifindex）和
`dpd_flow6`（40B），两张 LRU map；入口按 family 分支，各查一张。

- 收益：v4 命中路径少读 24B、jhash 少 24B；估算 1–2%。
- 成本：ABI 12 + 迁移；两张 map 的内存略增（16k × 20B vs 44B）。
- 风险：低；但会让 `dpdctl` 的 flow dump 代码要改两处。

### 6.6 验证与回退

- **无流量微基准**：`bpftool prog run id <id> data_in /tmp/pkt.bin repeat 1000000`，
  对比 ABI 11/12 的 ns/run；再用 `bpftool prog profile id <id> duration 10 cycles instructions llc_misses`。
- **有流量**：固定 2 Gbit/s，`perf stat -e cycles,instructions,cache-misses` 前后各 3 次；
  算 cycles/packet = Δcycles / Δ(ethtool tx_packets)。
- **正确性**：`dpdctl stats` 的 `mss_clamp`/`ttl_drop` 计数不变；`tcpdump` 无 bad csum；
  `ping -s 1472`、`curl`、`tracepath` 全过；VLAN 场景用 `vlan` 子接口 + `ping -s 1472`。
- **回退**：ABI 12 对象与 ABI 11 对象分开命名（`dpd_fastpath.bpf.o` vs `.abi11.o`），
  `dpd-fastpath.sh` 的 `DPD_OBJ` 可切换；pinned map 不兼容时删 pin 重建（已有逻辑）。

---

## 7. 明确否掉的（以及为什么）

| 方案 | 否掉理由（具体限制/公开数据） |
|---|---|
| **XDP 快路径** | XDP 在 TC/TCX 之前，`XDP_PASS` 才进 TC；用它做 FIB+redirect 会绕过 honk 的 TCX（代理泄漏），也会绕过 einat 的 WAN TCX（NAT 看不到）。PPPoE 帧在 XDP 里没有 IP 头，要第二套解析。项目已因“绕过 skb/TC、与 einat/flowtable 的 NAT 冲突”否决过，结论不变。 |
| **AF_XDP（copy 模式）做生产转发** | copy 模式每包一次内核→用户拷贝；2.5G 线速 64B ≈ 3.72 Mpps，单核 copy 通常 1–3 Mpps（估算），已接近上限；且 XSK 拿走队列后内核协议栈/einat/honk 看不到包。 |
| **AF_XDP zero-copy** | 需要驱动 ZC + 独占队列 + UMEM；igc 有 ZC，igb 的 ZC 支持随内核版本（2023 年 v4 补丁），但队列隔离与 einat/honk 的 TCX 归属直接冲突。 |
| **DPDK / VPP** | 独占网卡（UIO/VFIO）、hugepage、自带协议栈/NAT，1–2 核常驻；与 OpenWrt netifd/fw4/einat/honk 集成成本 30+ 人日；家用 2.5G 的收益不值。VPP `af_xdp` plugin 仍要 XDP+XSK，冲突同上。 |
| **Snabb** | master 最后提交 `f327292`（2024-08-30），之后基本是 lwAFTR/YANG 维护；LuaJIT + 自带驱动，不适合做 OpenWrt 路由数据面。 |
| **PF_RING / ZC、netmap** | 树外内核模块、独占队列、许可/打包问题；OpenWrt 无现成包。 |
| **flowtable / `nft flow add`** | 依赖 conntrack；einat 是 conntrack-free，加速流没有 conntrack 状态，reply 接不住；硬件 offload 只对 NSS/PPE 目标有意义。 |
| **`act_ct`** | 在 TC 里再建一套 conntrack，与“NAT 唯一归属 einat”直接冲突。 |
| **在 honk 之前插 TCX** | p1 之前实测：honk 开着时 dpd 在 br-lan 上 `pkt_total +0`；p1 之后 direct 流才回来。在 honk 前插会抢走代理判定所需的首包，造成代理泄漏。 |
| **`bpf_redirect(..., BPF_F_INGRESS)`** | 会把包注入目标设备的 ingress，重复 TC/TCX，可能成环；没有收益。 |
| **`bpf_redirect_peer`** | 只对 veth/netkit 有效；我们的 LAN 是桥/物理口。 |
| **per-CPU 流表** | 反向流可能被另一个 CPU 处理，per-CPU 会双份学习/漏命中；共享 LRU 的查找是无锁的，不需要 per-CPU。 |
| **`bpf_timer` 做流过期** | 每次命中比较时间戳更便宜；timer 要额外 map/回调，且 einat 已经证明 timer 适合 CT，不适合每包 flow cache。 |
| **全局 `net.core.busy_poll`** | 会让所有 socket 忙轮询，烧核；2 vCPU 上直接挤掉转发/代理。只可按 socket 给 honk，且 4 核以上再试。 |
| **全局 `default_qdisc=fq` 用于所有口** | `fq` 对转发流量只是额外哈希/定时器；BBR 只需要在本地 TCP 出口（WAN）有 pacing。LAN 改 `pfifo`。 |
| **CAKE `nat` 在加速开启时** | 加速流不过 conntrack，`cake nat` 查不到内网地址，会分错 host；必须关。 |
| **`irqbalance` / `tuned`** | 与上游 `packet_steering` 抢 IRQ 亲和；OpenWrt 没有 tuned。 |
| **硬件 TC offload（i211/i226）** | 不支持 switchdev/TC flower offload；不要浪费时间。 |
| **IPv6 加速** | 无 NAT66；v6 reply 没有 einat 的 conntrack-free 路径，fw4 会拒。保持现状（默认关）。 |
| **第二套 NAT / 第二套 conntrack** | 项目红线；所有“在 TC 里做 NAT”的方案（包括 flowtable、act_ct、nft fullcone）都不做。 |

---

## 8. 测量方法学（不引入测量偏差）

### 8.1 先固定环境

```sh
# 1) governor / turbo / IRQ 亲和
for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    echo performance > "$c" 2>/dev/null
done
cat /proc/interrupts | grep -E 'eth0|eth1'      # 记录 IRQ 分布
/etc/init.d/packet_steering status              # 确认上游 steering 在跑
ethtool -l eth0; ethtool -l eth1                # 队列数
ethtool -k eth0 | egrep 'gro|gso|tso|lro'       # offload 状态
```

- 客户端/服务端在**另一台机器**；路由器上不要跑 iperf3 服务端（会抢 CPU）。
- 客户端/服务端各自 `taskset` 到不同物理核；路由器 2 vCPU 不要被管理面占用。
- 每组测试前 `sleep 10` 让 CPU 频率/温度稳定；每组 3 次，取中位数，报告离散度。

### 8.2 每包成本：先测 BPF 程序本身，再测整机

```sh
# 找到程序 id
bpftool prog show | grep -E 'dpd_fastpath|einat|honk'

# A) 无流量微基准：重复跑同一个包，得到 ns/run
#    需要先把一个 64B/1500B 的以太网帧存成二进制
bpftool prog run id "$DPD_ID" data_in /tmp/pkt1500.bin data_size_in 1514 \
    repeat 1000000

# B) 程序自身的 cycles/instructions/LLC
bpftool prog profile id "$DPD_ID" duration 10 cycles instructions llc_misses

# C) 整机 cycles/packet（前后各 3 次；-C 选转发所在 CPU，别把 idle 算进来）
perf stat -C "$CPU" -e cycles,instructions,cache-misses,branch-misses -- sleep 20
# pps 从网卡计数器取，别用 iperf 的瞬时值
ethtool -S eth1 | egrep 'tx_packets|rx_packets|tx_dropped'
```

**计算**：`cycles_per_packet = Δcycles / Δ(tx_packets + rx_packets)`。同一个 boot 内做 A/B，
不要跨重启比较（JIT 布局/内存布局会变）。

### 8.3 延迟：不要用 ping

| 指标 | 工具 | 说明 |
|---|---|---|
| TCP 往返 p50/p99/p999 | `sockperf under-load -m 64 -t 60 --mps 100000` | 用户态精确，但要固定速率 |
| TCP request/response | `netperf -t TCP_RR -l 60 -- -r 64,64` | 看 min/mean/max；p99 用 sockperf |
| 单向延迟 | `irtt client -i 10ms -d 60s -l 64` | 自带 `SO_TIMESTAMPING`，比 ping 准 |
| HTTP p99 | `wrk2` / `h2load --latency` | 端到端，含 TLS |
| 硬件时间戳 | `ethtool -T eth1` + `phc2sys`/`ptp4l` | 需要两端 PHC 同步；i211/i226 支持 |

`SO_TIMESTAMPING` 的要点：

```c
int flags = SOF_TIMESTAMPING_TX_SCHED | SOF_TIMESTAMPING_TX_HARDWARE |
            SOF_TIMESTAMPING_RX_HARDWARE | SOF_TIMESTAMPING_OPT_ID |
            SOF_TIMESTAMPING_OPT_TSONLY;
setsockopt(fd, SOL_SOCKET, SO_TIMESTAMPING, &flags, sizeof(flags));
/* 用 recvmsg 的 SCM_TIMESTAMPING cmsg 取三个时戳：软件、硬件、PHC */
```

- **不要**在计时窗口里跑 `tcpdump`；抓包会改变 cache/softirq 行为。需要证据时用
  `perf trace -e skb:kfree_skb` 或 `bpftrace` 计数，且单独跑。
- `ping` 只测 ICMP 本地 fast path，不经过 TCP/转发/CAKE，不能代表转发延迟。

### 8.4 CPU 火焰图与 cache

```sh
# 火焰图：只采一个 CPU，999 Hz，30 s
perf record -C 1 -F 999 -g --call-graph dwarf -- sleep 30
perf script | stackcollapse-perf.pl | flamegraph.pl > /tmp/dpd.svg

# cache / 假共享
perf stat -e LLC-loads,LLC-load-misses,LLC-stores,LLC-store-misses -- sleep 10
perf c2c record -a -- sleep 5 && perf c2c report   # 若内核/工具支持

# 丢包/队列
tc -s qdisc show dev eth1
nstat -az | egrep 'TcpRetrans|UdpInErrors|IpInDiscards|IpOutNoRoutes'
cat /proc/net/softnet_stat   # 第 2 列 time_squeeze
```

### 8.5 偏差控制清单

1. **固定速率**：吞吐测试用 `iperf3 -b 2G`（UDP）或发送端 `tc` 限速；不要“尽量跑满”后
   比较两个不同的负载点（`bench-3way.md` 的满载延迟对比就吃过这个亏）。
2. **`--omit 5`**：跳过 TCP 慢启动/CAKE 收敛。
3. **同一 boot 内 A/B**：换镜像会改变内存布局/JIT，跨镜像比较只能看大趋势。
4. **随机化顺序**：A/B/B/A，避免温度/邻居流量漂移。
5. **报告 cycles/packet 与 p99，不只报告 Gbit/s**：1–3% 的吞吐差异在噪声里，cycles/packet
   更敏感。
6. **确认没有 drop**：`tc -s qdisc` 的 drops、`ethtool -S` 的 `tx_dropped`、
   `softnet_stat` 的 time_squeeze 必须为 0 或稳定；有 drop 的“更快”是假的。
7. **代理路径单独测**：honk 的 TLS 代理吞吐/延迟与转发是两条路径，不能混在一张表里。

### 8.6 判据（建议写进 CI/验收）

- 吞吐：≥ +3%（3 次中位数），且 p99 不回退 >5%。
- 延迟：p99 ≥ −10%，且吞吐不回退 >1%。
- 每包：`bpftool prog profile` 的 cycles/run ≥ −5%，或整机 cycles/packet ≥ −3%。
- 任何一项出现 drop/retrans 上升 → 直接判失败，不看吞吐。

---

## 9. 下一步实验计划（2 vCPU x86 + 1 台真机优先）

> 假设 1 人投入；每周 4–5 个有效工作日。第 1–3 周不需要改内核，第 4 周才开始碰
> `dpd_fastpath.bpf.c` 的结构性改动。

| 周 | 实验 | 产出/判据 | 依赖 |
|---|---|---|---|
| **W1** | 搭测量台：`bpftool prog run/profile` + `perf stat` + `sockperf/irtt`；跑基线（dpd 开/关、honk 开/关、p1） | 一张 baseline 表：cycles/packet、p99、pps、CPU；确定噪声带 | 现有镜像 |
| **W1** | qdisc A/B：A `fq/fq`、B `pfifo/pfifo`、C `pfifo/pfifo + WAN fq`、D `fq_codel`；XPS 开/关 | 选出默认 profile；若 B ≥ +3% 且无 drop，进默认 | root shell |
| **W2** | ABI 12 命中路径减负：`now_ms`、cfg+stats 合并、内联校验和 | `prog run` ns/run、整机 cycles/packet；正确性（csum/TTL）全过 | W1 基线 |
| **W2** | VLAN 出口原型：`bpf_skb_vlan_pop` + 直发；先在 VLAN 测试拓扑 | VLAN 场景 +5% 或每包 −300 cycles；非 VLAN 无回退 | VLAN 测试口 |
| **W3** | TCX-after-honk：`dpdctl attach-tcx` + gate + 看门狗 | 顺序正确/反转/重启三种演练全过；classic vs TCX 的 cycles/packet | p1 核心 |
| **W3** | 失败注入：honk stop/start、link 删除、顺序反转、无 p1 | 必须落 `observe` 或零加速，不能代理泄漏 | W3 代码 |
| **W4** | 桥端口直发原型：FDB map（MAC→port）+ flow 缓存；下载方向 A/B | 下载 +3% 且 bridge/ebtables 行为不变；否则放弃 | W4 代码 |
| **W4** | NAPI 双档：`gro_flush_timeout` 0/20/50 µs；`napi_defer_hard_irqs` 0/2；`netdev_budget` 300/600 | 吞吐档/延迟档两张表；p99 代价可接受才保留 | W1 测量台 |
| **W5** | 汇总、回归、文档；决定哪些进默认、哪些留 opt-in | 更新 `dpd-fastpath.sh` 的 gate/文档；CI 加静态断言 | 全部 |

**真机安排**：

- x86 2 vCPU（ESXi 或裸机 i226）：W1–W3 全部；裸机优先，虚拟机只做功能回归。
- 第二台 x86（i211/i226 直通）：W4 的桥端口/NAPI 必须在这里做，虚拟机数据不可信。
- RK35xx（4×A55）：W5 之后单独做 tail call / busy poll / XPS 的 ARM 对比；**不要**把
  x86 的百分比直接搬到 ARM。

**每周固定产出**：一张表（配置、吞吐、pps、cycles/packet、p99、drop）、一段结论
（做/不做/再测）、一个回退点（能一条命令回到上周的配置）。

---

## 10. 参考（仓库/版本/关键文件）

| 项目 | 版本/commit | 关键文件 | 用途 |
|---|---|---|---|
| Linux 内核（本项目） | 6.18.55 / 6.12.87 | `net/core/dev.c` `sch_handle_ingress()`/`tcx_run()`；`net/core/filter.c` `bpf_redirect()`/`bpf_fib_lookup()`；`net/sched/cls_bpf.c`；`net/sched/sch_cake.c` | 路径与成本事实 |
| TCX | 内核 6.6+；libbpf commit `e6ab647970a4`、`71d8eadb9066` | `tools/testing/selftests/bpf/prog_tests/tc_links.c`；`include/uapi/linux/bpf.h` `BPF_F_BEFORE/AFTER`、`TCX_NEXT` | TCX 排序/挂载 |
| `bpf_fib_lookup` TBID | 内核 commit `8ad77e72caae`（2023 bpf-next，mainline 6.5；部分 vendor 6.1 backport） | `net/core/filter.c` `bpf_ipv4_fib_lookup()` | 多 WAN 直查表 |
| Cilium | `v1.20.4`（2026-10-23） | `bpf/bpf_lxc.c`、`bpf/bpf_host.c`、`bpf/lib/l3.h`、`bpf/lib/local_delivery.h`；commit `ebf007af3015966fb187d61e439d5851f5e03b8f`（pod-to-pod `bpf_redirect_peer`） | tail call、mark、redirect_peer、DSR 参考 |
| Katran | commit `623234e1814befd07be9fb2c7c8100afdb9e57ef`（2026-11-01） | `katran/bpf/balancer_kern.c`、`katran/lib/` | XDP L4LB 的 LRU/healthcheck 模式（不采用 XDP） |
| einat-ebpf | `EHfive/einat-ebpf`（main，2026-10 抓取） | `src/bpf/einat.bpf.c`（`bpf_loop`、`bpf_timer`、`BPF_FIB_LOOKUP_MARK/SRC`） | NAT 唯一归属；bpf_loop/timer 的用法 |
| einat OpenWrt 包 | `muink/openwrt-einat-ebpf`（2026-06 更新） | `files/einat.init`、`README.md` | 包装/门禁 |
| honk | `kwrum1/openwrt-honk`，core commit `54b2e1cfbe1e7f8a93dba3a0f64fabf2a9f88e38`，p1 | `work/honk/ci/patches/honk-direct-unspec.py`、`work/honk/honk/files/direct-unspec` | `DIRECT_UNSPEC_MARK` 的来源 |
| xdp-tools | `v1.6.3`（2026-03-25） | `xdp-trafficgen`、`xdpsock`、`libxdp` | 打流/测量（不作为生产） |
| AF_XDP | 内核文档 `Documentation/networking/af_xdp.rst` | `XDP_COPY`/`XDP_ZEROCOPY`、`XSKMAP` | copy/ZC 的上限与条件 |
| io_uring ZC Rx | 内核 6.16+ 文档 `networking/iou-zcrx.html` | `IORING_OP_RECV_ZC`、`IORING_SETUP_CQE32` | 只观察，不集成 |
| Snabb | commit `f32729274b0a1b0da612bface2eabd8b57eef200`（2024-08-30） | `src/apps/intel/`、`src/program/lwaftr/` | 维护状态证据 |
| CAKE / fq_codel | 内核文档 + `sch_cake.c`/`sch_fq_codel.c` | `cake` 的 `nat`/`dual-srchost`、`fq` 的 EDT | 队列成本 |
| 本报告引用的项目文档 | — | `src/docs/bench-3way.md`、`src/docs/kernel-and-tuning-research.md`、`src/docs/honk-dpd-both.md`、`src/docs/proxy-accel-coexistence.md`、`src/docs/round9-real-machine.md` | 项目实测与红线 |

---

## 附录 A：ABI 12 变更草案（供评审，不落地）

```c
#define DPD_ABI_VERSION 12

struct dpd_config {
    __u32 abi_version;
    __u32 mode;
    __u32 enable;
    __u32 redirect;
    __u32 flow_ttl_ms;
    __u32 policy;
    __u32 epoch;
    __u32 flow_refresh_ms;
    __u32 ipv6;
    __u32 mss_clamp;
    /* new */
    __u32 attach_mode;          /* 0 classic, 1 tcx-after-honk */
    __u32 require_direct_mark;  /* LAN hook only */
    __u32 now_ms;               /* monotonic ms, 1 Hz */
    __u32 now_valid;
};

struct dpd_cpu_val {
    struct dpd_config cfg;
    struct dpd_stat_val st;
};

/* map: dpd_cpu, BPF_MAP_TYPE_PERCPU_ARRAY, 1 entry */
```

**升级注意**：

- `dpd_flows` 的 value 从 24B 扩到 32B 会改变 pinned map 的 value size；`dpd-fastpath.sh`
  已有“value size 不匹配就删 pin”的保护，确认它覆盖 `dpd_flows` 和 `dpd_cpu`。
- 旧 `dpd_cfg`/`dpd_stats` 可保留为兼容镜像，`dpdctl` 先写新 map，再写旧 map。
- `now_ms` 的更新者必须是 procd 常驻（watchdog）；`dpdctl set now` 只用于测试。

## 附录 B：风险登记

| # | 风险 | 触发条件 | 缓解 |
|---|---|---|---|
| R1 | TCX 顺序反转导致零加速（不是泄漏） | honk 重启/升级 | 看门狗 20 s 重挂；gate 发布 `order-inverted` |
| R2 | mark 定义漂移/撞车 | honk 改 `DIRECT_UNSPEC_MARK`；多 WAN fwmark 与 honk bit 重叠 | 门禁读 `/usr/share/honk/direct-unspec` + 版本检查；BPF 里定义同名常量并加注释；`mydist-mwan` 校验 `dpd_wan.mark` 不落在 0x2000_0000/0x4000_0000/tproxy_mark 上 |
| R3 | VLAN push/pop 破坏校验和/MTU | VLAN WAN/IPTV | 只在 `l2_ok` 且确定 egress 类型时做；失败回 `redirect_neigh` 并计数 |
| R4 | qdisc 改 `pfifo` 后 LAN 突发丢包 | 多流同时下载 | limit 1000 + BQL；出现 drop 回 `fq_codel` |
| R5 | `now_ms` 停更导致流表不老化 | watchdog 挂 | `now_valid` + 服务停止即停 dpd；`now_ms==0` 回退 helper |
| R6 | 桥端口直发绕过 ebtables/FDB | 有 ebtables/STP/VLAN filtering 的拓扑 | 默认关；只在 `policy=allow_all` 且无 ebtables 规则时开；epoch 失效 |
| R7 | 测量噪声把 1–3% 当成 10% | 虚拟机/单次跑 | 固定速率、3 次中位数、cycles/packet、同一 boot |

---

**一句话总结**：先把出口 qdisc/桥的“隐形税”拿掉（最大、最便宜），再把 dpd 以
TCX-after-honk + mark 门控的方式放到正确的位置（结构性、个位数收益），最后用 ABI 12
把命中路径的固定开销削掉（低风险、可测量）。XDP/AF_XDP/DPDK/VPP/Snabb 这条线全部不做——
它们解决的是“绕过内核”，而我们的问题是“内核里还剩多少不必要的每包工作”。
