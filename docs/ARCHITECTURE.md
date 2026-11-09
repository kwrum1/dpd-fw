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

## 15. P2.1 / P3 / P4 进展（2026-11-09）

### P2.1 双向加速（ABI 16，已验证）

结论先说：**不能在 ingress 重写源地址**。DPD 从 ingress redirect 出去的 skb
仍然会经过 einat 的 TCX egress；einat 看到源地址已经是外部地址，会按
“external IP SNAT to itself” 再分配一个端口（实测
`198.18.0.1:9044 -> 198.18.0.1:9300`），服务端 ACK 全部对不上，连接卡在
prime 窗口。

最终设计：

```
LAN ingress（classic pref 100, DPD）
    前向命中 -> dpd_nat 闸门 -> bpf_redirect(eth1)
                                     |
                                     v
                         einat TCX egress（真正做 SNAT）
                                     |
                                     v
                                   WAN

WAN ingress（einat TCX 先，DPD classic 后）
    einat 反 SNAT（DNAT） -> DPD 回程命中 -> redirect 到 br-lan
```

- `dpd_nat` 只是**准入闸门**，保存
  `(内网 addr, port, proto) -> (外部 addr, port)`，由 `dpd-einat-sync` 从
  einat 的 `map_binding`（只取 `BINDING_ORIG_DIR_FLAG`）1 Hz 镜像；
- 学习前向 flow 时，如果 FIB 出口带学到的 IPv4 nexthop，就打
  `DPD_FLOW_F_NAT (0x0080)`；**只有带这个标记的 flow 在命中时复查
  `dpd_nat`**，回程不受影响；
- 绑定在 flow 存活期间消失时，下一次命中返回 `TC_ACT_UNSPEC` 并计
  `ST_NAT_GONE`，交回栈由 einat 重建，不会把未 NAT 的包发出去；
- 镜像进程从**活着的程序的 map_ids** 解析 map，而不是按名字找：einat/DPD
  重启后旧 map 仍带同名，按名字会连到已死的实例（实测踩过）。

### 实验环境的重要修正

ESXi 里原来那台“客户端”VM 根本不在 dpd-test 的 LAN 上（其 192.168.10.1
的 MAC 不是 dpd-test br-lan 的 MAC），所以此前所有客户端侧的 P2 结论都不可信。
现在用 network namespace + veth 挂进 br-lan：

```
ip netns add lc
ip link add vlc type veth peer name vbr
ip link set vlc netns lc
ip link set vbr master br-lan up
ip -n lc addr add 192.168.10.200/24 dev vlc
ip -n lc route add default via 192.168.10.1
```

DPD 作为 bridge port 也 attach 到 `vbr`，路径与真实 LAN 客户端一致。

### 实测（ABI 16）

| 方向 | 条件 | 结果 |
|---|---|---|
| 下载 32MB | `vbr` egress tbf 20Mbit | 14.05s 完成，`flow_hit=26774 redirect=26774 nat_gone=0` |
| 上传 32MB | `eth1` egress tbf 20Mbit，netns `nc` 到 198.18.0.2:9000 | 服务端记录 `PEER 198.18.0.1 28721 BYTES 33554432`，`flow_hit 9968->20100`，`nat_gone=0` |

`28721` 在 einat 的外部端口段 20000-29999 内，字节数精确，说明加速后的前向
包经过 einat SNAT 且校验和正确。前向 flow 形如
`(192.168.10.200:52356 -> 198.18.0.2:8000) egress=3 flags=0x182`，
其中 `0x80` 是 `DPD_FLOW_F_NAT`。

**约束**：einat 与 fw4 `masquerade` 不能同时开启。两者都开时，慢路径包由 nft
分配外部端口、加速包由 einat 分配另一个端口，同一连接会出现两个源端口，批量
传输在 prime 窗口后卡死（2026-11-09 用 `masq=1` 复现）。einat 的 init 本来就会
通过 procd 注入规则关掉 masq，gate 也只在 einat 确认挂在上行时才置
`nat_offload`，所以这是误配置而非常态。

### P2.3 前向 SNAT + 端口分配由 DPD 完成（ABI 20，实验性）

`nat_forward=dpd` 时，前向写包不再经过 einat：

- **挂载点**：新增 `classifier/egress` 程序，只挂在上行的 **egress** 钩子。
  这是路由和 netfilter 之后、和 einat 的 TCX egress 完全相同的位置，所以
  “netfilter 看到哪些包”不变。不能改在 ingress 做：P2.1 实测过，ingress
  改写后 einat egress 会把包再 NAT 一次（双 NAT，服务器丢弃所有 ACK）。
