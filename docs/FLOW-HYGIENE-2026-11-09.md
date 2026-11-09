## G. Flow-table hygiene (N5000 inspection, 2026-11-09)

Measured on the live N5000 after ~2.2 h uptime (`dpdctl flows -a`, 7531 entries):

```
age > 5 min      7250  (96%)
age > 30 min     6572  (87%)
age > 1 hour     6011  (80%)
pkt=0 bytes=0    5064  (67%)
state=bind        257  (3%)
epoch bumps       258 / 8036 s  (one per ~31 s, neighbour-driven)
```

Nothing but LRU ever removed an entry: the hit path only *judged* an entry
expired and fell back to the stack, so `dpd_flows` was effectively "every
5-tuple ever learned". A second finding: `neigh` events (6503 in 2.2 h) kept
the 30 s epoch cooldown saturated, so the whole cache was logically invalidated
every ~31 s; most of the 3.07 M misses were re-learning, not new flows.

Changes:

- **datapath, delete on miss**: an entry that is expired, epoch-stale, or has no
  egress is `bpf_map_delete_elem()`-ed the moment a packet looks it up.
- **datapath, no dead L2 entries**: a flow whose emit class is L2 but whose
  destination MAC is all zero is not learned (would emit into a black hole).
- **dpdfwd, 60 s sweep**: `dpdctl flows prune 900000` removes entries idle for
  longer than any TTL (TCP is clamped at 600 s), which covers flows that never
  come back and therefore never hit the delete-on-lookup path.
- **dpdctl**: new `flows prune [age_ms]` (collect keys, then delete; deleting a
  key the cursor sits on invalidates the iterator).

Expected map occupancy after this: roughly the flows active within the last
10–15 minutes (a few hundred to a couple of thousand), instead of climbing to
16384 and thrashing.

Not changed yet: the neighbour-driven epoch policy. Only bumping on
`NUD_FAILED/INCOMPLETE` (or a real dmac change) should remove most of the
remaining re-learning, but it needs an ARP/ND regression on the live box first.
