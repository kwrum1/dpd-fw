# 多 WAN 负载均衡使用说明

多 WAN 在 **mydist 数据面**上把新建连接按权重分配到多条 WAN：

- NAT 仍只由 **einat** 做，每条 WAN 一个实例、各自一段 NAT 端口；
- **dpd** 在 LAN 入口按五元组选出 WAN，首包打 `fwmark` 走对应的路由表，
  后续包直接 `bpf_redirect` 到缓存的出口；
- **mydist-mwan** 负责路由表、`ip rule`、`dpd_wans` 表、健康检查和
  WAN 侧下载钩子；`/etc/init.d/mydist-mwan` 是它的 procd 服务（S61）。

当前只有 **balance（按权重）** 模式，没有主备/failover 切换，也**不支持 IPv6**。
页面在 **网络 → 多 WAN**（`admin/network/mwan`）。

> 状态：实验台（x86_64，内核 6.18.55，两条以太网 WAN）已验收；
> 家用双 PPPoE 实链路尚未实测，见文末“未验证 / 已知问题”。

## 1. 适用场景

- 家里有两条宽带（双 PPPoE、PPPoE + DHCP、两条静态/动态以太网），
  想同时使用两条线的上行带宽；
- 多条 WAN 的下一跳、网关和 MTU 由 netifd 正常管理，路由器能对每条 WAN
  分别 `ping` 通；
- 主要流量是 LAN → WAN 的新建连接（网页、下载、视频）。已有连接不会因为
  改权重而迁移，重载/断线后会重新选路。

不适合：

- 只想要“主线路坏了再切备用”——目前没有 failover 模式，健康检查只影响
  `dpd_wans` 的可用集合；
- IPv6 多 WAN；
- 需要每条 WAN 独立策略路由/独立防火墙策略的复杂拓扑。

## 2. 准备 netifd

多 WAN 的“WAN 名字”用的是 **netifd 逻辑接口名**，不是设备名：

| 场景 | `interface` 填什么 | 运行时设备（`l3_device`） |
|---|---|---|
| 第一条 PPPoE | `wan` | `pppoe-wan` |
| 第二条 PPPoE | `wan2` | `pppoe-wan2` |
| 两条 DHCP/静态以太网 | `wan` / `wan2` | `eth1` / `eth2` |

`mydist-mwan` 每次 reconcile 都用
`ubus call network.interface.<名字> status` 取 `l3_device`，所以：

- **不要**在配置里写 `pppoe-wan2` 或 `eth2`，写 `wan2` 即可；
- 第二条 WAN 也要在 `/etc/config/network` 里有完整的 interface（proto、
  用户名/密码、metric 等），并且 `up`；
- 把 `wan2` 加进 fw4 的 **wan zone**（或与 `wan` 相同的 zone），否则入站
  策略和 MSS 钳制不会覆盖它。NAT 由 einat 负责，**不要再开 masquerade**。

示例（`/etc/config/network` 的骨架，实际按运营商填写）：

```uci
config interface 'wan'
	option proto 'pppoe'
	option device 'eth1'
	option username 'user1'
	option password 'pass1'
	option ipv6 '0'

config interface 'wan2'
	option proto 'pppoe'
	option device 'eth2'
	option username 'user2'
	option password 'pass2'
	option ipv6 '0'
	option metric '20'
```

## 3. 配置多条 WAN

### 3.1 LuCI

**网络 → 多 WAN**：

1. 打开“启用多 WAN”，健康检查间隔一般保持 `5` 秒；
2. 在“WAN 接口”表里添加行：
   - **WAN 接口**：下拉选择 netifd 接口（`wan`、`wan2`……），也可以直接输入；
   - **权重**：1–8，默认 1；
   - **启用**：单条 WAN 的开关；
   - **健康目标**：留空用该 WAN 的网关；PPPoE 接口没有默认网关时 daemon
     会退回 `1.1.1.1`，所以双 PPPoE 建议显式填写一个从这条线能 ping 通的
     公网地址；
   - **状态**：只读，显示 `up/down`、设备名和该设备的累计 RX/TX 字节。
3. 保存。页面会执行 `uci commit mydist_mwan`，然后
   `/etc/init.d/mydist-mwan restart`（关闭总开关时执行 `stop`）。
   服务重跑 reconcile，已有连接会重建。

权重是**新流**的比例，不是带宽上限：`wan=2, wan2=1` 表示新流约 2/3 走
`wan`、1/3 走 `wan2`。要限速请用 **网络 → QoS**（只整形上传）或上游设备。

### 3.2 UCI

```uci
config global 'global'
	option enabled '1'
	option health_interval '5'

config wan 'wan'
	option interface 'wan'
	option weight '2'
	option enabled '1'
	option health '1.1.1.1'

config wan 'wan2'
	option interface 'wan2'
	option weight '1'
	option enabled '1'
	option health '1.0.0.1'
```

section 名（`wan` / `wan2`）只是 UCI 标识，真正生效的是 `option interface`。
保存后：

