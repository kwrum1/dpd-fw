# 调研：DPD 作为高通 PPE/NSS 硬件加速的回退加速器

状态：调研（2026-11-09）。真机验证放在最后，本阶段只做可行性、耦合方式与实施计划。

## 1. 问题

高通 IPQ807x/IPQ60xx 的 NSS/ECM 把已建立流转发卸载到 NSS 固件，CPU 基本不参与。但硬件卸载不是万能的，**UDP 的失败率明显高于 TCP**：

- 长连接 UDP 可能在加速一段时间后停止转发（社区在 MTK PPE 上有大量同类报告，OpenWrt #17915 是同一类问题）；
- UDP 的 conntrack/flowtable 超时短（`nf_flowtable_udp_timeout` 默认 30s），空闲后要重新建流；
- 单向 UDP、分片、组播/广播、隧道/PPPoE 封装、IPv6 扩展头、校验和异常等都会让卸载失败；
- NSS ECM 还有自己的拒绝原因（`can_accel`、规则数据、驱动/加速引擎 NAK、连续无动作等）。

目标是：**PPE/NSS 卸载失败的流，回退到 DPD 的 TC eBPF 软件快路径**，而不是掉回 Linux 慢路径；已卸载的流继续由硬件处理，二者不能抢同一条流。

## 2. 三条加速路径的边界

| 路径 | 数据面 | 卸载后包是否还进 Linux/TC | 状态可观测性 |
|---|---|---|---|
| Qualcomm NSS/ECM | NSS 固件（SoC 内） | 否（只有异常/未卸载包回到 host） | ECM 加速模式（netlink/debugfs） |
| 软件 flowtable | 内核 `nf_flow_table` | 否（首包/建立后绕过） | conntrack `IPS_OFFLOAD` / `[OFFLOAD]` |
| MTK PPE/HNAT | PPE + flowtable 硬件 offload | 否 | conntrack `IPS_HW_OFFLOAD` + `/sys/kernel/debug/ppe0/bind` |
| DPD（本方案） | TC ingress eBPF | 是（每包都经过 TC） | `dpdctl stats` / UFS |

关键事实：

- NSS 官方（qosmio/openwrt-ipq）明确要求 **关闭软件/硬件 flow offloading**：NSS 绕开内核栈，和 OpenWrt 自带卸载“处理包的方式冲突”，同时开启会重复/冲突加速。
- 因此 DPD 不能做成“第二个 flowtable”，只能做成 **NSS 异常路径上的补充**：NSS 卸载成功的流 DPD 根本看不到；DPD 只处理回到 Linux 的那部分包。
- MTK PPE 与 NSS 不同：首包走 host，flowtable 命中后由 PPE 接管。DPD 的 TC 钩子能看到首包，因此必须依赖“卸载状态”或 grace 窗口，避免在 PPE 决策前把流抢走。

## 3. “PPE 失败”的判定方式

### 3.1 内核标准状态（软件 flowtable / MTK PPE）

`include/linux/netfilter/nf_conntrack_common.h`：

```
IPS_OFFLOAD_BIT    = 14   /* 软件 flowtable 卸载 */
IPS_HW_OFFLOAD_BIT = 15   /* 硬件卸载（kernel >= 5.7） */
```

ctnetlink 的 `CTA_STATUS` 带上这两个 bit；`/proc/net/nf_conntrack`/`conntrack -L` 显示 `[OFFLOAD]` 或 `[HW_OFFLOAD]`。`dpdfwd` 可以订阅 ctnetlink 的 NEW/UPDATE/DESTROY，按 5-tuple 维护“已卸载/未卸载”状态。

注意：NSS 是 out-of-tree 前端，**不保证**把 NSS 卸载写进 `IPS_HW_OFFLOAD`；IPQ 上不能只依赖这个 bit。

### 3.2 Qualcomm ECM 加速模式（IPQ）

ECM 的 `ecm_front_end_acceleration_modes`（qca-nss-ecm 源码）：

