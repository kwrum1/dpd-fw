# 代理与加速共�?—�?研究报告与优化方�?
> 触发�?026-10-18，用户提问）�?*"目前 honk �?dpd 无法同时工作吗？加速就不能代理�?> 代理就不能加速？参�?chawrt �?landscape 的优化，继续研究打磨优化方向和代理加�?> 兼容方式�?**
>
> **结论先行**：这个前�?*不准�?*。honk(dae) 自己就把路由策略**编译�?eBPF 在内核里
> 判定**，并�?*直连判定 offload 回内�?*（`RoutingMeta` bit 57 / "native direct"）；
> 只有**代理判定**�?*"域名终局性未�?的直连判�?*才进用户态。所�?代理 + 加�?本来
> 就是**按流分区**，不是二选一�?>
> 我们上一轮测�?honk 跑着�?dpd 计数器不�?，用的恰好是**必然进用户�?*的两种流�?> （被代理域名 + �?must �?fallback 直连）�?*从没有测�?`direct(must)` 流量** —�?> 唯一一种必须在内核里跑完的直连�?>
> 所以下一件事不是"设计共存"，而是�?*(1) 做一次定向实验，证明 CN `direct(must)` 流量
> 仍然经过 dpd�?2) �?还会掉进用户�?的直连压到最少；(3) 补上加速路径真正缺的东�?> （MSS clamp）�?>
> ---
>
> ### ⚠️ 2026-10-18 02:00 更正：实验做完了�?*上面的结论被证伪**
>
> 定向实验（`build/qemu-honk-dpd-coexist.sh`）跑完了�?*P1 失败**：honk 一开�?> `dip(geoip:cn) �?direct(must)` 的流**�?dpd 上计数为 +0**（同一目的地址�?honk 关掉时是
> `+38574`）。而且 `dae0` 这个"honk 用户�?见证**无效** —�?P3 的代理明确成功（出口是节�?> IP）时 `dae0` 依然�?+0�?>
> 所以：**"代理与加速按流分�?在本挂法下不成立**，实测是 **honk �?TC redirect 管线整体
> 让位**。�? 的归属矩阵作废；细节、原始数字、能�?不能说的边界、以及两条可走的方案
> （B 接受现状 / C 改到 WAN 入口做下载方向）�?**§8**。用户最初那�?加速就不能代理�?> 代理就不能加�?**比本文原来的结论更接近事�?*�?*

本文中每个论断都标了来源等级�?
| �?| 含义 |
|---|---|
| **实测** | 本轮/上一轮在真实镜像或真实内核源码树上看到的 |
| **上游文档** | honk / landscape 自己文档里写的设计（未在我们机器上验证） |
| **待测** | 有明确判据、还没跑�?|

---

## 1. 本轮新增的实测事�?
| # | 事实 | 证据 |
|---|---|---|
| F1 | honk-core �?**TCX + `bpf_sk_assign`**：`sk_assign` 6 处、`tproxy/TPROXY` 134 处、`dae0` 62 处、`bpf_redirect` 8 �?| `strings` 镜像 `/usr/bin/honk-core`�?7 MB�?|
| F2 | 我们发货的内�?**6.18.55** �?`BPF_F_BEFORE` / `BPF_F_AFTER`，uapi 里有 `relative_fd/relative_id/expected_revision`�?*libbpf 头里 `bpf_link_create_opts.tcx` 也有这三个字�?* | `linux-6.18.55/include/uapi/linux/bpf.h:1223,1649`；`staging_dir/.../include/bpf/bpf.h:443` |
| F3 | 出厂/镜像�?honk 的策略是 `dip(geoip: cn) && !dport(53) -> direct(must)`、`domain(geosite: cn) -> direct`、`fallback: direct`；`dial_mode: domain`；`nfqueue_enable: false`（我们的裁剪�?| `root-x86/etc/honk/config.dae`、`/usr/share/honk/default-config.dae`、`system.dae` |
| F4 | 内核只有 `CONFIG_TCP_CONG_CUBIC=y`（`DEFAULT_TCP_CONG="cubic"`），**没有 BBR**，manifest 里也没有 bbr 模块 | `linux-6.18.55/.config` + 镜像 manifest |
| F5 | `option mtu_fix 1` 在出�?firewall 里（fw4 给转发流量加 `TCPMSS clamp`）；**dpd 完全不做 MSS**；einat 的注释明确把 MSS 推给 firewall（`option mtu_fix`�?| 镜像 rootfs `/etc/config/firewall:28`；`einat-ebpf/files/einat.init:37`、`README.md:22` |
| F6 | 三条链的挂载点：honk = **br-lan �?TCX**（ingress/egress）；dpd = **br-lan �?classic filter**；einat = **WAN �?TCX**（ingress `ingress_rev_snat` / egress `egress_snat`）。同 hook �?TCX 先于 classic | 上一�?`bpftool net show` 实测 + 本轮 closure 复现 |
| F7 | honk 文档明确写了**内核直连 offload**：`RoutingMeta` bit 57 `OFFLOAD`；`Direct` 模式 "normalize every non-`must`, non-`block` flow to `direct` and offload it"�?No flow is sent to userspace merely because its policy is compiled." | honk `doc/en/design/datapath.md` §Route-time direct offload、`routing.md` |
| F8 | 哪些直连**�?* offload：非 `must` �?*域名终局性未�?*的直�?�?`ControlPlaneRouting`（进用户态嗅�?SNI�?| honk `doc/en/design/routing.md` §Compiled routing decision plane |

