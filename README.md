# DPD 加速系统（dpd-fw）

**DPD = Dynamic Packet Datapath（动态报文数据面）。**

本文统一使用全称简称 **DPD**，产品/系统层面称 **DPD 加速系统**；仓库名 `dpd-fw`
（DPD firmware/dataplane）指它的实现与打包部分。

## 1. 为什么叫 DPD

三个词对应三件事：

- **Dynamic（动态）**：加速不是全局开关，而是**按流**决定。每条流先由 Flow Manager
  观察，达到阈值后才被数据面接管；链路、地址、路由、邻居变化会让整个流表失效重学，
  流量特征变化时接管参数（priming、TTL、计数采样）会自动调整。
- **Packet（报文）**：干活的单位是报文。在 `tc` ingress/egress 上直接查流缓存、
  改写二层头、`bpf_redirect` 发出去，不经过 netfilter、路由、qdisc 的慢路径。
- **Datapath（数据面）**：它是一条**旁路数据面**，不是新的协议栈。没命中、没学会、
  被门禁拦下的报文原样交回内核协议栈，行为与没有 DPD 时一致。

合起来就是：**一张会自己学习和失效的报文级转发快路径**。所以叫动态报文数据面，
简称 DPD；加上固件/打包这一层，就是 DPD 加速系统。

## 2. 它解决什么问题

OpenWrt 的转发默认走完整协议栈：netfilter/conntrack → 路由 → 邻居 → qdisc。
家宽到千兆以后，这条路径的每包开销开始压在软中断上，而且它和透明代理、硬件卸载
互相抢流。

DPD 的做法是把**已经确认的流**记下来，下一个包直接转发：

```
第一个包（或前 N 个） → 协议栈照常处理（conntrack/防火墙/代理都看得到）
       ↓ Flow Manager 学习、门禁检查
后续报文 → TC eBPF 查流缓存 → 直接改写 + redirect（不再进协议栈）
```

这样防火墙、NAT、代理的策略判断一次都不少，但只发生在流的开头。

## 3. 组成

```
┌──────────────────────────── 控制面 ────────────────────────────┐
│ dpdfwd       流生命周期、ctnetlink、自动调参、epoch、插件宿主  │
│ dpdctl       map / 流表 / 本地地址 / NAT 绑定的命令行           │
│ dpd-napi     NAPI / IRQ / GRO / RPS / XPS / qdisc 调优          │
│ LuCI         状态、简易防火墙、多 WAN、NAPI/DPD 页面            │
└───────────────────────────────┬────────────────────────────────┘
                                │ pinned BPF maps
┌───────────────────────────────┴────────────────────────────────┐
│ TC eBPF 数据面（bpf/core/src/dpd_fastpath.bpf.c）               │
│  classifier/l2   LAN 入口（br-lan / 网桥端口）                  │
│  classifier/l3   WAN 入口（pppoe-wan，downlink=1）              │
│  classifier/nat  WAN ingress（DPD 自有 NAT 时的 DNAT）          │
│  classifier/egress  WAN egress（DPD 自有 NAT 时的 SNAT）        │
└─────────────────────────────────────────────────────────────────┘
```

插件：`dpd-honk`（honk 生命周期与门禁）、`dpd-einat`（NAT 绑定同步）、
`dpd-acl`、`dpd-qos`、`dpd-mwan`、`dpd-observe`。

## 4. 它不是什么

- 不是 XDP/AF_XDP/DPDK，也不接管驱动：只用 `tc` 钩子，x86 和 ARM 用原厂驱动就能跑。
- 不是第二个防火墙、第二个 NAT（默认 NAT 归 einat）、第二个 flowtable。
- 不替代 PPE/NSS/HNAT：同一**条**流不会被两层同时加速，DPD 只接硬件接不住的那部分。
- 不是透明代理：代理归 honk，DPD 只负责把 honk 放行的 direct 流转发掉。

## 5. 数据从哪来、到哪去

- NAT：默认由 **einat**（TC eBPF full-cone NAT）拥有，DPD 只加速它已经正确 NAT 的流；
  einat 绑定与反查必须一致，否则不学习（`nat_gone`）。
- 代理：honk 在 LAN TCX 上做分流，direct 流以 `TC_ACT_UNSPEC` 交回经典 TC 链，
  DPD 就在这条链上接管；proxy/block 仍是终态。
- 硬件：PPE/NSS 卸载后的报文不进 TC，DPD 看不到也不抢。

## 6. 包

| 包 | 作用 |
|---|---|
| `dpd-fastpath` | UFS 流缓存 + `dpdctl` + BPF 对象 |
| `dpdfwd` | Flow Manager（控制面，不碰报文） |
| `dpd-napi` | NAPI/IRQ/GRO/RSS/qdisc 调优 |
| `dpd-einat` | full-cone NAT 绑定与 EIF |
| `dpd-honk` | honk 生命周期与门禁 |
| `dpd-acl` / `dpd-qos` / `dpd-mwan` / `dpd-observe` | 策略、QoS、多 WAN、可观测性 |
| `luci-app-dpd` | 状态与插件页面 |

## 7. 构建与发布

- 源码：`bpf/core`（BPF + dpdctl）、`userspace/*`、`openwrt/*`、`plugins/*`。
- CI（本仓库）：`lint`（BPF/dpdctl 编译、ABI、shell）、`sdk`（用官方 OpenWrt SDK
  出 `dpdfwd / dpd-fastpath / dpd-napi / luci-app-ebpf` 的 apk，不需要整镜像）、
  `einat`（full-cone NAT 二进制）、`honk-core`（direct 流回调经典 TC 链的 honk core）、
  `upstream`（补丁锚点）、`auto-clean`（03:00 清 artifacts 后重建）。
- 固件镜像由 `kwrum1/ebpf-honk-ImmortalWRT-CI` 构建，只从这里下载
  `core-p1` 和 `einat-p2` 两个固定 tag 的产物；IPQ/MTK 镜像完全不依赖本仓库。

## 8. 文档

- [DPD-FW 技术说明（中文）](docs/DPD-GUIDE.zh-CN.md) /
  [Technical Guide (English)](docs/DPD-GUIDE.en.md)：架构、包路径、流生命周期、
  NAT 归属、与 honk/PPE 共存、NAPI、可观测性。
- [ARCHITECTURE.md](docs/ARCHITECTURE.md)：早期设计笔记。
- [OPERATIONS.md](docs/OPERATIONS.md)：运维手册。
- [einat/README.md](einat/README.md)：随 DPD 发布的 full-cone NAT 二进制。
- [honk/README.md](honk/README.md)：honk p1 core（direct 流交还经典 TC 链）。
