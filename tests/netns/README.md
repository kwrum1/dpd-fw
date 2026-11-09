# tests/netns — two-namespace DPD path

These scripts build a disposable client/server pair on the router itself, so
the traffic traverses the real DPD hook: LAN ingress -> routing/NAT -> WAN
egress. No switch, VM or external traffic generator is required.

## Layout

```
client ns (dpd-ns-client)            router                      server ns (dpd-ns-server)
  192.168.10.200/24  -- veth --  br-lan ... dpds0/203.0.113.1  -- veth --  203.0.113.2/24
                                                                            203.0.113.3/24
```

- `dpdc0` is a bridge port of `br-lan`; the client default route is
  `192.168.10.1`.
- `dpds0` is in a dedicated firewall zone `dpd_test` with masquerading and a
  `lan -> dpd_test` forwarding rule.
- With `WAN_DUMMY=1`, `dpds0` is instead bridged with a dummy interface
  (`dpdtest0` in `dpdtestbr`) and `203.0.113.1/24` lives on the bridge, so the
  server side looks like a separate uplink.
- `203.0.113.3` is a second address on the server for the `full-cone` peer.

## Requirements

- OpenWrt with `ip-full` (`ip netns`), root shell.
- `br-lan` (or `LAN_BRIDGE=<name>`).
- Optional: `iperf3` (throughput engine), `conntrack` (scoped delete for
  `nat-recreate --force`), `dpdctl` (`nat-recreate` epoch bump), `ethtool`.

## Create / destroy

From the repository root on the router:

```sh
sh tests/netns/setup.sh
```

With a dummy uplink and jumbo MTUs:

```sh
WAN_DUMMY=1 JUMBO=1 sh tests/netns/setup.sh
# equivalent to MTU=9000; br-lan's old MTU is saved and restored
```

Remove everything:

```sh
sh tests/netns/teardown.sh
```

Both scripts are idempotent. Re-running `setup.sh` removes the previous
namespaces, veths, firewall section and dummy bridge first. Only names with
the `dpd`/`dpdtest` prefix are touched.

### Environment

| Variable | Default | Meaning |
|---|---|---|
| `CLIENT_NS` / `SERVER_NS` | `dpd-ns-client` / `dpd-ns-server` | namespace names |
| `CLIENT_IP` / `CLIENT_PREFIX` | `192.168.10.200` / `24` | client address |
| `CLIENT_GW` | `192.168.10.1` | client default gateway |
| `SERVER_IP` / `SERVER_PREFIX` | `203.0.113.2` / `24` | server address |
| `SERVER_PEER_IP` | `203.0.113.3` | second peer address (full-cone) |
| `SERVER_GW` | `203.0.113.1` | router-side server gateway |
| `LAN_BRIDGE` | `br-lan` | existing LAN bridge |
| `LAN_ZONE` | `lan` | firewall zone that owns the LAN bridge |
| `WAN_DUMMY` | `0` | `1` = bridge the server veth with a dummy uplink |
| `DUMMY_DEV` / `SERVER_BRIDGE` | `dpdtest0` / `dpdtestbr` | names for `WAN_DUMMY=1` |
| `MTU` | `1500` | veth MTU; `9000` for the jumbo matrix |
| `STATE_FILE` | `/tmp/dpd-netns.state` | state used by teardown |

The same variables are read by `run.sh` (addresses and namespace names).

## Run a scenario

`run.sh` prints one CSV row, or a header plus one row by default:

```sh
sh tests/netns/run.sh ping
sh tests/netns/run.sh --size 64 --seconds 10 ping
sh tests/netns/run.sh --size 1500 --seconds 10 tcp-download
sh tests/netns/run.sh --size 1500 --seconds 10 tcp-upload
sh tests/netns/run.sh --size 64 --flows 10 --seconds 10 udp
sh tests/netns/run.sh full-cone
sh tests/netns/run.sh --force nat-recreate
```

Options:

| Option | Default | Meaning |
|---|---|---|
| `--size N` | `1500` | ICMP payload / UDP datagram / TCP block hint (`iperf3 -l`, shell `dd bs`) |
| `--seconds N` | `10` | test duration |
| `--flows N` | `1` | parallel flows |
| `--engine auto\|shell\|iperf3` | `auto` | `auto` = iperf3 when installed |
| `--port N` | `5301` | base port (`--port + flow index`) |
| `--no-header` | off | suppress the CSV header (used by `tests/bench/matrix.sh`) |
| `--strict` | off | exit 1 when the scenario gate failed |
| `--force` | off | `nat-recreate`: allow a scoped conntrack delete |

### CSV

```
scenario,size,flows,mbps,pps,cpu_pct,retrans,ts
```

