# 软硬双加速：ABI 22 协调层验收（2026-11-11）

设备：太乙 `10.10.10.100`，ImmortalWRT SNAPSHOT `r0-5cd11f1`，
`qualcommax/ipq60xx`，kernel 6.18.55，aarch64，2 GB RAM。
经跳板机 `nas.tokisaki-kurumi.cc` 接入。

本文只记录**本轮新增**的协调层（ABI 22）与其实测结果。DPD 数据面本身的
首次上机验收见 `LAB-IPQ60XX-2026-11-11.md`。

## 1. 这一轮补的是"缺失的那一层"

上一轮修的是 `ppe-probe.sh` 的**识别** bug（它把 `qca-ppe` 误判成 NSS）。
但 `RESEARCH-PPE-DUAL.md` 里描述的协调机制从来不存在：

```
dpd_ppe map           -> 不存在
ppe_fallback          -> 不存在
ppe_grace_ms          -> 不存在
```

`dpdfwd` 虽然早就在解析 conntrack 的 `IPS_OFFLOAD`/`IPS_HW_OFFLOAD`，
但只用来**计数**，没有任何数据面影响。所以"双加速"当时只是一份设计文档。

现在补上了。

## 2. 设计：状态放在哪里，为什么不加成本

协调必须**按流**做，而且不能给热路径加 lookup。做法是把状态塞进
`dpd_flow_val.ct_cookie`——这个字段从 ABI 18 起就写着"留给可选的 bpf_ct
路径"，但代码从未使用它。

```c
__u32 ct_cookie;   /* ABI 22: enum dpd_ppe_state */
```

结果：**`sizeof(struct dpd_flow_val)` 仍是 72 字节**，命中路径仍然只有
一次 `dpd_flows` 查找。

| 状态 | 含义 | 谁写 |
|---|---|---|
| `UNKNOWN` | 刚学到，还没人认领 | 数据面学习时 |
| `SW_ACTIVE` | conntrack 说没人卸载 | dpdfwd |
| `YIELDED` | 软件 flowtable 接管 | dpdfwd |
| `OFFLOADED` | 硬件接管 | dpdfwd |
| `FAILED` | 硬件试过但失败 | 运维/插件 |
| `DENIED` | 硬件拒绝 | 运维/插件 |

`FAILED`/`DENIED` 刻意**不由 dpdfwd 自动写**：conntrack 只能证明"有人接管了"，
证明不了"硬件尝试失败"。把猜测写成证据会制造假状态，所以这两种由
`dpdctl flows ppe failed|denied` 显式设置。

## 3. 三种行为

```
ppe_mode=off     从不 yield（x86/RK 默认，那里没有这种硬件）
ppe_mode=yield   OFFLOADED/YIELDED 时让路
ppe_mode=dual    硬件优先；硬件 FAILED/DENIED 的流 DPD 收回
```

命中路径：

```c
static int dpd_ppe_yield(cfg, fval, age, st)
{
    if (cfg->ppe_mode == DPD_PPE_OFF) return 0;
    switch (fval->ct_cookie) {
    case OFFLOADED: case YIELDED:  -> ST_PPE_YIELD; return 1;   /* 让路 */
    case FAILED:   case DENIED:    -> return cfg->ppe_mode == FALLBACK ? 0 : 1;
    default: break;
    }
    if (cfg->ppe_grace_ms && age < cfg->ppe_grace_ms) {
        ST_PPE_GRACE; return 1;                                 /* 等内核 */
    }
    return 0;
}
```

## 4. 实测（真实 IPQ60xx）

拓扑：两个独立的 veth 对，`dpdc ns --> dpdtest0 [DPD] dpdtest1 --> dpds ns`，
iperf3 打流。

### 4.1 yield：硬件拥有的流，数据面完全停止干预

连接**在飞行中**被标记（iperf3 每次新建 5-tuple，必须在连接活着时标记，
否则标的是旧流）：

```
ppe offloaded: 24 of 24 flow(s) updated
--- 之后 4 秒，流仍在跑 ---
ppe_yield:  94664 -> 174356     <- 数据面让路 79692 个包
flow_hit : 351497 -> 351497     <- 命中计数完全冻结
iperf    : 8.87 GBytes  6346 Mbits/sec  0 重传
```

