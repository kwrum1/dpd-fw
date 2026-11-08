# DPD-FW 选型与架构设计

版本：0.1（P0）
日期：2026-11-08
状态：设计基线，进入 P0/P1

---

## 1. 执行摘要

DPD-FW 不是把现有 DPD 推倒重写，而是把它从“每包重新判断的 eBPF 快路径”
升级为“连接级流状态 + ECM 式流管理 + 系统级 NAPI 调优”的软件数据面：

- 保留 TC ingress eBPF、PPPoE L3 处理、VLAN、MSS clamp、IPv6、gate/status；
- 增加统一流状态 UFS（Unified Flow State），把 NAT、egress、L2、DSCP、
  queue、策略结果缓存在一条流里；
- 增加 `dpd-flowd`（Flow Manager），用 conntrack/honk/einat/ACL 事件建立和
  老化流，短流不加速，长流一次查表；
- 增加 `dpd-napi`，把 NAPI/IRQ/GRO/GSO/qdisc/RSS/XPS 纳入数据面；
- 把代理、NAT、ACL、QoS、多 WAN、观测拆成插件，形成 `dpd-fw` 生态。

目标：1G/2.5G 线速、10G 大包线速、低 CPU、低延迟、功能不倒退。
非目标：XDP/DPDK/驱动适配、10G 64B 普适线速、GPU 逐包转发。

---

## 2. 现状与瓶颈

现有 DPD 已经具备：

| 能力 | 现状 |
|---|---|
| 已建立连接 flow cache | `dpd_flows` LRU_HASH，一次 lookup |
| per-CPU 配置+统计 | `dpd_cpu` PERCPU_ARRAY，一次 lookup |
| 路由/邻居缓存 | L2 dmac/smac、`nh4`、`bpf_redirect` |
| 拓扑变化失效 | `epoch` + 控制面 bump |
| PPPoE L3 入口 | `dpd_iface` 判断 + `bpf_skb_change_head` |
| MSS / VLAN / DHCP / 分片 / DNS 例外 | 已有 |
| gate / status / LuCI | 已有 |

真正的瓶颈：

1. 每包开头仍查 `dpd_iface` 判断 L3/L2；
2. einat 在 DPD 之前又做 2–4 次 NAT/CT 查表；
3. PPPoE 上行 `bpf_redirect_neigh(nh)`、下行 `bpf_skb_change_head` 每包有成本；
4. 没有把 GRO/GSO、IRQ 亲和、NAPI、qdisc 作为数据面的一部分；
5. 流管理与策略分散在多个程序，无法“一次查表、一次决策”。

结论：DPD-FW 的核心是 **一次 UFS 查表 + 一次改包 + 一次转发**。

---

## 3. 设计原则与门禁

| 原则 | 内容 |
|---|---|
| 内核 | 统一 6.18.x，x86/RK 同源 |
| 钩子 | TC ingress/egress；不用 XDP/AF_XDP/DPDK |
| 驱动 | 不做驱动适配；只用标准 ethtool/sysfs/sysctl |
| 覆盖 | IPv4/IPv6、TCP/UDP/ICMP、PPPoE/VLAN/bridge、NAT/full-cone、proxy/direct、多 WAN |
| 状态归属 | NAT 绑定归 einat；转发缓存归 DPD；代理归 honk；慢路径归 fw4/conntrack |
| 单流单主 | 不允许 DPD 与 nft flow offload/SFE 同时接管同一条流 |
| 可回退 | off / observe / stateless / stateful 四档 + gate + epoch + watchdog |
| 可观测 | 每流、每 CPU、每阶段计数；稳定错误 token |
| 不绕策略 | 代理、ACL、block 必须显式缓存，不允许默认放行 |

### 性能门禁

| 平台 | 链路 | 1500B | 64B | CPU | P99 |
|---|---|---|---|---|---|
| x86 4C8T | 10G | 线速 | 3–6 Mpps | ≤ 2 核 | 基线 + 80µs |
| x86 8C16T | 10G | 线速 | 8–12 Mpps（冲刺） | ≤ 4 核 | 基线 + 100µs |
| x86 2C4T | 2.5G | 线速 | ≥ 3.7 Mpps | ≤ 2 核 | 基线 + 80µs |
| RK3588 | 2.5G | 线速 | ≥ 3.7 Mpps | ≤ 2×A76 | 基线 + 100µs |
| RK3568 | 1G | 线速 | ≥ 1.48 Mpps | ≤ 2 核 | 基线 + 100µs |