- `mbps` is measured at the receiving side (iperf3 receiver SUM line, or the
  bytes counted by `wc -c`).
- `pps` is derived from the requested `size` (`mbps * 125000 / size`).
- `cpu_pct` is the host CPU busy percentage (all CPUs, `/proc/stat`) over the
  measurement window.
- `retrans` is the sending namespace's `Tcp: RetransSegs` delta (0 for UDP and
  the gate scenarios). When iperf3 reports a retransmit count, that is used.
- `ts` is UTC ISO-8601 to the second.

## What each scenario proves

| Scenario | Proves | Gate |
|---|---|---|
| `ping` | the client -> br-lan -> routing/NAT -> server path works; RTT and loss are sane | at least one reply |
| `tcp-download` | server -> client bulk TCP through NAT, including reverse acceleration | bytes > 0 |
| `tcp-upload` | client -> server bulk TCP, including forward acceleration/NAT | bytes > 0 |
| `udp` | datagram forwarding, per-packet path, fragmentation at the chosen size | bytes > 0 |
| `full-cone` | an inbound packet from a **different peer IP and port** reaches the client socket after one outbound packet | delivered = `mbps 1.000` |
| `nat-recreate` | the flow is re-learned after a `dpdctl bump` (or a scoped conntrack delete) without breaking the NAT binding | both datagrams delivered |

`full-cone` needs `dpd-einat` with full-cone mappings enabled. It reads the
external port from the reply tuple of `/proc/net/nf_conntrack` (or
`/proc/net/ip_conntrack`), then sends from `203.0.113.3:9001` to that port.
`mbps` is a gate bit, not a throughput number.

`ping` sends one probe per second (busybox `ping` has no portable fractional
interval); its `mbps`/`pps` columns are the probe rate, and loss is reported on
stderr. Use it as a reachability gate, not a throughput number.

`nat-recreate` sends two 3-byte UDP datagrams on the same 5-tuple. A pass means
the second one still arrived after the epoch bump. Without `dpdctl` and without
`--force` the script reports a failure and changes nothing.

## Engines

- `iperf3` is used automatically when installed. It is the only engine that
  gives reliable flow counts at `--flows 1000` and precise UDP rates.
- `shell` uses only OpenWrt busybox `nc`, `dd`, `timeout` and `wc`. It is
  functional but not a line-rate generator: for high pps/flow counts install
  `iperf3`.
- TCP `size` is a hint. TCP packet boundaries follow the MSS/MTU; to measure
  frame-size effects use UDP plus `JUMBO=1` for 9000-byte datagrams.

## Notes and limits

- `run.sh` reads the namespace names and addresses from the environment; the
  defaults match `setup.sh`.
- The `dpd_test` zone is a separate masquerading zone, not the real `wan`
  network. DPD must be attached to `br-lan` for the ingress hook to see the
  client flow; a profile that only accelerates a specific real WAN device
  must include this test uplink (or use `WAN_DUMMY=1` and point the profile
  at the bridge).
- The counters for `retrans` are read inside the namespace, not from the root
  namespace's `/proc/net/snmp`.
- `JUMBO=1` raises br-lan, both veths and both namespaces. Teardown restores
  the saved br-lan MTU.
- The shell UDP sender is a shell loop; expect CPU-bound pps. Use `iperf3` for
  the bench matrix when available.
- `full-cone` and `nat-recreate` leave no persistent state; they only use the
  test flow's UDP ports.

## Full-cone (EIF): `full-cone.sh`

`run.sh full-cone` learns the mapping from the reply tuple in conntrack and
is the right gate on a masquerading uplink. `full-cone.sh` is the einat
variant: einat allocates the external port, the operator supplies it, and the
script proves that a datagram from a **different peer IP and port** reaches
the client socket that created the mapping. That is Endpoint-Independent
Filtering (EIF).

### Topology

```
client ns (dpd-ns-client)            router                    server ns (dpd-ns-server)
 192.168.10.200:40000  -- veth -- br-lan ... WAN                203.0.113.2:9000  peer A
                                     198.18.0.1  (einat lab)   203.0.113.3:9001  peer B
                                     203.0.113.1  (setup.sh)
```

Peer A only listens; its job is to make the client's outbound probe create a
real UDP binding (and to reveal the external tuple). Peer B is the unrelated
peer: it binds `SERVER_PEER_IP:EIF_B_PORT` and sends to the mapping's
external tuple. `setup.sh` already assigns both server addresses.

### Prerequisites

- `tests/netns/setup.sh` has run.
- einat is attached with full-cone enabled and `dpd-einat-sync` is mirroring
  bindings into `dpd_nat`; DPD is attached to `br-lan`.
- `python3` on the router for the inline UDP sender/receiver. busybox `nc`
  is deliberately not assumed to implement `-u`.
