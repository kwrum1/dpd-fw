# DPD-FW Roadmap

## P0 — 仓库与基线（当前）

- [x] 新建 `kwrum1/dpd-fw`
- [x] 迁移 `router-dataplane` → `bpf/core`
- [x] 迁移 `router-acl` → `plugins/dpd-acl`
- [x] 迁移 `einat-ebpf` → `plugins/dpd-einat`
- [x] 迁移 `router-qos` → `plugins/dpd-qos`
- [x] 迁移 `router-tuning` → `plugins/dpd-tuning`
- [x] 迁移 `luci-app-ebpf` → `openwrt/luci-app-dpd`
- [x] 生成选型与架构设计 Word 文档
- [ ] 6.18 config fragment
- [ ] ESXi 基线（router-lab / ebpf-client2）
- [ ] CI：shellcheck + BPF 对象 + ABI
- [ ] `dpd-fw` feed 接入固件仓库

## P1 — 一次查表 / Flow Manager

- [x] `dpdfwd` MVP：link/addr/route/neigh 事件 → 去抖 epoch bump；conntrack
      计数；`/var/run/dpd/flowd.json`（ESXi 实测 epoch 0→1、ct_new 增长）
- [ ] 按流定向失效（需要 ct_cookie ↔ UFS key 映射）
- [ ] UFS key/value 定稿（当前 48B/28B，缺 NAT 结果/DSCP/action/计数器）
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
- [ ] 陌生入站 EIF（einat 已具备，需双 peer 验证）
- [ ] IPv6 双向（状态防火墙或 NAT66）
- [ ] `bpf_ct_*` 可选路径

## P3 — 功能迁移

- [x] `dpd-acl` meta + router-acl 保留 UCI
- [x] `dpd-qos` meta + router-qos 保留 UCI
- [x] `dpd-mwan` meta + ebpf_mwan 保留 UCI
- [ ] keep-settings 升级与旧 UCI alias（meta 已兼容旧名）

## P4 — NAPI 与 10G

- [x] `dpd-napi` sysfs 版（budget/dev_weight/gro_flush/defer_irqs/RPS/XPS）
- [x] `dpd-napi-netdev`（netdev-genl per-NAPI：gro_flush/defer/irq_suspend/threaded）
      - dpd-test 6.18 实测：eth1 的 4 个 NAPI（537-540）逐个设置并回读成功
- [ ] threaded NAPI / IRQ affinity 的 A/B（vmxnet3 不支持 threaded，虚拟环境无结论）
- [ ] GRO/GSO/TSO A/B
- [ ] qdisc 模式与门禁
- [ ] 1G/2.5G/10G 大包达标

## P5 — 插件与 UI

- [x] `dpd-honk`（唯一代理插件，控制面）
- [x] `dpd-observe`（status/gate/plugins JSON + ubus）
- [x] `luci-app-dpd` 页面（overview/honk/flows/napi）
- [x] `dpd-napi` 脚本/包（sysfs 版；netdev-genl 版待 P4）
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