- **分配**：miss 时用 5 元组哈希在 `[nat_port_min, nat_port_max]`
  （默认 20000–29999）里探测 8 个候选；用 `dpd_nat_rev` 本身做端口归属表，
  `BPF_NOEXIST` 插入反向条目即“抢到”该端口，两个 CPU 不会同时赢。
  反向条目带 CLOCK_MONOTONIC 毫秒时间戳，超过 TCP TTL 后视为可回收；
  命中时最多每分钟刷新一次时间戳。
- **外部地址**：分配时对目的地址做一次
  `bpf_fib_lookup(..., BPF_FIB_LOOKUP_OUTPUT | BPF_FIB_LOOKUP_SRC)`，
  取路由的首选源地址。多地址上行（实验箱 eth1 同时有 10.46.0.6 和
  198.18.0.1）只有这样才对；`dpdctl nat_addr` 教进去的 `addr4` 只是
  兜底和“这是一条 NAT 上行”的开关。
- **写包**：命中或刚分配都把 saddr/sport 改成 `(ext, port)`，增量更新
  IP/L4 校验和；UDP 校验和为 0 时跳过 L4 更新。回程仍由 ABI 19 的
  `dpd_nat_rev` DNAT 完成 —— 两个方向各一次查表。
- **ICMP**：echo 的 16 位 id 当作“端口”复用同一套分配/反向表；SNAT 改
  saddr + id（IP 和 ICMP 校验和分别更新，ICMP 校验和不含伪首部），DNAT
  还原 daddr + id。ICMP **不做快路径**（UFS key 没有端口，同一主机的所有
  id 会撞成一条），全部走栈；这样回程 DNAT 后与 conntrack 原始 tuple
  完全一致，反而比 TCP/UDP 更容易被判为 established。
- **回程 DNAT 的挂载点在 pref 50，不在主程序（pref 100）里**：
  router-acl 占 90；DNAT 之前回包的目的地址还是路由器自己，策略层会把它
  当“WAN→本机”处理（实测 ICMP 回包在 pref 100 时被 pref 90 丢掉，ping
  0/3；同一程序挂到 pref 50 后 3/3）。所以单独出一个
  `classifier/nat`（DNAT-only、永远 `TC_ACT_UNSPEC`），在主程序之前把
  tuple 还原；主程序里的 DNAT 块保留作兜底。
- **安全阀**：`nat_forward=dpd` 且 bpftool 确认任一上行还挂着 einat 时，
  gate 直接降级到 observe，egress 程序也不挂载（宁可不动，也不能双 NAT）。
  默认 `nat_forward=einat` 时新程序完全不挂。
- **与 fw4 masquerade 共存**：masq 在 POSTROUTING 先改包，我们的 egress
  看到 `saddr == ext` 就直接放行，不会二次改端口。

ESXi 实测（2026-11-09，eth1 同时有 10.46.0.6/198.18.0.1）：

| 场景 | 结果 |
|---|---|
| 1MB 下载（einat ingress/egress 都 detach） | OK；`nat_alloc=1`、`nat_snat=117`、`nat_dnat=241` |
| 绑定内容 | `192.168.10.200:35744 -> 198.18.0.1:25626`（端口在范围内） |
| 32MB 下载 | 33554432 字节完整 |
| 两条并发流 | 各自分到 23312 / 22924，表里 4 条 binding |
| 恢复 `nat_forward=einat` + einat 重新挂载 | 下载 OK，`nat_snat/nat_dnat/nat_alloc` 全为 0 |
| ICMP ping（pref 50 DNAT 阶段） | 3/3，`nat_snat=3`、`nat_dnat=3` |
| 重构后 1MB / 32MB 下载 | OK；1MB `nat_snat=96/nat_dnat=144`，32MB 33554432 字节完整 |
| 默认模式 | pref 50 与 egress 钩子都不存在，ping/下载正常 |

还没做（能力边界要写清楚）：

- **ICMP 错误报文**（type 3/11，traceroute 依赖）没有做 inner-packet 的
  id/地址改写；目前只处理 echo request/reply。UDP traceroute 的端口部分
  可用，ICMP 错误回包仍走栈。
- **fw4 accept 要自己给**：einat 停掉后它注入的 WAN→LAN 兜底 accept 也没了。
  `nat_forward=dpd` 目前要求操作者显式加一条 fw4 规则；下一步应在包里
  提供 nft include 并让 gate 检查它。