---

## 2. 机制：为什�?代理就不能加�?是误�?
### 2.1 honk �?决策在内核、代理在用户�?，不�?什么都进用户�?

honk �?`routing` 策略不是用户态解释执行的规则表，而是**编译成一�?eBPF 函数**
（`RoutingInput -> RoutingDecision`，装�?`ROUTING_POLICY_ROOT` map-in-map �?`slot0/slot1`），�?`lan_ingress_l2` �?TCX �?*同步调用**。（上游文档�?
判定结果只有三种去向�?
```
LAN 客户端包 �?br-lan TCX (honk lan_ingress_l2)
                 �? �?内核编译策略判定
                 ├─ proxy            �?重定向进 dae0 �?dae0peer �?bpf_sk_assign
                 �?                     �?daens 里的透明监听 �?用户态代�?                 ├─ direct(must)     �?交回主机路由（native direct）★ 内核里跑�?                 └─ direct(�?must，域名未�? �?ControlPlaneRouting �?也是用户�?```

（`dae0`/`dae0peer` �?netkit/veth 对，回复�?`dae0_ingress` 换回 MAC 后送到 br-lan。）

### 2.2 按流分区的归属矩�?
| 流的种类 | honk 判定 | honk 动作 | dpd 是否参与 | 状�?|
|---|---|---|---|---|
| CN IP / CN 域（`geoip:cn`�?| `direct(must)`，终止、不嗅探 | native direct（交回内核） | **应该参与并加�?* | **待测（O-1�?* |
| 被代理域名（�?`ipinfo.io`�?| proxy | `dae0` �?用户�?| 不参与（合理�?| 上游文档 + 上一轮实测一�?|
| �?CN、域名未定（�?`ifconfig.me`�?| `fallback: direct`，非 must、域名终局性未�?| ControlPlaneRouting �?用户态嗅�?| 不参与（**这是可优化处**�?| 上游文档，解释了我们上一轮的观测 |
| `:53` | �?honk �?DNS 归属策略 | 视策�?| dpd �?`dns_skip` 主动让路 | 已实�?|

### 2.3 我们上一轮的观测为什么是"正常�?

上一�?closure �?honk 打开后的三条流是�?
```
client DIRECT  https://ifconfig.me/ip   �?�?CN、域名未�?�?fallback �?用户�?client PROXIED https://ipinfo.io/ip     �?代理域名       �?用户�?client DIRECT2 https://ifconfig.me/ip   �?同上
```

三条**全部**落在"必然进用户�?的两类里 �?dpd �?`pkt_total/neigh_ok` 当然不涨�?结论"dpd 原地待命"没错，但�?*只覆盖了 honk 会拿走的那部分流�?*，不能推�?"直连流量也不能加�?�?
对照证据�?*本轮 closure �?C 段（honk 未启动）** 用同样的客户端取 `ifconfig.me/ip`�?`neigh_ok +14`、`eth1_tx +9630` —�?说明计数器本身是灵敏的，差别只在"honk 在不�?�?
---

## 3. landscape 的做法（这是我们要找�?决策平面"�?
landscape 的架构一句话�?*"DNS plane decides. Kernel enforces."**

| 它的机制 | 它的实现 | 我们的现�?| 可借鉴�?|
|---|---|---|---|
| **DNS 答案填充内核 map** | 每个 flow 一条独�?Hickory DNS 实例；答案写进该 flow �?eBPF map | honk 自己�?DNS 嗅探/学习（F7/F8），�?*和我们的 dnsmasq→SmartDNS 链是什么关系没验证�?* | **�?*（见 O-3�?|
| **内核�?map 分流** | XDP/TC �?map，命中就按策略走�?*其余流量直接穿过，不进用户�?* | 我们已经是这个形状（honk 编译路由 + dpd�?| 已有 |
| **把命中的流转给代�?* | `tproxy.bpf.c`：`bpf_skc_lookup_tcp`/`bpf_sk_lookup_udp` 找到透明监听 �?`bpf_sk_assign(skb, sk, 0)` + `bpf_skb_change_type(PACKET_HOST)` + `skb->mark=1` | honk 内部同样�?`sk_assign`（F1），**不需要我们做** | 已有（但要理解） |
| **geo 库（DAT/TXT）灌�?map** | 自建 geo 索引 | honk 自己�?`geoip.dat`/`geosite.dat` | 中（O-7 才用得上�?|
| **MSS clamp 在内�?* | `tc_mss.bpf.c` / `xdp_mss.bpf.c` | **我们没有**（F5�?| **�?*（O-4�?|
| **NAT 目的锁定 + 按域/�?IP 全锥例外** | 默认 stricter-than-symmetric，PCDN/BT 例外开全锥 | 我们全线全锥（红线） | 中（O-6，安全口径） |
| 独立 DNS/策略 per flow、容器重定向、REST API | �?| 不需要（我们只有一�?LAN�?| �?|

**关键差别**：landscape �?代理"（Docker 容器）是**它自�?steering 的下�?*，所以它�?保证"只有策略命中的流才进用户�?。我们的"代理"�?honk�?*steering 也归 honk**�?这一条决定了 O-8�?*不要试图�?honk 前面再插一层我们自己的判定**（除非能证明
我们�?direct �?�?honk �?direct 集，�?O-8）�?
---

