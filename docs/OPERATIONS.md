# DPD-FW 交付与运维手册

适用：v1（ABI 20，内核 6.18，x86_64 / N5000）。
定位：`dpd-fastpath` 是 TC ingress 经典 eBPF 加速器 + 可选的 DPD 自有 NAT；
einat 仍是默认 NAT。**不依赖 XDP/AF_XDP/DPDK，不需要改驱动。**

## 1. 交付物

| 文件 | 用途 |
|---|---|
| `immortalwrt-x86-64-generic-squashfs-combined.img.gz` | BIOS/legacy 启动的整机镜像（sha256 见 `docs/LOCAL-BUILD.md`） |
| `...-combined-efi.img.gz` | EFI 启动 |
| `dpd-fastpath` / `dpdfwd` / `dpd-einat-sync` / `dpd-napi` / `dpd-honk` / `dpd-observe` | 包 |
| `luci-app-dpd` | LuCI 页面 |
| `docs/OPERATIONS.md`（本文） | 运维 |
| `docs/ACCEPTANCE-N5000.md` | 验收矩阵 |

## 2. 首次部署

### 2.1 刷机

```sh
sha256sum immortalwrt-x86-64-generic-squashfs-combined.img.gz   # 对照 LOCAL-BUILD.md
sysupgrade -n /tmp/fw.img.gz                                    # 或写盘/VM 替换
```

首次启动后：

```sh
uname -r                 # 6.18.x
dpdctl version           # abi 20
cat /usr/lib/dpd/abi     # 20
```

### 2.2 最小网络配置

```sh
uci set network.lan.ipaddr='192.168.10.1'
uci set network.wan.proto='static'   # 或 dhcp/pppoe
uci set network.wan.ipaddr='198.18.0.1'
uci set network.wan.netmask='255.255.255.0'
uci commit network
/etc/init.d/network restart
```

### 2.3 启用加速（默认配置即可）

`/etc/config/dpd_fastpath` 默认：`attach=1`、`enabled=1`、`mode=stateful`、
`nat_forward=einat`、`nat_ingress=einat`、`downlink=1`。

```sh
/etc/init.d/dpd-fastpath enable
/etc/init.d/dpd-fastpath start
/usr/libexec/dpd-gate-refresh    # 重新评估门禁
```

判据：

```sh
cat /var/run/ebpf/gate           # 第 2 行 stateful，第 3 行 ok
dpdctl status | head -5
```

### 2.4 可选：DPD 自有 NAT

只在**没有 einat** 或明确要让 DPD 拥有 NAT 时使用：

```sh
/etc/init.d/einat stop            # 或 detach 它的 TCX
uci set dpd_fastpath.global.nat_forward='dpd'
uci set dpd_fastpath.global.nat_ingress='dpd'
uci commit dpd_fastpath
/etc/init.d/dpd-fastpath restart
```

验证：

```sh
dpdctl show | grep nat_           # forward 1 / ingress 1
tc filter show dev <wan> ingress | grep 'pref 50'   # classifier/nat
tc filter show dev <wan> egress  | grep 'classifier/egress'
dpdctl nat                        # 绑定与端口范围
```

> 注意：`nat_forward=dpd` 与 einat **不能同时**挂在同一上行（双 NAT）。
> gate 会拒绝加速，egress 钩子也不会挂。

## 3. 日常检查

```sh
# 一屏状态（人读/JSON）
dpdctl status
dpdctl status -j

# 门禁与原因
cat /var/run/ebpf/gate
cat /var/run/ebpf/gate.json

# 计数器
dpdctl stats

# 流表 / NAT 绑定 / 策略
dpdctl flows
dpdctl nat -a
dpdctl class list

# 守护进程状态
cat /var/run/dpd/flowd.json        # ct 计数、class 应用状态
logread | grep -E 'dpd|einat' | tail -50
```

建议监控（脚本/告警）：

| 指标 | 正常 | 告警 |
|---|---|---|
| `gate` 第 2 行 | `stateful`/`stateless` | `observe` 超过 5 分钟 |
| `gate` 第 3 行 | `ok` | 任何其他 code |
| `flow_hit` | 随流量增长 | 长期为 0 且 pkt_total 增长 |
| `nat_gone` | 0 | 持续增长（einat binding 丢失） |
| `nat_exhaust` | 0 | 增长（端口池耗尽） |
| `flowd.json.errors` | 0 | 增长 |
| `dpdfwd`/`einat` 进程 | 存在 | 消失（procd 会拉起，连续重启要查） |

## 4. 配置参考（`/etc/config/dpd_fastpath`）

| 选项 | 默认 | 说明 |
|---|---|---|
| `attach` | 1 | 是否加载并挂载程序 |
| `enabled` | 1 | 数据面总开关（BPF 内） |
| `mode` | stateful | off/observe/stateless/stateful/neigh-probe |
| `redirect` | auto | auto/neigh/dev |
| `accel_after_pkts` | 32 | 新方向走栈的包数（0..127） |
| `tcp_ttl_ms` | 300000 | TCP 空闲超时 |
| `udp_ttl_ms` | 120000 | 双向 UDP |
| `udp_unidir_ttl_ms` | 30000 | 单向 UDP |
| `flow_refresh_ms` | 250 | 命中时刷新时间戳的最小间隔 |
| `mss_clamp` | 1 | 加速 SYN/SYN-ACK 的 MSS clamp |
| `ipv6` | 1 | 是否加速 v6 |
| `downlink` | 1 | 是否挂 WAN ingress（回程加速） |
| `nat_forward` | einat | einat/dpd，前向 SNAT 归属 |
| `nat_ingress` | einat | einat/dpd，回程 DNAT 归属 |
| `nat_port_min/max` | 20000/29999 | DPD NAT 端口池 |
| `class_enable` | 1 | 是否查 `dpd_class` |
| `policy` | allow_all | allow_all/vlans_only |

