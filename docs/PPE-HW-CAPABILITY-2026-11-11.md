# qca-ppe 硬件卸载：能力边界实测（2026-11-11）

设备：太乙 `10.10.10.100`，ImmortalWRT SNAPSHOT `r0-5cd11f1`，
`qualcommax/ipq60xx`，kernel **6.18.55**，aarch64 Cortex-A53。

## 0. 结论（含一次自我纠正）

**这台机器的 PPE 硬件卸载是工作的**，但它走的是 **tc flower（ACL 表）**，
不是 nft flowtable 的 L3 卸载。两者是不同的表，计数器也不同：

| 表 | 用途 | 本机状态 |
|---|---|---|
| `acl` | tc flower 的 L2–L4 匹配 + drop/redirect | ✅ **工作**（`in_hw`） |
| `offload` / `live_entries` | netfilter flowtable 的 L3 卸载 | ❌ 恒为 0 |

> **纠正**：本文的第一版写着"驱动没有注册任何 flow-block 钩子，所以硬件
> 卸载不可用"。前半句对，后半句错。实测发现 `tc flower skip_sw` 只要把
> filter preference 降到 512 以下，就真的落进硬件（`in_hw in_hw_count 1`）。
> 第一版之所以失败，是因为 `tc` 默认 pref 是 **49152**，超出驱动 ACL 索引
> 空间（512），内核返回的 `Not supported` 掩盖了真正的错误信息。
> 这个教训值得留着：**默认参数导致的 ENOTSUPP 不等于能力缺失**。

## 1. 证据：tc flower 真的落进硬件

```
# tc qdisc add dev lan3 clsact
# tc filter add dev lan3 ingress pref 100 protocol ip flower \
      dst_ip 10.9.9.9 skip_sw action drop

# tc filter show dev lan3 ingress
filter protocol ip pref 100 flower chain 0 handle 0x1
  eth_type ipv4
  dst_ip 10.9.9.9
  skip_sw
  in_hw in_hw_count 1          <-- 硬件收下了
	action order 1: gact action drop
	 index 3 ref 1 bind 1
	used_hw_stats immediate        <-- 硬件在统计
```

`skip_sw` 的含义是"只装硬件，不允许软件回退"。它能成功，就证明硬件真的
接了这个 filter。

### 1.1 行为可验证：增删都正确

```
装第二个 (pref 200):  hw-bound filters = 2
删掉 pref 200:        hw-bound filters = 1
```

硬件的 ACL 索引被正确分配和回收。

### 1.2 非 switch 端口会被正确拒绝

```
# tc filter add dev dpa ingress pref 100 ... skip_sw ...     (dpa 是 veth)
RTNETLINK answers: Not supported
```

驱动只接受真实 switch 端口（`lan1/lan2/lan3/wan`），对 veth 明确拒绝。
这正是 `ingress_not_switch_port` / `egress_not_switch_port` 这两个计数器
存在的理由。

### 1.3 pref 必须 < 512

```
# tc filter add dev lan3 ingress flower ... (默认 pref 49152)
Error: qca_ppe: filter preference is above what the classifier can order;
       use one below 512.
```

filter preference 就是硬件 ACL 的索引空间。**默认值会失败，必须显式指定
`pref < 512`**。这是这台机器上最重要的操作细节。

## 2. 为什么 `offloaded` / `live_entries` 恒为 0

因为它们统计的是**另一张表**：

```
offloaded              <- netfilter flowtable 的 L3 卸载（FLOW_BLOCK_BIND）
live_entries           <- 同上，当前在表条数
active_flows 0 0 0/2048<- L3 流表占用
l3_interface           <- 每个被路由的子网一条
```

`qca_ppe_setup_tc` 的符号表证明它**只实现 QoS 整形**：

```
qca_ppe_setup_tc_mqprio   <- 队列
qca_ppe_setup_tc_ets      <- 调度
qca_ppe_setup_tc_prio     <- 优先级
qca_ppe_setup_tc_tbf      <- 限速
```

没有 `FLOW_BLOCK_BIND`/`TC_SETUP_FT` 分支，所以 `nft ... flowtable flags offload`
永远到不了它。这点第一版的判断是对的。