## 4. chawrt 的做法（结论：方向不同，不抄�?
chawrt（liudf0716）的卖点是：**eBPF 智能流控**（单机限速、时间策略、FastPath�?
**xDPI**（七层协议识�?合规审计�? apfree-wifidog 认证 + xfrpc 内网穿透�?
| 它的东西 | 我们的对�?| 结论 |
|---|---|---|
| eBPF 单机限�?时间策略 | CAKE（`kmod-sched-cake` 已在镜像，`router-qos`�?| **不抄**：两套限速器会互相打架，CAKE �?per-host fairness + 流隔离比朴素�?eBPF 令牌桶好 |
| FastPath | 我们�?dpd | 已是同一思路 |
| xDPI 七层识别 | honk 自己嗅探 SNI 做分流（F4/F7�?| **不抄**：第二套 DPI 只是重复解析，且会成为代理判定的第二�?真相�? |
| xfrpc 内网穿�?| 不在本项目范�?| 不抄 |

chawrt 值得学的只有一�?*工程态度**：把"谁在什�?hook 上、什么顺�?当一号证�?（它�?aw-bpf 性能对比就是这么做的）——这也正是本轮实验的设计方式�?
---

## 5. 优化方向（按优先级）

### O-1【P0，实验】证�?证伪"共存"

`build/qemu-honk-dpd-coexist.sh`（已写好、`bash -n` 通过、未运行）。对同一条客户端链路
取三种流，每条流三个独立见证�?
| 见证 | 手段 | 说明 |
|---|---|---|
| dpd 有没有拿到包 | `dpdctl stats`（`pkt_total/neigh_ok/redirect_ok`�?| 加速器视角 |
| honk 用户态有没有拿到�?| **`/sys/class/net/dae0/statistics/tx_packets`** | 用户态路径视角（关键鉴别器） |
| 客户端有没有被服�?| http code / 出口 IP | 端到�?|

判据�?
| 编号 | �?| 预测 | 若成立说�?|
|---|---|---|---|
| P0 | honk 关，CN IP 字面�?| dpd �?| 计数器灵敏性对�?|
| **P1** | **honk 开，CN IP 字面量（`direct(must)`�?* | **dpd �?�?dae0 不涨** | **共存成立：代理在跑，直连照样�?dpd 加�?* |
| P2 | honk 开，CN 域名 | dpd �?�?dae0 不涨 | DNS 学习�?OK |
| P3 | honk 开，被代理�?| dae0 �?�?dpd 不涨 | honk 拥有它（合理�?|
| P4 | honk 开，非 CN 未定�?| dae0 �?�?dpd 不涨 | 嗅探缺口（O-3 的靶子） |

### O-2【P0，配置】让直连判定更常"终局"

honk 只在**域名终局性确�?*时才 offload 直连（F8）。�?前缀里有没有 live �?domain
谓词"是决定性的：`fallback: direct` �?*前缀 = 全部规则**，只要有一�?`domain(...)`
规则存在，fallback 就永远不终局 �?所有未知域名连接都进用户态�?
- **可做**：出厂配置里�?`domain(geosite: cn) -> direct` �?`dip(geoip: cn) -> direct(must)`
  **高度重复**，却�?fallback 不终局。去掉它（或改成不依�?domain 的写法）可以�?  "�?CN 的、无域名规则的直�?也回到内核。代价：CN 域名落在�?CN IP 上的少数情况
  会失�?按域名直�?的兜底�?- **注意**：只要用户策略里�?代理域名列表"（如 `domain(suffix: ipinfo.io) -> proxy`），
  fallback �?*必然**不终局 —�?内核不可能在不嗅探的前提下知道某个域名不在代理列表里�?  这不是缺陷，是信息论。所�?O-3（把域名事实喂给内核）是真正的解�?
### O-3【P0，DNS 平面】让 honk 真能拿到域名事实（最大杠杆）

如果内核里有"这个 IP 对应哪个域名/哪些域谓�?的事实，`domain(geosite: cn)` 这类规则
就能在内核直接判�?�?verdict 终局 �?**直连 offload、代理也少一次往�?*�?
现状**未验�?*的点：LAN �?DNS �?`dnsmasq(:53) �?SmartDNS(127.0.0.1:6053)`（我们自己的
`router-dns` 包），�?honk �?`dns.routing.request` 说明�?*本意是接�?LAN DNS**�?谁真正回答客户端、honk 学不学得到，**没测�?*�?
- **先测**：客户端解析一�?CN 域名，看 honk 的连接表/日志里有没有该域名对应的事实
  （harness �?`api.sh` 段已打印 `/connections` �?honk 日志）�?- **若要�?*：把 `:53` 的所有权交给 honk，让 honk 的上游指�?SmartDNS
  （`127.0.0.1:6053`），形成 `客户�?�?honk(学习+分流) �?SmartDNS(缓存/优�? �?上游`�?  收益：内核域名事实完整；SmartDNS 的能力保留。代价：DNS 关键路径多一跳，honk 挂了
  要能回落（dnsmasq 直接�?SmartDNS �?223.5.5.5）�?- **不改的后�?*：如 P4 —�?未知域名直连全部走用户态，�?代理就不能加�?的体感一致�?
### O-4【P1，数据面缺陷】加速路径没�?MSS clamp

**实测 F5**：`mtu_fix` 在（fw4 会给**转发**流量 clamp），�?*dpd 的加速路径根本不�?netfilter forward**（FIB + `bpf_redirect_neigh` 直接�?WAN），�?dpd 自己不做 MSS�?einat 的注释也�?MSS 明确推给 firewall。结果：