```
FAIL_DEFUNCT      = -7   连接已失效
FAIL_DECEL        = -6   去加速失败
FAIL_NO_ACTION    = -5   连续多次卸载请求没有任何包被卸载
FAIL_ACCEL_ENGINE = -4   加速引擎连续 NAK
FAIL_DRIVER       = -3   驱动交互连续失败
FAIL_RULE         = -2   规则数据错误
FAIL_DENIED       = -1   can_accel 拒绝
DECEL             = 0    未加速
ACCEL_PENDING / ACCEL / DECEL_PENDING
```

`ECM_FRONT_END_ACCELERATION_FAILED(mode) = (mode < 0)`。这是最权威的“NSS 卸载失败/被拒绝”信号。读取方式有两条：

1. ECM 的 netlink 事件 / `ecm_db` debugfs（版本相关，需要按固件的 ECM 版本适配）；
2. 在 NSS 异常路径上**推断**：NSS 卸载后包不再进 Linux，所以“grace 窗口后同一流仍有包到达 TC”就等价于“没被 NSS 卸载”。这条不依赖 ECM API，可移植性最好。

### 3.3 建议：状态机 + 推断兜底

`dpd_ppe` map（BPF hash）：

```
key   = 5-tuple + direction
value = { state, accel_mode, first_seen_ms, last_seen_ms, reason }
state = UNKNOWN | OFFLOADED | FAILED | DENIED
```

- 由 `dpdfwd` 从 ctnetlink/ECM 事件维护；命中路径只读一个 byte。
- 推断规则：`UNKNOWN` 且 `now - first_seen > ppe_grace_ms` 且该流仍有包到达 TC → 置 `FAILED`（reason=no-offload）。
- `OFFLOADED` 的流若因超时重新回到 TC，状态改回 `UNKNOWN`，重新走 grace。

## 4. 耦合架构

```
                 ┌──────────────────────────────┐
   NIC ─────────▶│ NSS 固件（快路径）            │──▶ 出端口
                 └──────────────┬───────────────┘
                                │ 未卸载/异常
                                ▼
                 ┌──────────────────────────────┐
                 │ Linux 栈 + TC ingress（DPD）  │
                 │  dpd_ppe gate → UFS → redirect│
                 └──────────────────────────────┘
```

- **顺序**：NSS 决策在前，DPD 在后。DPD 只在 NSS 异常路径上工作，天然不会和 NSS 抢已经卸载的流。
- **grace**：`ppe_grace_ms`（默认 1500ms）或 `accel_after_pkts`（建议 IPQ 上 64）之前不接管；给 ECM/flowtable 足够的决策时间。
- **协议策略**：`ppe_fallback=udp|all|off`，默认 `udp`（UDP 是硬件失败率最高的部分，TCP 留给 NSS）。
- **状态门禁**：`state=OFFLOADED` → 返回 `TC_ACT_UNSPEC`，永不接管；`FAILED/DENIED` → 允许 UFS 学习/命中；`UNKNOWN` → 等到 grace 超时。
- **NAT 约束（重要）**：
  - IPQ 上 NAT 归 NSS/conntrack，不是 einat。DPD 必须 `nat_offload=0`，**不接管 WAN 上行**，否则 redirect 会绕过 NSS NAT。
  - 默认只加速 **WAN→LAN 回程**（NSS 已完成反 NAT），这是安全的。
  - 上行要加速属于 P2.2：需要从 conntrack/NSS 同步 NAT 映射，或让 DPD 自己 SNAT 并与 NSS 协调；短期不做。
- **与 einat/full-cone 的关系**：einat 不走 conntrack，NSS 无法卸载它；IPQ 上二者不共存（二选一）。本调研面向 NSS/conntrack 场景；x86/RK 继续用 einat 方案。

## 5. 与现有 DPD 代码的衔接

已有能力可以直接复用：

