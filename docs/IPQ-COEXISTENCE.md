# IPQ60xx / MTK 共存：DPD 不参与硬件已经加速的流

状态：**已实现，静态验证完成**（2026-11-10）。无 IPQ/MTK 硬件在环，所以真机
验收项在最后一节，需要上机确认一次。

## 1. 设计立场

IPQ60xx/IPQ807x 的加速来自**内核 flowtable + PPE 硬件卸载**，MTK 来自 flowtable
/ PPE。它们已经在做转发加速，而且做得比 TC eBPF 更省 CPU。

所以 DPD 在这类机器上的定位不是"再快一点"，而是**完全不参与**：

- 不安装数据面包（`dpd-fastpath`、`einat-ebpf`、`router-acl`）；
- 即使有人手动装，gate 也会因为检测到 flow offloading 而停在 `observe`；
- 不覆盖 IPQ/MTK 原有的 NSS / 原版 honk / 原版 config。

两套加速器抢同一条流会产生"谁先看到包"的不确定行为，这比少一点性能危险得多。

## 2. 三层保护（都在 CI 里，删掉就失败）

第 7 项检查 `Scripts/verify-drift.sh` 分三层，每一层都实测过"删掉保护会失败"：

| 层 | 检查 | 拦住的错误 |
|---|---|---|
| a | IPQ*/MTK*/AIROHA* 的 `Config/*.txt` 不得选中 DPD 数据面包 | 有人在 config 里打开 `CONFIG_PACKAGE_einat-ebpf=y` |
| b | `Packages.sh` 的 `ebpf/` 拷贝必须在 `X86|ROCKCHIP` 分支内 | 改动 case 分支，让 IPQ 也捡到整个数据面 |
| c | 任何安装 `*.bpf.c` 的包必须 `@!(TARGET_qualcommax)` | 新增一个带 BPF 对象的包但忘了排除 IPQ |

第 c 层是从目录树**自动发现**的，不是硬编码包名，所以以后新增的包自动受约束。
它上线时就抓到了一个真实漏洞：`router-acl` 会挂 tc 过滤器到 WAN（pref 90，
在 flowtable/PPE 决策之前），却没有排除 qualcommax。

## 3. 包级改动

```make
# bpf/core/Makefile (dpd-fastpath)
DEPENDS:=@!(TARGET_qualcommax) +libbpf +libelf +kmod-sched-core ...

# einat-ebpf
DEPENDS:=@(x86_64||aarch64) @!(TARGET_qualcommax) +kmod-sched-core ...

# router-acl / dpd-acl
DEPENDS:=@!(TARGET_qualcommax) +libbpf +libelf ...
```

注意 `einat-ebpf` 原来是 `@(x86_64||aarch64)`，而 **IPQ 是 aarch64**，所以旧闸门
根本挡不住它，这是这次修掉的实质问题。

## 4. gate：即使误装也只观察

`bpf/core/files/dpd-fastpath.sh` 新增 `dpd_hw_offload_active()`：

```sh
config_load firewall
config_get fo '@defaults[0]' flow_offloading 0
config_get fh '@defaults[0]' flow_offloading_hw 0
[ "$fo" = "1" ] || [ "$fh" = "1" ]
```

命中就输出

```
gate: mode 'stateful' downgraded to 'observe' [hw-offload]:
fw4 flow offloading (software or hardware) is enabled: the kernel
flowtable/PPE already accelerates these flows, and DPD does not compete
with it -- staying in observe
```

X86/RK 镜像里 `flow_offloading=0`（`Handles.sh` 主动关掉），所以这条在那些机器上
是空操作。

顺带修了一个真实的 gate bug：原来 `no-uplink` 检查没有判 `code=ok`，
**会覆盖掉前一个 gate 的失败原因**，导致"实际没加速但 gate 显示 no-uplink"。
现在每个后续检查都带 `[ "$code" = "ok" ]`。

## 5. 真机验收清单（需要你上机）

```sh
# 1. image 里不该有数据面
apk list --installed 2>/dev/null | grep -E 'dpd-fastpath|einat-ebpf|router-acl'
#   期望：无输出

# 2. flowtable 必须还在
nft list ruleset | grep -A3 flowtable
#   期望：有 flowtable，且 devices 含 WAN

# 3. 手动装一次，确认 gate 停在 observe
apk add --allow-untrusted /tmp/dpd-fastpath-*.apk
/etc/init.d/dpd-fastpath restart
cat /var/run/dpd/gate.json
#   期望："code": "hw-offload"，"effective": "observe"

# 4. 确认没有抢流：flowtable 计数继续增长，bpftool 的 run_cnt 不涨
sysctl -w kernel.bpf_stats_enabled=1
bpftool prog show | grep dpd_fastpath
#   跑一段流量后再看 run_cnt

# 5. PPE/NSS 路径没被破坏
cat /proc/interrupts | grep -i -E 'ppe|nss'
conntrack -C
```

第 3 步是最关键的一条：它验证"误装也只观察"，也就是 DPD 最坏情况下不会
把一台已经硬件加速的路由器拖慢。

## 6. 不做的事

- 不在 IPQ 上做 DPD 与 PPE 的**双加速**（`docs/RESEARCH-PPE-DUAL.md` 只是探讨，
  没有一行代码进入默认路径）；
- 不改 PPE/NSS 的驱动、队列、IRQ；
- 不用 DPD 的 NAT 去替代 NSS/conntrack 的 NAT（`nat_offload=0`）。