```sh
uci commit mydist_mwan
/etc/init.d/mydist-mwan restart
```

`restart` 会重新 reconcile 并重启 health 循环；只想重读 netifd 状态（例如
PPPoE 刚拨上、网关变了）可以用 `reload`，它不会杀掉 health 循环。

### 3.3 运行时状态

```sh
cat /var/run/mydist-mwan/wans
# ifn dev mark table pref weight target flags p1 p2
# wan  eth1 0x101 100 40 2 1.1.1.1 1 20000 29999
# wan2 eth2 0x102 101 41 1 1.0.0.1 1 30000 39999
```

- `flags` 最低位 = up；
- `p1 p2` 是该 WAN 的 einat NAT 端口段，不能重叠；
- 文件为空/不存在：服务没运行，或没有一条 WAN 达到可用条件（netifd up +
  网关/邻居就绪）。

`bpftool map dump pinned /sys/fs/bpf/tc/globals/dpd_wans` 可以看内核里的
WAN 表；`ip rule` 应有 `fwmark 0x101/0x102` 两条规则，`ip route show table
100/101` 应各有一条默认路由。

## 4. 验收数据（2026-10-27，实验台）

实验台：2 vCPU / 1 GB，Linux 6.18.55；两条 WAN 分别到 `198.18.0.2` /
`198.19.0.2`；上传方向 `iperf3 -c 198.18.0.2 -p 5201`，用路由器
`/sys/class/net/eth{1,2}/statistics/tx_bytes` 前后差计算。

### 4.1 权重 1:1

| 样本 | eth1 | eth2 | 比例 |
|---|---|---|---|
| 64 流（4 × `-P16 -t3`） | 3.70 GiB | 3.94 GiB | 48.5 / 51.5 |
| 64 流（最终态） | 3.04 GiB | 3.18 GiB | 48.9 / 51.1 |
| **合计 256 流** | 12.47 GiB | 14.99 GiB | **45.4 / 54.6** |

12 流的小样本会在 33/67～67/33 之间摆（二项分布），不是选路错误；
判断分流请用 64 流或更大样本。

### 4.2 权重 2:1

| 权重 | eth1 | eth2 | 比例 | 期望 |
|---|---|---|---|---|
| 1:1（64 流） | 3.70 GiB | 3.94 GiB | 48.5 / 51.5 | 50/50 |
| **2:1（64 流）** | 5.12 GiB | 2.68 GiB | **65.6 / 34.4 = 1.91:1** | 66.7/33.3 ✅ |
| 2:1（16 流，顺序端口） | 9.27 GiB | 5.62 GiB | 62.3 / 37.7 = 1.65:1 | ✅ |

旧公式 `score = hash * weight` 在同样 2:1 下是 74.8/25.2（约 3:1），
现在的“每 WAN 抽 `weight` 次 hash 取最大”才是按比例。

### 4.3 断一条

| 配置 | eth1 Δ | eth2 Δ | 上传 |
|---|---|---|---|
| `wan2.enabled=0` | +2.58 GiB | **0** | 5.29 Gbit/s |
| `wan1.enabled=0` | **0** | +2.18 GiB | 4.46 Gbit/s |
| 恢复 1:1 | 两条都承载 | 两条都承载 | 4.22–5.50 Gbit/s |

新流全部落到剩下的 WAN；reconcile 会 flush `dpd_flows`，旧连接报错重建
（预期行为）。

### 4.4 吞吐

| 场景 | 上传 | 下载 `-R` |
|---|---|---|
| 单 WAN1 | 4.42 Gbit/s | 3.01 Gbit/s |
| 单 WAN2 | 4.46 Gbit/s | 3.18 Gbit/s |
| **双 WAN 1:1** | **5.26–5.51 Gbit/s** | 2.82–3.14 Gbit/s |
| 双 WAN 2:1 | 5.38 Gbit/s | — |

双 WAN 总上传约为单 WAN 的 1.2 倍（两路各自排队），RTT 同量级
（0.79 ms vs 0.83 ms）。下载 `-R` 没有随 WAN 数增加，瓶颈在服务器侧
nft 逐包处理，不是选路。

## 5. 风险边界

### 5.1 被加速的包不进 conntrack / fw4 forward

这是 dpd 快路径的既有语义，不是多 WAN 引入的：

- 每个流的**首包**仍然走完整 netfilter（fw4 规则、einat 的 NAT、router-acl），
  所以端口转发、入站拒绝、策略路由仍按首包决定；
- 命中 `dpd_flows` 之后的包由 `bpf_redirect` 直接送到 WAN/LAN，**不经过**
  conntrack 和 fw4 forward 链。依赖 `ct state`、`limit`、`counter`、每包
  `dnat`/`snat` 的规则看不到这些包；
- 因此不要在多 WAN 上再叠加依赖逐包 netfilter 的功能（例如额外的
  masquerade、每包 mark 规则）。

### 5.2 需要逐包限速/整形时关掉 downlink

- QoS 页面只做**上传**方向的 CAKE（`root cake`），它看到的是 WAN egress，
  和 dpd 不冲突；