**但 tc flower 走的是另一条路**（`qca_ppe_cls_flower_add`），那条路是通的。

## 3. 这对"软硬双加速"意味着什么

| 层 | 状态 | 证据 |
|---|---|---|
| DPD 软件数据面 | ✅ 完整验证 | 6.3–7.7 Gbit/s，命中率 99.98% |
| 软件 flowtable | ✅ 工作 | conntrack `[OFFLOAD]`，桥转发 6.7 Gbit/s |
| 软件↔软件协调（ABI 22） | ✅ 完整验证 | `ppe_yield` 94664→174356，`flow_hit` 冻结 |
| **PPE 硬件 ACL 卸载（tc flower）** | ✅ **实证工作** | `in_hw in_hw_count 1`，增删正确 |
| PPE 硬件 L3 卸载（nft flowtable） | ❌ 驱动未实现 | `offloaded` 恒 0，无 `FLOW_BLOCK_BIND` |

所以"软硬双加速"在这台机器上的正确形态是：

- **硬件**：PPE 的 ACL/steering 表（tc flower），用于 drop/redirect/限速；
- **软件**：DPD 的 TC eBPF 数据面，用于转发加速；
- **协调**：ABI 22 让 DPD 在 flowtable 接管某条流时让路。

硬件的 L3 转发卸载（比 eBPF 更省 CPU 的那种）**这颗内核不支持**，
不是没配置对。

## 4. 在这台机器上做实"硬件那一半"的正确方法

由于 tc flower 可用，硬件侧的验收应该这样做，而不是等 WAN 载波：

```sh
# 1. 在真实 LAN 端口上装一个硬件 ACL，确认 in_hw
tc qdisc add dev lan3 clsact
tc filter add dev lan3 ingress pref 100 protocol ip flower \
    dst_ip <某个测试地址> skip_sw action drop
tc filter show dev lan3 ingress | grep in_hw      # -> in_hw in_hw_count 1

# 2. 确认驱动 ACL 表在计数
cat /sys/kernel/debug/3a000000.ppe/acl

# 3. 确认删除后硬件释放
tc filter del dev lan3 ingress pref 100
tc filter show dev lan3 ingress | grep -c in_hw   # -> 0
```

这套流程不需要第二块网卡、不需要 WAN 载波，也不碰任何现有流量
（ACL 只匹配测试地址）。

## 4.1 决定性证据：`Sent hardware` vs `Sent software`

前面证明的是"filter 进了硬件"。这一条证明的是"**包真的由硬件处理**"。

在 lan1/lan2 上装一条匹配 NAS（`10.10.10.173`）的硬件 ACL，然后等真实流量：

```
--- lan2 ---
    src_ip 10.10.10.173
    in_hw in_hw_count 1
    Sent 612 bytes 8 pkt (dropped 8, overlimits 0 requeues 0)
    Sent software 0 bytes 0 pkt          <-- 软件路径：0 个包
    Sent hardware 612 bytes 8 pkt        <-- 硬件路径：8 个包全部
    used_hw_stats immediate

driver acl hit: 3 -> 10
```

`Sent software 0 pkt` / `Sent hardware 8 pkt` 是这套硬件加速最硬的证据：
8 个真实数据包由 PPE 处理并丢弃，**CPU 一个都没碰**。同时驱动自己的
`acl` 表从 3 涨到 10，说明是硬件计数器在报数，不是软件模拟。

（lan1 上那条是 0 包，因为 NAS 的流量从 lan2 进——两个端口都装了规则，
正好用来说明"装上了"和"真的用上了"是两回事，前者看 `in_hw`，后者看
`Sent hardware`。）

## 5. 若要验证 flowtable L3 卸载

需要另一台硬件：MTK PPE（有 `/sys/kernel/debug/ppe0/bind`）或支持
`FLOW_BLOCK_BIND` 的驱动。Qualcomm NSS/ECM 是 out-of-tree 栈，其
`IPS_HW_OFFLOAD` 写入**不保证**，需按 `RESEARCH-PPE-FALLBACK.md` 说明
改为读 ECM 的 netlink 状态。
