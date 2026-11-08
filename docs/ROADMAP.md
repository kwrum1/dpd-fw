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

## P1 — 一次查表

- [ ] `dpd-flowd` 骨架：conntrack/honk/einat 事件
- [ ] UFS key/value 定稿
- [x] L2/L3 双 BPF section，去掉每包 `dpd_iface` 查询
- [x] 网桥端口自动 attach/detach（ESXi 实测：br-lan ingress 看不到转发帧）
- [ ] 配置移出热路径
- [ ] `accel_after_pkts`（默认 32）
- [ ] 命中路径只更新 2 个 per-CPU 计数
- [ ] PPPoE emit A/B：`pull_data + redirect` vs `redirect_neigh(nh)`

## P2 — NAT / full-cone / IPv6

- [ ] `dpd-einat` 绑定表与 UFS 合并
- [ ] 正反双向 UFS
- [ ] 陌生入站 EIF
- [ ] IPv6 双向（状态防火墙或 NAT66）
- [ ] `bpf_ct_*` 可选路径

## P3 — 功能迁移

- [ ] `dpd-acl` 规则/epoch
- [ ] `dpd-qos`：off/cake/hybrid
- [ ] `dpd-mwan`：WAN 选择/健康/失效
- [ ] keep-settings 升级与旧 UCI alias

## P4 — NAPI 与 10G

- [ ] `dpd-napi`：netdev-genl per-NAPI 配置
- [ ] threaded NAPI / IRQ affinity
- [ ] GRO/GSO/TSO A/B
- [ ] qdisc 模式与门禁
- [ ] 1G/2.5G/10G 大包达标

## P5 — 插件与 UI

- [x] `dpd-honk`（唯一代理插件，控制面）
- [x] `dpd-observe`（status/gate/plugins JSON + ubus）
- [x] `luci-app-dpd` 页面（overview/honk/flows/napi）
- [x] `dpd-napi` 脚本/包（sysfs 版；netdev-genl 版待 P4）
- [ ] 升级/回退演练（脚本已加，待在镜像上跑）

## P6 — 可选

- [ ] `dpd-knod` GPU provider（AMD RDNA2 + XDP + 支持 NIC）
- [ ] NPU/GPU 仅控制面分析
