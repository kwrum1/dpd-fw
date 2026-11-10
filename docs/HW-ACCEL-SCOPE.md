# 硬件加速验收：能力边界与三个可选路径（2026-11-11 终版）

设备：太乙 `10.10.10.100`，ImmortalWRT SNAPSHOT `r0-5cd11f1`，
`qualcommax/ipq60xx`，kernel **6.18.55**，aarch64 Cortex-A53 ×4。

这份文档的用途：**把"硬件那一半"的验收标准钉在事实上**，而不是继续
尝试一个这颗芯片+内核做不到的事情。

## 1. 这颗硬件到底能做什么

`qca-ppe`（builtin，`/sys/kernel/debug/3a000000.ppe`）提供两个独立的加速面：

| 面 | 用途 | 状态 | 证据 |
|---|---|---|---|
| **ACL** | tc flower 的 L2–L4 匹配 + drop / mirred redirect | ✅ **工作** | `in_hw in_hw_count 1`、`used_hw_stats immediate` |
| **offload / l3_interface** | netfilter flowtable 的 L3 转发+SNAT 卸载 | ❌ **驱动未接线** | `offloaded=0`，拒绝计数全 0，无 `bind` 文件 |

### 1.1 ACL 面是真硬件

```
# tc filter add dev lan2 ingress pref 100 protocol ip flower \
      src_ip 10.10.10.173 skip_sw action drop
# tc -s filter show dev lan2 ingress
  in_hw in_hw_count 1
  Sent 612 bytes 8 pkt (dropped 8)
  Sent software 0 bytes 0 pkt        <-- 软件路径 0
  Sent hardware 612 bytes 8 pkt      <-- 硬件 8 个包
  used_hw_stats immediate
```

`Sent software 0` 是关键：8 个真实数据包由 ASIC 处理，CPU 一个都没碰。
驱动自己的 `acl` 表同步从 3 涨到 10。

`action mirred egress redirect dev lan1` 同样能 `in_hw`，也就是硬件能做
**端口间重定向**，不只是丢包。

### 1.2 ACL 的三个硬约束（都实测过）

1. **只能挂在真实 switch 端口上**（`lan1/lan2/lan3/wan`）。
   挂 `br-lan`（软件桥设备）→ `RTNETLINK answers: Not supported`；
   挂 veth → 同样 `Not supported`。
2. **filter preference 必须 < 512**。
   默认 `tc` 用 49152，会得到一条误导性的 `Not supported`；
   驱动真正的话是 `filter preference is above what the classifier can
   order; use one below 512`。
3. **桥内转发的包不经过 slave 的 tc ingress**。
   `lan1/lan2/lan3` 都是 `br-lan` 成员，LAN↔LAN 的流量由 ASIC 的 L2 表
   直接转发，因此 ACL 匹配不到——挂上去是 `Sent 0 pkt`。

第 3 条正是"没法在现有拓扑上演示硬件加速一条转发流"的物理原因。

### 1.3 L3 卸载为什么一定是 0

`qca_ppe_setup_tc` 的符号表说明了它实现了什么：

```
qca_ppe_setup_tc_mqprio   <- 队列
qca_ppe_setup_tc_ets      <- 调度
qca_ppe_setup_tc_prio     <- 优先级
qca_ppe_setup_tc_tbf      <- 令牌桶限速
```

全是 **QoS 整形**。没有 `FLOW_BLOCK_BIND` / `TC_SETUP_FT` 分支，所以
`nft ... flowtable flags offload` 的 `flow_block` 回调根本到不了驱动，
`offloaded` / `live_entries` / `l3_interface` 因此恒为 0。

三条独立佐证：
- 没有 `bind` 文件（MTK PPE 有 `/sys/kernel/debug/ppe0/bind`）；
- 驱动的拒绝计数全 0（说明从未被请求过，不是拒绝）；
- `skip_sw`（要求硬件）对 flowtable 类匹配返回 `Not supported`。

**这不是配置问题，也不是我们没做出来。**

## 2. 现状总结：软硬双加速做到了什么

