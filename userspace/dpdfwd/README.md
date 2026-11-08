# dpdfwd — DPD Flow Manager

Control-plane daemon for DPD-FW.

## Responsibilities

- Subscribe to:
  - conntrack events (new/destroy/update),
  - honk ubus state,
  - einat binding events,
  - ACL/QoS/MWAN config changes,
  - netlink link/route/neighbour events.
- Maintain the flow state machine:
  `NEW -> OBSERVE(accel_after_pkts) -> BIND -> FIN`.
- Install/refresh/expire UFS entries through `libdpd`.
- Apply classifier plugins (`dpd-acl`, `dpd-qos`, `dpd-mwan`, `dpd-honk`).
- Publish gate/status/telemetry.

## Design notes

- Simple direct flows may be learned in BPF; `dpdfwd` handles complex flows
  (NAT/full-cone/MWAN/proxy) and policy.
- A flow is not accelerated until `accel_after_pkts` (default 32) are observed,
  so short flows stay on the stack.
- Topology/policy changes bump an epoch; stale UFS entries are ignored.
- The daemon must be restartable without dropping the dataplane: UFS entries
  survive, `dpdfwd` repopulates metadata.

## Status

Scaffold (P0). Implementation lands in P1.