- 不加速的转发：MSS �?clamp �?- **dpd 加速的转发：没�?clamp �?* —�?客户端按 1500 通告 MSS，PPPoE(1492)/隧道
  WAN 上要�?PMTUD 兜；一�?ICMP frag-needed 被挡，就是大包黑洞（小包正常，最典型�?  "网页能开、下载卡�?）�?
修法：在 dpd 里对 TCP SYN / SYN-ACK �?clamp（landscape �?`tc_mss` 同款），
按出�?MTU �?头长算，两个方向都要。优先级 P1，因为它**只影响加速路�?*�?而加速路径正是我们要推广的东西�?
### O-5【P1，隧道侧】代理流量的外侧腿：BBR + socket 缓冲

代理流的**里侧�?*（客户端 �?honk）注定过用户态，拿不回性能；能优化的是
**外侧�?*（路由器 �?真实节点的那�?TCP）：

- 内核**没有 BBR**（F4，只�?cubic）。国际线�?+ 丢包下这是实打实的吞�?时延损失�?  �?`CONFIG_TCP_CONG_BBR=y`（内�?config 片段）并�?`default_qdisc=fq`�?  还要�?honk �?`auto_config_kernel_parameter: true` 到底设了哪些 sysctl（别互相覆盖）�?- `net.ipv4.tcp_rmem/wmem`、`net.core.rmem_max/wmem_max` 拉高（大带宽×�?RTT �?  BDP 需求），以�?`tcp_notsent_lowat`�?- 这是"代理�?唯一能拿到真实收益的方向：加密与用户态拷贝拿不掉，但拥塞控制能换�?
### O-6【P2，可选】NAT 目的锁定（landscape �?NAT 细节�?
landscape 默认"目的锁定"（同一内部端点只允许第一个外部目的），按�?�?IP 开全锥例外�?用来�?PCDN 端口消耗。我们的红线�?*全锥必需**（BT/PT/游戏），但可以加一�?**例外�?*：对指定集合（如 PCDN 对端）使用目的锁定，其余全锥。属于安�?隐私口径�?不是性能，排在后面�?
### O-7【P2】我们自己的"DNS �?map"平面

landscape 的核心能力。对我们来说它的价�?*不在 honk 在的时�?*（那�?honk 自己判定�?我们去抢判定只会制造不一致），而在�?
- honk 不在时，dpd 的加速策略可以从"`policy allow_all` 全加�?升级�?按域/按集合分�?�?- �?O-2 �?子集证明"提供数据源（�?*同一�?* geo 数据与配置生成，保证我们�?direct
  �?�?honk �?direct 集）�?
先做 O-1/O-3；O-7 是它们结论确定后的延伸，不要抢在前面�?
### O-8【明确不做】在 honk 前面插我们自己的 TCX 判定

技术上是可行的（F2：`BPF_F_BEFORE` + `relative_id` 都在），�?*不建�?*�?
- 一旦我们抢�?honk 前把某个包发走，honk 就永远看不到这个流；**回复方向**也会变成
  我们拥有（honk �?`lan_egress` 会看到它没建过状态的回复包）�?两个真相源�?- 判定不一致的后果�?*代理泄漏**（该代理的直连了）�?- 唯一可接受的形式�?同源配置 + 子集证明"，收益却只是"honk 本来就会 offload 的那部分",
  除非 O-1 证伪（P1 不成立）。所以：**�?O-1 的结�?*�?
### O-9【文档化】UDP 精度 vs 裁掉 NFQUEUE（既有取舍，如实写）

honk README 明确：`nfqueue_enable: true` �?holders ambiguous LAN-forwarded first
packets before conntrack/NAT"；关掉它是我们的裁剪（`docs/honk-nfqueue-trim.md`），
换来的是不依�?`nfnetlink_queue` �?netfilter�?*代价**：含糊的 UDP 首包不再�?扣住"�?部分 UDP/QUIC/游戏流量的分流精度可能下降。这条已经存在，缺的是把它写进交付说明，
并给�?如果 UDP 分流不准，先怀疑这�?的排查路径�?
---

## 6. 待跑的实验与判据（本轮就绪）

1. **`build/qemu-honk-dpd-coexist.sh`**（已上传、语法通过）：O-1 �?P0–P4 矩阵�?   判据�?§5 O-1�?*必须�?closure 跑完之后单独�?*（独�?tap/QEMU）�?2. closure �?C3 段已经证�?`dnsmasq �?SmartDNS` 是真的转发（拔掉 SmartDNS 就不解析）�?   O-3 需要补的是�?*honk 能不能看到这些解�?*（`api.sh` 段）�?3. O-4（MSS）：先确认现状（`nft list ruleset | grep mss` 在加速流上是否真的不生效），
   再决�?dpd 内实现�?
---

