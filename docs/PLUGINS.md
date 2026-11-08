# DPD-FW 插件模型

## 目标

- 数据面热路径固定：一次 UFS 查表、一次改包、一次转发。
- 插件默认只挂控制面/慢路径；不允许每包遍历插件链。
- 插件崩溃不影响 `dpd-core` 数据面。
- 插件可独立打包、独立升级，但必须通过 ABI/内核/固件版本检查。

## 插件类型

| 类型 | 例子 | 运行位置 | 是否进热路径 |
|---|---|---|---|
| proxy | `dpd-honk` | 独立进程 + honk TCX | 否（honk 先 redirect） |
| nat | `dpd-einat` | BPF + 用户态绑定表 | 慢路径建立，UFS 缓存 |
| policy | `dpd-acl` | TC pref 90 + BPF | 是（在 UFS 之前） |
| qos | `dpd-qos` | qdisc + BPF 元数据 | 是（qdisc 路径） |
| mwan | `dpd-mwan` | 控制面 + UFS | 慢路径建立 |
| observe | `dpd-observe` | 用户态 | 否 |
| provider | `dpd-knod` | 可选加速器 | 可选 |

## ABI

```c
struct dpd_plugin_ops {
    const char *name;
    int version;
    int (*init)(void);
    int (*flow_classify)(struct dpd_flow_desc *);
    int (*flow_create)(struct dpd_flow_desc *);
    void (*flow_expire)(struct dpd_flow_desc *);
    void (*topology_event)(int type);
    int (*dump)(struct dpd_dump *);
};
```

- `flow_classify` 只在流建立/策略刷新时调用。
- `flow_create` 可写 UFS 附加值（DSCP、queue、WAN、binding）。
- `flow_expire` 在 UFS 老化/失效时调用。
- `topology_event` 用于 link/route/neigh/WAN 变化。
- 插件不得直接修改热路径 UFS 的转发字段；只能通过 `dpd-flowd` 的受控 API。

## 生命周期

1. `dpd-flowd` 启动，加载 `dpd-core` ABI。
2. 插件注册：名称、版本、能力位。
3. `dpd-flowd` 校验内核/ABI/固件版本。
4. 事件循环：conntrack、honk ubus、einat、netlink、定时器。
5. 插件失败 → 降级/禁用，不影响直连转发。

## 版本检查

- `DPD_ABI_VERSION`：UFS 结构/命令。
- `DPD_PLUGIN_ABI`：插件接口。
- `kernel 6.18`：内核特性/配置。
- 固件 tag：`dpd-fw` 版本。

不匹配时拒绝加载并给出稳定错误码，不允许“猜着跑”。

## 插件与许可证

- `dpd-core`、`dpd-acl`、`dpd-qos`、`dpd-mwan`、`dpd-observe`：GPL-2.0-only。
- `dpd-honk`：GPL-3.0-only，独立进程/插件，不链接 core。
- 文档：CC BY 4.0。
