# DPD-FW 技术说明（中文）

本文说明 DPD-FW 的架构、数据面工作原理、NAT/加速归属、与 honk/PPE 的协作、
NAPI 调优、可观测性、构建与运维。英文版见 [DPD-GUIDE.en.md](DPD-GUIDE.en.md)。

## 1. 定位

DPD-FW 是 OpenWrt 上的 **TC/eBPF 软件数据面**：

- 在 `tc` ingress/egress 钩子上做流缓存（UFS）与转发，不依赖 XDP、AF_XDP、
  DPDK 或任何驱动私有接口；
- 默认在 x86 与 Rockchip（ARM64）上以 stock 驱动工作；
- 硬件加速（Qualcomm PPE/NSS、MediaTek HNAT）是**另一层**：本项目的目标是
  与它协作/回退，而不是取代硅片；
- NAT 的默认拥有者是 `einat`（TC eBPF full-cone NAT），DPD 只做转发加速；
  也可以切到 DPD 自有 NAT，但两者不能同时挂在同一条上行。

它**不是**：第二个防火墙、第二个 NAT（默认）、第二个 flowtable，或硬件卸载
驱动。

## 2. 组件

```
┌──────────────────────────── 控制面 ────────────────────────────┐
│ dpdfwd        流生命周期、ctnetlink、自动调参、epoch、插件      │
│ dpdctl        map/流表/本地地址/NAT 绑定的命令行                │
│ dpd-napi      NAPI/IRQ/GRO/RPS/XPS/qdisc 调优（自适应档位）     │
│ LuCI          状态、简易防火墙、多 WAN、NAPI/DPD 页面           │
└───────────────────────────────┬────────────────────────────────┘
                                │ pinned BPF maps
┌───────────────────────────────┴────────────────────────────────┐
│ TC eBPF 数据面（bpf/core/src/dpd_fastpath.bpf.c）               │
│  classifier/l2   LAN 入口（br-lan / 网桥端口）                  │
│  classifier/l3   WAN 入口（pppoe-wan，downlink=1）              │
│  classifier/nat  WAN ingress pref 50（DPD 自有 NAT 时的 DNAT）  │
│  classifier/egress  WAN egress（DPD 自有 NAT 时的 SNAT）        │
└─────────────────────────────────────────────────────────────────┘
```

插件：`dpd-honk`（honk 生命周期/门禁）、`dpd-einat`（NAT 绑定同步）、
`dpd-acl`、`dpd-qos`、`dpd-mwan`、`dpd-observe`、`dpd-knod`（可选 GPU provider）。

## 3. 包路径

```
收到帧
  │
  ├─ br-lan / eth0..2 ingress：classifier/l2
  │    └─ 解析 L2/L3/L4，查 UFS（dpd_flows）
  │
  └─ pppoe-wan ingress：classifier/l3（downlink）
       └─ 同一套 UFS 逻辑

命中（hit）：
  epoch/TTL/策略检查
    → （NAT 流）dpd_nat 绑定闸门
    → 恢复 skb_priority
    → VLAN 处理 / TTL 递减
    → dpd_emit_cached：写 L2 头 + bpf_redirect
       （ppp/tun 用 bpf_redirect(ifindex)，无需邻居表）

未命中（miss）：
  → 本机地址快判（dpd_local）→ 命中则交回协议栈
  → bpf_fib_lookup（ppp/tun 首次 NO_NEIGH 时用 SKIP_NEIGH 重试）
  → 本机/不可转发 → 交回协议栈
  → NAT 闸门（einat 模式要求 forward+reverse 绑定一致）
  → 学习 UFS（prime = accel_after_pkts）
  → 当前包仍走协议栈
```

### 3.1 流键与 UFS

`struct dpd_flow_key` = 入接口 ifindex + family + proto + 五元组。
`dpd_flows` 是 LRU hash（默认 16384 条），每条保存：

