# 源码布局：main 与 arm

固件仓库不再保存 dpd 的源码副本。数据面只有一份源码，在这里：

| 位置 | 作用 |
|---|---|
| `main` | 唯一源码树：`bpf/core/src`、`userspace/dpdfwd/src`、`bpf/core/files` |
| `arm` | 由 `main` 生成的**打包快照**，固件构建时拉取 |
| 固件仓库 `ebpf/router-dataplane`、`ebpf/dpdfwd` | 只有 Makefile 与 README |

## 为什么

以前固件仓库里有一份 `dpdctl.c` / `dpdfwd.c` / helper 脚本的副本。两份副本会
漂移：2026-11-11 的固件提交 `09487cb` 里还是 ABI 22 之前的 `dpdctl`
（没有 `hooked` / `iface_count` / `ppe_hw`），而设备上跑的是新二进制。镜像
一旦构建出来，概况页就读不到 DPD/PPE 数据。

## arm 分支的内容

```
packaging/router-dataplane/src/{dpdctl.c,dpd_common.h,dpd_bpf.h,dpd_fastpath.bpf.c}
packaging/router-dataplane/files/*        (init, helper, hotplug, config)
packaging/dpdfwd/src/{dpdfwd.c,dpd_plugin.h}
packaging/dpdfwd/files/*                  (init, class.conf)
```

它是生成物，不要手改。更新流程：

```sh
git checkout arm
sh packaging/sync.sh
git add -A packaging
git commit -m "arm: sync packaging"
git push origin arm
```

## 固件如何引用

固件仓库的 `Scripts/Fetch-DPD.sh` 在构建前执行：

```sh
git clone --depth 1 --branch arm https://github.com/kwrum1/dpd-fw.git
cp -a .../packaging/router-dataplane/{src,files} ebpf/router-dataplane/
cp -a .../packaging/dpdfwd/{src,files}           ebpf/dpdfwd/
```

`WRT-CORE.yml`（所有镜像）和 `sdk.yml`（包构建）都调用它。脚本打印解析到的
commit；发布构建可用 `DPD_REF=<sha>` 固定，镜像 provenance 会记录该值。

## 验证记录

2026-11-11 的 sdk 构建（固件 `7e510ca`，dpd-fw `0c31afb`）日志：

```
fetch-dpd: https://github.com/kwrum1/dpd-fw.git arm @ 1cd3695...
ok: dpdfwd
ok: dpd-fastpath
```

两个架构的 apk 都重新生成，aarch64 的 `dpdctl` 仍包含
`iface_count` / `hooked` / `active_flows` / `ppe_hw`。
