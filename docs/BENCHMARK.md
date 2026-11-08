# DPD-FW Benchmark Plan

## 目标

回答三个问题：

1. 每个包花在哪些阶段（解析、UFS、NAT、TTL、VLAN、emit、qdisc、NAPI）？
2. DPD-FW 相比原版 Linux / nft flow offload / SFE / 当前 DPD 快多少？
3. 功能（NAT/full-cone/honk/QoS/MWAN/ACL）开启后还剩多少余量？

## 测试床

- ESXi `10.1.18.124`
  - `router-lab`：OpenWrt，2 vCPU / 2GB，e1000，LAN 192.168.10.1，WAN DHCP。
  - `ebpf-client2`：OpenWrt，2 vCPU / 2GB，vmxnet3，192.168.10.162。
  - 串口：router-lab 7005，ebpf-client2 7004。
- 外部打流：x86 物理机 / `pktgen` / `Trex`（需要时）。
- 生产参考：`10.10.10.1`（X86 PPPoE） + `10.10.10.173`。

## 包长/流数

| 维度 | 取值 |
|---|---|
| 包长 | 64 / 128 / 512 / 1500 / 9000 |
| 流数 | 1 / 10 / 100 / 1000 / 10000 |
| 协议 | TCP / UDP / ICMP；IPv4 / IPv6 |
| 封装 | 原生 / VLAN / PPPoE |
| 功能 | direct / NAT / full-cone / honk / ACL / QoS / MWAN |

## 指标

- PPS、Gbps、丢包；
- P50/P99/P999 RTT（sockperf / netperf TCP_RR）；
- CPU%（单核/总）、软中断、上下文切换；
- map lookup 次数（`bpftool prog profile` / perf）；
- 建流速率、并发流数；
- `tc -s qdisc`、NAPI 队列、`/proc/softirqs`。

## 对比组

1. 原版 Linux 转发；
2. nft flow offload（软件）；
3. SFE（若分支支持）；
4. 当前 DPD；
5. DPD-FW P1；
6. DPD-FW P2；
7. DPD-FW P4（NAPI 调优）。

## 门禁

| 场景 | 门禁 |
|---|---|
| 1G 64B | 0 丢包，≥ 1.48 Mpps |
| 1G 1500B | ≥ 940 Mbps |
| 2.5G 64B | ≥ 3.7 Mpps |
| 2.5G 1500B | ≥ 2.35 Gbps |
| 10G 1500B | 线速（x86 4C+） |
| 10G 64B | 8C+ x86 冲刺，不承诺 |
| P99 延迟 | 基线 + 50–100µs |
| 24h soak | 0 丢包/0 泄漏/无 watchdog 降级 |

## 记录

每次 benchmark 必须记录：

- `dpd-fw` commit、内核版本、固件 tag；
- CPU 型号/核数、NIC 型号、ESXi 版本；
- `qdisc`、GRO/GSO/TSO、NAPI 配置；
- 是否开 NAT/full-cone/honk/QoS/MWAN；
- 原始 `iperf3`/`sockperf`/`perf` 输出文件。