- `egress_ifindex`、`flags`（L2/DEV/NO_NEIGH/L3OUT/NAT）、`wan`（WAN 索引与 epoch）；
- `dmac/smac`、IPv4 nexthop；
- `last_seen_ms`、`state`（OBSERVE/BIND/FIN）、`action`（forward/proxy/block/local）；
- `packets/bytes`（`flow_counters` 0/1/2）。

### 3.2 接管门槛（priming）

新流每个方向先走 `accel_after_pkts` 个包（默认 8，自动调参可降到 8/升到 64）。
原因不是“礼貌”：太快接管会让 netfilter 看不到握手/ACK，conntrack 状态不完整。
`accel_after=8` 兼顾短流命中与 conntrack 完整性。

### 3.3 epoch

链路/地址/路由变化会让整个流表失效（epoch++）。邻居（IPv6 NUD）事件最多每
30 秒触发一次 bump，否则每 2 秒一次的全表失效会让短流永远学不会。
epoch 只在 `dpd_flow_val.wan` 的高 8 位，命中路径一次比较即可。

### 3.4 本机地址快判（dpd_local）

`dpdctl local sync` 把路由器自己的 IPv4/IPv6 地址写入 `dpd_local`。miss 路径在
FIB 之前查它：命中说明包只能本机投递，直接 `local++` 并返回 `TC_ACT_UNSPEC`，
不再做必然失败的 `bpf_fib_lookup`。`dpdfwd` 在地址事件时自动重新 sync。

## 4. NAT 归属

### 4.1 einat 模式（默认）

- einat 在 TC 层做 SNAT/DNAT（full-cone），不在 conntrack 里；
- `dpd-einat-sync` 把 einat 的绑定镜像到 `dpd_nat`/`dpd_nat_rev`；
- DPD 的命中/学习闸门要求 **forward 与 reverse 绑定一致**：
  `dpd_nat` 的 `to_addr/to_port` 反查 `dpd_nat_rev`，必须指回同一条内网 tuple；
  不一致（绑定被回收/覆盖）就不学习，`nat_gone++`，留在协议栈。
- 因此 DPD 只加速 einat 已经正确 NAT 的流；长命流活过绑定生命周期时会被
  闸门挡住，而不是带着错误的 external port 发出去。

### 4.2 DPD 自有 NAT（`nat_forward=dpd` / `nat_ingress=dpd`）

- WAN ingress pref 50 做 DNAT，WAN egress 做 SNAT + 端口分配（20000–29999）；
- 有自己的 `dpd_nat` 绑定与回收；与 einat 互斥（gate 拒绝双 NAT）；
- 适合没有 einat 的部署；当前真机 A/B 显示它在上行/回程学习上还不如 einat，
  默认不启用。

### 4.3 与 honk 的关系

honk 在 LAN TCX 上做透明代理。原版 core 对 `direct` 流返回 `TC_ACT_OK`，
TCX 链终止，后面的经典 TC 链（DPD）看不到这些包。x86/RK 使用 **p1 core**：
direct 流打 `DIRECT_UNSPEC_MARK` 并返回 `TC_ACT_UNSPEC`，DPD 才能继续接管；
proxy/block 判决仍是终态，NAT 仍归 einat。IPQ/MTK 使用原版 honk。

## 5. 与 PPE/NSS/flowtable 协作

- **Qualcomm qca_ppe（IPQ60xx/807x）**：PPE 是 netfilter flowtable 卸载，
  首包走主机，之后硬件接管；DPD 在 grace 前不抢流，卸载后包不进 TC；
- **Qualcomm NSS/ECM**：卸载后的包不进 Linux，DPD 只处理回到主机的异常流；
- **DPD 自有 NAT + PPE**：NAT 引擎必须二选一（conntrack/PPE 或 einat/DPD），
  不能中途换；
- **MTK HNAT**：flowtable 模型，同上。

原则：**同一条流不能被两层同时加速**；DPD 只做硬件接不住/没接的流。

## 6. NAPI / 队列