- 下载方向如果要按主机/按包整形，需要 IFB 或 ingress qdisc。dpd 在 WAN
  ingress 上装了 downlink 钩子，把已识别的包直接 redirect 到 LAN，这些包
  不会再经过 IFB/ingress 整形；强行加 IFB 还会和 router-acl/dpd 抢包。
- 所以：**需要逐包下载限速时，先关掉 downlink 加速**（不要给该 WAN 挂
  dpd 的 ingress 钩子；目前这条钩子由 `mydist-mwan reconcile` 自动挂上，
  需要临时移除或改脚本跳过），再在 WAN ingress 上做整形。代价是下载不再
  走快路径。上传整形不需要关。

### 5.3 NAT / 防火墙

- NAT 唯一归属 einat；`einat.init` 会让 fw4 关闭 masquerade。不要再手工开
  `masquerade`，否则同一条流会被 fw4 先 SNAT、einat 再 SNAT，源端口变化会
  导致服务器 RST（实验台踩过）。
- 每条 WAN 的 einat 端口段由 `mydist-mwan` 按顺序分配
  （20000–29999、30000–39999……），不要手工再起一个 einat 抢同一段。
- `einat restart` 会删掉同一 netdev 上的 classic dpd 过滤器；
  `mydist-mwan restart`（或 reconcile）会自动重挂每条 WAN 的 downlink 钩子。
  只重启 einat 而不 reconcile 时，下载仍能转发，只是没有快路径。

### 5.4 PPPoE / MTU

- 代码按 `l3_device=pppoe-wanN` 处理：不写 L2 头，flags 带 L3，
  用 `bpf_redirect` 的无头路径；
- PPPoE 的 MTU/MSS 仍由 fw4 的 `mtu_fix` 负责，保持开启；
- 两条 WAN 的 MTU 可以不同，但不要手工改小其中一条而不改另一条，否则
  大包会出现“有的站能开、有的站卡住”的半开状态。

### 5.5 其它

- 权重上限是 8（BPF 里 clamp）；填 9 会按 8 处理，页面限制在 1–8；
- 权重只影响**新流**；已有流在 `dpd_flows` 失效（超时/断线/重载）前
  保持原 WAN；
- 页面状态里的 RX/TX 是**设备累计字节**，不是实时速率；要看速率用
  `cat /sys/class/net/<dev>/statistics/*_bytes` 隔几秒取差，或用
  `ifstat`/`vnstat`；
- 多 WAN 页面不提供 failover 模式，也不显示每条 WAN 的当前流数/延迟。

## 6. 排障

```sh
# 服务与配置
/etc/init.d/mydist-mwan status
uci show mydist_mwan
cat /var/run/mydist-mwan/wans
logread -e mydist-mwan | tail -30

# 路由与规则
ip rule
ip route show table 100
ip route show table 101

# 内核 WAN 表 / 流表
bpftool map dump pinned /sys/fs/bpf/tc/globals/dpd_wans
bpftool map dump pinned /sys/fs/bpf/tc/globals/dpd_flows | head

# WAN 侧下载钩子（每条 WAN 都应有 pref 100 的 bpf 过滤器）
tc filter show dev eth1 ingress
tc filter show dev eth2 ingress
```

常见现象：

| 现象 | 检查 |
|---|---|
| 页面状态“未就绪” | `global.enabled` 是否为 1；对应 netifd 接口是否 up；`ip neigh` 是否有网关邻居 |
| 只有一条 WAN 有流量 | 另一条是否 `enabled=1`、weight>0；`dpd_wans` 是否 count=1；`ip rule` 是否有两条 |
| 改了权重比例没变 | 旧流仍在原 WAN；断开重连或 `restart` 后再测 |
| 网页能开、大文件卡 | 检查两条 WAN 的 MTU/MSS、fw4 `mtu_fix`、PPPoE 是否双拨成功 |
| 重启 einat 后下载变慢 | 运行 `/usr/libexec/mydist-mwan reconcile` 重挂 downlink 钩子 |

## 7. 未验证 / 已知问题

1. **真实 PPPoE 双拨未测**：实验台只有以太网。`l3_device=pppoe-wanN` 的
   无头 redirect 路径已按代码写好，但没有在两条真实 PPPoE 上跑过。
2. **物理断线/上游不可达的健康切换未实测**：本次“断一条”用
   `enabled=0` + reconcile 模拟；health 循环会 ping 健康目标，但
   “链路 carrier 在、上游 ping 不通”的组合还需要一次拔线/黑洞测试。
   netifd 判定接口 down 时，reconcile 会把该 WAN 从 `dpd_wans` 移除。
3. **权重 8 上限**没有在页面上提示 clamp 细节（页面限制 1–8）。
4. **`dpdctl` 版本**：镜像里旧 `dpdctl` 的流表解码 ABI 可能与新对象不一致；
   判断选路请用 `bpftool map dump` 的原始值，不要用旧 `dpdctl flows`。
5. 页面不做 failover、不做 IPv6、不做每条 WAN 的实时速率/流数。
