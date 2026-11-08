# 三变体 NAT 转发基准报告（x86 / ESXi / vmxnet3）

日期：2026-10-26
实验台：ESXi `10.1.18.124`（2×Xeon，12 核，17 GB），全部虚拟网卡为 **vmxnet3**，
bench 网络使用两台**无上行链路的独立 vSwitch**，与办公网物理隔离。

---

## 1. 结论摘要

1. **stock（纯 conntrack）与 eBPF（einat + dpd）在本实验台上吞吐同一档**：
   TCP 2.3–3.2 Gbit/s、64B 小包 32–36 万 pps，差异小于宿主机噪声幅度（同变体跨轮波动可达 40%）。
2. **固定负载下 eBPF 更省 CPU**：2 Gbit/s 时 28% vs 44%（相对 −36%）；1 Gbit/s 时 9% vs 13%；
   3 Gbit/s 时基本持平（61% vs 63%），此时两边都接近单核瓶颈。
3. **满载延迟 eBPF 更高**（10.5 ms vs 3.4 ms），但两组不是同负载：测 eBPF 时已经跑到 3.2 Gbit/s，
   stock 只有 2.3 Gbit/s，排队更长属预期。要下定论需固定速率重测。
4. **SFE 尚未出数**：Lean 的 shortcut-fe 依赖内核补丁（`sk_buff.fast_forwarded` 等），
   与 OpenWrt 自带的 `952-net-conntrack-events` 补丁在同一文件冲突；已裁剪补丁并重新构建中（见 §6）。

> 一句话：**在这台 2 vCPU 的虚拟机上，加速机制不是瓶颈，vSwitch/vmxnet3/软中断才是。**
> eBPF 的价值不在“跑得更快”，而在 full-cone NAT、per-flow 策略和可观测性。

---

## 2. 三个变体

| 变体 | 固件 | 数据面 |
|---|---|---|
| `stock` | VIKINGYFY/OpenWRT-CI 官方 X86 产物（`26.10.26-07.24.32`，r0-57b6307） | fw4 nftables conntrack + masquerade |
| `sfe` | 同源码 + shortcut-fe / fast-classifier（本次自行构建） | SFE 软件快路径 |
| `ebpf` | mydist v1.0.0（`X86-kwrum1-mydist-26.10.26-08.00.37`，r0-a37c1ea） | einat-ebpf `nat44`（TCX）+ dpd-fastpath（classic BPF，`effective=stateless`） |

两个镜像内核同为 **6.18.55**；stock 的 manifest 中无 `einat/dpd/mydist/honk`，是干净上游。

---

## 3. 拓扑与参数

```
bench-client ──[bench-lan]── router ──[bench-wan]── bench-server
192.168.10.198 (静态)      LAN 192.168.10.1      WAN 198.18.0.1        198.18.0.2
                           mgmt 10.1.18.236（仅串口/管理，无测试流量）
```

- router：2 vCPU / 1 GB；client：3 vCPU / 448 MB；server：2 vCPU / 448 MB；磁盘 NVMe 虚拟盘。
- 管理通道：ESXi 虚拟串口（`ttyS0` → TCP 7101/7103/7105），不依赖 guest 网络。
- **WAN 必须用 198.18.0.0/24**：einat 默认把 `10/8`、`172.16/12`、`192.168/16` 当内网，
  用 10.46.x 做 WAN 会导致 eBPF 变体不做 SNAT，比较直接失效（这是实测踩到的坑）。
- 三个路由变体互斥运行（同一时间只开一台），端点机全程不动。
- 测试项：TCP 单流 20 s、TCP 4 流 20 s、UDP 1400 B 20 s、小包 15 s、ping 10×1 s（空载/满载）。
- 每个变体 3 轮取中位数；路由 CPU 用测试前后 `/proc/stat` 差值。

**小包 pps 的测法**：纯 64 字节 UDP 会被 iperf3 的用户态发包/收包限死
（单进程 ~9.7 万 pps，三进程时服务端丢包约 50%），测到的是端点而不是路由器。
因此改为把两端 MTU 降到 96（MSS 56 ≈ 110 B 帧），用 3 个并发 TCP 流让**内核**驱动小包，
接收路径在软中断里，路由器才会成为瓶颈。测试后 MTU 恢复 1500。

---

## 4. 结果

### 4.1 吞吐 / pps / 延迟（同一天相邻时段的两轮，中位数）

| 指标 | 原版无加速 | mydist eBPF |
|---|---|---|
| TCP 单流 (Gbit/s) | 2.60 | 3.21 |
| TCP 4 流 (Gbit/s) | 2.32 | 3.23 |
| UDP 1400B (Mbit/s) | 990 | 1034 |
| UDP 丢包 | 3.9 % | 4.8 % |
| 小包 pps（MSS 56） | 322 768 | 363 393 |
| 小包路由 CPU | 72 % | 73 % |
| TCP4 路由 CPU | 56 % | 67 % |
| TCP4 单核峰值 | 79 % | 73 % |
| 空闲 RTT (ms) | 2.14 | 2.12 |
| 满载 RTT (ms) | 3.36 | 10.49 |

> **波动提示**：同一变体跨轮差异很大。stock 的 TCP4 在 6 轮里出现过 2.27 / 2.32 / 3.60 / 3.70 / 3.70 / 4.09 Gbit/s；
> eBPF 在 2.54–3.32 Gbit/s。上表只是“相邻时段”的一组，**不能当成精确排名**。