`dpd-napi` 有三档：

- `low`（默认）：`gro_flush_timeout=0`、`napi_defer_hard_irqs=0`、
  `netdev_budget=300`、`dev_weight=64`、RPS/XPS 关闭；
- `throughput`：`20000ns/2`、`1000`、`128`、RPS/XPS=`f`；
- `adaptive`：从 low 开始；CPU>60% 连续 3×10s 切 throughput，<25% 连续
  6×10s 切回。

`irq_cpus` + `irq_spread=1` 把每个 IRQ 轮转绑到一个 CPU（例如 `0-3`）；
`busy_poll`/`busy_read` 只影响设置 `SO_BUSY_POLL` 的 socket，转发路径不用，
默认 0。

本机 64B UDP A/B（固定 90 Mbps）：spread 与整掩码吞吐在噪声内，每 MB CPU
约低 7%；吞吐档在约 176k pps 时 softirq 约减半（GRO/RPS），但代价是延迟。

## 7. 可观测性

```sh
dpdctl status -j          # cfg/maps/counters/gate，JSON
dpdctl show               # 人类可读的 cfg/iface/ttl/nat
dpdctl stats              # 每 CPU 汇总的计数器
dpdctl flows -a           # 全量 UFS（含五元组、state、pkt/bytes）
dpdctl local list         # 本机地址快判表
dpdctl nat [-a]           # einat 镜像的绑定/反查表
cat /var/run/dpd/flowd.json   # 流管理、epoch、tune、ct offload
cat /var/run/dpd/napi.json    # NAPI 档位、IRQ spread、busy_poll
cat /var/run/ebpf/gate.json   # 门禁与原因
```

关键计数器：`flow_hit/flow_miss`、`bytes_hit_v4/v6`、`fib_ok/fib_fail`、
`local`、`nat_gone`、`flow_bind/fin`、`redirect_ok/neigh_ok`。

## 8. 构建与 CI

- `dpd-fw` 仓库：`bpf/core`（BPF 对象 + dpdctl）、`userspace/*`（dpdfwd、
  dpdctl、dpd-napi）、`openwrt/*`（LuCI）、`plugins/*`。CI 在
  `.github/workflows/ci.yml`：shellcheck、BPF 编译、ABI/段落/计数器校验。
- `ebpf-honk-ImmortalWRT-CI`：镜像/包构建。X86/RK 使用本仓库
`patches/honk/`（源码补丁 + `core-p1`）；IPQ/MTK 使用原版 honk。
  `HONK-CORE` 构建 p1 core 并发到固定 tag `core-p1`。
- 本地构建：`sh scripts/check-scripts.sh`、`make -C bpf/core`、
  `sh scripts/verify-abi.sh`。

## 9. 运维与排障

- 门禁：`/var/run/ebpf/gate.json` 的 `code`/`reason`；`no-einat`、`honk-unpatched`
  等会降级为 observe；
- 流不加速：先看 `gate`，再看 `dpdctl flows` 的 state/epoch，最后看
  `nat_gone`/`fib_fail`；
- 命中率低：区分“没学到”（短流、NAT 绑定、FIB 失败）和“学到了但没命中”
  （epoch/绑定变化）；
- 长命 NAT 流：`conntrack -D` 回收后让客户端重连，或等 TTL；
- 关闭/回滚：`dpdctl set mode off|observe`；`/etc/init.d/dpd-fastpath stop`。

## 10. 已知边界

- 不做 XDP/AF_XDP/DPDK；不接管驱动；
- 家庭带宽下瓶颈通常在链路，CPU 不是；微优化收益有限；
- IPv4 NAT 流中途不能换 NAT 引擎；
- PPE/NSS 卸载后的包 DPD 看不到，双加速是流级分区，不是同流叠加；
- GPU/NPU 不适合快路径（延迟/批量/DMA），只适合旁路批处理；
- 自动调参的 TTL 有步进限制，避免抖动。
