# 调研：DPD 与高通 PPE/NSS 的软硬双加速

状态：调研（2026-11-09）。本文只做可行性、边界与实施计划；真机验证需要一台
Qualcomm 参考设备。

## 1. 先把“高通 PPE”拆成两件事

社区和文档里的 “PPE” 实际指两套不同的东西，混在一起会得出错误结论：

| | 上游 `qcom-ppe`（6.18 主线） | NSS / ECM（IPQ807x、IPQ60xx） |
|---|---|---|
| 代码位置 | `drivers/net/ethernet/qualcomm/ppe/`（`qcom-ppe.ko`） | out-of-tree `qca-nss-drv`、`qca-nss-ecm`、`nss-clients` + 固件 |
| 支持的 SoC | IPQ9574、IPQ5424 | IPQ807x、IPQ60xx |
| 硬件能力 | 6 个 MAC、switch core（BM/QM/SCH/L2 FDB）、EDMA | NSS 核 + 固件，做 L3 转发/NAT/PPPoE/VLAN/qdisc/IGS |
| 当前软件能力 | **只做以太网 + L2 桥/队列**；L3/NAT 卸载“后续可扩展” | 完整 L3/NAT 卸载 |
| 包是否还进 Linux | 是（没有 L3 卸载） | 卸载后**不进** Linux/TC，主机只看异常包 |
| 观测 | `/sys/kernel/debug/ppe/`（端口/CPU/队列计数） | `/sys/kernel/debug/ecm/`、`nssinfo`、ECM 加速模式 |
| 内核版本 | 主线 6.18 起 | 社区 feed 支持 6.18/7.3，但已归档、不再进镜像 |

两个直接结论：

1. **IPQ9574 + 主线 6.18**：PPE 只做 L2/队列，L3 仍走 Linux。DPD 和它天然是
   分层关系（PPE 二层、DPD 三层），不存在抢流；但这也**不是**“硬件 NAT 加速”。
2. **IPQ807x/IPQ60xx + NSS**：NSS 固件起来后**所有有线口都挂到 NSS 数据面**，
   主机只收到异常/未卸载包。DPD 的 TC 钩子只能看到 NSS 没接住的流量。

所以“软硬双加速”在两种平台上含义不同，必须分开设计。

## 2. 双加速的核心约束：同一流不能被两边同时接管

NSS 卸载后的包根本不进 Linux，DPD 看不到，这一半是安全的。真正危险的是
**卸载发生之前**：

- NSS/ECM 的卸载决策依赖 conntrack 和它自己的包计数；
- DPD 在 TC ingress（netfilter 之前）redirect，被它接管的包不会进 conntrack；
- 如果 DPD 太早接管，ECM 的计数不增长，卸载永远不会发生 —— 这不是“双加速”，
  而是“软件加速把硬件加速饿死”。

因此双加速只能是**流级分区**，而且分区必须在 DPD 接管之前决定。可选的三条路：

### A. 分层双加速（IPQ9574 主线 PPE）

PPE 做 L2 桥/队列，DPD 做 L3 转发/策略。二者在不同层，互不抢流。当前 6.18
的 `qcom-ppe` 没有 L3 卸载，所以这是**现在就能落地**的形态；等上游把 L3/NAT
卸载做进来，再切到 B/C。

### B. 分区双加速（NSS）

按“这条流 NSS 能不能/该不该接”分区：

- **NSS 负责**：长命、可卸载的 TCP 大流，PPPoE/VLAN 已支持的封装；
- **DPD 负责**：NSS 明确拒绝/失败的流（UDP 失败率最高）、proxy/ACL/QoS 等
  NSS 无法表达的流、短流；
- **判定**：`ppe_grace_ms` 内先让 ECM 决策；grace 之后仍在主机上出现的流，
  视为 NSS 没有接住，DPD 才接管；已卸载的流不会出现在 TC，天然不冲突。

这是 `docs/RESEARCH-PPE-FALLBACK.md` 的方案，定位是“NSS 异常路径的补充”。
它不是对称的双加速，但在 NSS 平台上这是唯一不会互相破坏的形态。

### C. 窗口双加速（实验）

想让短流也吃到软件加速，又不饿死 NSS，可以让 DPD **只接管一个窗口**：

```
0 ................ accel_after .... handoff_ms .......... grace_ms
栈（conntrack/ECM 决策）  DPD 软件加速       交还 ECM/NSS      仍未卸载→DPD 回退
```

