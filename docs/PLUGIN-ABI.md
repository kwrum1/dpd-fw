# dpdfwd 插件 ABI（v1）

`dpdfwd` 是控制面 Flow Manager。插件是**控制面共享库**，不进入每包热路径；
热路径仍然是“一次 UFS 查表 + 一次改包 + 一次转发”。插件可以看到
conntrack/拓扑事件、给新流一个分类结论、维护自己的状态，但不得直接修改
数据面的转发字段。

## 1. 发现与加载

- 目录：`/usr/lib/dpd/plugins/`，只扫描 `*.so`；
- 符号：`struct dpd_plugin_ops dpd_plugin_ops`；
- `version` 必须等于 `DPD_PLUGIN_ABI`（当前 1）；
- `init()` 返回非 0、符号缺失、版本不符或 `dlopen` 失败：**只跳过该插件**，
  记录一行 stderr，不影响 `dpdfwd` 和转发；
- 最多 8 个插件；`--plugin-dir DIR` / `--no-plugins` 可覆盖/关闭。

## 2. 结构

```c
struct dpd_plugin_ops {
    const char *name;
    int version;
    int  (*init)(void);
    int  (*flow_classify)(struct dpd_flow_desc *);
    int  (*flow_create)(const struct dpd_flow_desc *);
    void (*flow_expire)(const struct dpd_flow_desc *);
    void (*topology_event)(int event, const char *ifname);
    int  (*dump)(char *buf, size_t len);
};
```

`struct dpd_flow_desc`：family/proto/ifindex、saddr/daddr（16 字节槽，
IPv4 占前 4 字节）、sport/dport（主机序）、action/skb_priority（输出）、
packets/bytes（过期时的统计）。完整定义见
`userspace/dpdfwd/src/dpd_plugin.h`，安装到 `/usr/include/dpd/dpd_plugin.h`。

## 3. 事件与调用点

| 事件 | 调用 | 说明 |
|---|---|---|
| `DPD_EV_LINK/ADDR/ROUTE/NEIGH` | `topology_event()` | rtnetlink 事件，和 epoch 去抖同源 |
| `DPD_EV_CT_NEW` | `flow_classify()` → `flow_create()` | 新 conntrack 流；classify 可设置 action/priority |
| `DPD_EV_CT_UPDATE` | `flow_classify()` → `flow_create()` | 复用同一路径（插件应幂等） |
| `DPD_EV_CT_DESTROY` | `flow_expire()` | conntrack 销毁 |

`flow_classify` 返回的 `action`（`forward/proxy/block/local`）和
`skb_priority` 非默认时，`dpdfwd` 通过 `dpdctl class add any ...` 写入
`dpd_class`；`bump`/定向删流后对新流生效。默认（forward/0）不写，避免
每个流都 fork 一次。

## 4. 安全与边界

- 插件是**同进程**代码，崩溃会带走 `dpdfwd`（procd 会拉起），但数据面
  仍由 BPF 独立运行；设计上要求插件失败只降级自己。
- 插件不得写 `dpd_flows`/`dpd_nat` 等热路径 map；需要改策略时用
  `dpdctl class`/`bump` 的受控路径。
- 插件不参与端口分配、不参与重写、不参与 UFS 命中决策。
- 许可证：`dpd_plugin.h` 和示例为 GPL-2.0-only；第三方插件自行声明。

## 5. 示例

`plugins/dpd-plugin-sample/`：导出 `dpd_plugin_ops`，对 TCP/25 返回
`DPD_PLUGIN_BLOCK`，并统计拓扑/流事件。

```sh
make package/dpd-plugin-sample/compile
# .so 安装到 /usr/lib/dpd/plugins/dpd_plugin_sample.so
logread | grep dpdfwd          # "plugin sample loaded (ABI 1)"
```

手工验证（不装包）：

```sh
mkdir -p /tmp/plugins
cp dpd_plugin_sample.so /tmp/plugins/
dpdfwd --plugin-dir /tmp/plugins --dry-run      # init + 事件，不写 class
```

`--dry-run` 下 `flow_classify` 仍会被调用，但不会执行 `dpdctl class add`。

## 6. 与独立 daemon 插件的关系

`dpd-observe`、`dpd-napi`、`dpd-honk` 等仍是独立包/进程，通过 ubus/文件/
各自的 TCX 工作；本 ABI 只覆盖“需要在 Flow Manager 事件点上做决策”的
轻量插件。两者可以共存。