`/etc/dpd/class.conf`（可选）：

```text
# any tcp 192.168.10.50 0 198.18.0.2 8000 block
# wan tcp 192.168.10.0 0 0.0.0.0 0 forward 0
```

规则在 UFS 学习时复制；改完执行 `dpdctl bump` 或定向删流才对已学流生效。

## 5. 故障排查

| 现象 | 先看 | 处理 |
|---|---|---|
| 完全没加速 | `gate` 第 3 行 | 按 code：
`no-einat`（einat 没挂，先起 einat 或切 nat_forward=dpd）；
`no-uplink`（WAN 没地址/默认路由）；
`chain-guard`（我们后面还有 bpf 过滤器）；
`honk-unpatched`（honk 直接退出是终态，需 p1 core）；
`nat-forward-conflict`（dpd 模式但 einat 还挂着） |
| 下载卡死/大包丢 | `mss_clamp`、`dpdctl stats \| grep mss` | 确认 `dpd_mtu` 有 WAN MTU；PPPoE 用 1492；看 `mss_skip` |
| 上传/下载一半断 | `nat_gone`、einat 日志 | einat binding 丢了；确认 einat 在跑或切 dpd NAT |
| ping 不通但 TCP 通 | `nat_ingress` | 回程 DNAT 需要 `nat_ingress=dpd` 且 pref 50 钩子存在 |
| 端口耗尽 | `nat_exhaust` | 缩小 `nat_port_*` 冲突排查，或查异常短流 |
| 改配置不生效 | `cat /var/run/ebpf/gate` | `/etc/init.d/dpd-fastpath restart`；ABI 变更会自动清 pin |
| 升级后加载失败 | `dpdctl abi` vs `/usr/lib/dpd/abi` | 不一致时 `rm -f /sys/fs/bpf/tc/globals/dpd_*` 再启动 |
| 页面无数据 | `dpdctl status -j` | 先保证 CLI 正常；再看 `/var/run/ebpf/status.json` |

紧急恢复（不影响转发）：

```sh
dpdctl set mode off          # 立即让数据面让路（不用卸载）
# 或
/etc/init.d/dpd-fastpath stop
tc filter del dev br-lan ingress pref 100
tc filter del dev <wan> ingress pref 50
tc filter del dev <wan> egress pref 100
```

## 6. 升级与回退

```sh
# 备份
cp /etc/config/dpd_fastpath /root/dpd_fastpath.bak
cp /etc/dpd/class.conf /root/class.conf.bak 2>/dev/null
cp /etc/config/network /root/network.bak

# sysupgrade（保留配置）
sysupgrade /tmp/fw.img.gz

# 升级后
dpdctl version && cat /usr/lib/dpd/abi
cat /var/run/ebpf/gate
```

ABI 变化时 `dpd_pins_compat()` 会自动删除旧 pin；若手工升级且加载失败：

```sh
rm -f /sys/fs/bpf/tc/globals/dpd_*
/etc/init.d/dpd-fastpath restart
```

回退：刷回旧镜像 + 恢复 `/etc/config/*`。UCI 兼容性由 keep-settings 脚本处理。

## 7. 备份与恢复

必须备份：

- `/etc/config/dpd_fastpath`、`/etc/config/network`、`/etc/config/firewall`；
- `/etc/dpd/class.conf`（如果有）；
- 验收记录与镜像 sha256。

状态文件无需备份（`/var/run/*` 重启即重建）。

## 8. 安全边界

- **加速流跳过 netfilter**：prime 窗口（默认 32 包）之后，fw4 的 per-packet
  计数、`limit`、动态黑名单只看到每流的前若干包；需要逐包审计的流量把
  `mode` 设为 `observe` 或 `off`。
- `nat_forward=dpd` 要求 einat 从所有上行 detach；两者同时挂会双 NAT。
- `class.conf` 的 `block` 在 UFS 学习时生效，已建立的流需 `dpdctl bump`。
- 回程 DNAT 阶段（pref 50）只改写、不丢弃、不加速；策略层（router-acl 90）
  仍然先看到每个包。
- DPD NAT 模式实测**不需要**额外的 fw4 WAN→LAN accept（einat 完全停止后
  ping/TCP 仍通）；若自建防火墙策略更严，可加一条仅 WAN→LAN 的 accept。

## 9. 容量与限制

| 资源 | 上限 |
|---|---|
| UFS 流表 | 65536（LRU） |
| NAT 正向/反向表 | 65536（LRU） |
| 外部端口池 | 10000（20000–29999，可配） |
| 策略缓存 | 16384 |
| 接口表 | 64 |
| 多 WAN | 8 |

## 10. 支持矩阵

| 项 | v1 |
|---|---|
| 架构 | x86_64（N5000 验证） |
| 内核 | 6.18.x（OpenWrt immortalwrt owrt） |
| 数据面 | TC ingress 经典 eBPF；无 XDP/DPDK/驱动改造 |
| NAT | einat（默认）/ DPD 自有（v4 TCP/UDP/ICMP echo） |
| IPv6 | 出站加速；入站走栈；无 NAT66 |
| 代理 | honk 可选（p1 core 的 direct-unspec） |
| 性能 | 不做门禁；以功能闭环为准 |