## 7. 风险与未�?
| # | 风险/未决 | 处置 |
|---|---|---|
| R1 | honk �?`direct offload` 是否也适用�?LAN→WAN �?*所�?* `direct(must)`（本实验只覆�?IPv4 TCP�?| P1/P2 只覆�?IPv4 TCP；UDP �?IPv6 另测 |
| R2 | P1 �?*不成�?*（dae0 也涨 / dpd 不涨），说明 honk �?offload 与它文档不一致，或我们对 TCX 顺序的理解有�?| 立刻改为�?`bpftool net` + honk 日志 + 内核 `tracepoint` 三条证据 |
| R3 | `dial_mode: domain` �?honk �?域名真实性检�?，可能把更多流推给用户�?| O-3 定论后再评估是否�?`ip` |
| R4 | �?DNS 所有权（O-3）是全链路关键路�?| 必须带回落：honk 不在�?dnsmasq 直接�?SmartDNS/上游 |
| R5 | BBR �?honk �?`auto_config_kernel_parameter` 互相覆盖 | 先读 honk 究竟设了什么，再决定谁�?sysctl |
| R6 | 两条朝向"更多 offload"的改动叠加（O-2 + O-3）后，代理泄漏面变大 | 每次只改一条，P3/P4 必须复测（代理域仍走代理�?|

---

## 8. 定向实验的结果（2026-10-18 01:47�?1:58，`build/qemu-honk-dpd-coexist.sh`�?
**这个实验�?§2 �?按流分区"证伪了�?* 原始日志�?`/opt/wrt/logs/qemu-coexist-run.log`（harness�? `/opt/wrt/logs/qemu-coexist.log`（控制台）�?
### 8.1 数字（全部来自这套镜�?+ 真实节点 `37.123.192.246`�?
| �?| 流量 | dpd `pkt` | dpd `neigh` | `dae0 tx` | `eth1 tx` | 应用�?| 判定 |
|---|---|---|---|---|---|---|---|
| P0 | honk **�?*，CN IP 字面�?`103.235.46.96`（`--resolve`，SNI=baidu�?| **+38574** | **+16** | +0 | +38228 | curl (28) 超时 | �?对照组：dpd 确实能看到并加�?|
| P1 | honk 开，同一 CN IP �?应命�?`dip(geoip:cn) �?direct(must)` | **+0** | **+0** | +0 | +389 | curl (35) TLS connect error | �?**没被 dpd 看到** |
| P2 | honk 开，CN 域名 `www.baidu.com`（走 DNS�?| +0 | +0 | +0 | +770 | curl (6) 域名解析失败 | �?没被 dpd 看到（且 DNS 本身失败�?|
| P3 | honk 开，`ipinfo.io` �?应走代理 | +0 | +0 | **+0** | +354 | 出口 IP = **37.123.192.246**（节点） | 代理**成功**，但 dpd 没看�?|
| P4 | honk 开，`ifconfig.me`（非 CN，fallback direct�?| +0 | +0 | +0 | +354�?271 | 出口 IP = 113.194.4.185 | 直连**成功**，但 dpd 没看�?|

harness 自己的汇总：**PASS=12 FAIL=4**�?
### 8.2 从这个结果能说什么、不能说什�?
**能说的（实测）：**

1. **honk 在跑的时候，dpd �?classic ingress 过滤器在 `br-lan` 上一种流都看不到** —�?包括
   `dae0` 也不涨。对照组（P0）在同一个目的地址�?dpd +38574，所以不�?目的地址不可�?
   造成的计数器�?0，而是**honk �?TCX 层在这些包到达我们的 classic 链之前就把它们处理掉�?*�?2. honk 的日志给出了机制线索�?*实测**）：
   `INFO honk_core: Using eBPF TC redirect datapath (tproxy_mark=0x8000000)` +
   `dae0peer_ingress attached and link held`。它自己的说法是 TC **redirect** datapath：入�?   TCX 把包 redirect 进自己的管线（带 `0x8000000` mark），于是**根本不会再回到同一设备上的
   classic ingress �?*�?3. **`dae0 tx` 不能当作"honk 用户态接�?的见�?*：P3 的代�?*确实成功�?*（出口是节点 IP），
   �?`dae0 tx` 依然�?+0。所以本�?§1 F 表里�?`dae0` 当判别器�?*错的**，上一�?closure
   用同一个判别器得出�?直连流没�?honk 用户态、只�?dpd 没数�?的结�?*同样不可�?*（那�?   结论现在既没有正面证据也没有反面证据）�?4. P2 的失败是**另一个平�?*的问题（不是本条结论）：honk 接管�?DNS（策略里 `!dport(53)` 就是
   为它留的），而它的上游直�?DoH 失败 —�?`WARN honk_core::control::dns_control: DNS controller
   forward failed; sending SERVFAIL ... upstream 'default' failed via 223.5.5.5:443`。客户端因此
   `Could not resolve host`。这�?O-3（DNS 平面）直接相关，需要单独查�?5. P3/P4 说明**数据面本身是通的**（代理出口正确、直连出口正确）—�?被证伪的�?dpd �?honk 按流
   分工"，不�?代理能不能用"�?
**不能说的�?*

* 不能断定"一定是 honk �?TCX redirect 导致 dpd 看不�?（这是最符合证据的解释，但没有直接抓�?  一�?redirect 事件；要定论得在 honk �?TCX 程序返回点打 tracepoint，或在它前面挂一个只计数�?  探针 TCX）�?* 不能断定"direct(must) �?honk 里是在内核完成还是去了用户�? —�?dae0 见证失效后，我们**两个
  方向都没有证�?*�?
