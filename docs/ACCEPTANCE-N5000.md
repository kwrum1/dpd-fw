# DPD-FW v1 功能闭环验收（真机 N5000）

状态：**进行中**（2026-11-09 确定范围）
决策：性能门禁（64B PPS / 1G/2.5G/10G 线速 / IMIX）**不再作为 v1 验收条件**；
v1 以**真机 N5000 上的功能闭环**为准，之后进入交付运维阶段。

本文是 v1 的验收基线：每一项都有可复现命令和明确判据。没有跑到的项目写
“未测”，不当作已验证。

## 1. 范围

### 1.1 v1 必须通过

- 内核 6.18.x + 完整镜像启动、持久化、升级/回退；
- TC eBPF 快路径（UFS v2 + Flow Manager）在真机网卡上的挂载与转发；
- NAT 两种模式：
  - `nat_forward=einat` / `nat_ingress=einat`（默认，einat 拥有 NAT）；
  - `nat_forward=dpd` / `nat_ingress=dpd`（DPD 自有 SNAT/DNAT + 端口分配）；
- TCP / UDP / ICMP echo 的加速与 NAT；
- MSS clamp（PPPoE 场景必须有）；
- `dpd_class` 策略（block/proxy/forward/local + 优先级）；
- conntrack destroy → UFS + NAT binding 定向回收；
- 多 WAN（双上行时）、VLAN、IPv6（加速出站 + 入站走栈）；
- QoS/SQM、ACL、honk（可选）不回归；
- dpdfwd / dpd-observe / LuCI 页面可用；
- 重启、服务重启、kill 守护进程、模式切换不丢转发。

### 1.2 v1 明确不做

- 64B PPS、10G 线速、IMIX 等性能门禁（按决策取消）；
- NAT66（IPv6 只做转发/加速，不做地址转换）；
- `bpf_ct_*` 内核 conntrack 助手路径（NAT 由 dpd_nat/dpd_nat_rev 承担）；
- 高通 PPE/NSS 回退实现（调研文档保留，实现挂起）；
- GPU/NPU（P6）。

### 1.3 已知限制（验收时记录，不阻塞）

- ICMP 错误报文（type 3/11）暂不做 inner-packet 改写：ICMP/UDP traceroute
  在 DPD NAT 模式下可能不完整；普通 ping、TCP/UDP 不受影响。
- `dpd_nat` / `dpd_flows` 是 LRU：极端并发下活跃条目可能被挤出；端口按
  TCP TTL 回收，CT destroy 会主动释放（ABI 20）。
- 加速流跳过 netfilter：QoS/ACL 的 per-packet 计数只看到 prime 窗口内的包。

## 2. 环境

| 项 | 值 |
|---|---|
| 设备 | N5000（Intel Pentium Silver N5000，x86_64） |
| 内存/磁盘 | 待填 |
| 网卡 | 待填（`lspci -nn \| grep -i ether`；确认 r8169/igb/igc/e1000e 驱动） |
| 控制台 | 待填（HDMI/串口/SSH） |
| 镜像 | `immortalwrt-x86-64-generic-squashfs-combined.img.gz`，sha256 见 `docs/LOCAL-BUILD.md` |
| 内核 | 6.18.x（`uname -r`） |
| 上游 | 至少一个可 NAT 的 WAN；双 WAN 时两个独立网口/上游 |

刷机前记录：`sha256sum`、`lspci`、`ip -br link`、`ethtool -i <wan>`。

## 3. 验收矩阵

每条命令在路由器上执行；`lc` 表示 LAN 侧测试客户端（netns 或独立主机）。

### N1 启动与包

| ID | 检查 | 判据 |
|---|---|---|
| N1.1 | `uname -r` | 6.18.x |
| N1.2 | `opkg list-installed \| grep dpd`（或 apk） | dpd-fastpath、dpdfwd、dpd-einat-sync、dpd-napi、dpd-honk、dpd-observe、luci-app-dpd 全在 |
| N1.3 | `dpdctl version` / `dpdctl abi` | abi 20 / loaded 20 |
| N1.4 | `cat /usr/lib/dpd/abi` | 20 |
| N1.5 | `cat /var/run/ebpf/gate` | 第 1 行 `ok`，effective 为 `stateful` |

### N2 挂载

| ID | 检查 | 判据 |
|---|---|---|
| N2.1 | `tc filter show dev <lan> ingress \| grep pref 100` | `classifier/l2` 或 `l3` |
| N2.2 | 网桥端口 | `br-lan` 的每个 brif 都有 pref 100 |
| N2.3 | `bpftool net show` | 无 einat TCX 时，经典链上有 dpd |
| N2.4 | `dpdctl status` | attached yes，gate ok |

### N3 基础转发

| ID | 检查 | 判据 |
|---|---|---|
| N3.1 | `ip netns exec lc ping -c 3 <peer>` | 3/3 |
| N3.2 | TCP 下载 1MB / 32MB | 完整字节数 |
| N3.3 | UDP echo（若测试端支持） | 双向通 |
| N3.4 | `dpdctl stats` | `pkt_total`、`flow_hit/miss` 增长；`fib_ok > 0` |

### N4 einat 模式（默认）

| ID | 检查 | 判据 |
|---|---|---|
| N4.1 | `dpdctl show \| grep nat_` | `nat_forward 0`、`nat_ingress 0` |
| N4.2 | `bpftool net show \| grep tcx` | einat ingress+egress 在 WAN |
| N4.3 | 32MB 下载/上传 | 字节精确；`flow_hit` 增长 |
| N4.4 | `tc filter show dev <wan> egress` | 无 dpd `classifier/egress` |
| N4.5 | `dpdctl stats \| grep nat_` | `nat_snat/nat_dnat/nat_alloc` 不增长 |