10G 64B 满线速（14.88 Mpps）不是普适承诺；只有高核数 x86 冲刺目标。

---

## 4. 集百家之所长：选型矩阵

| 来源 | 核心设计 | 采纳 | 不采纳 |
|---|---|---|---|
| Qualcomm NSS/ECM | conntrack 事件、分类器链、frontend 选择、accel_delay_pkts、UNBIND/BIND/FIN | Flow Manager、延迟加速、分类器、生命周期 | NSS 硬件/固件/驱动 |
| MediaTek PPE/HNAT | FOE 表、HNAPT/HNAT/L2/PPPoE/VLAN、30pps、硬件 aging、DSCP 学习、短包优先 | UFS flow_type、min_pps、DSCP/queue、aging、短包队列 | PPE 硬件、mtk_hnat 驱动 |
| Qualcomm SFE | conntrack 驱动、offload_at_pkts=128、内核 hook、no tcp window check | 延迟加速阈值、conntrack 事件、TCP window 处理 | 内核 hook 补丁 |
| FreeBSD pf/ip_fastforward | 先查状态、miss 才查规则、per-bucket 锁、UDP 自适应超时、run-to-completion、只碰 IP 头 | 状态优先、UFS 分片、UDP 超时、最小解析 | mbuf/iflib 驱动 |
| OPNsense | RSS per-flow、netisr bindthreads、direct/deferred/hybrid | RSS/RPS、per-flow CPU 亲和、NAPI 绑核 | netisr 实现 |
| VPP | vector/graph/feature arc/per-thread replica/hugepages/NUMA/poll | GRO/GSO 批处理、per-CPU 副本、feature 缓存、NUMA map | DPDK/poll-mode/hugepage 包缓冲 |
| PanaOS（Panabit） | 数据/控制分离、独立快速栈/驱动/内存/调度、插件虚拟化、双实例 | 分层、per-core 调度、插件生态、回退 | 自研 OS/驱动 |
| KNOD（2026 RFC） | NIC→GPU DMA、SPSC ring、批量 SIMT、verdict、offload device | provider 抽象、batch/verdict 模型、可选 GPU 插件 | XDP JIT、AMD GPU、驱动/page_pool 改造 |
| Linux 6.18 NAPI | per-NAPI netlink、threaded NAPI、gro_flush、defer_irqs、irq_suspend | dpd-napi、per-queue 绑核、GRO/GSO | 路由器无 socket 的 busy-poll |

选型结论：**TC eBPF UFS + Flow Manager + NAPI/queue 调优 + 插件生态**。
XDP/DPDK/驱动适配拒绝；KNOD/GPU 只做可选 provider。

---

## 5. 总体架构

```
┌──────────────────────────────────────────────┐
│ dpd-flowd（控制面 / Flow Manager）            │
│  conntrack + honk + einat + ACL/QoS/MWAN 事件 │
│  NEW → OBSERVE(N包) → BIND → FIN              │
│  分类器链、老化、epoch、defunct                │
└───────────────┬──────────────────────────────┘
                │ 写 UFS / 策略 / 统计
┌───────────────▼──────────────────────────────┐
│ dpd-core（TC eBPF 数据面）                    │
│  L2 变体 / L3 变体 → 一次 UFS 查表            │
│  NAT 增量改写 → TTL → VLAN → emit → 统计      │
└───────────────┬──────────────────────────────┘
                │
┌───────────────▼──────────────────────────────┐
│ dpd-napi（系统层）                            │
│  NAPI 线程/IRQ 亲和、GRO/GSO、qdisc、RSS/XPS  │
└──────────────────────────────────────────────┘
```

### 5.1 UFS（Unified Flow State）

