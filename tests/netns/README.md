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