**这是核心证据**：DPD 对硬件拥有的流一个包都不碰，而吞吐不受影响
（流量由协议栈/硬件正常转发）。

### 4.2 fallback：硬件失败的流，DPD 收回来

```
ppe_mode = fallback
flow_hit: 291918 -> 314248      <- 恢复增长
iperf   : 1.21 GBytes  5195 Mbits/sec
```

这正是"双加速"的实际含义：硬件先挑，硬件不行 DPD 兜底。

### 4.3 grace：新流上不抢，先等内核决定

```
ppe_mode = yield, ppe_grace_ms = 3000, 全部标记 UNKNOWN
ppe_grace: 38004 -> 75696       <- 等待窗口生效
flow_hit : 几乎不动（+2）
iperf    : 1.53 GBytes  6580 Mbits/sec
```

## 5. 一致性守卫（CI）

`dpdfwd` 故意不 include `bpf/core/src/dpd_common.h`：控制面只通过 `dpdctl`
和 pinned map 说话，为了共享 6 个常数而拖进 `linux/bpf.h` 会把它绑死在某版
内核 UAPI 上。代价是枚举定义重复两份。

`scripts/verify-ppe-abi.sh` 是守卫，已接进 `lint` workflow：

```
ok:   dpd_ppe_state identical (6 values)
      DPD_PPE_UNKNOWN=0
      DPD_PPE_SW_ACTIVE=1
      DPD_PPE_YIELDED=2
      DPD_PPE_OFFLOADED=3
      DPD_PPE_FAILED=4
      DPD_PPE_DENIED=5
ok:   the hit path calls dpd_ppe_yield()
ok:   ST_PPE_YIELD defined
ok:   ST_PPE_GRACE defined
verify-ppe-abi: OK
```

**负向测试**：把 `dpd_plugin.h` 里的 `DPD_PPE_DENIED` 改成 9，脚本立即
FAILED 并逐值打印两份定义；改回来后 OK。写这个脚本时还抓到自己的一个 bug:
最初的 shell/awk 版本把"显式 =0 之后隐式递增"算错（`SW_ACTIVE` 报成 0
而不是 1），会掩盖真实差异，已改成 python 实现。

## 6. gate 的变化：从"一刀切让开"到"可协商"

ABI 21 的 gate 规则是：只要 fw4 开了 flow offloading 就降级 observe。
这对 `ppe_mode=off` 是对的（看不见硬件就别抢），但它让双加速**不可能**发生。

现在：

| 条件 | 结果 |
|---|---|
| `ppe_mode=dual\|fallback` + flow offloading | 允许共存，gate 记日志 |
| 其他 + flow offloading | 仍降级 observe，并提示怎么开 dual |

## 7. 硬件侧：已查清，是驱动不支持（不是没测出来）

> 完整证据见 `PPE-HW-CAPABILITY-2026-11-11.md`。这里只放结论。

在反复尝试之后，硬件侧的问题已经从"不知道怎么触发"变成了一个**确定的
能力事实**：

```
# tc filter add ... flower ... skip_sw action drop
RTNETLINK answers: Not supported          <- -EOPNOTSUPP
```

```
# grep -E 'setup_tc|flow_block' /proc/kallsyms | awk '{print $3}'
qca_ppe_setup_tc_mqprio      <- 队列整形
qca_ppe_setup_tc_ets         <- 调度
qca_ppe_setup_tc_prio        <- 优先级
qca_ppe_setup_tc_tbf         <- 限速
```

这个驱动的 `ndo_setup_tc` **只实现 QoS 整形**，没有 `FLOW_BLOCK_BIND`。
netfilter 的 `nft ... flowtable flags offload` 走的正是 `flow_block`，
所以它不可能到达硬件，`offloaded` 永远是 0。

三条互相独立的证据：

1. `skip_sw` 被内核拒绝（`Not supported`）；去掉 `skip_sw` 能装上但标记
   `not_in_hw`；
2. 没有 `bind` 文件（MTK PPE 有 `/sys/kernel/debug/ppe0/bind`）；
3. 驱动的拒绝计数**全为 0** —— 说明从未被请求过，不是拒绝了某个流。