### 4.2 固定负载下的 CPU（每档 3 次取中位数，这是最能说明问题的表）

| 固定负载 | 原版无加速 | mydist eBPF |
|---|---|---|
| 1 Gbit/s | 13 % CPU | **9 %** |
| 2 Gbit/s | 44 % CPU | **28 %** |
| 3 Gbit/s | 63 % CPU | 61 % |

- 1–2 Gbit/s：eBPF 路径每包成本明显更低（2 G 时省 36% CPU）。
- 3 Gbit/s：两者都撞到**单核 72–74%**，说明瓶颈已经转移到软中断/单队列，不再是 NAT 实现。
- 两个变体的“单核峰值”都远高于总 CPU，说明转发主要压在 1–2 个核上，vmxnet3 多队列并没有真正铺开。

### 4.3 小包

- 32–36 万 pps、**0% 丢包**，路由 CPU 72–73%。两者同档。
- 这个数字是**测试台的上限，不是路由器的上限**：client 只有 3 vCPU，iperf3 单进程用户态发包约 9.7 万 pps。
  要压出百万级 pps 需要专用打流器（DPDK/pktgen）或更多 vCPU。

---

## 5. 解读

1. **为什么两种加速几乎一样快？**
   在 2 vCPU 虚拟机里，2–3 Gbit/s 的转发成本主要花在 vmxnet3 收包、软中断、
   `skb` 分配和 vSwitch 上；NAT 查表只是其中一小段。eBPF 省下的那部分，被 TCX/classic 两趟
   BPF 遍历抵掉了大半，所以总吞吐差别落在噪声里。
2. **eBPF 的真实收益是“同负载更省 CPU”**，这在低负载（1–2 G）最明显；
   到 3 G 时已经被单核软中断顶住，省不出来。
3. **CAKE 在本次对比里是关闭的**（eBPF 镜像默认 100 Mbit 整形会把所有变体压到同一水平），
   所以这里衡量的是纯转发数据面。CAKE 的整形精度需要单独测。
4. **延迟**：eBPF 满载 RTT 更高，但两组负载不同（3.2 G vs 2.3 G），不能直接下结论；
   需要固定 2 G 重测才有意义。
5. **SFE 的预期**：SFE 的设计目标是“弱 CPU 上少走协议栈”，在 x86 上通常收益有限；
   真正的对照点是 64 B 小包 pps 和 CPU。等镜像出来会用同一套脚本补测。

---

## 6. SFE 构建记录（未完成）

三次尝试：

1. 直接拉 `coolsnowwolf/lede` 的 `shortcut-fe` + `fast-classifier` → **失败**：
   `sfe_ipv4.c: error: 'struct sk_buff' has no member named 'fast_forwarded'`
   （Lean 的内核树带专用补丁，ImmortalWrt 6.18 没有）。
2. 加入 Lean 的 `953-net-patch-linux-kernel-to-support-shortcut-fe.patch` → **失败**：
   该补丁里 `include/net/netfilter/nf_conntrack_ecache.h` 与 `net/netfilter/nf_conntrack_ecache.c`
   两段和 OpenWrt 自带的 `952-net-conntrack-events-support-multiple-registrant.patch` 冲突。
3. **裁剪版补丁**（只保留 `if_bridge.h`、`skbuff.h`、`net/Kconfig`、`br_if.c`、`dev.c` 五处；
   conntrack 那两段只被 `sfe_cm.c` 使用，而 `kmod-shortcut-fe-cm` 与 `fast-classifier` 互斥、本变体并不构建）
   → 构建中（run `40349480358`）。

CI 里已经落地：
- `Config/X86-SFE.txt`：与官方 X86 完全相同的包集 + `kmod-shortcut-fe` + `kmod-fast-classifier`；
- `Scripts/Packages.sh`：稀疏拉取 Lean 的两个包并放入裁剪补丁；
- `.github/workflows/BENCH-SFE.yml`：手动触发的单目标构建。

---

## 7. 建议

- **家用 x86 / 2.5G 以内**：原版已经够用，mydist 的吞吐不会更快；选它的理由应该是
  full-cone NAT（P2P/游戏/主机联机）、SmartDNS 归属、CAKE 和可观测性。
- **虚拟机/低核数场景**：不要指望 eBPF“提速”，它的价值是 1–2 G 区间更省 CPU 和策略能力。
- **想看到加速差异**：需要 10 G 级网卡直通、更多 vCPU、或专用打流器；当前的 2 vCPU + vSwitch
  组合把三者压在了同一个天花板下。
- **SFE**：在 x86 上大概率与 stock 同档；等镜像出来用同一套脚本验证后补进本报告。

---

## 8. 复现

```powershell
cd C:\路由设计\work\bench
sh switch.sh stock|sfe|ebpf          # 在 ESXi 上切换路由变体
python bench.py <variant> <port> 3   # 吞吐 / pps / 延迟 / CPU
python load.py <variant> <port> 3    # 固定 1/2/3 G 的 CPU 效率
python report.py                     # 汇总表
```

原始数据：`work/bench/results/*.json`；脚本：`work/bench/*.py`、`work/bench/*.sh`。
