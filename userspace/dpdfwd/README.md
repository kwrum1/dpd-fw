# dpdfwd — DPD Flow Manager

Control-plane daemon for DPD-FW.

## Implemented (MVP)

- Subscribes to rtnetlink **link / IPv4 address / IPv4 route / neighbour**
  events. A burst of events is coalesced (300 ms) into **one** flow-cache
  epoch bump (`dpdctl bump`), which invalidates every cached egress decision
  without walking the flow table.
- Subscribes to **conntrack** new / update / destroy events (NETLINK_NETFILTER,
  CTNETLINK groups) and keeps per-type counters. This is the hook for a future
  per-flow delete; it never blocks or drops anything.
- Publishes `/var/run/dpd/flowd.json` every 2 s:

  ```json
  { "uptime": 42, "link": 1, "addr": 1, "route": 2, "neigh": 0,
    "ct_new": 12, "ct_update": 8, "ct_destroy": 10,
    "epoch_bumps": 2, "unknown": 0, "errors": 0, "ct_delete_batches": 3,
    "class_rules": 2, "class_bad": 0, "class_applied_at": 1700000000,
    "class_error": 0, "last_event": 1700000000 }
  ```

- `--dry-run` counts without calling `dpdctl`; `--once` exits after the first
  debounced bump (used by tests).

## Split with the dataplane

- The BPF program owns the direct flow lifecycle: learn on miss,
  `accel_after_pkts`, FIN/RST release, per-protocol TTL, epoch validation.
  `dpdfwd` never touches a packet and is not in the fast path.
- `dpdfwd` owns the environment: a link/route/neighbour change invalidates the
  cache in one place, even when the change did not come through a hotplug
  script (operator `ip route`, tunnel, carrier flap).

## Targeted invalidation (implemented)

On a conntrack DESTROY, the orig and reply 5-tuples are parsed from ctnetlink
and queued (128 max). Once per second the daemon writes them to
`/tmp/dpd-ct-delete` and calls `dpdctl delete -f` **once**; dpdctl scans the
UFS map and deletes every key matching any tuple. A conntrack that no longer
exists therefore does not leave a UFS entry behind until its TTL.

`--no-ct-delete` disables the batch; `--dry-run` keeps the tuples but skips the
call. The UFS key's ingress ifindex is not in the conntrack message, so the
pattern uses `any` for it (the 5-tuple is unique per direction in practice).

## Declarative class policy (`class.conf`)

`dpdfwd` can own the `dpd_class` policy cache from a text file. The default is
`/etc/dpd/class.conf`; `--class-file PATH` overrides it and `--no-class`
disables the feature. One rule per line:

```text
<iface|any> <proto|tcp|udp|number> <saddr> <sport> <daddr> <dport> <forward|proxy|block|local> [priority]
```

`#` starts a comment and blank lines are ignored. `any` (or `0`) is the
wildcard for the interface and for a port. Addresses are literal IPv4 or IPv6
addresses (both must use the same family) and the match is the exact 5-tuple
plus the optional ingress interface: there is no CIDR or address wildcard, only
the ifindex / source-port / destination-port wildcards the datapath already
implements. The optional priority is copied into the UFS entry's
`skb_priority`.

Example `/etc/dpd/class.conf`:

```text
# block outbound SMTP to one host; proxy DNS to a local resolver
br-lan tcp 192.168.1.10 0 192.0.2.10 25 block
any udp 192.168.1.10 any 192.168.1.1 53 proxy 10
```

The daemon `stat()`s the file every 5 s. When its mtime or size changes (and
once at start-up when it exists) it runs `dpdctl class flush`, then one
`dpdctl class add ...` per valid rule with `fork`+`execvp` and an argv array
(never a shell). Invalid lines are skipped and counted; one aggregate warning
is printed per apply. A missing file or a missing `dpdctl` is a silent no-op,
and in a normal run the file is only applied when the `dpd_class` pin exists,
i.e. when `dpd-fastpath` has loaded the core object. Applying stops after 20
consecutive `dpdctl` failures so a removed map cannot make the daemon fork
forever.

Rules are copied into a UFS entry when a flow is learned, so a changed file
only affects flows learned afterwards. To apply a new policy to live flows,
bump the epoch (`dpdctl bump`) or delete the matching flows, then let them be
re-learned.

Verify with `dpdctl class list` (the cache contents) and `dpdctl stats`
(`flow_block` / `flow_skip` grow once a matching flow is learned; the class
cache must also be enabled with `dpdctl set class 1`).

`flowd.json` reports `class_rules` (rules applied), `class_bad` (invalid lines
in the last read), `class_applied_at` (unix time of the last successful apply,
0 = none) and `class_error` (failed `dpdctl` invocations).

## Not yet implemented

- `accel_after_pkts` / TTL policy decisions: the daemon publishes nothing into
  `dpd_cfg` today; the values come from UCI via the datapath init script.
- Plugin classification (ACL/QoS/MWAN/honk) is still done by the individual
  packages; `dpd_class` is the cache, but there is no plugin registration ABI
  yet.