同时确认：**软件 flowtable 是工作的**（两个 netns 之间桥转发 iperf3
6.7 Gbit/s，conntrack 出现 `[OFFLOAD]`）。所以这台机器上"软硬双加速"的
硬件那一半**在这个内核里不存在**，与我们是否实现协调层无关。

ABI 22 的价值也因此更清楚了：它依赖的是内核告诉我们"这条流被别人接管
了"，而软件 flowtable 恰好会写 `IPS_OFFLOAD` —— 这一点已经在真机上验证。

### 7.1 原本记录的"环境限制"

以下是最初的判断，已被上面的证据取代，保留以说明排查过程：



```
offloaded     = 0
live_entries  = 0
active_flows  = 0 0 0/2048
wan carrier   = 0
br-lan ports  = 3  (lan1/lan2/lan3)
```

原因不变，且**不是代码问题**：

1. 所有端口都在 `br-lan`，桥内流量由交换机硬件直转，**不经过 L3/flowtable**；
2. WAN 无载波，构造不出第二段路由；
3. 驱动的拒绝计数全为 0（`ingress_not_switch_port`、`egress_not_switch_port`、
   `no_egress_l2_header`…），说明它**从未被请求过**，不是拒绝。

`lan2` 有 13455 rx / 20393 tx 和真实设备在跑，拆它会断线，所以没有动。

**要在硬件侧验收 `offloaded>0`，需要二选一**：
- 给 WAN 插网线拿到载波；
- 指认一个可以临时拆出 `br-lan` 的空闲端口。

## 7.5 端到端：conntrack → dpdfwd → dpdctl → 数据面（2026-11-11 补齐）

这是之前唯一没有跑过的链路。所有 yield 测试都是手工
`dpdctl flows ppe offloaded` 驱动的，`dpdfwd` 只是部署了、没有证据显示它
真的在工作。现在跑通了，而且在跑通的过程中发现并修掉了四个真实缺陷。

### 7.5.1 四个缺陷

| # | 缺陷 | 为什么会发生 | 怎么发现 |
|---|---|---|---|
| 1 | **ctnetlink 根本不上报卸载转换** | 流被 flowtable 接管后就不再经过 netfilter，内核不会再发 CT UPDATE，`CTA_STATUS` 里的 `IPS_OFFLOAD` 永远不会出现 | 实测：proc 表里 2 条 `[OFFLOAD]`，`ct_offload` 整条连接一直是 0 |
| 2 | sweep 的字段扫描只前进一个字节 | `/proc/net/nf_conntrack` 的列用**多个空格**对齐（`ipv4     2 tcp      6`），`p = end + 1` 落在空格上，后续 token 长度全为 0 | `ppe_swept` 一直是 0，而 `[OFFLOAD]` 明明匹配到了 |
| 3 | 同一 tuple 可能入队两次，弱状态覆盖强状态 | 事件路径写 `SW_ACTIVE`，sweep 写 `YIELDED`，谁最后写谁赢 | 流条目显示 `ppe=sw_active`，而 sweep 日志说 `want=2`（YIELDED） |
| 4 | 端口字节序不匹配 | `ct_tuple.sport` 是网络序，`ppe_flush` 直接 `%u` 打印；`dpdctl` 按主机序解析，于是查到的是**另一条流** | 状态写入了，但流条目的 `ct_cookie` 不动 |

修复都在 `fa1628f`：

- `ppe_sweep()` 每秒扫一次 `/proc/net/nf_conntrack`，作为事件路径的补充；
- 跳过整段分隔符而不是一个字节；
- `ppe_update()` 按 tuple 去重，`OFFLOADED(3) > YIELDED(2) > SW_ACTIVE(1)`；
- `ppe_flush()` 用 `ntohs()` 输出主机序端口；
- 顺带：`dpdctl flows` 增加 `ppe=<状态>` 列，否则这一切无法观察。

### 7.5.2 实测结果

拓扑：路由（非桥接）双 netns，`inet` flowtable 带 `flags offload`，
`ppe_mode=yield`，`grace=3000`。**全程没有任何手工 `dpdctl flows ppe` 调用。**

