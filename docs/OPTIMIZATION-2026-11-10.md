# DPD 优化工作流（2026-11-10）

本轮按“文件不重叠”拆成三个并行工作流；每个专家只改自己的文件，避免合并冲突。
所有改动先做源码级审查，真机 A/B 等 SSH 重新打开后统一做。

## 工作流 A：挂载去重（item 1）

文件：`src/ci/ebpf/router-dataplane/files/dpd-fastpath.sh`、
`files/dpd_fastpath.config`（仅新增选项时）。

问题：`bpftool net show` 显示 `dpd_fastpath_l2` 同时挂在 `br-lan` 和
`eth0/eth1/eth2`，桥接帧可能执行两遍。

改动：默认只挂 bridge master；新增 `attach_bridge_ports`（默认 0）保留旧行为；
跳过“端口 + master 已在挂载列表”的重复挂载。

验证：

```
tc filter show dev eth0 ingress        # 默认应无 dpd
bpftool net show | grep dpd            # 只剩 br-lan + pppoe-wan
bpftool prog show                      # 对比 run_cnt（需支持 run_cnt 的 bpftool）
```

预期：LAN 入向每包少一次程序执行；64B 高 PPS 场景收益最大。

## 工作流 B：每包成本（items 2/3）

文件：`bpf/core/src/dpd_fastpath.bpf.c`、`dpd_common.h`（仅注释/无 ABI 变化）、
`bpf/core/src/dpdctl.c`。

改动：`flow_counters=2` 表示 1/16 采样更新 `packets/bytes`；0/1 行为不变；
`dpdctl set counters` 接受 0/1/2。ABI 保持 20。

验证：已知大小传输对比 `dpdctl flows` 计数；64B A/B（counters 0/1/2）。

预期：命中路径每包少两次 64 位写；高 PPS 下几个百分点。

## 工作流 C：覆盖与可观测（items 6/7 的低风险部分）

文件：`userspace/dpdfwd/src/dpdfwd.c`。

改动：

1. 忽略 **bridge port** 的 link 事件（`/sys/class/net/<if>/master` 存在），
   不再为测试 veth/端口 up-down 全表失效；新增 `link_port` 计数。
2. 解析 ctnetlink `CTA_STATUS` 的 `IPS_OFFLOAD`(bit14)/`IPS_HW_OFFLOAD`(bit15)，
   在 `flowd.json` 增加 `ct_offload`/`ct_hw_offload`（只观测，不改行为）。

验证：`flowd.json` 的 `epoch_bumps`/`link_port`；命中率前后对比。

## 不在本轮（需要单独决策）

- **v4 游戏流/NAT 闸门**：根因是 einat 绑定/hook 顺序，需要 NAT 归属决策
  （DPD 自有 NAT 或客户端重连），不是微优化。
- **PPE/NSS 双加速**：上一轮已确认 IPQ60xx 走 `qca_ppe` flowtable，
  IPv4 NAT 存在引擎二选一约束；先搁置。
- **GPU/NPU**：结论是不划算，不做快路径。

## 2026-11-10 真机结果（N5000）

### A. 挂载去重：假设被数据否定

349 MB 下载期间 BPF `run_cnt` 增量：

```
eth0 l2   +32114
br-lan l2 +1591
eth1/eth2    0
```

端口钩子才是 LAN 主路径，bridge master 只看到约 5%。**master-only 会丢约 95% 的
LAN→WAN 包**，所以默认改回 `attach_bridge_ports='1'`；`0` 只保留为特殊拓扑的
实验开关，并在 `0` 时主动删除端口上的旧钩子（reload 不一定走 detach）。
现场已恢复：eth0/eth1/eth2 + br-lan + pppoe-wan 全部挂载，`uci get` 为 1。

结论：item 1 不是“重复挂载”，没有 2x 收益；这条优化到此为止，不再投入。

### B. `flow_counters=2` 采样

`dpdctl set counters 2` 接受，`dpdctl show` 显示 `ufs counters 2`，已设回 1。
ABI 仍为 20，未做 64B A/B（本轮优先验证 A/C）。

### C. 链路事件过滤 + offload 观测

veth churn（创建/enslave/up/删除）：

```
before: link=0  link_port=0  epoch_bumps=5
after : link=15 link_port=7  epoch_bumps=7
```

旧行为会把 15 个 link 事件合并成一次 bump；现在 7 个端口事件被跳过，只剩
2 次（DEL 时名字已消失的保守路径）。`flowd.json` 新增 `link_port`、
`ct_offload`、`ct_hw_offload`，JSON 有效。

### D. 本地投递快判（fib_fail）

基线（100 个 ping 到 10.10.10.1）：`fib_fail +189`、`local +0`。
安装后同一测试：`fib_fail +0`、`local +361`（请求+回复+本机流量）。

实现：

- `dpd_local` hash（family + 16 字节地址），miss 路径在 `bpf_fib_lookup()`
  之前查；命中则 `ST_LOCAL++` 并返回 `TC_ACT_UNSPEC`，不再做 FIB；
- `dpdctl local sync|flush|list` 从 `getifaddrs()` 填充（跳过 loopback，
  包含 WAN/LAN/ULA/link-local）；
- `dpdfwd` 在 `RTM_NEWADDR/DELADDR` 重新 sync（PPPoE 重拨会换地址）；
- init 在 attach 后 sync 一次。

现场 `local table 10/128`，`dpdctl local list` 能看到 WAN/LAN/ULA/link-local
全部地址。代价是转发 miss 多一次小 hash 查表；本地流量不再产生 `fib_fail`。

### 未做

- v4 游戏流/NAT 闸门（需要 NAT 归属决策，见 `RESEARCH-PPE-DUAL.md`）；
- `fib_fail` 快判、IRQ 亲和、busy-poll（需要单独 A/B）；
- 64B 高 PPS 的 counters 0/1/2 对比。