### 8.3 因此修正的结�?
* **§2.2 的归属矩阵作�?*�?`direct(must)` �?内核直连 �?dpd 加�?这一格没有实测支持）�?  实测是：**honk 一开，`br-lan` 上的加速层就让位给 honk �?TCX redirect 管线**�?  "代理 + 加�?�?*当前挂法**下不是按流分区，而是**整体让位**�?* 用户最初那句话�?加速就不能代理、代理就不能加�?�?*比我们文档读出来的结论更接近事实**�?  尽管原因不是"honk 把一切都送进用户�?�?* **O-8（不要在 honk 前面插我们自己的 TCX）依然成立且更必要了**：dpd 抢在 honk 前判定会破坏
  honk 的域�?终局性判定（它需要看到流才能决定 direct/proxy）�?*�?honk 之前插入是不安全�?*�?* 真正可走的只有两条，且都要实测：
  * **B（接受现状）**：honk 在跑时，`br-lan` 上的加速归 honk 的内核直连路径；dpd 只在 honk
    不在（或不在它挂的设备上）时生效。代价：我们自己的加速在有代理时等于不存在�?  * **C（换方向：WAN 入口�?*：`eth1`/`pppoe-wan` �?**ingress** �?honk 没有钩子（实�?    `bpftool net show` 只有 `eth1 clsact/egress acl_egress`，那是我们的 ACL），einat �?TCX �?    我们�?classic 过滤器在 TCX 之后可以并存。下载方向的加速（WAN→LAN�?*不经�?honk 的判�?*
    （回程包的目的地是内网，不属�?honk 的策略域），这条路上 dpd 有可能真正常驻。代价：这是
    **另一个功�?*（下载侧加速），要重新设计门禁与自证，且必须证明它不会碰代理流的回程�?* **下一轮最小实�?*（能一次定论的）：
  1. �?`eth1`/`pppoe-wan` ingress 挂一�?*只计�?*的探针（`tc filter ... bpf da`，或
     `bpftool` �?tracepoint 统计），�?P0–P4，看**下载方向的回程包**有多少能到达 classic 链；
  2. 对照 `bpftool net show` + `honk /connections`（这�?API 登录没拿�?token�?     `login token: <none>`，需要先�?`system.dae` �?`password_auth` 口径）；
  3. 只在 1 有正结果时，才谈 C 方案的实现�?
---

## 9. 第二�?+ 第三轮：honk 在跑时的 DNS 与锚点，实测收口�?026-10-18 02:4x�?4:0x�?
�?8 节留下的两个问题，这一轮都拿到了答案：

1. honk 一开，我们自己的 classic 加速层还有没有"锚点"可用�?2. P2 �?DNS 失败，是"honk 抢了 DNS"还是别的原因？把 DNS 还给内核之后�?   客户端和路由器自己能不能解析**�?*名字�?
> 方法论先说清楚，因为�?8 节的教训正是这个�?*必须用本次开机从未查过的名字**�?> dnsmasq �?smartdns 都有缓存，重查一个已经查过的名字，DNS 平面坏成什么样都会
> 给答案。第 8 �?修好�?的读数，就是缓存给的�?
### 9.1 锚点：没有。加速层让位是结构性的，不是概�?
honk 起来后的实际 hook 表（`bpftool net show`，本质镜�?+ 真实节点 `37.123.192.246`）：

```
eth0(2)   tcx/ingress  lan_ingress_l2      prog_id 80 link 15
eth0      tcx/egress   lan_egress_l2       81/16
br-lan(6) tcx/ingress  lan_ingress_l2      80/11
eth1(3)   tcx/ingress  ingress_rev_snat    31/3     <- einat
eth1      tcx/ingress  wan_ingress_l2      83/14    <- honk
eth1      tcx/egress   egress_snat         32/4     <- einat
eth1      tcx/egress   wan_egress_l2       82/13    <- honk
eth1      clsact/ingress acl_ingress id 47          <- router-acl（classic�?eth1      clsact/egress  acl_egress  id 52          <- router-acl（classic�?br-lan    clsact/ingress dpd_fastpath id 57 pref 100 <- dpd（classic�?```

也就是说�?*我们�?classic filter 的每一个设备（br-lan / eth0 / eth1），honk 都在
TCX 层挂了程序，而且两个方向都挂�?* 再叠加内核语义（`linux-6.18.55/net/core/dev.c`
�?`sch_handle_ingress()`）：

```c
if (tcx_needed) {
        sch_ret = tcx_run(skb, ...);
        if (sch_ret != TC_ACT_UNSPEC)
                goto ingress_verdict;   /* 整条 classic 链被跳过 */
}
sch_ret = tc_run(...);                  /* 我们�?filter 在这�?*/
```

**任何一�?TCX 程序给出�?UNSPEC 判决，同一设备同一方向的整�?classic 链就整个被跳过�?*
honk 对直连流也返回非 UNSPEC（第 8 节实�?+ 本轮 br-lan ingress �?dpd 计数 +0），
所�?honk 没接的包才轮到我�?这句话的真实含义是：**honk 在跑时，我们的加速层看不到任何流量�?*

