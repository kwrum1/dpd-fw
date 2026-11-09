# DPD-FW Roadmap

## 进度概览（2026-11-09）

| 阶段 | 复选框 | 完成度 | 主要缺口 |
|---|---|---|---|
| P0 | 12/13 | 92% | feed 接入 |
| P1 | 11/12 | 92% | PPPoE A/B |
| P2 | 4/7 | 57% | EIF、IPv6、`bpf_ct_*`；SNAT 的 ICMP/回收边界 |
| P3 | 5/5 | 100% | ACL/QoS 分类器接入 dpd_class（机制已就绪） |
| P4 | 4/8 | 50% | threaded/IRQ A/B、GRO/GSO A/B、qdisc 门禁、10G/64B 门禁 |
| P5 | 5/5 | 100% | — |
| P6 | 0/2 | 0% | 可选 |
| P7 | 1/6 | 17% | 仅调研，实现已挂起 |

- 按 P0–P5 复选框加权：**约 78%**；
- 按设计文档的“能力”口径：**约 60–65%**（UFS 全量字段、Flow Manager 状态机、
  插件 ABI、full-cone/IPv6、性能门禁仍未完成）；
- 性能验证：**约 10–15%**（只做了 payload 扫描，没有 64B PPS/10G 门禁）。

## P0 — 仓库与基线

- [x] 新建 `kwrum1/dpd-fw`
- [x] 迁移 `router-dataplane` → `bpf/core`
- [x] 迁移 `router-acl` → `plugins/dpd-acl`
- [x] 迁移 `einat-ebpf` → `plugins/dpd-einat`
- [x] 迁移 `router-qos` → `plugins/dpd-qos`
- [x] 迁移 `router-tuning` → `plugins/dpd-tuning`
- [x] 迁移 `luci-app-ebpf` → `openwrt/luci-app-dpd`
- [x] 生成选型与架构设计 Word 文档
- [x] 6.18 config fragment（`kernel/configs/6.18/dpd.config`）
- [x] ESXi 基线（netns 客户端；见 `docs/ARCHITECTURE.md` §15）
- [x] CI：shellcheck + BPF 对象 + ABI（`.github/workflows/ci.yml`）
- [x] 本地完整镜像构建 + sysupgrade 刷机复验（`docs/LOCAL-BUILD.md`）
- [ ] `dpd-fw` feed 接入固件仓库（目前是 `Scripts/Packages.sh` 直拷）

## P1 — 一次查表 / Flow Manager

- [x] `dpdfwd` MVP：link/addr/route/neigh 事件 → 去抖 epoch bump；conntrack
      计数；`/var/run/dpd/flowd.json`（ESXi 实测 epoch 0→1、ct_new 增长）
- [x] 按流定向失效：`dpdfwd` 解析 conntrack destroy 的 orig/reply tuple，
      每秒批量调用一次 `dpdctl delete -f`（一次扫描删所有匹配项）；
      实测一次批量删除 8 条回程流
- [x] UFS v2（ABI 18）：state/action/skb_priority/ct_cookie/nat_flags/dscp/
      packets/bytes；显式 OBSERVE→BIND 状态机
- [x] `dpd_class` 策略缓存 + `dpdctl class`（端口 0/ifindex 0 通配；
      实测 eth1 block 生效）
- [x] `dpdfwd` 声明式分类策略：`/etc/dpd/class.conf`（5 元组 + 动作），
      mtime 变化时 flush + 逐条 `dpdctl class add`，结果进 `flowd.json`
      （`class_rules/class_bad/class_applied_at/class_error`）；
      实测 block 规则生效（`flow_block` +76，清空文件后流量恢复）
- [x] L2/L3 双 BPF section，去掉每包 `dpd_iface` 查询
- [x] 网桥端口自动 attach/detach
- [x] 配置移出热路径（per-CPU cfg 块，一次查表）
- [x] `accel_after_pkts`（默认 32；短流不进快路径，实测 flow_hit=0）
- [x] FIN/RST 立即释放（`ST_FLOW_FIN`）
- [x] TCP 300s / UDP 120s / 单向 UDP 30s 超时
- [ ] 命中路径只更新 2 个 per-CPU 计数
- [ ] PPPoE emit A/B：`pull_data + redirect` vs `redirect_neigh(nh)`

## P2 — NAT / full-cone / IPv6

- [x] P2.1 UFS+einat NAT 合并（前向/上传也加速，ABI 16）
      - `dpd_nat` 只做准入闸门，SNAT 仍由 einat TCX egress 完成（在 ingress 重写会被
        einat 二次 SNAT，实测 9044→9300，ACK 全丢）
      - `DPD_FLOW_F_NAT` 标记只作用在上行 flow；回程不做 `dpd_nat` 查询
      - ESXi netns 客户端：32MB 上传 `PEER 198.18.0.1:28721 BYTES 33554432`，
        `flow_hit` 9968→20100，`nat_gone=0`
