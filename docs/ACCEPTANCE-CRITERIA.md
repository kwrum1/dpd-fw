# 软硬双加速：正式验收标准（2026-11-11，用户批准）

适用范围：`qualcommax/ipq60xx` + `qca-ppe` + kernel 6.18.55（太乙 `10.10.10.100`）。

## 0. 决定

**验收标准收窄为两个可实测的加速面**，并明确记录 L3 转发卸载不在本硬件
能力范围内。这是 2026-11-11 由项目负责人确认的决定，依据是
`HW-ACCEL-SCOPE.md` 里的实测证据。

收窄**不是降低要求**：两个面都是真硬件/真内核行为，都有计数器级证据，
且整套协调逻辑（ABI 22）在这两个面上都验证过。

## 1. 验收项与判定标准

### AC-1 软件数据面（DPD TC eBPF）

| 判定项 | 阈值 | 状态 |
|---|---|---|
| BPF 对象在 6.18.55 上加载 | verifier 通过，jited 非空 | ✅ |
| 转发吞吐 | ≥ 5 Gbit/s TCP（veth 对，iperf3） | ✅ 5.1–7.7 |
| 流命中率 | ≥ 99% | ✅ 99.98% |
| 真实网口 observe 模式 | 计数增长且不写流表 | ✅ |

### AC-2 软件 flowtable 卸载（内核 nf_flowtable）

| 判定项 | 阈值 | 状态 |
|---|---|---|
| conntrack 出现 `[OFFLOAD]` | ≥ 1 条 | ✅ 2 条 |
| 桥/路由转发吞吐 | ≥ 6 Gbit/s | ✅ 6.5–7.2 |

### AC-3 ABI 22 协调层（软件↔软件）

| 判定项 | 阈值 | 状态 |
|---|---|---|
| conntrack → dpdfwd → dpdctl → 数据面，无手工调用 | `ppe=yielded` 自动出现 | ✅ |
| 让路生效 | `ppe_yield` 单调增长 | ✅ 134819→288705 |
| 不抢流 | `flow_hit` 在让路期间冻结 | ✅ 全程 0 |
| 吞吐不因让路受损 | ≥ 6 Gbit/s | ✅ 7.0 |
| fallback 收回 | FAILED 流上 `flow_hit` 恢复增长 | ✅ 291918→314248 |
| grace 生效 | `ppe_grace` 增长、`flow_hit` 不增 | ✅ 38004→75696 |
| 两份枚举一致 | `verify-ppe-abi.sh` 通过 | ✅ CI |

### AC-4 PPE 硬件卸载（tc flower ACL）

| 判定项 | 阈值 | 状态 |
|---|---|---|
| filter 落进硬件 | `in_hw in_hw_count 1` + `used_hw_stats immediate` | ✅ |
| **包由硬件处理** | `Sent hardware > 0` 且 `Sent software == 0` | ✅ 612 bytes / 8 pkt，软件 0 |
| 驱动自己计数 | `acl` 表 hit 增长 | ✅ 3→10 |
| 增删正确 | 装 2 个 → 2 `in_hw`；删 1 个 → 1 | ✅ |
| 非 switch 端口被拒 | veth 返回 `Not supported` | ✅ |
| 硬件能做转发动作 | `mirred redirect` 也 `in_hw` | ✅ |

### AC-5 镜像交付

| 判定项 | 阈值 | 状态 |
|---|---|---|
| 包版本 | `dpd-fastpath r11` / `dpdfwd r10` | ✅ |
| 包内 ABI | `/usr/lib/dpd/abi == 22` | ✅ |
| 端到端修复在二进制里 | dpdfwd 含 `nf_conntrack` + `ppe_swept` | ✅ |
| ppe 配置随包 | `option ppe_mode` / `ppe_grace_ms` | ✅ |
| 两棵源码树一致 | 7 个文件 `cmp` 相同 | ✅ |

## 2. 明确不纳入验收的项

### AC-X 硬件 L3 转发卸载 —— 平台不支持

**不是未完成，是不可用。** 依据：

- `qca_ppe_setup_tc` 只分发 `mqprio/ets/prio/tbf`（QoS 整形），无
  `FLOW_BLOCK_BIND`，所以 `nft flowtable flags offload` 到不了 ASIC；
- `offloaded` / `live_entries` / `l3_interface` 恒为 0；
- 驱动拒绝计数全 0 —— 从未被请求过，不是拒绝；
- 无 `bind` 文件（MTK PPE 有 `/sys/kernel/debug/ppe0/bind`）。

要验证这一项，需要 MTK PPE 或支持 `FLOW_BLOCK_BIND` 的驱动。ABI 22 的
对应分支（`IPS_HW_OFFLOAD → DPD_PPE_OFFLOADED`）已实现且测过映射逻辑，
换硬件即可启用，无需改代码。

### AC-Y "同一条转发流上软件 + 硬件同时加速"

在本平台上**不可构造**，原因是三条实测约束叠加：

1. 硬件 ACL 只能挂真实 switch 端口（`br-lan`/veth 均 `Not supported`）；
2. `pref` 必须 < 512；
3. **桥内转发不经过 slave 的 tc ingress** —— 挂上去 `Sent 0 pkt`。

而 `lan1/lan2/lan3` 全在 `br-lan` 里，`wan` 无载波（`carrier=0`），
所以没有"两条真实端口之间的路由流量"可供硬件 ACL 匹配。

这条不在验收范围内，原因已记录，不是遗漏。

## 3. 回归方法

```sh
# AC-1 / AC-3：数据面与协调层
#   见 docs/ACCEPTANCE-PPE-DUAL-ABI22.md 第 7.5 节的完整脚本

# AC-2：软件 flowtable
nft list flowtable inet fw4 ft        # flags offload
grep -c OFFLOAD /proc/net/nf_conntrack

# AC-4：硬件 ACL（关键：pref < 512，真实 switch 端口）
tc qdisc add dev lan2 clsact
tc filter add dev lan2 ingress pref 100 protocol ip flower \
    src_ip 10.10.10.173 skip_sw action drop
tc -s filter show dev lan2 ingress | grep -E 'in_hw|Sent hardware|Sent software'
#   期望：in_hw in_hw_count 1，Sent hardware > 0，Sent software 0
tc qdisc del dev lan2 clsact

# AC-5：镜像
#   从 release 取 manifest 与 rootfs，见第 8 节
```

## 4. 后续若要扩展

按优先级：

1. **插 WAN 网线** —— 可把 AC-4 的证据从"真实包"提升到"真实路由流量"，
   仍不会让 `offloaded>0`；
2. **MTK PPE 设备** —— 唯一能让 AC-X 变成可验收的路；
3. **NSS/ECM 设备** —— 需要把 ABI 22 的硬件状态源从 conntrack 位改为
   ECM netlink，因为 NSS 不保证写 `IPS_HW_OFFLOAD`。