```c
struct dpd_ufs_key {
    __u32 ifindex;
    __u8  family;
    __u8  proto;
    __u16 vlan;
    union {
        struct { __be32 saddr, daddr; __be16 sport, dport; } v4;
        struct { __be32 saddr[4], daddr[4]; __be16 sport, dport; } v6;
    };
};

struct dpd_ufs_val {
    __u32 egress_ifindex, nh4, mtu;
    __u8  dmac[6], smac[6];
    __u32 flow_type;      /* L2 / IPv4_HNAPT / IPv4_HNAT / IPv6 / PPPoE */
    __u32 state;          /* NEW / OBSERVE / BIND / FIN */
    __u32 action;         /* FORWARD / PROXY / BLOCK / LOCAL */
    __u32 nat_flags, binding_id;
    __be32 new_src, new_dst;
    __be16 new_sport, new_dport;
    __u16 vlan, flags, epoch;
    __u32 dscp, queue, skb_priority;
    __u32 ct_cookie;
    __u64 packets, bytes;
    __u32 last_seen_ms;
};
```

要点：

- 正向/反向各一条，学习时一次写两条。
- v4/v6 可分表，key 更小。
- 命中路径不再查 einat/ACL/MWAN/QoS 的 map。
- 条目带 epoch；拓扑/策略变化可全表或定向失效。

### 5.2 快路径

```c
parse_minimal();
key = build_key();
v = bpf_map_lookup_elem(&ufs, &key);
if (v && !expired(v) && v->epoch == cfg->epoch) {
    if (v->nat_flags) nat_apply_incremental(v);
    ttl_decrement();
    vlan_pop_if_needed(v);
    emit_cached(skb, v);
    stats_hit(v->family, skb->len);
    return TC_ACT_REDIRECT;
}
return slow_or_learn();
```

优化点：

1. L2/L3 双程序变体，去掉每包 `dpd_iface` 查询；
2. UFS 合并 NAT 结果，去掉 einat 每包 2–4 次查表；
3. 配置移出热路径（`.rodata`/单条目 array）；
4. 命中路径只更新 2 个计数；
5. PPPoE emit 实验：上行 `bpf_skb_pull_data` + `bpf_redirect`，下行 `change_head` 替代方案；
6. GRO/GSO 摊薄每包成本；
7. qdisc 模式：pure forwarding 用 noqueue/mq，QoS 用 CAKE。

### 5.3 慢路径与例外

以下流量永远走慢路径：

- 首包/prime；
- IPv4 分片、IPv6 扩展头/分片；
- DHCP 67/68、DNS 53、ARP/ND、非单播；
- 目的本机、fw4/ACL 策略流；
- honk 代理流；
- full-cone 陌生入站（UFS miss → einat binding → 建反向 UFS）；
- NAT 新建、端口分配、多 WAN 选路。

### 5.4 Flow Manager 状态机