- [x] 正反双向 UFS（前向 egress=eth1、回程 DNAT 后入 UFS）
- [x] P2.2 回程 DNAT 由 DPD 完成（ABI 19，`nat_ingress=dpd`，
      `dpd_nat_rev` 从 einat 反向 binding 镜像；detach einat ingress 后
      1MB 下载 OK、`nat_dnat=332`；默认与 einat ingress 共存安全）
- [x] P2.3 前向 SNAT/端口分配归 DPD（ABI 20，`nat_forward=dpd`）
      - `classifier/egress` 挂在上行 egress（路由/netfilter 之后，和 einat
        TCX egress 同一位置），哈希+8 次探测分配 20000–29999；
        `dpd_nat_rev` 兼作端口归属表，`BPF_NOEXIST` 抢占，TTL 回收
      - 外部地址用 `bpf_fib_lookup(BPF_FIB_LOOKUP_OUTPUT|SRC)` 按路由取，
        多地址上行也正确；`dpdctl nat_addr` 的 addr4 只作兜底/开关
      - 实测：1MB 下载 OK（`nat_alloc=1/snat=117/dnat=241`）、32MB 完整、
        两条并发流分到不同端口；恢复 einat 后三个计数均为 0
      - 边界：ICMP 未做、fw4 accept 需操作者提供、LRU 挤掉活跃 binding
        无主动回收
- [ ] 陌生入站 EIF（einat 已具备，需双 peer 验证）
- [ ] IPv6 双向（状态防火墙或 NAT66）
- [ ] `bpf_ct_*` 可选路径

## P3 — 功能迁移

- [x] `dpd-acl` meta + router-acl 保留 UCI
- [x] `dpd-qos` meta + router-qos 保留 UCI
- [x] `dpd-mwan` meta + ebpf_mwan 保留 UCI
- [x] keep-settings 升级与旧 UCI alias（meta + uci-defaults +
      `/usr/lib/dpd/keep-settings.sh`）
- [x] 策略缓存机制 `dpd_class`（ACL/QoS 分类器尚未接入，见 P1.1）

## P4 — NAPI 与 10G

- [x] `dpd-napi` sysfs 版（budget/dev_weight/gro_flush/defer_irqs/RPS/XPS）
- [x] `dpd-napi-netdev`（netdev-genl per-NAPI：gro_flush/defer/irq_suspend/threaded）
      - dpd-test 6.18 实测：eth1 的 4 个 NAPI（537-540）逐个设置并回读成功
- [x] `dpd-napi-irq` / `dpd-napi-gro` / `dpd-napi-qdisc` 工具（已实现，未做 A/B 门禁）
- [x] `tests/netns` + `tests/bench` 脚本；ESXi payload 扫描
      （64K..32M，32M 372.8 Mbps，`tests/bench/results-2026-11-09-esxi.csv`）
- [ ] threaded NAPI / IRQ affinity 的 A/B（vmxnet3 不支持 threaded，虚拟环境无结论）
- [ ] GRO/GSO/TSO A/B
- [ ] qdisc 模式与门禁
- [ ] 1G/2.5G/10G 大包达标 / 64B PPS 矩阵

## P5 — 插件与 UI

- [x] `dpd-honk`（唯一代理插件，控制面）
- [x] `dpd-observe`（status/gate/plugins JSON + ubus）
- [x] `luci-app-dpd` 页面（overview/honk/flows/napi）
- [x] `dpd-napi` 脚本/包（sysfs + netdev-genl per-NAPI 都已交付）
- [x] 升级/回退演练（本地 `.apk` 安装 + 校验：`PASS: abi=15 attached=true mode=observe`）

## P6 — 可选

- [ ] `dpd-knod` GPU provider（AMD RDNA2 + XDP + 支持 NIC）
- [ ] NPU/GPU 仅控制面分析

## P7 — 高通 PPE/NSS 回退（调研完成，待实现）

- [x] 调研：NSS/ECM、软件 flowtable、MTK PPE 的卸载边界与 UDP 失败原因
      （`docs/RESEARCH-PPE-FALLBACK.md`）
- [ ] P7.0 `dpdfwd` 解析 `CTA_STATUS` 的 OFFLOAD/HW_OFFLOAD + `dpd_ppe` map
- [ ] P7.0 DPD 命中门禁 `ppe_fallback=off|udp|all` + `ppe_grace_ms`
- [ ] P7.1 IPQ 上 ECM 加速模式/异常路径推断
- [ ] P7.2 内核回调/BPF map 精确化
- [ ] P7.3 上行 NAT 映射同步