| 层 | 状态 | 关键证据 |
|---|---|---|
| DPD 软件数据面 | ✅ | 6.3–7.7 Gbit/s，命中率 99.98% |
| 软件 flowtable 卸载 | ✅ | conntrack `[OFFLOAD]`，桥转发 6.7 Gbit/s |
| ABI 22 协调（软件↔软件） | ✅ | 端到端：`ppe=yielded`、`ppe_yield` 134819→288705、`flow_hit` 冻结 0 |
| **PPE 硬件 ACL（drop / redirect）** | ✅ **实测** | `Sent software 0 / Sent hardware 8 pkt` |
| **PPE 硬件 L3 转发卸载** | ❌ 驱动不支持 | `offloaded=0`，无 `FLOW_BLOCK_BIND` |

"同一条转发流上软件快路径 + 硬件卸载"**在这台机器上不可能**：硬件没有
L3 转发卸载，ACL 又看不到桥内流量。

## 3. 三个可选路径（需要你选一个）

### A. 用 MTK PPE 或 NSS 设备验收（唯一能让 `offloaded>0` 的路）

- **MTK PPE**：有 `/sys/kernel/debug/ppe0/bind`，写 `IPS_HW_OFFLOAD`，
  能真正卸载 L3 转发流；
- **Qualcomm NSS/ECM**（IPQ807x out-of-tree）：`ecm_front_end_acceleration_modes`
  可观测，但**不保证写 `IPS_HW_OFFLOAD`**（见 `RESEARCH-PPE-FALLBACK.md`），
  那种情况下 ABI 22 需要改为读 ECM netlink 而不是 conntrack 位。

需要：一台这样的设备。这是**唯一**能产出 `offloaded>0` 证据的路。

### B. 把验收标准正式收窄到本项目实际使用的两个加速面

即：**软件 flowtable 卸载 + ABI 22 yield（已完整验证）**
＋ **PPE 硬件 ACL 卸载（已实测 `Sent hardware`）**，
并明确记录"L3 转发卸载不在本硬件能力范围内"。

这条路不需要新硬件，但需要你**明确同意**改验收标准。

### C. 等一根网线

给 `wan` 插上网线（现在 `carrier=0`、`rx=0`）。有了第二段路由，
`wan` 与 `br-lan` 之间就是真实的路由转发，硬件 ACL 可以挂在 `wan`
和 `lan*` 上匹配/重定向真实流量。

注意：**这条路仍然不会让 `offloaded>0`**（驱动没有 L3 卸载），
它只能把"硬件处理真实转发包"的证据做得更完整。

## 4. 我的建议

**B + C 组合**，并把 A 记为需要外部硬件的前置条件：

1. 现在就把验收标准写成两个面（软件 yield + 硬件 ACL），这是
   **可复现、可回归、有证据**的；
2. 你方便时插一根 WAN 网线，我可以把"硬件 ACL 处理真实路由流量"
   补成端到端（不需要新设备）；
3. 真要做 L3 卸载，等有 MTK/NSS 设备再说，代码侧 ABI 22 已经准备好
   （`IPS_HW_OFFLOAD → DPD_PPE_OFFLOADED` 分支已实现并测试过映射逻辑）。

## 5. 复现命令

```sh
# 硬件 ACL 是否真的在硬件里（注意 pref < 512）
tc qdisc add dev lan2 clsact
tc filter add dev lan2 ingress pref 100 protocol ip flower \
    src_ip 10.10.10.173 skip_sw action drop
tc -s filter show dev lan2 ingress | grep -E 'in_hw|Sent hardware|Sent software'

# 驱动实现了哪些 offload 入口
grep -E 'setup_tc|flow_block|cls_flower' /proc/kallsyms | awk '{print $3}'

# L3 卸载是否被请求过（全 0 = 从未）
grep -E 'offloaded|live_entries|not_switch_port|unsupported' \
     /sys/kernel/debug/3a000000.ppe/offload

# 软件 flowtable + ABI 22 协调（已在本仓库测试脚本里）
#   见 docs/ACCEPTANCE-PPE-DUAL-ABI22.md 第 7.5 节
```