- Nothing else: the script does not need `conntrack`, and it does not change
  firewall, NAT or DPD configuration.

### Finding the mapped port

einat allocates the port on the first outbound packet, so there is no
configuration value to read. Inspect the ORIG binding for the client's
internal tuple:

```sh
bpftool map dump name map_binding
```

- `key.from_addr` / `key.from_port` are the client tuple
  (`192.168.10.200:40000` by default).
- `key.flags` bit 0 is `BINDING_ORIG_DIR_FLAG`; `key.l4proto` is `17` (UDP).
- `value.to_addr` / `value.to_port` are the external tuple to pass as
  `--external-ip` / `--mapped-port`.

`bpftool map dump` prints the raw key/value hex for custom maps; with BTF it
prints field names. On a little-endian router read the `__u32`/`__u16`
fields accordingly. `logread | grep dpd-einat-sync` confirms that the mirror
is alive (`mirrored N binding(s)`), but it does **not** print individual
ports.

If the first run uses a stale port, step 3 reports the tuple peer A actually
observed and the script exits 1 with the corrected values:

```sh
sh tests/netns/full-cone.sh --mapped-port 1 --external-ip 198.18.0.1
# step 3: mapping is 198.18.0.1:28721, not 198.18.0.1:1
sh tests/netns/full-cone.sh --mapped-port 28721 --external-ip 198.18.0.1
```

The UDP binding normally outlives the failed run, so the corrected re-run
reuses it.

### Commands

```sh
# print every command, send no packets
sh tests/netns/full-cone.sh --dry-run --mapped-port 20001 --external-ip 198.18.0.1

# ESXi lab (einat WAN address)
sh tests/netns/full-cone.sh --mapped-port 20001 --external-ip 198.18.0.1

# plain setup.sh topology (masquerading via SERVER_GW)
sh tests/netns/full-cone.sh --mapped-port 20001 --external-ip 203.0.113.1
```

Options: `--mapped-port PORT` (required), `--external-ip ADDR` (default
`203.0.113.1`), `--dry-run`. Environment overrides: `CLIENT_NS`,
`SERVER_NS`, `CLIENT_IP`, `SERVER_IP`, `SERVER_PEER_IP`, `EXTERNAL_IP`,
`EIF_CLIENT_PORT`, `EIF_A_PORT`, `EIF_B_PORT`, `TIMEOUT`.

### What proves what

1. The client binds `CLIENT_IP:EIF_CLIENT_PORT` and sends
   `dpd-eif-probe` to peer A. This is the outbound packet that creates the
   mapping.
2. Peer A receives it and prints the source tuple it saw. A match against
   `EXTERNAL_IP:MAPPED_PORT` proves the binding exists and that the operator's
   arguments are current; a mismatch fails with the observed tuple.
3. Peer B, from a different address and port, sends `dpd-eif-from-b` to
   `EXTERNAL_IP:MAPPED_PORT`.
4. The client socket receives `dpd-eif-from-b` from `SERVER_PEER_IP`.
   A restricted-cone mapping (endpoint-dependent filtering) would drop it
   even though the binding exists; a full-cone mapping delivers it.

The client's echo back to B is informational (the return path is already
established by B's packet). The gate is step 4. The final line is
`full-cone: PASS` or `full-cone: FAIL`; diagnostics and hints go to stderr.

### Notes and limits

- The test needs einat (or another full-cone NAT) on the WAN side. With fw4
  masquerade only, use `run.sh full-cone`, which reads conntrack.
- Do not run einat and fw4 masquerade on the same uplink at the same time:
  the slow path and accelerated path would allocate different external
  ports (see `docs/P2-NAT.md`).
- A wrong `--mapped-port` is not a NAT failure. The script stops at step 3
  and prints the tuple to use.
- Exit codes: `0` PASS or `--dry-run`, `1` FAIL, `2` usage/prerequisite
  (including a missing `--mapped-port` or `python3`).

## IPv6: `ipv6.sh`

`ipv6.sh` configures one ULA /64 on each side of the router, proves that the
v6 path routes and forwards, then runs a TCP transfer large enough for DPD's
fast path to take over. It also checks the reverse flow entry that DPD seeds
for IPv6 (there is no NAT66 to create one later).

### Topology

```
client ns                         router                              server ns
fd00:10::2/64  -- veth -- br-lan fd00:10::1/64
                          dpds0 fd00:20::1/64  -- veth --  fd00:20::3/64
```