- 窗口内 DPD 接管，短流直接受益；
- 到 `handoff_ms` 强制让流回到栈，让 ECM 看到后续包并完成卸载；
- 代价：ECM 的包计数少了窗口内的包，卸载会被推迟 `window_pkts` 个包；
- 收益/代价比取决于 ECM 的卸载触发是“包数”还是“时间”，必须真机测量。

窗口模式作为 P8.3 的实验项，不作为默认。

## 3. 状态机与门禁

`dpd_ppe` map（BPF hash，key = 5-tuple + direction）：

```
UNKNOWN    -> 还没等到 grace，不接管
SW_ACTIVE  -> DPD 正在加速
YIELDED    -> 窗口到期，主动交还 ECM，不接管
OFFLOADED  -> 确认/推断已被 NSS/PPE 接管，永不接管
FAILED     -> ECM 明确失败，或 grace 后仍有包到达 TC
DENIED     -> ECM can_accel 拒绝（proxy/ACL/规则）
```

- 命中路径：`OFFLOADED/YIELDED` → `TC_ACT_UNSPEC`；`SW_ACTIVE/FAILED/DENIED`
  → 正常 UFS 命中；`UNKNOWN` → 等到 grace。
- 学习路径：同上，外加 `ppe_fallback=udp|all|off` 的协议过滤。
- 状态来源优先级：
  1. conntrack `CTA_STATUS` 的 `IPS_OFFLOAD`(bit14) / `IPS_HW_OFFLOAD`(bit15)
     —— 适用软件 flowtable 和 MTK PPE，NSS 不保证写；
  2. ECM `ecm_front_end_acceleration_modes`（`<0` 即失败/拒绝），通过
     `/sys/kernel/debug/ecm/` 或 ECM netlink 读取；
  3. 兜底推断：grace 后同一条流仍有包到 TC ⇒ `FAILED`（可移植性最好）。

## 4. NAT 与 einat 的关系

- **NSS 平台**：NAT 由 NSS/ECM 做，DPD 必须 `nat_offload=0`，且**不接管上行**，
  只加速 WAN→LAN 回程（NSS 已完成反 NAT）。einat 与 NSS 不能共存（einat 不走
  conntrack，NSS 无法卸载它）。
- **IPQ9574 主线 PPE**：目前 PPE 不做 NAT，NAT 仍是 fw4/einat，和 x86 一样；
  DPD 可以按现有 einat 模式工作。
- 上行回退（NSS 失败的流还要 DPD 做 SNAT）需要 NAT 映射同步，属于 P8.4，
  短期不做。

## 5. 与现有代码的衔接

已有能力可直接复用：

| 现有 | 用途 |
|---|---|
| `dpdfwd` ctnetlink 订阅 | 增加 `CTA_STATUS` 的 offload bit 解析，写 `dpd_ppe` |
| `accel_after_pkts` | 天然提供“先观察再接管”的窗口 |
| `dpd_nat` 闸门 / `nat_offload` | NSS 平台置 0，禁止上行接管 |
| UFS epoch | NSS 重启/ECM decel/链路变化时统一失效 |
| `dpdctl status -j` / `flowd.json` | 增加 `ppe_backend/offload/fail/yield/grace` 计数 |
| `dpd-fastpath.sh` gate | 增加 PPE/NSS 探测，决定 `ppe_mode` 是否允许 |

新增 UCI（草案）：

```
option ppe_mode 'auto'        # off | auto | fallback | dual | window
option ppe_grace_ms '1500'    # ECM 决策窗口
option ppe_handoff_ms '0'     # window 模式：DPD 接管多久后交还（0=不交还）
option ppe_fallback 'udp'     # off | udp | all
option ppe_accel_after '64'   # IPQ profile 覆盖 accel_after_pkts
```

`auto` 的语义：

- `qcom-ppe`（无 L3 卸载）→ `dual`（分层，DPD 正常加速）；
- NSS/ECM → `fallback`（默认只回退 UDP/TCP 失败流）；
- 都没有 → `off`（当前 x86/RK 行为不变）。

## 6. 探测与遥测

`scripts/ppe-probe.sh` 做只读探测，输出：

- `backend=none|qcom-ppe|nss-ecm`
- `ppe_debugfs=yes/no`、`ecm_debugfs=yes/no`
- netdev 驱动（`qca-ppe`/`nss-dp`/`qca-nss`）
- conntrack 里 `[OFFLOAD]`/`[HW_OFFLOAD]` 的条数
- `nssinfo` 是否存在
- DPD 当前 `mode/nat_offload`

遥测统一进 `flowd.json` 和 `dpdctl status -j`，便于 LuCI 显示
“硬件加速 / 软件回退 / 未加速”三类流的占比。

