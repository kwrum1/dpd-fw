# 本地完整镜像构建（X86）

目的：不依赖 GitHub Actions，在本地 40 核构建机上产出带 DPD 包的固件镜像，并刷到
实验 VM 复验。2026-11-09 已跑通。

## 环境

- Ubuntu 24.04，40 核 / 62GB，`/build` 350GB 可用；
- 上游 `VIKINGYFY/immortalwrt@owrt`；
- 固件脚本仓库 `kwrum1/ebpf-honk-ImmortalWRT-CI`（`Config/`、`Scripts/`、
  `ebpf/`）；
- Go 1.24、LLVM 20（clang/llc/opt/llvm-strip）在 PATH 里。

## 步骤

```sh
# 1. 固件脚本仓库
git clone https://github.com/kwrum1/ebpf-honk-ImmortalWRT-CI.git /build/ci
# 2. 上游树
git clone --depth=1 --single-branch --branch owrt \
    https://github.com/VIKINGYFY/immortalwrt.git /build/ci/wrt
cd /build/ci/wrt

# 3. feeds
./scripts/feeds update -a
./scripts/feeds install -a

# 4. 第三方包 + 本地 ebpf/ 包
export GITHUB_WORKSPACE=/build/ci
bash $GITHUB_WORKSPACE/Scripts/Packages.sh
bash $GITHUB_WORKSPACE/Scripts/Handles.sh

# 5. 生成 .config（X86 = Config/X86.txt + Config/GENERAL.txt）
export WRT_CONFIG=X86 WRT_THEME=vantage WRT_NAME=OWRT WRT_SSID=OWRT \
       WRT_WORD=12345678 WRT_IP=192.168.10.1 WRT_PW=无 \
       WRT_MARK=local WRT_DATE=$(date +%Y%m%d) \
       WRT_TARGET=x86 WRT_SUBTARGET=64 WRT_WIFI=WIFI-NO
bash $GITHUB_WORKSPACE/Scripts/Settings.sh
bash $GITHUB_WORKSPACE/.github/scripts/prepare-build-host.sh
make defconfig

# 6. root 编译必须（GNU tar/autoconf 拒绝 root）
export FORCE_UNSAFE_CONFIGURE=1

# 7. 下载 + 编译
make download -j40
make -j40
```

产物在 `bin/targets/x86/64/`：

```
immortalwrt-x86-64-generic-squashfs-combined.img.gz      (BIOS, sysupgrade)
immortalwrt-x86-64-generic-squashfs-combined-efi.img.gz  (EFI)
immortalwrt-x86-64-generic-squashfs-combined.vmdk        (直接给 ESXi)
```

## 本地构建踩过的坑

1. **root 编译**：`configure: you should not run configure as root` →
   `FORCE_UNSAFE_CONFIGURE=1`。
2. **honk 的 `generated-stage.mk`**：`Scripts/Packages.sh` 用 GitHub API 查 release，
   没有 `GITHUB_TOKEN` 时可能拿不到（限流/401）。现象是构建到
   `package/honk download` 才报 `Cannot find appropriate hash command`，
   因为包内 fallback 的 `HONK_HASH_*:=SKIP` 是大写，而 `download.pl` 只认小写
   `skip`。处理：
   - 设置 `GITHUB_TOKEN`；或手动把
     `https://github.com/kwrum1/openwrt-honk/releases/download/core-p1/generated-stage.mk`
     放到 `package/honk/`；
   - `luci-app-honk` 还需要 `generated-doona-stage.mk`（`source-*` release），
     并把其中 `PKG_SOURCE_URL` 从 `kenzok8` 改成实际 release（`kwrum1`），
     否则 404。
   - `Packages.sh` 已加无 token 的 fallback 和告警（`7ca3b7f`）。
3. **immortalwrt CDN 卡住**：`sources-cdn.immortalwrt.org` 的
   `zlib-2.3.3.tar.zst` / `ncurses-6.6.20260801.tar.zst` / `libbpf-1.8.0.tar.zst`
   会长时间 0 字节。改从 `https://sources.openwrt.org/` 手动下载到 `dl/`，
   再跑 `make download`。
4. **`make download` 必须先完成**：编译阶段不会再下载，缺 doona tarball 会让
   `luci-app-honk` 直接失败，且 `world` 失败后不会出镜像。

## 刷机（实验 VM，非真机）

构建机起 HTTP 服务：

```sh
cd bin/targets/x86/64
python3 -m http.server 8081
```

路由器（串口或 SSH）：

```sh
wget -O /tmp/fw.img.gz http://10.1.18.100:8081/immortalwrt-x86-64-generic-squashfs-combined.img.gz
sha256sum /tmp/fw.img.gz
sysupgrade -n /tmp/fw.img.gz
```

也可以把 `...-combined.vmdk` 直接换给 ESXi VM（BIOS）。本次用的是 sysupgrade，
VM 配置不变。

## 2026-11-09 实测

- 镜像：`immortalwrt-x86-64-generic-squashfs-combined.img.gz`，
  sha256 `575e1f8abd9e679fd5637b5db7b558d8a96af100f27b2e5d2b021ca949512c35`；
- 启动内核 `6.18.60`；manifest 含 `dpd-fastpath`、`dpdfwd`、`dpd-einat-sync`、
  `dpd-napi`、`dpd-honk`、`dpd-observe`、`luci-app-dpd`、`einat-ebpf`；
- `dpdctl status`：ABI 17 loaded/built，mode stateful，gate ok；
- 新镜像上的 netns 客户端：
  - 32MB 下载 0.80s，`flow_hit=13253 redirect=13253 nat_gone=0 flow_fin=3`；
  - 32MB 上传，服务端 `PEER 198.18.0.1 29397 BYTES 33554432`，字节精确；
- `dpdfwd`、`dpd-einat-sync` 都在运行；`flowd.json` 有 ct 计数；
- `dpd-napi` 启用后 `napi.json` `netdev_genl=true`，`dpd-napi-netdev list eth1`
  返回 NAPI 527/528；
- LuCI 四个页面（overview/honk/flows/napi）和菜单 JSON 都在。