结论（已�?dist 里落地）�?*不做"按流分工"的幻想，做诚实门禁�?*
`dpd-fastpath.sh` �?`dpd_honk_owns()` �?`bpftool net show` 匹配 honk 的程序名
（`lan_ingress_l2|lan_egress_l2|wan_ingress_l2|wan_egress_l2|dae0_ingress`），
命中就把加速模式降级成 `observe` 并在日志里写明原因。失败方向是安全的：
丢掉的是"加�?，不�?转发"；代理在跑时，数据面就是 honk 的�?
honk 不是我们的服务（它从自己�?UI 起停），所以门禁不能只�?开�?/ einat 事件"
触发。`/usr/libexec/dpd-gate-watchdog`（procd 的第二个 instance�?0 s 轮询�?只在"所有权变化"时重算一次并把结果写进日�?—�?实测 closure �?honk 起得晚，
没有它时 dpd 会一直报 `stateless` ✗；有了它，honk �?�?`observe`、honk �?�?`stateless`，各自一条日志�?
### 9.2 DNS：第 8 节的"修好�?是缓存，冷名字才是判�?
每一行都用本次开机从未查过的名字。策�?A = 我们现在发布�?（`dport(53) -> direct(must)` 插到最�?+ honk 自己�?`dns.upstream.default`
指向 smartdns）；策略 B = �?LAN 源地址�?:53 放行、其�?:53 交给 honk 代理�?
| 场景 | 客户�?by-name（冷�?| 路由�?`nslookup �?223.5.5.5` | 路由�?`nslookup �?127.0.0.1`（dnsmasq→smartdns�?| 本地 TCP `curl http://223.5.5.5/` |
|---|---|---|---|---|
| honk **�?*（对照） | �?200/501 | �?有答�?| �?有答�?| �?404 |
| honk 开，策�?A | �?`Could not resolve host` | �?超时 | �?超时 | �?404 |
| honk 开，策�?B�?53 �?proxy�?| �?`Could not resolve host` | �?超时 | �?超时 | �?404 |
| honk 开，策�?A + **smartdns 上游�?DoT** | �?**200**（smzdm / dianping / zol 三个冷名字） | �?仍超�?| �?有答�?| �?404 |

从这张表能说清的�?
* **转发流量没问�?*：客户端 �?路由器的 :53 �?honk �?`direct(must)` 放行，dnsmasq
  收得到、也答得出（�?8 节和本轮都测到）�?* **honk 自己�?socket 没问�?*：它带自己的 mark，不受自己的 datapath 影响�?* **路由器自己发起的 UDP 完不�?*：直连（`direct(must)`）和代理（`-> proxy`�?*都一样超�?*�?  所以这不是策略问题，是传输问题�?* **同一地址的本�?TCP 正常**（`curl http://223.5.5.5/` �?404）�?* 因此�?smartdns 的上游换�?**DoT（TCP/853，带证书主机名）**，整条链就活了：
  冷名字经 LAN 客户端拿�?200；honk 关掉�?DoT 同样可用 —�?两种状态只有一种传输�?* 仍然不通的�?路由器直�?`nslookup 223.5.5.5`"：那�?honk 对本�?UDP 的限制�?  **我们不去绕它**（实测绕不过去：策略 B 的代理路径也失败），DNS 平面不再依赖它�?
### 9.3 因此 dist 里是**两半**，各修一�?
1. `/usr/libexec/router-honk-dns`（由 `router-dns.init` �?honk �?S95 之前调用）：
   �?LAN �?:53 还给内核/dnsmasq，honk 自己的上游指�?smartdns�?   **必要但不充分** —�?它只解决"honk �?DNS"�?2. `/etc/uci-defaults/97-mydist-dns`：smartdns 上游改成 DoT
   （`223.5.5.5` = `dns.alidns.com`，`119.29.29.29` = `dot.pub`，两路并发）�?   这是"冷查询真的能出网"的那一半�?3. `dpd-fastpath.sh`：honk 占着 TCX 时降�?`observe`�?.1）�?
只做 1 的效果是"缓存还在时一切正�?，只�?2 的效果是"客户端仍然解析不�?�?53 还在 honk 手里�?。两条必须一起�?
### 9.4 honk 自己的操作坑（不是我们的 bug，但会咬人，写进文档�?
* `honk stop` 之后 `dae0` / `daens` 有时残留，下一�?`start` 直接拒绝�?  `honk: dae0 already exists` / `honk: daens network namespace already exists`�?  恢复办法：`ip netns del daens; ip link del dae0` �?start�?  本轮就是这么�?honk 救回来的（`build/dns2-dot2.sh`）�?* `control.sh initialize` �?**stdin �?JSON** `{"username":"�?,"password":"�?}`
  （密�?8�?12 字节）。用 `printf '{\"username\":…}'` 这种二次转义喂给它，会得�?  `{"ok":false,"message":"invalid_credentials"}`，而随后的 `start` 只报
  "package must be explicitly enabled and initialized" —�?症状和原因离得很远�?  测试台踩过一次，注释留在 `build/qemu-honk-dns2.sh` 里�?* `initialize` 会先起一�?mock honk-core 验证配置，失败报 `mock_core_start_failed`�?  同一台机器上有残留资源时报的是别的错（先�?`honk: …` 那行）�?* 启动后约 90�?00 s 节点才健康。此�?代理流失�?是正常的，别当成数据面坏了�?
### 9.5 还没解决的（写进已知限制�?
* honk 在跑时，路由器自身的**�?DNS UDP**（NTP、WireGuard 客户端、QUIC）同样出不去�?  这是 honk 的数据面行为，我们不�?dist 里绕（绕不过�?.2 的代理路径也失败）�?  开 honk 之前应当知道这件事�?* honk �?TCX �?einat �?TCX 同在 eth1 上，两者之间的先后顺序（按 link 顺序）本轮没�?  单独确认；本轮只涉及 LAN 侧结论�?* 真实硬件仍是 0 次验证（�?6 节的限制没变）�?
### 9.6 复现