```
t≈6s    ppe=yielded   ppe_yield 134819   flow_hit 0   ppe_writes 17  ppe_swept 12
t≈12s   ppe=yielded   ppe_yield 211826   flow_hit 0   ppe_writes 29  ppe_swept 24
t≈18s   ppe=yielded   ppe_yield 288705   flow_hit 0   ppe_writes 41  ppe_swept 36
        conntrack [OFFLOAD] = 2
        iperf3  18.0 GBytes / 7039 Mbits/sec
```

三个关键点同时成立：

1. **`ppe=yielded`** —— 状态是 `dpdfwd` 从 conntrack 自己写进去的；
2. **`flow_hit` 全程冻结在 0** —— 数据面一个包都没有接管被内核卸载的流；
3. **吞吐 7.0 Gbit/s** —— 流量由 flowtable/硬件路径承载，没有因为 DPD 让路而受损。

`ppe_swept` 与 `ppe_writes` 共同说明链路是活的：sweep 读到了 conntrack 的
卸载标记，flush 把它们变成了 map 里的状态。

### 7.5.3 为什么 grace 是必要的

第一次尝试（`grace=0`）失败：DPD 抢在 flowtable 之前接管了流，于是
conntrack 看到的包太少、**根本没有卸载**（`[OFFLOAD] = 0`），自然也没有
状态可写。

`grace=3000` 让 DPD 在新流的前 3 秒让路，flowtable 趁机接管并写下
`IPS_OFFLOAD`，之后 `dpdfwd` 记录 `YIELDED`，DPD 就永久让路。这个顺序是
协调层能工作的前提，不是可调参数。

## 8. 进了镜像（这一条已闭环，含端到端修复）

### 8.0 第二次构建：r11 / r10

第一次镜像（`0466df8`）里是 r10/r9，**不含**后面修掉的四个端到端缺陷。
用 `c9ddb3c` 重建后重新核对发布产物：

```
release: dpd-fw-wrt-X86-26.11.11-04.25.56

manifest:
  dpd-fastpath - 0.1.0-r11      <- 之前 r10
  dpdfwd       - 0.1.0-r10      <- 之前 r9

rootfs (dpd-fw-wrt-x86-64-rootfs-none-26.11.11-04.25.56.tar.gz):
  /usr/lib/dpd/abi = 22
  lib/bpf/dpd_fastpath.bpf.o = 311656 bytes
  usr/sbin/dpdfwd = 36923 bytes     <- 之前 24635，体积印证修复合入
  usr/sbin/dpdctl = 44699 bytes
  option ppe_mode 'off'
  option ppe_grace_ms '0'

二进制内容核对（不是看构建日志）：
  dpdfwd contains /proc/net/nf_conntrack : True   <- sweep 在
  dpdfwd contains ppe_swept              : True   <- 新计数器在
```

所以镜像里跑的确实是端到端验证过的那一版。

### 8.1 第一次构建（r10 / r9，已作废）

ABI 22 不只是在设备上手工验证：它已经**打包进正式镜像**并核对过实际产物。

构建：固件仓库 `0466df8` → `Auto-Clean` → 四个 workflow，全部 success：

```
QCA-PPE       4/4 jobs success   (IPQ60XX/807X × WIFI-NO/YES)
QCA-NSS       4/4 jobs success
EBPF-WRT-ALL  2/2 jobs success   (X86, ROCKCHIP)  <-- ABI 22 数据面在这里
MTK-ALL       进行中
```

发布产物 `dpd-fw-wrt-X86-26.11.11-02.46.00`，从 release 里取出 manifest 和
rootfs 核对：

```
=== manifest ===
  dpd-fastpath - 0.1.0-r10        <- ABI 22 的版本号
  dpdfwd       - 0.1.0-r9
  einat-ebpf   - 0.1.11-r3
  tc-bpf       - 7.3.0-r1

=== rootfs (dpd-fw-wrt-x86-64-rootfs-none-...tar.gz) ===
  *** /usr/lib/dpd/abi = 22                     <- 包内的 ABI 戳
  *** lib/bpf/dpd_fastpath.bpf.o (311656 bytes)
  *** usr/sbin/dpdctl  (44699 bytes)
  *** usr/sbin/dpdfwd  (24635 bytes)
  config: option ppe_mode 'off'
  config: option ppe_grace_ms '0'
```