### N5 DPD 自有 NAT（`nat_forward=dpd`）

准备：`/etc/init.d/einat stop`（或 detach TCX），`uci set dpd_fastpath.global.nat_forward=dpd`、
`nat_ingress=dpd`、`uci commit`，重启 dpd-fastpath。

| ID | 检查 | 判据 |
|---|---|---|
| N5.1 | `dpdctl show \| grep nat_` | forward 1 / ingress 1 |
| N5.2 | `tc filter show dev <wan> ingress \| grep pref 50` | `classifier/nat` |
| N5.3 | `tc filter show dev <wan> egress` | `classifier/egress` |
| N5.4 | `ping -c 3 <peer>` | 3/3；`nat_snat=3`、`nat_dnat=3` |
| N5.5 | `dpdctl nat` | 绑定 `内网:port -> 外部IP:20000-29999` |
| N5.6 | 1MB / 32MB 下载 | 完整；`nat_snat/nat_dnat` 随包数增长 |
| N5.7 | `dpdctl delete -f`（用绑定内网 tuple） | 打印 `released 1 nat binding(s)`，`dpdctl nat` 不再显示 |
| N5.8 | 恢复 `nat_forward=einat` + einat start | ping/下载正常，pref 50 与 egress 钩子消失，三个 NAT 计数不再增长 |

### N6 MSS / PPPoE（如有 PPPoE 上行）

| ID | 检查 | 判据 |
|---|---|---|
| N6.1 | 在 WAN 抓 SYN/SYN-ACK | MSS = min(MTU)-40（v4）/ -60（v6） |
| N6.2 | clamp=0 对照 | MSS 保持原值，下载仍正常 |
| N6.3 | `mss_clamp` / `mss_skip` | 只在实际改写/拒绝时增长 |

### N7 策略与失效

| ID | 检查 | 判据 |
|---|---|---|
| N7.1 | `/etc/dpd/class.conf` 写 block 规则 | `flow_block` 增长，目标流被拒 |
| N7.2 | 清空 class.conf | 5s 内 flush，流量恢复 |
| N7.3 | TCP 流建立后 `conntrack -D`（或等 CT 超时） | `dpdctl flows` 对应条目被删；NAT 绑定被释放 |
| N7.4 | `dpdfwd` kill | 转发不受影响；重启后恢复 |

### N8 多 WAN（双网上行时）

| ID | 检查 | 判据 |
|---|---|---|
| N8.1 | 两条默认路由/权重 | `dpdctl wans`（或 show）两条 UP |
| N8.2 | 拔掉主上行 | 流量切到备上行，会话重建后正常 |
| N8.3 | DPD NAT 模式 | 每条 WAN 的绑定使用该 WAN 自己的外部地址 |

### N9 IPv6 / VLAN

| ID | 检查 | 判据 |
|---|---|---|
| N9.1 | 客户端获得 v6 地址 | RA/DHCPv6 正常 |
| N9.2 | 出站 v6 ping/TCP | 通；`v6_ok` 增长；`dpdctl flows` 有 fam=10 |
| N9.3 | 入站 v6（外部发起） | 由栈转发（不要求加速） |
| N9.4 | VLAN 客户端 | tagged 流可加速；`tag_pop/skip` 合理 |

### N10 运维与稳定性

| ID | 检查 | 判据 |
|---|---|---|
| N10.1 | 重启路由器 | 配置/包/挂载/流量自动恢复 |
| N10.2 | `sysupgrade` 保留配置 | 升级后 abi 20、gate ok、流量正常 |
| N10.3 | 模式切换 observe/stateful/off 反复 10 次 | 每次切换后 ping 正常 |
| N10.4 | 1h soak（持续下载/上传） | 无 oops、无计数器异常、内存稳定 |
| N10.5 | 24h soak（可选） | 同上 |
| N10.6 | `logread \| grep -i dpd` | 无反复报错/重连 |

### N11 EIF / full-cone（有双 peer 时）

| ID | 检查 | 判据 |
|---|---|---|
| N11.1 | `tests/netns/full-cone.sh --mapped-port ...` | PASS（peer B 的打点到达 client） |
| N11.2 | 无 python3 时 | 脚本按设计 skip（exit 3），不伪造 PASS |

## 4. 证据与报告

每个 ID 记录：命令、原始输出（关键行）、日期、镜像 sha256。最终报告建议放在
`docs/acceptance-N5000-<date>.md`，并附：

- `dpdctl status -j`；
- `cat /var/run/ebpf/gate.json`；
- `dpdctl stats`；
- `dpdctl nat -a`（DPD NAT 模式）；
- `bpftool net show` / `tc filter show` 关键行；
- `dmesg | tail`（无 oops）。

## 5. 通过标准

- N1–N10 的**必须项**全部 PASS；N11 在没有双 peer 时记为“环境不具备”，不算失败；
- 任一 P0/P1 功能（转发、NAT 两种模式、MSS、策略、重启恢复）失败即 v1 不闭环；
- 性能只做合理性记录（链路能跑满则记录，不作判据）。

## 6. 后续（v1 之后）

- 交付运维阶段：`docs/OPERATIONS.md`；
- ICMP 错误报文改写（traceroute）作为 v1.1；
- NAT66 / bpf_ct_* 作为 v2 评估项。