## 7. 实施阶段

| 阶段 | 内容 | 验证 |
|---|---|---|
| P8.0 | `ppe-probe.sh`、`ppe_backend` 探测、gate 放行逻辑、遥测字段；**不改数据面行为** | x86/RK：backend=none，行为与现在完全一致 |
| P8.1 | fallback：`dpd_ppe` map、ctnetlink offload bit、grace、UDP 策略 | x86 用 nft flowtable 模拟：TCP 卸载不进 DPD、UDP 不卸载进 DPD |
| P8.2 | NSS 分区：IPQ807x/60xx 上开 NSS + DPD，验证卸载流不进 TC、失败流被接管、无双 NAT | 真机：NSS 统计 + DPD 计数 + 吞吐/CPU |
| P8.3 | window 双加速实验：`ppe_handoff_ms`，测 ECM 卸载延迟与短流收益 | 真机 A/B：window=0 vs 200/500ms |
| P8.4 | 精确 ECM 状态：debugfs/netlink 解析，或 BPF kprobe 读 ECM 决策 | 与推断状态对账，去掉 grace 猜测 |
| P8.5 | IPQ9574 主线 PPE：L2 共存验证，跟踪上游 L3 卸载 | debugfs 计数、无丢包、DPD 计数正常 |

## 8. 测试矩阵

1. **x86 + nft flowtable（模拟硬件卸载语义）**：TCP 长流进 flowtable 后不进
   DPD；UDP 短流不进 flowtable 时 DPD 接管；两者不互相影响。
2. **IPQ807x/IPQ60xx + NSS**：NSS 开、DPD 开；确认已卸载流不出现在 `dpdctl flows`；
   长 UDP 断流后 DPD 接管；上行不被 DPD 接管；NAT 只由 NSS 做。
3. **IPQ9574 + 主线 `qcom-ppe`**：PPE L2 + DPD L3；确认 `/sys/kernel/debug/ppe/`
   计数正常、无丢包、DPD 加速比例与 x86 同量级。
4. **无 PPE 回归**：x86/RK 上 `ppe_backend=none`，所有现有验收项不变。

## 9. 风险

- **NSS 抢走全部有线流量**：IPQ807x 上 DPD 可能几乎看不到包，“双加速”的收益
  主要在异常流和短流，不要承诺“超过 NSS”。
- **上游 PPE 还没有 L3 卸载**：IPQ9574 现在只能做分层双加速，硬件 NAT 要等
  上游；不要把“PPE 驱动存在”当成“硬件 NAT 可用”。
- **NSS 状态不可观测**：`IPS_HW_OFFLOAD` 不保证写，grace 推断是保底方案；
  精确化需要 ECM 版本适配或内核探针。
- **内核/out-of-tree**：NSS feed 对 6.18/7.3 有支持但已归档；主线 PPE 与
  QSDK 内核的时钟/驱动依赖（CMN PLL、NSSCC）要一起验证。
- **同流双加速**：必须由“NSS 卸载后不进 TC + 状态门禁 + grace”三重保证。

## 10. 待确认

- 目标硬件是哪一类：IPQ807x（NSS）、IPQ60xx（NSS）、还是 IPQ9574（主线 PPE）？
  这决定先做 P8.2 还是 P8.5。
- 是否接受“NSS 平台默认 fallback，不做窗口双加速”的保守默认？
- NAT 归属：NSS 平台确认 `nat_offload=0`、einat 停用；x86/RK 保持 einat。

## 11. 参考

- 内核 `qcom-ppe` 文档：<https://docs.kernel.org/networking/device_drivers/ethernet/qualcomm/ppe/ppe.html>
- LWN：Add PPE driver for Qualcomm IPQ9574（L2/L3 卸载后续扩展）：
  <https://lwn.net/Articles/1034225/>
- Phoronix：Qualcomm PPE driver in Linux 6.18：
  <https://www.phoronix.com/news/Qualcomm-PPE-Driver-Linux-6.18>
- NSS feed（qca-nss-drv/ecm/clients，6.18/7.3）：
  <https://github.com/JuliusBairaktaris/nss-packages>
- qosmio NSS packages（ECM/前端）：<https://github.com/qosmio/nss-packages>
- 现有回退调研：`docs/RESEARCH-PPE-FALLBACK.md`
- conntrack 状态位：`include/linux/netfilter/nf_conntrack_common.h`
  （`IPS_OFFLOAD_BIT=14`、`IPS_HW_OFFLOAD_BIT=15`）