`/usr/lib/dpd/abi` 就是 `dpd_pins_compat()` 用来决定要不要丢弃旧 pinned map
的那个文件；它等于 22，说明镜像里的数据面和用户态是同一版 ABI。

两棵源码树也逐文件比对过（`cmp`），7 个文件**字节完全相同**：

```
OK dpd_common.h   OK dpd_fastpath.bpf.c   OK dpdctl.c
OK dpdfwd.c       OK dpd_plugin.h
OK dpd-fastpath.sh   OK dpd_fastpath.config
```

## 9. 复现

```sh
# 数据面
clang -target bpf -O2 -g -DDPD_MODE_DEFAULT=1 ...
clang --target=aarch64-linux-gnu -static ... -o dpdctl
clang --target=aarch64-linux-gnu -static ... -o dpdfwd

# 设备上
tc qdisc add dev <if> clsact
tc filter add dev <if> ingress bpf obj dpd_fastpath.bpf.o sec classifier/l2 da
dpdctl ifaces <in> <out>
dpdctl set mode stateful
dpdctl set ppe yield        # or dual
dpdctl set grace 2000
dpdctl set enable 1

# 模拟"硬件接管了这条流"
dpdctl flows ppe offloaded
dpdctl stats | grep -E 'ppe_|flow_hit'
```


## 10. 实装：开机路径、诚实状态与概况页（2026-11-11）

这一节记录的是"把已验证的数据面装进一台真实路由器"时补掉的三处缺口，
以及概况页最终呈现的样子。设备：太乙 `10.10.10.100`，IPQ60xx，
ImmortalWRT SNAPSHOT，只接了 LAN 口，WAN 无载波、无默认路由。

### 10.1 服务化

手工部署的 `dpdctl` / `dpdfwd` / `dpd_fastpath.bpf.o` 之外，还装了：

```
/etc/init.d/dpd-fastpath          S95
/etc/init.d/dpdfwd                S96
/usr/libexec/dpd-fastpath.sh
/usr/libexec/dpd-gate-watchdog
/usr/libexec/dpd-gate-refresh
/etc/hotplug.d/iface/90-dpd-fastpath
/etc/sysctl.d/99-ebpf-accel.conf
/etc/config/dpd_fastpath
```

`option interfaces 'lan'` 解析成 `br-lan`，并按既有设计同时挂到它的每个
bridge port（`lan1`/`lan2`/`lan3`）。实测：

```
attached      yes (ABI 22 loaded, 22 built; tc hook on 4/4 ifaces)
br-lan 1   lan1 1   lan2 1   lan3 1   wan 0
```

`wan` 保持 0 是设计约束：上行 hook 只在 `option downlink '1'` 且
`mode=stateful` 时才有意义。

### 10.2 "attached" 不再等于"已加载"

旧实现里 `dpdctl status` 的 `attached` 只检查 pinned `dpd_cfg` 是否存在，
也就是"程序加载过"。它在下面这种情况下会撒谎：测试用的 netns 删除后，
tc filter 随设备消失，但 pinned map 还在，于是状态报 `attached yes`，
而 `flow_hit` 一直冻结在 0、任何设备上都没有 filter。概况页会据此显示
"on"，操作者却找不到任何被加速的包。

现在 `status -j` 明确拆成四个字段：

```
"attached": true|false      = loaded && hooked > 0
"loaded":   true|false      = dpd_cfg 存在
"hooked":   N               = 真正带 dpd_fastpath filter 的接口数
"iface_count": N            = 配置里仍存在的接口数（不叫 ifaces：JSON 里
                              另有一个 ifaces 数组，重名时解析器取值不一致）
"hook_unknown": true|false  = 没有 tc，无法判断（不把"不知道"当成"关"）
```

文本输出也直接给出可行动的信息：

```
attached      no (ABI 22 loaded, but no tc filter on 4 configured ifaces;
                  nothing reaches the fast path)
```

`hooked` 由 `tc filter show dev <if> ingress` 得到，只对 `dpd_iface` 里的
接口采样；TC 不存在时返回 `hook_unknown`，避免在没有 iproute2 的镜像上
把正常的 datapath 报成关闭。