```
NEW ──(N packets / bytes)──> OBSERVE ──(eligible)──> BIND
  │                              │                    │
  └────────(short flow)──────────┴──(expire)──────────┘
                                                   FIN
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `accel_after_pkts` | 32 | 短流不加速；0/8/32/128 可调 |
| `min_pps` | 0 | PPE 式低速率不常驻 |
| TCP timeout | 300s | 与 conntrack 对齐 |
| UDP timeout | 30/120s 自适应 | pf 式 |
| FIN/RST | 立即 defunct | 释放 UFS |
| 拓扑/邻居变化 | epoch++ | 全表或定向失效 |
| honk reload / einat 绑定变化 | 定向失效 | 不误伤直连流 |

---

## 6. 插件生态

```
plugins/
├── dpd-honk/     # 唯一代理插件（可选）
├── dpd-einat/    # full-cone NAT
├── dpd-acl/      # 防火墙 / ACL
├── dpd-qos/      # CAKE / SQM / DSCP
├── dpd-mwan/     # 多 WAN
├── dpd-observe/  # 遥测
└── dpd-knod/     # 可选 GPU provider（未来）
```

### 6.1 插件 ABI

```c
struct dpd_plugin_ops {
    const char *name;
    int version;
    int (*init)(void);
    int (*flow_classify)(struct dpd_flow_desc *);
    int (*flow_create)(struct dpd_flow_desc *);
    void (*flow_expire)(struct dpd_flow_desc *);
    void (*topology_event)(int type);
    int (*dump)(struct dpd_dump *);
};
```

- 热路径固定 UFS，不逐包调用插件；
- 只有异常/慢路径允许注册 BPF tail-call；
- 插件进程化（ubus/netlink），崩溃不影响数据面；
- `dpd-honk` 通过 ubus 与 honk 交互，不链接 honk 代码。

### 6.2 dpd-honk

- honk 是 **唯一代理插件**，不是 `dpd-core` 的依赖；
- 保证 honk TCX 在 DPD classic 之前；
- honk reload/策略变化 → UFS epoch/定向失效；
- 代理流不进 UFS；
- 状态页汇总 honk 健康、节点、gate。

### 6.3 dpd-einat

- full-cone 绑定表是权威；
- UFS 缓存 NAT 翻译结果；
- 陌生入站 EIF 反查；
- 绑定过期/变更 → 使 UFS 失效；
- 可选 `bpf_ct_*` 写 conntrack cookie，保留 `conntrack -L` 语义。

### 6.4 dpd-acl

- TC pref 90，先于 DPD；
- `must`/`block` 在 TC 层执行；
- UFS 只缓存已放行流；
- 规则变更/策略变化 → flush；
- fw4 仍是慢路径权威。

### 6.5 dpd-qos

- `mode=off`：noqueue/mq，冲 10G；
- `mode=cake`：WAN egress CAKE，保留 SQM；
- `mode=hybrid`：LAN noqueue，WAN CAKE；
- UFS 写 `skb->priority`/DSCP；
- 10G 线速只在 `qos=off` 承诺。

### 6.6 dpd-mwan

- 建流时选 WAN，UFS 记录 `wan_id/egress/nh`；
- 健康检查失败/链路变化 → epoch++/定向失效；
- 每流粘滞；
- 兼容现有 `ebpf-mwan` UCI/LuCI。

---

## 7. NAPI 与系统调优

Linux 6.18 的 NAPI 能力：

- `netdev-genl` 的 `napi-get` / `napi-set`：
  - `defer-hard-irqs`
  - `gro-flush-timeout`
  - `irq-suspend-timeout`
  - `threaded`（threaded NAPI）
- threaded NAPI：每个 NAPI 一个 `napi/<if>-<id>` kthread，可绑核；
- RSS/RPS/XPS、IRQ affinity；
- `net.core.netdev_budget`、`dev_weight`；
- GRO/GSO/TSO 逐设备 A/B；
- `qdisc`：noqueue/mq/fq/cake。

`dpd-napi` 负责：

1. 枚举 NAPI/IRQ/队列；
2. 绑核、设置 `gro-flush-timeout`/`defer-hard-irqs`/`irq-suspend-timeout`；
3. 选择 threaded/softirq；
4. 配 RSS/RPS/XPS；
5. 输出每队列 PPS/丢包/延迟，作为门禁。

注意：

- 路由器通常没有用户态 socket，`SO_BUSY_POLL` 不适用；
- threaded NAPI 降低抖动但可能增加延迟，需 A/B；
- GRO/GSO 对 eBPF 软件快路径有利；对硬件 offload 反而要关（NSS/PPE 的做法），两者不能混。

---

## 8. 内核 6.18 基线

```
CONFIG_BPF_JIT=y
CONFIG_BPF_JIT_ALWAYS_ON=y
CONFIG_BPF_SYSCALL=y
CONFIG_DEBUG_INFO_BTF=y
CONFIG_NET_CLS_BPF=y
CONFIG_NET_ACT_BPF=y
CONFIG_NET_SCH_INGRESS=y
CONFIG_NET_TC_SKB_EXT=y
CONFIG_NET_GRO=y
CONFIG_NET_GSO=y
CONFIG_NET_TSO=y
CONFIG_HZ_1000=y
CONFIG_PREEMPT=y
CONFIG_NF_CONNTRACK=y
CONFIG_NF_NAT=y
CONFIG_NF_CT_NETLINK=y
CONFIG_PPPOE=y
CONFIG_VLAN_8021Q=y
CONFIG_BRIDGE=y
CONFIG_BPF_CT=y
CONFIG_NET_SCH_CAKE=y
CONFIG_NET_SCH_FQ=y
CONFIG_NET_SCH_HTB=y
CONFIG_NET_SCH_MQPRIO=y
CONFIG_CPU_FREQ_GOV_PERFORMANCE=y
CONFIG_SMP=y
CONFIG_NR_CPUS=64
CONFIG_RCU_NOCB_CPU=y
```

运行时：

- `net.core.netdev_budget` / `netdev_budget_usecs` / `dev_weight`；
- `rps_sock_flow_entries`、RPS/XPS、IRQ affinity；
- `cpufreq` performance；RK 大核跑转发；
- `nf_conntrack_tcp_be_liberal=1` 仅在 prime 绕过 conntrack 时；
- `tcp_congestion_control=bbr`、`fq` pacing；
- `ethtool -K` GRO/GSO/TSO 逐设备验证；
- 只保留 clsact + eBPF，关闭不需要的 tc 花活。

---

## 9. 仓库与迁移

```
dpd-fw/
├── bpf/core/
├── plugins/{dpd-honk,dpd-einat,dpd-acl,dpd-qos,dpd-mwan,dpd-observe,dpd-knod}/
├── userspace/{dpdfwd,dpdctl,libdpd,dpd-napi}/
├── openwrt/{package,luci-app-dpd}/
├── kernel/{configs/6.18,patches}/
├── docs/
└── tests/{netns,qemu,bench,ci}/
```

迁移步骤：

1. 新建 `kwrum1/dpd-fw`；
2. 用 `git filter-repo` 或 `git subtree split` 迁移
   `router-dataplane`、`router-acl`、`einat-ebpf`、`luci-app-ebpf`、
   `router-qos`、`router-tuning` 历史；
3. 固件仓库改为消费 `dpd-fw` feed/tag；
4. `Packages.sh` 增加 `UPDATE_PACKAGE "dpd-fw" ...`；
5. `verify-drift` 校验 tag、UFS ABI、6.18 配置；
6. 旧包名做 alias，keep-settings 升级不丢配置。

---

## 10. 实施阶段

| 阶段 | 内容 | 验收 |
|---|---|---|
| P0 | 仓库/迁移/6.18 config/benchmark 台/ESXi 基线 | 可编译、可测 |
| P1 | Flow Manager + accel_after_pkts + UFS 一次查表 + L2/L3 双程序 | 快路径减一次 map，短流不加速 |
| P2 | einat full-cone 并入 UFS + 正反双向 + IPv6 | NAT/full-cone 回归全过 |
| P3 | ACL/QoS/MWAN 迁移 | 功能不倒退 |
| P4 | dpd-napi + GRO/GSO/IRQ/qdisc + 10G 调优 | 达到门禁 |
| P5 | dpd-honk + dpd-observe + LuCI | 代理/观测/UI 完整 |
| P6 | 可选 dpd-knod GPU provider | 不影响默认 |

---

## 11. 测试矩阵

| 维度 | 取值 |
|---|---|
| 包长 | 64 / 128 / 512 / 1500 / 9000 |
| 流数 | 1 / 10 / 100 / 1000 / 10000 |
| 协议 | TCP / UDP / ICMP；IPv4 / IPv6 |
| 封装 | 原生 / VLAN / PPPoE |
| 功能 | direct / NAT / full-cone / honk 代理 / ACL / QoS / MWAN |
| 指标 | PPS、Gbps、P99 RTT、CPU%、map lookup、丢包、建流速率 |

对比组：

1. 原版 Linux 转发；
2. nft flow offload（软件）；
3. SFE；
4. 当前 DPD；
5. DPD-FW P1；
6. DPD-FW P2。

工具：`iperf3`、外部 `pktgen`/`Trex`、`sockperf`、`netperf TCP_RR`、
`perf stat`、`bpftool prog profile`、`tc -s`。

---

## 12. 风险与不做什么

| 风险 | 缓解 |
|---|---|
| TC 在 skb 分配之后，10G 64B 难满线速 | 明确门禁；高核数 x86 冲刺；不承诺普适 |
| UFS 合并 NAT 破坏 full-cone | P2 回归；绑定表权威；可回退 dpd-einat 旧路径 |
| 多核 flow affinity | RSS/RPS/XPS + per-CPU 表；压测 |
| QoS/qdisc 与线速冲突 | `qos=off` 纯转发；`cake` 单独门禁 |
| 插件热路径拖慢 | 插件只挂控制面/慢路径 |
| 内核特性差异 | 6.18 统一基线；CI 矩阵 |

不做什么：

- XDP/AF_XDP/DPDK/驱动适配；
- GPU 逐包转发（KNOD 只做可选 provider）；
- 10G 64B 普适线速承诺；
- 两套 fastpath 同时开；
- 为了快绕过 ACL/代理/防火墙。

---

## 13. 实验室验证记录（2026-11-08）

ESXi `10.1.18.124` 上的测试床：

| 角色 | 配置 | 地址 |
|---|---|---|
| `dpd-test` | 4 vCPU / 4GB / vmxnet3 ×3，BIOS vmdk | LAN 192.168.10.1，WAN 198.18.0.1，mgmt 10.1.18.250 |
| `ebpf-client2` | OpenWrt，2 vCPU / 2GB | 192.168.10.162 |
| `ly-route-lab` | Debian，4 vCPU / 4GB | 198.18.0.2 |

已确认：

- P1 的 `classifier/l2` 版本可以加载，`tc filter` 显示
  `dpd_fastpath.bpf.o:[classifier/l2] direct-action`；
- 流表能学到正反双向条目，`flow_hit`/`redirect` 计数增长；
- 慢路径小文件下载正常。

发现的两个真实问题：

1. **br-lan ingress 看不到网桥端口之间的转发帧**
   - 只在 `br-lan` 上挂 tc 时，LAN→WAN 的计数不增长；
   - 把同一个程序挂到 `eth0`（网桥端口）后，`flow_hit`/`redirect` 立即增长；
   - 已在 `bpf/core/files/dpd-fastpath.sh` 修复：`dpd_attach_one` +
     `dpd_attach_if` 自动遍历 `/sys/class/net/<master>/brif/*`，并对称 detach。

2. **DPD 在 LAN ingress 接管会绕过 einat 的 NAT**
   - 快速路径的流键是 **pre-NAT** 的 LAN 源地址；重定向到 WAN 后，
     einat 的 egress SNAT 没有覆盖到该包，服务器看到的是 192.168.10.162，
     不是 198.18.0.1；
   - 小流量/首包（prime）能过，bulk TCP 在几秒后失败；
   - 这与设计中的“NAT 只有一个归属：einat”并不矛盾，而是说明
     **P1 的 L2 快路径不能独立接管需要 NAT 的上行流**；
   - 结论：P2 的 UFS + einat NAT 合并是必需项，不是可选项。

其他记录：

- 该 ESXi 宿主对 EFI 固件启动失败，测试 VM 使用 BIOS vmdk；
- 3 个 vmxnet3 + pvscsi 需要显式 `pciBridge4..7` 和槽位
  （scsi0=16, ethernet0=192, ethernet1=224, ethernet2=256），
  否则 `msg.pci.noslotavail`；
- `ebpf-mwan` 的 4787 策略规则会在 table 4787 缺默认路由时让
  `bpf_fib_lookup` 失败；单 WAN 测试先禁用 mwan 并清理规则。

下一步：

- P2：把 einat 的 full-cone 绑定结果写进 UFS，命中路径做 NAT 增量改写；
- 在 P2 之前，先用“服务器静态回程路由 + 关闭 einat”的方式单独验证
  L2 转发，避免 NAT 干扰定位。

## 14. P5 交付与验证（2026-11-08）

P5 的四个包已用本地 25.12.4 SDK 编译，并在 ESXi `dpd-test` 上安装：

```
dpd-honk-0.1.0-r1.apk          1892
dpd-napi-0.1.0-r1.apk          1811
dpd-observe-0.1.0-r1.apk       1443
luci-app-dpd-0.1.0-r1.apk      3272
```

验证：

- `apk info -e` 报告四个包均已安装；
- `ubus call dpd status` 返回 `dpd.abi=15`、`gate.effective`；
- `/var/run/dpd/observe.json`、`honk.json`、`napi.json` 均生成；
- 升级演练：`PASS: abi=15 attached=true mode=observe`；
- `luci-app-dpd` 的 menu/ACL/rpcd/4 个 JS 视图已安装，DPD 页面是插件页，
  加速摘要仍只在 Vantage 首页健康行。

P5 的边界（必须如实报告）：

- P5 完成了插件/UI/状态文档和包级升级演练；
- **P2 的 UFS+NAT 合并仍未完成**：LAN→WAN 的前向加速在 NAT 场景下仍会
  绕过 einat 的 SNAT，bulk TCP 会失败；P5 的 UI 不掩盖这一点；
- 全量固件镜像构建尚未在本轮本地完成，当前验证用的是云镜像 + 本地包。

## 15. P2.0 / P3 / P4 进展（2026-11-09）

### P2.0 safe mode（已实现）

LAN→WAN 的 FIB 出口如果带学到的 IPv4 nexthop（NAT 上行），DPD 不再接管前向；
首包/前向交给 fw4/einat SNAT，回程在 einat 反 NAT 之后仍然学习并加速。

ESXi `dpd-test` 验证（WAN 上 `masq=1`）：

- 32 MB 下载：`7.98s` 完成，不再出现 bulk TCP 失败；
- `flow_hit=39`、`redirect=39`，流表只有回程条目；
- 这是“下载加速、上传慢路径”的安全模式，不是最终双向方案。

### P2.1 的下一步（已定位可用的数据）

einat 的 `map_binding` BTF/布局已实测：

```
map_binding_key   12B: ifindex, flags, l4proto, from_port, from_addr
map_binding_value 28B: to_addr, to_port, flags, is_static, outbound_ref,
                       ref, seq, ct_state_cached, ct_touch_ms
map_ct_key        20B: ifindex, flags, l4proto, pad, external tuple
map_ct_value      40B: origin tuple, flags, pad, state, seq, timer
```

`map_binding` 正是前向 SNAT 所需的“内网 (addr,port) -> 外部 (addr,port)”映射。
P2.1 有两条实现路径：

1. DPD 自己的 `dpd_nat` 镜像表，由 `dpd-einat` 从 einat map 同步，UFS 命中时
   直接写回；不需要修改 einat 二进制。
2. 自定义 loader 用 `bpf_map__reuse_fd` 复用 einat 的 map FD；少一次同步，
   但要把 `tc` 加载改成 libbpf loader。

### P3 / P4

- P3：`dpd-acl`/`dpd-qos`/`dpd-mwan` meta 包已加入包集，底层仍是
  `router-acl`/`router-qos`/`ebpf-mwan`，UCI 不变。
- P4：`dpd-napi` sysfs 版已交付并写入 `napi.json`；per-NAPI netdev-genl、
  threaded NAPI、IRQ affinity 仍在 P4.1。

## 16. 参考

- Qualcomm NSS/ECM: https://github.com/qosmio/nss-packages
- MediaTek PPE: https://github.com/torvalds/linux/blob/master/drivers/net/ethernet/mediatek/mtk_ppe_offload.c
- Qualcomm SFE: https://github.com/lede-project/source/pull/1269
- FreeBSD ip_fastforward: https://github.com/freebsd/freebsd-src/blob/main/sys/netinet/ip_fastfwd.c
- OpenBSD pf paper: https://www.benzedrine.ch/pf-paper.html
- OPNsense performance: https://docs.opnsense.org/troubleshooting/performance.html
- VPP architecture: https://docs.fd.io/vpp/26.02/developer/corearchitecture/softwarearchitecture.html
- Panabit PanaOS: https://www.panabit.com/
- KNOD LPC 2026: https://lpc.events/event/20/contributions/2462/
- Linux NAPI: https://docs.kernel.org/6.18/networking/napi.html
- Linux netdev-genl: https://docs.kernel.org/6.18/netlink/specs/netdev.html