- `accel_after_pkts`（ABI 17，默认 32）：天然提供“先观察再接管”的窗口；
- `dpd_nat` 闸门 + `nat_offload`：IPQ 上置 0，禁止上行接管；
- `dpdfwd`：已经在订阅 ctnetlink 并输出 `flowd.json`，只需增加 `CTA_STATUS` 的 offload bit 解析和 `dpd_ppe` 写入；
- UFS/epoch：NSS 重启、链路变化、ECM 去加速都通过 epoch/状态失效；
- `dpdctl stats`：新增 `ppe_offload/ppe_fail/ppe_grace` 计数，便于门禁。

新增配置（建议）：

```
option ppe_fallback 'udp'        # off | udp | all
option ppe_grace_ms '1500'
option ppe_accel_after '64'      # 覆盖 accel_after_pkts（IPQ profile）
```

## 6. 实施阶段

| 阶段 | 内容 | 验证 |
|---|---|---|
| P7.0 | `dpdfwd` 解析 `CTA_STATUS` 的 OFFLOAD/HW_OFFLOAD；`dpd_ppe` map；DPD 命中门禁；`ppe_fallback` UCI | x86 实验室用 nft flowtable 模拟：TCP 卸载、UDP 不卸载，确认 UDP 回退、TCP 不被抢 |
| P7.1 | IPQ 上读取 ECM 加速模式（netlink/debugfs）或异常路径推断；`ppe_grace_ms` 调参 | IPQ807x/60xx 真机：长连接 UDP 断流时 DPD 接管；TCP 仍由 NSS |
| P7.2 | 内核小模块/`flow_block` 回调把 offload 结果写入 BPF map；与 MTK `ppe0/bind` 对账 | 精确、无轮询；MTK PPE 与 NSS 双平台 |
| P7.3 | 上行 NAT 交给 DPD（`bpf_ct_lookup` 或 NSS 映射同步） | 上传也回退；与 NSS NAT 一致性 |

## 7. 风险与门禁

- **双加速**：同一流不能同时被 NSS 和 DPD 接管。三道保护：NSS 卸载的包不进 TC、`dpd_ppe=OFFLOADED` 门禁、grace 窗口。
- **抢流**：grace 太短会把本可被 NSS 加速的流抢走（尤其 TCP）。默认只回退 UDP，grace 1.5s，TCP 不动。
- **NAT 破坏**：IPQ 上绝不接管上行；`nat_offload=0`；只做回程。
- **NSS 崩溃/重启**：epoch 失效 + `dpd_ppe` 状态清理；流回退到栈。
- **性能**：DPD 在 ARM 上的成本要实测；只承诺“失败流从慢路径提升到软件快路径”，不承诺超过 NSS。
- **可观测**：`ppe_fallback.json` + `dpdctl stats`；每条流记录 state/reason，便于判断是“没卸载”还是“被拒绝”。

## 8. 结论

- **可行**，但定位必须是“NSS 异常路径的补充”，不是第二个 flowtable，也不能与软件/硬件 flow offloading 同时开。
- 最稳妥的落地顺序：**x86 用软件 flowtable 验证检测逻辑 → IPQ 用 ECM/异常路径推断做实机 → 内核回调做精确化**。
- 短期收益最大的是 **UDP 回退**：NSS/PPE 对 UDP 的卸载失败率最高，而 DPD 的 TC 软件路径正好能接住这些流；TCP 继续交给 NSS。
- 上行加速依赖 NAT 映射同步，属于后续阶段，不影响“回程回退”这一第一阶段目标。

## 9. 参考

- qosmio/openwrt-ipq README：NSS 与 OpenWrt 软件/硬件 flow offloading 的冲突说明。
- Linux `include/linux/netfilter/nf_conntrack_common.h`：`IPS_OFFLOAD_BIT=14`、`IPS_HW_OFFLOAD_BIT=15`。
- nftables wiki Flowtables：卸载在 conntrack 状态建立后发生；`nf_flowtable_udp_timeout` 默认 30s。
- qca-nss-ecm `ecm_front_end_types.h`：`ecm_front_end_acceleration_modes` 及 FAIL 原因。
- OpenWrt #17915 / Keenetic MT7981 案例：长连接 UDP 硬件卸载断流。
- OpenWrt WED 文档：`/sys/kernel/debug/ppe0/bind` 可观测 PPE 绑定流。
