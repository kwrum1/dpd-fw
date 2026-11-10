# qca-ppe 硬件卸载：能力边界实测（2026-11-11）

设备：太乙 `10.10.10.100`，ImmortalWRT SNAPSHOT `r0-5cd11f1`，
`qualcommax/ipq60xx`，kernel **6.18.55**，aarch64 Cortex-A53。

## 1. 结论

**这个内核里的 `qca-ppe` 驱动没有注册任何 flow-block / tc 硬件卸载钩子。**
所以 `/sys/kernel/debug/3a000000.ppe/offload` 的 `offloaded` / `live_entries`
永远是 0 —— 不是没有流量，也不是配置错误，而是**没有通路**。

这不是猜测，下面每一条都是设备上的实测输出。

## 2. 证据

### 2.1 `skip_sw` 直接被内核拒绝

`skip_sw` 的含义是"只装硬件，不允许软件回退"。驱动不能卸载时内核返回
`-EOPNOTSUPP`：

```
# tc filter add dev dpa ingress protocol ip flower dst_ip ... skip_sw action drop
RTNETLINK answers: Not supported

# tc filter add dev dpa ingress protocol ip matchall skip_sw action drop
RTNETLINK answers: Not supported
```

同一个 filter **去掉** `skip_sw` 就能装上，但被明确标记 `not_in_hw`：

```
# tc filter add dev dpa ingress protocol ip flower dst_ip 192.168.200.10 action drop
# tc filter show dev dpa ingress
filter protocol ip pref 49152 flower chain 0 handle 0x1
  eth_type ipv4
  dst_ip 192.168.200.10
  not_in_hw          <-- 硬件没收
```

### 2.2 驱动只在 QoS 方向实现 `ndo_setup_tc`

`/proc/kallsyms` 里的实际符号：

```
qca_ppe_setup_tc          <-- 分发器
qca_ppe_setup_tc_mqprio   <-- 队列整形
qca_ppe_setup_tc_ets      <-- ETS 调度
qca_ppe_setup_tc_prio     <-- 优先级映射
qca_ppe_setup_tc_tbf      <-- 令牌桶限速
```

全是 **QoS 整形**，没有一个是 `FLOW_BLOCK_BIND` 或 `FLOW_BLOCK_UNBIND`。
netfilter 的 flowtable（`nft ... flowtable flags offload`）走的正是
`flow_block` 回调，所以它**根本到不了这个驱动**。

对比：一个真正支持 flowtable 卸载的驱动会暴露 `ndo_setup_tc` 里处理
`TC_SETUP_FT` / `TC_SETUP_CLSFLOWER` 的分支，并且在 debugfs 里有一个
`bind` 文件（MTK PPE 就是 `/sys/kernel/debug/ppe0/bind`）。

```
# ls /sys/kernel/debug/3a000000.ppe/ | grep -c bind
0
```

### 2.3 有 `cls_flower` 符号，但对 DSA 用户端口无效

```
qca_ppe_cls_flower_add
qca_ppe_cls_flower_del
qca_ppe_cls_flower_stats
```

这些是 DSA switch 的 flower 卸载入口。但实测 `skip_sw` 返回 `Not supported`，
说明在当前 DSA 拓扑（`lan1/lan2/lan3/wan` 都是同一块 `eth0` 的 DSA 用户端口）
下，它没有被接通到可用的硬件表。

### 2.4 驱动自己的拒绝计数全为 0

```
offloaded                0
live_entries             0
ingress_not_switch_port  0
egress_not_switch_port   0
no_egress_l2_header      0
unsupported_match        0
unsupported_protocol     0
unsupported_action       0
table_full               0
```

**关键**：如果驱动被请求过但因为参数不合适而拒绝，这些计数器会动。
全 0 说明它**从未被请求**。结合 2.1 的 `-EOPNOTSUPP`，结论一致：
卸载请求在到达驱动之前就被内核挡掉了。

### 2.5 硬件本身在转发，只是不经过卸载表

```
# cat /sys/kernel/debug/3a000000.ppe/egress
port packets bytes drop_packets drop_bytes
0    24311   9415762 0 0
2    15963   6105427 0 0
3    31094  12311625 0 0
```

交换 ASIC 确实在转发（端口计数在涨），`active_flows` 只是 L3 卸载表的
占用（`0 0 0/2048`），两者不是一回事。桥内/普通转发由 ASIC 的 L2 表完成，
不需要 L3 卸载表。

### 2.6 软件 flowtable 是工作的

用两个 netns 之间的桥转发实测（iperf3 **6.7 Gbit/s**），conntrack 出现了
`[OFFLOAD]` 条目：

```
conntrack OFFLOAD entries: 2
```

也就是**软件 flowtable 正常加速**，只是不会下沉到 PPE 硬件。这正是
ABI 22 协调层要处理的场景，也是 `ppe_yield` 在真实设备上被验证的原因。

## 3. 那么"软硬双加速"到底是什么状态

| 层 | 状态 | 证据 |
|---|---|---|
| 软件加速（DPD TC eBPF） | ✅ 完整验证 | 6.3–7.7 Gbit/s，命中率 99.98% |
| 软件 flowtable | ✅ 工作 | conntrack `[OFFLOAD]`，桥转发 6.7 Gbit/s |
| 软件↔软件协调（ABI 22） | ✅ 完整验证 | `ppe_yield` 94664→174356，`flow_hit` 冻结 |
| **硬件卸载（qca-ppe L3）** | ❌ **驱动不支持** | `skip_sw` → `Not supported`，无 flow-block 符号 |

所以这台机器上**不存在"软硬双加速"的硬件那一半**，不是我们没做出来，
是这颗内核的驱动没有提供这个能力。

## 4. 要在硬件侧真正闭环，有两条路

### 4.1 换用支持 flowtable 卸载的驱动/机型
- MTK PPE：`/sys/kernel/debug/ppe0/bind` 存在，`IPS_HW_OFFLOAD` 会被写入；
- Qualcomm **NSS/ECM**（IPQ807x 的 out-of-tree 栈）：`ecm_front_end_acceleration_modes`
  可以观测，但**注意它不一定写 `IPS_HW_OFFLOAD`**（见
  `RESEARCH-PPE-FALLBACK.md` 的说明），那种情况下 ABI 22 需要改为读
  ECM 的 netlink 状态，而不是 conntrack 位。

### 4.2 在这台机器上验证"协调"而非"硬件"
ABI 22 的价值本来就不依赖硬件是否真的接管：它依赖的是**内核告诉我们
"这条流被别人接管了"**。软件 flowtable 恰好会写 `IPS_OFFLOAD`，这一点
已经在真机上验证（`ppe_yield` 冻结 `flow_hit`）。

如果目标是验证 `IPS_HW_OFFLOAD` 分支，需要一台 MTK PPE 或 NSS 设备。

## 5. 复现命令

```sh
# 1. 硬件卸载是否被支持（最直接的一条）
tc qdisc add dev <port> clsact
tc filter add dev <port> ingress protocol ip flower dst_ip 10.0.0.1 \
    skip_sw action drop
#   -> "RTNETLINK answers: Not supported"  = 驱动不支持

# 2. 驱动实现了哪些 setup_tc 分支
grep -E 'setup_tc|flow_block|cls_flower' /proc/kallsyms | awk '{print $3}'

# 3. 有没有 flow_block 注册
ls /sys/kernel/debug/*.ppe/ | grep -c bind      # 0 = 没有

# 4. 驱动是否被请求过（全 0 = 从未被请求）
grep -E 'offloaded|live_entries|not_switch_port|unsupported' \
     /sys/kernel/debug/*.ppe/offload
```