The script derives each gateway by replacing the host part with `::1`
(`fd00:10::2/64` -> `fd00:10::1/64`) and adds it temporarily to `br-lan` and
to the WAN-side device. The device is found from `ip route get SERVER_IP`
(fallback: `SERVER_DEV` in `STATE_FILE`, then `dpds0`). It adds host routes
(`/128`) in the namespaces, not default routes, so nothing else is
clobbered. On exit it removes the addresses and routes it added and restores
`net.ipv6.conf.all.forwarding`.

### Prerequisites

- `tests/netns/setup.sh` has run; IPv6 is enabled in the kernel and both
  namespaces (`net.ipv6.conf.all.disable_ipv6=0`).
- DPD has IPv6 acceleration enabled: `option ipv6 '1'` (the shipped config)
  or `dpdctl set ipv6 1`. `dpdctl show` must print `ipv6 1`, and the mode
  must not be `off` or `observe`.
- fw4 allows `lan -> dpd_test` forwarding for IPv6. The forwarding rule from
  `setup.sh` is family-agnostic; a custom zone must not be v4-only.
- `ping6` (or `ping -6`), `dpdctl`, and one of `iperf3`, `python3`, or
  `nc`+`timeout`. `iperf3` and `python3` are preferred: some busybox `nc`
  builds listen on IPv4 only.
- `--client6` and `--peer6` must be in different /64s.

### Commands

```sh
sh tests/netns/ipv6.sh --dry-run
sh tests/netns/ipv6.sh
sh tests/netns/ipv6.sh --client6 fd00:10::2/64 --peer6 fd00:20::3/64
```

Options: `--client6 ADDR/64` (default `fd00:10::2/64`), `--peer6 ADDR/64`
(default `fd00:20::3/64`), `--dry-run`. Environment: `CLIENT_NS`,
`SERVER_NS`, `CLIENT_IP`, `SERVER_IP`, `STATE_FILE`, `CLIENT6`, `PEER6`,
`CLIENT6_DEV`, `SERVER6_DEV`, `TCP_PORT`, `TCP_BYTES`, `TIMEOUT`, `DPDCTL`.

### What proves what

- **Ping6 replies.** The client's packets cross `br-lan`, the routing code
  and the `dpd_test` zone to the peer and back. IPv6 is routed; no NAT66 is
  involved. ICMPv6 is not eligible for the DPD fast path, so ping alone
  never proves acceleration.
- **`v6_ok` grows.** The TCP transfer is 256 KiB by default, well past
  `accel_after_pkts` (default 32). `dpdctl stats` must show a positive
  `v6_ok` delta; that counter is incremented only when DPD actually takes
  over an IPv6 packet. `v6_skip` (not a gate) explains refusals.
- **The reverse entry exists.** `dpdctl flows -a` must contain at least two
  more `fam=10` (AF_INET6) entries after the transfer: the forward flow
  learned from the first packet, plus the reverse entry seeded from the same
  frame. The reverse entry is what lets the reply half use the fast path
  even though conntrack, not NAT66, carries it. The listing does not print
  addresses, so the script counts entries before and after; `iperf3` may
  create a control and a data connection, so a delta of 4 is also normal.

PASS requires all three: replies > 0, `v6_ok` delta > 0, and `fam=10` flow
delta >= 2. The final line is `ipv6: PASS` or `ipv6: FAIL`.

### Notes and limits

- The ESXi lab's `ly-route` peer has only IPv4 today. When the peer cannot
  be configured for IPv6, `ipv6.sh` prints `ipv6: SKIP (...)` with the reason
  and exits 3; it never reports a pass without traffic. Run the scenario on
  the netns lab, or pass a `--peer6` on a v6-capable peer.
- IPv6 stays routed-only: no NAT66. DPD accelerates only LAN->WAN TCP/UDP
  without extension headers or fragments; return traffic stays on the stack
  and is covered by conntrack/fw4. Do not use `--client6`/`--peer6` with
  `fe80::/10` (link-local) or multicast addresses.
- If the egress is taught as a NAT uplink (`dpd_iface.gw4` is set, i.e.
  `ip -4 route show default dev <if>` is non-empty for that device in the
  router namespace), the fast path refuses IPv6 by design and `v6_ok` stays
  flat. The netns `dpds0` is not such an uplink because the server's default
  route lives in its own namespace; a real WAN is. That is a code limitation,
  not a test bug.
- `setup.sh` does not configure IPv6. `ipv6.sh` is safe to rerun (it uses
  `addr replace`/`route replace`), but after a crash remove
  `fd00:10::1/64` from `br-lan` and `fd00:20::1/64` from the WAN-side
  device by hand, and restore `net.ipv6.conf.all.forwarding` if it was
  changed. A rerun will not remove an address it found already present.
- Exit codes: `0` PASS or `--dry-run`, `1` FAIL, `2` usage/setup, `3` SKIP
  (IPv6 not available or DPD's `ipv6` option is off).