* `build/qemu-honk-dns2.sh` —�?策略阶梯 + 冷名�?+ bpffs/规则/日志取证（自�?`DRYGEN=1` 自检）�?* `build/inject-cons.sh` + `build/dns2-matrix.sh` / `build/dns2-dot*.sh` —�?  往一个已经启动的 VM 的控制台 FIFO 里直接注入命令，省掉每次 8 分钟�?TCG 启动�?  本轮 9.2 的表就是这套跑出来的�?* 证据日志：`/opt/wrt/logs/qemu-honk-dns2-{run,console,matrix,dot,dot2,dot3}.log`�?
### 9.7 落到镜像后的验收（round-8，feed `1f8e721` / 镜像 `08:10`�?
| 用例 | 结果 | 判据 |
|---|---|---|
| `qemu-closure.sh` | **37/37** | �?honk 在跑�?dpd 诚实停在 observe" |
| `qemu-honk-dns-accept.sh` | **22/0** | 唯一失败�?外网直连抓取"——本 guest 到多数境外站点不可达（QEMU 环境），不是数据面问题；DNS 全部冷名字通过 |
| `qemu-pppoe-func.sh` | **20/0** | einat 挂上 `pppoe-wan`、客户端�?*送达对端**（对端访问日志为证）、dpd **真的发射�?*（`fib_ok 9 / redirect_ok 9`），`redirect=dev\|neigh\|auto` 三档都能送达 |
| `qemu-tuning-audit.sh` | 值全�?| 审计 dump �?`default_qdisc fq` / `tcp_congestion_control bbr` / `tcp_mtu_probing 1` / `netdev_max_backlog 8192` / `packet_steering enabled` 全部落地 |

accept harness 里最关键的三行（同一�?VM、shipped 配置、未注入任何东西）：

```
@@@P_dot=2      server-tls 223.5.5.5:853 -host-name dns.alidns.com
@@@U_cold=...   www.ctrip.com -> 有答�?         （honk 在跑，冷名字�?@@@U_mode=observe                                （门禁降级，日志里有原因�?```

**验收里抓到的最后一个真 bug（值得记下来）**：第一�?DoT 配置写成�?
```sh
uci -q set "smartdns.$section.type='tls'"     # �?uci 把单引号当值的一部分
```

于是 `uci show` 里是 `type=''\"'\"'tls'\"'\"''`、smartdns init �?`[ "$type" = "tls" ]` 永远不成立，回落�?UDP —�?镜像"看起来配�?DoT"�?冷查询依旧只有缓存能答。正确写法是 `uci -q set "smartdns.$section.type=tls"`
（外层已经有一对引号，值里再写引号就会被存进去）�?
### 9.8 PPPoE：加速发射是 **FIB 查询**的问题，已修好（2026-10-18 11:4x�?
第一�?PPPoE 验收�?dpd 只走�?FIB 就停了：`pkt_total 33 / fib_ok 0 / fib_fail 29`�?根因不是 ppp 特殊，而是 **`bpf_fib_lookup()` 默认连邻居一起解�?*：ppp �?`NOARP|POINTOPOINT`，没有邻居表 �?每个包都返回 `BPF_FIB_LKUP_RET_NO_NEIGH` �?一条流都到不了发射阶段�?
修法（ABI 4）：

1. 第一次查询返�?`NO_NEIGH` �?计数 `fib_retry` �?�?   **`BPF_FIB_LOOKUP_SKIP_NEIGH`** 再查一次（只要路由）；
2. 第二次成功即证明"这个出口没有邻居"（`no_neigh`）：发射�?   **`bpf_redirect(ifindex)`**，不�?`bpf_redirect_neigh()`；这个事实随流记�?   （`dpd_flow_val.flags = DPD_FLOW_F_NO_NEIGH`），Mode B 的快捷路径同样正确；
3. `bpf_redirect_neigh()` 失败时不再把 helper 的负 errno 当返回值（TC 只认
   `TC_ACT_*`），改成 `TC_ACT_UNSPEC` 交回协议栈�?
实测（bare QEMU + 宿主 `pppoe-server`，客户端 ping + HTTP）：

```
deltas over the flows: pkt_total=16 fib_ok=9 fib_retry=3 redirect_ok=9 neigh_ok=0
pppoe-wan tx_packets +33   peer access log: 1 hit   http code=200   ping rc=0
```

**ppp 出口上的 `bpf_redirect()` 是能送达的�?* 我一开始从
`ppp_start_xmit()` 的源码推�?Ethernet 头剥不掉 �?会发垃圾�?，实测否定了这个推断
（记在这里，免得下次又按推断改坏）。`redirect=neigh` �?ppp 上仍然不可用（没有邻居）�?所�?`auto` �?无邻�?这个事实�?dev�?
�?PPPoE 无关但同样咬人的两点：ppp 设备�?`state` 永远�?`UNKNOWN`（要�?`<...,UP,LOWER_UP>` 标志位，harness 一开始按 `state UP` 判，误报过一次）�?`firewall` �?`mtu_fix` �?**zone** 上而不�?`@defaults[0]` 上�?
顺带一�?procd 的坑：`start_service` �?`fork` 出来的守护进程会�?失败实例�?cgroup 清理"杀掉（第一�?einat �?WAN 等待者就是这么消失的，日志只有一�?`no external device yet` 然后什么都没有）。等待者现在是 procd 的一个实�?（`/usr/libexec/einat-wait-wan`），并且**优先用内核事�?*�?WAN�?`/proc/net/route` 里带 `0003` 标志的默认路由接口，不经�?ubus/jsonfilter
——实测在 procd 环境�?ubus 那几条路会返回空，�?`ip route` 明明是对的�?