概况页的 chip 因此改为 `attached && hooked` 才算"加速中"；仅加载时显示
模式名（如 `observe`），未加载时显示 `—` 并给出"加速引擎未启动"。

### 10.3 陈旧的接口键与流

接口被删除后，`dpd_iface` / `dpd_mtu` 里的旧 ifindex 不会自己消失，而内核
会复用 ifindex。实测在测试 netns 删除很久之后，map 里仍留着 `if159` /
`if161`。这既让概况页多显示不存在的接口，也可能让后来的设备继承别人的
flags/MTU。

`dpdctl ifaces ...` 现在先删除所有无法解析的 ifindex，再学习新接口；同时
删掉 `ingress_ifindex` 等于该值的 `dpd_flows` 条目，避免"2/16384 但一个包
也没在走"的假读数，以及 ifindex 复用后误命中旧流。实测清理后只剩
`br-lan` / `lan1` / `lan2` / `lan3`。

### 10.4 ppe_mode 在开机路径下发

`ppe_mode` / `ppe_grace_ms` 原先只在 gate watchdog 的第一轮（最多 20 秒后）
写入内核。开机后的这段时间里，无论 uci 写的是什么，内核里都还是 map 里
遗留的值（默认 0 = off）。

现在 `dpd_push_ppe()` 是唯一映射点（uci 的 `dual`/`fallback` 都写成
`DPD_PPE_FALLBACK`），`start_service()` 和 `dpd_gate_refresh_uci()` 共用。
实测用三个不同的值重启验证：

```
ppe_mode=yield      -> ppe_mode yield (hardware coexistence)
ppe_mode=fallback   -> ppe_mode fallback, ppe_grace 1500 ms
ppe_grace=0         -> ppe_grace 0 ms (take over at once)
```

### 10.5 概况页

两张流表分两行显示，格式与项目里的计数器一致：

```
observe · DPD: 0/16384 (IPv4: 0 IPv6: 0) · PPE: 0/2048 (IPv4: 0 IPv6: 0)
```

* `DPD` 是 eBPF fastpath 自己的流表（`maps.flows`）。
* `PPE` 是硬件 L3 卸载表，读 `/sys/kernel/debug/3a000000.ppe/active_flows`
  的第一行 `<ipv4> <ipv6> <used>/<max>`，实测为 `0 0 0/2048`；MTK PPE 的
  同样格式也可以直接读。
* 两者从不相加：一个是软件接管的流，一个是硬件接管的流，相加会把软件
  加速说成硬件加速。
* 没有 PPE 的机器（x86/RK）`ppe_hw.present=false`，这一行整体不显示，
  而不是显示一个假的 `0/0`。

数据由 `dpdfwd` 每 2 秒写 `/var/run/ebpf/status.json`（临时文件 + rename），
LuCI 通过 rpcd 的 file ACL 读取；ACL 同时授权 `/var/run/...` 和
`/tmp/run/...` 两种写法（`/var/run` 是符号链接）。

### 10.6 软件路径实测（受控路由流量）

因为本机只有 LAN、没有可路由的上行，真实 LAN 流量是二层交换，不经过
DPD 的转发判定；用两个 netns + veth 构造一条真实经过本机内核转发的流：

```
iperf3          5430 Mbits/sec (sender), 5423 Mbits/sec (receiver)
flow_hit        0 -> 90519
flows           entries 2 (v4 2, v6 0) / 16384
6 秒后          仍是 entries 2，未被 sweep 误删
ppe             unknown 2（无硬件 L3 卸载，符合本驱动能力）
```

这条证据补上了此前只验证"吞吐 + 流表条目"、没有单独记录 `flow_hit` 的
空白。

### 10.7 本机拓扑下的正确行为

装好服务后 gate 的原文是：

```
stateful
observe
no-uplink
no uplink (no WAN device or no default route), so there is no forwarding path
to accelerate and hooking the LAN would only steal traffic addressed to the
router itself
```

也就是说：**只有 LAN 口、没有上行时，DPD 应当停在 observe**，而不是报错。
数据面仍然挂着、计数仍然可读、PPE 表仍然显示，只是不会有人被加速。等
WAN 起来（或插上上行），`90-dpd-fastpath` 的 ifup 事件会重新评估 gate，
不需要人工干预。