- **binding 生命周期**：`dpd_nat` 是 LRU，极端压力下一条活跃 binding 可能
  被挤掉，之后同一 5 元组会分到新端口（上游会拒绝）。端口表只按 TTL 回收，
  没有 conntrack destroy 驱动的主动回收；`dpdfwd` 的 CT 事件可以接进来。
- 多 WAN 时端口归属按 `(ext_addr, port, proto)` 区分，同一个端口号可以在
  两个 WAN 地址上同时使用，这是符合 NAT 语义的；但端口池本身是全局的。

### P2.2 回程 DNAT 由 DPD 完成（ABI 19，可选）

- `dpd-einat-sync` 除正向 binding 外，还把 einat 的**反向 binding**
  （external tuple -> internal tuple）镜像到 `dpd_nat_rev`；
- `cfg.nat_ingress=1` 时，WAN 入包在 UFS 查表**之前**用 `dpd_nat_rev`
  做 DNAT（改 daddr/dport + 校验和），然后继续正常的 UFS/FIB 流程；
- **默认安全**：einat 的 ingress TCX 还挂着时，包已经被它 DNAT 过，
  `dpd_nat_rev` 的 key 不匹配，DPD 什么都不做（`nat_dnat` 保持 0）；
- 只有把 einat 的 **ingress link** detach 之后才生效（egress 继续负责
  前向 SNAT 和端口分配）。ESXi 实测：detach ingress 后 1MB 下载 OK，
  `nat_dnat=332`；恢复 einat 后 `nat_dnat=0`、下载正常。
- 这是“回程一次查表”的半步；前向 SNAT/端口分配由 P2.3（ABI 20）补齐。

### P1 Flow Manager（ABI 17，已实现 MVP）

数据面仍然由 BPF 学习直连流，`dpdfwd` 只做控制面事件；两者分工如下：

- **`accel_after_pkts`（默认 32）**：新方向的前 32 个包继续走栈，短流完全不进
  快路径。计数器从 8 位缩到 7 位（bit 15 留给 `DPD_FLOW_F_REPLY`）。
- **FIN/RST 立即释放**：命中路径检查 TCP flags，FIN/RST 时删除该方向 UFS
  条目并交回栈，计 `ST_FLOW_FIN`；不再等 TTL。
- **协议对齐超时**：TCP 300s、双向 UDP 120s、单向 UDP 30s。UDP “是否双向”
  在学习时查一次反向 key，置 `DPD_FLOW_F_REPLY`；命中路径不额外查表。
- **`dpdfwd`（新包）**：订阅 rtnetlink 的 link/addr/route/neigh 事件，300ms
  去抖后只调用一次 `dpdctl bump`；同时订阅 conntrack new/update/destroy 做
  计数，输出 `/var/run/dpd/flowd.json`。数据面不依赖它，daemon 崩溃不影响转发。
- **声明式分类**：`/etc/dpd/class.conf` 每行一个 5 元组 + 动作
  （`forward/proxy/block/local` + 可选 skb priority），`dpdfwd` 每 5 秒看
  mtime，变化时 `dpdctl class flush` 后逐条 `class add`；计数发布到
  `flowd.json` 的 `class_rules/class_bad/class_applied_at/class_error`。
  规则在 UFS 学习时复制进条目，改规则后要 `dpdctl bump`（或定向删流）才对
  已学流生效。ESXi 实测：`block` 规则使 `flow_block` +76、下载被拒；
  清空文件后自动 flush、流量恢复。

ESXi（ABI 17）验证：

| 场景 | 结果 |
|---|---|
| 短流（一个 JSON 请求） | `flow_hit` 不增长（32 包门限生效），`flow_fin` +1 |
| 32MB 下载 | 0.61s，`flow_hit=3994`，`flow_fin` +2，`nat_gone=0` |
| 路由增删 | `epoch 0→1`，`epoch_bumps=1`（两次事件合并成一次） |
| 一次 TCP 请求 | `flowd.json` `ct_new=6` |

还没做：把 `accel_after`/TTL 由 `dpdfwd` 动态决策（现在由 UCI 静态下发）；
UDP 自适应的真机/双 peer 验证。按流定向失效已落地（见 P1.1）。

### P1.1 UFS v2 + 策略缓存（ABI 18，已实现）

- `dpd_flow_val` 增加 `state/action/skb_priority/ct_cookie/nat_flags/dscp/
  packets/bytes`；显式记录 `OBSERVE -> BIND`，FIN/RST 置 `FIN` 后删除。
- 新增 `dpd_class` 策略缓存：用户态按 5-tuple 写
  `forward/proxy/block/local + skb_priority`，学习时复制进 UFS，命中路径
  不再查表。端口 0 与 ifindex 0 是通配（8 种组合，学习时最多 8 次查表）。
- `dpdctl class add|del|list|flush`、`set counters/class`；
  `dpdctl flows` 显示 state/action/priority/dscp/pkt/bytes。
- 实测（ABI 18）：eth1 回程 block 规则令 wget 超时（FAIL）；`class flush`
  后恢复 OK；命中路径的 action 门禁生效。
- **按流定向失效已落地**：`dpdfwd` 解析 ctnetlink DESTROY 的 orig/reply
  5-tuple，攒批后每秒调用一次 `dpdctl delete -f`；后者扫一遍 UFS 并按
  通配 5-tuple 删除。实测一次批量删除 8 条回程流。这样 conntrack 已经
  消失的流不会在 UFS 里留到 TTL。
- 仍归 einat/栈所有的：NAT 翻译结果（UFS 不缓存，P2.2）、
  ACL/QoS 的真实分类器（`dpd_class` 已提供机制）。

### P3 / P4

- P3：`dpd-acl`/`dpd-qos`/`dpd-mwan` meta 包已加入包集，底层仍是
  `router-acl`/`router-qos`/`ebpf-mwan`，UCI 不变。
- P4：`dpd-napi` 的 sysfs 版与 `dpd-napi-netdev`（netdev generic netlink）
  都已交付。后者按真实 NAPI 实例设置 `gro_flush_timeout`/`defer_hard_irqs`/
  `irq_suspend_timeout`/`threaded`，不再依赖每设备 sysfs。dpd-test 6.18 实测
  eth1 的 4 个 NAPI（537-540）逐个设置并回读成功。
  - UAPI 两个坑：`CTRL_ATTR_FAMILY_ID` 是 u16 而不是 u32；`NAPI_GET`/`NAPI_SET`
    的命令号是 11/14（`QUEUE_GET` 是 10、`BIND_RX` 是 13），错一位会静默 dump
    队列并且把设置打到 dmabuf 绑定上。
  - 6.17 的 NAPI dump 带 ifindex 过滤会返回 EINVAL（虽然 spec 允许），所以
    工具全量 dump 后在用户态过滤。
  - threaded NAPI 在 vmxnet3 上不生效（驱动未 opt-in），需要真机 A/B。

## 16. 高通 PPE/NSS 回退耦合（调研，2026-11-09）

调研结论：DPD 可以作为 **NSS 硬件卸载失败时的软件回退**，但只能定位为
“NSS 异常路径上的补充”，不能做成第二个 flowtable。详细分析见
`docs/RESEARCH-PPE-FALLBACK.md`，要点：

- NSS 卸载成功的包不再进入 Linux/TC；回到 TC 的本就是 NSS 没接住的流，
  因此 TC eBPF 天然是回退点。
- 判定“卸载失败”有三种信号：
  1. conntrack `CTA_STATUS` 的 `IPS_OFFLOAD`（bit14）/`IPS_HW_OFFLOAD`（bit15），
     适用软件 flowtable 与 MTK PPE；
  2. Qualcomm ECM 的 `ecm_front_end_acceleration_modes`（`< 0` 即永久失败：
     DENIED/RULE/DRIVER/ACCEL_ENGINE/NO_ACTION/DECEL/DEFUNCT）；
  3. 异常路径推断：grace 窗口后同一流仍有包到达 TC ⇒ 未被卸载。
- 方案：`dpdfwd` 维护 `dpd_ppe` map（UNKNOWN/OFFLOADED/FAILED/DENIED），
  DPD 命中路径只读；`ppe_fallback=udp|all|off` + `ppe_grace_ms`。
  UDP 是硬件失败率最高的部分，默认只回退 UDP，TCP 继续交给 NSS。
- NAT：IPQ 上 NAT 归 NSS/conntrack，`nat_offload=0`，DPD 不接管上行，只加速
  回程；上行加速需要 NAT 映射同步（P7.3）。
- 实施顺序：x86 用软件 flowtable 验证检测逻辑 → IPQ 用 ECM/推断做实机 →
  内核 `flow_block` 回调做精确化。

## 17. 参考

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
