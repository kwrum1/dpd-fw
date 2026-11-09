# tests/bench — DPD throughput / CPU / IRQ harness

Three small POSIX-sh tools around the `tests/netns` pair:

| Script | Purpose |
|---|---|
| `matrix.sh` | run the size/flow matrix, write `results.csv` |
| `sample.sh` | snapshot `/proc/net/dev`, `dpdctl stats`, `napi.json`, `/proc/interrupts`; print deltas |
| `compare.sh` | baseline vs DPD `results.csv` as a Markdown table |

## Quick start

```sh
# on the router, from the repository root
sh tests/netns/setup.sh

# baseline (DPD disabled or stock image)
sh tests/bench/matrix.sh --out baseline.csv

# enable/install DPD, then the same matrix
sh tests/bench/matrix.sh --out dpd.csv

sh tests/bench/compare.sh baseline.csv dpd.csv
```

`matrix.sh` uses `tests/netns/run.sh`, so the traffic crosses the real DPD
hook. The defaults are 64/128/512/1500/9000 bytes, 1/10/100/1000 flows and the
three throughput scenarios, 10 seconds per cell: 60 cells. Use `--quick` for a
smoke run.

## matrix.sh

```sh
# full default matrix
sh tests/bench/matrix.sh

# explicit axes
sh tests/bench/matrix.sh --sizes "64 128 512 1500 9000" \
                         --flows "1 10 100 1000" \
                         --scenarios "tcp-download tcp-upload udp" \
                         --seconds 10 --out results.csv

# one engine, one scenario
sh tests/bench/matrix.sh --scenarios udp --engine iperf3 --flows "1 100"

# compare a router against an external iperf3 server (no namespaces)
sh tests/bench/matrix.sh --server 192.168.10.162 --out wan.csv

# smoke test
sh tests/bench/matrix.sh --quick
```

Options: `--sizes`, `--flows`, `--scenarios`, `--seconds`, `--out`,
`--engine auto|shell|iperf3`, `--server HOST`, `--port`, `--quick`,
`--no-setup-check`.

### results.csv

```
scenario,size,flows,mbps,pps,cpu_pct,retrans,ts
tcp-download,1500,10,941.208,78434.0,37.1,0,2026-11-09T08:12:41Z
```

- `mbps` — receiver-side throughput.
- `pps` — `mbps * 125000 / size` (derived from the requested size).
- `cpu_pct` — host CPU busy (all CPUs) during the cell.
- `retrans` — TCP retransmits (iperf3 counter when present, otherwise the
  `/proc/net/snmp` delta on the sender side).
- `ts` — UTC ISO-8601.

Failures still write a zero row and append the command output/reason to
`results.csv.log`, so the CSV never has holes. The exit status is 0 once the
matrix ran; inspect the log and the rows for failures.

### 9000-byte rows

TCP and UDP `9000` only work end-to-end when the MTUs allow it:

```sh
JUMBO=1 sh tests/netns/setup.sh      # raises br-lan + veths, restores on teardown
```

Without jumbo MTUs the 9000-byte cells are still recorded (usually with low
throughput or loss); they are not silently skipped.

## sample.sh

```sh
# 30 s window, LAN and WAN devices
sh tests/bench/sample.sh --dev br-lan --dev eth1 --seconds 30

# default devices: br-lan + the UCI wan device (or every physical NIC)
sh tests/bench/sample.sh --seconds 60 --interval 5 --out /tmp/dpd.json

# keep the raw samples for auditing
sh tests/bench/sample.sh --dev eth1 --raw /tmp/eth1.raw --out /tmp/eth1.json
```

Sample while a load runs (in another shell), then compare the DPD run with the
baseline run:

```sh
sh tests/bench/sample.sh --dev br-lan --dev eth1 --seconds 30 --out base.json &
sh tests/netns/run.sh --size 1500 --seconds 30 tcp-download
wait
```

Output:

```json
{
  "seconds": 30,
  "samples": 31,
  "cpu_pct": 28.4,
  "devices": {
    "br-lan": {"rx_bytes": 0, "rx_pkts": 0, "rx_errs": 0, "rx_drops": 0,
               "rx_mbps": 0.0, "rx_pps": 0.0, ...}
  },
  "dpd": {"pkt_total": 123, "flow_hit": 100, ...},
  "napi": {"gro_flush_timeout": 0, "napi_defer_hard_irqs": 0,
           "netdev_genl": true, "devices": " br-lan eth1"},
  "interrupts": {"eth1": {"total": 14823, "irqs": {"40": 8123, "41": 6700}}}
}
```

- Device counters are deltas between the first and last sample, with rates over
  the measured wall-clock window.
- `dpd` contains the delta of every `dpdctl stats` counter.
- `interrupts` sums the device's NAPI/MSI IRQs over all CPUs
  (`dpd-napi-netdev list`, then `msi_irqs`, then `/proc/interrupts`).
- `napi.json` fields are copied from `/var/run/dpd/napi.json` if present.

The raw file is a pipe-delimited stream (`C|`, `D|`, `S|`, `I|`, `N|`) and is
printable/auditable with awk.

## compare.sh

```sh
sh tests/bench/compare.sh baseline.csv dpd.csv
sh tests/bench/compare.sh baseline.csv dpd.csv > compare.md
```

Runs are matched on `(scenario, size, flows)`; column order in the CSV does not
matter. The output is a Markdown table with baseline, DPD, and delta for Mbps
and pps, plus CPU and retransmit changes. It prints matched / only-baseline /
only-DPD counts, improved/degraded counts, and the aggregate throughput ratio.
It exits 1 when there is no common row.

## Notes

- The matrix covers throughput scenarios (`tcp-download`, `tcp-upload`, `udp`,
  and `ping`). The gate scenarios (`full-cone`, `nat-recreate`) are run
  directly with `tests/netns/run.sh`; they do not have a size/flow axis.
- Both `matrix.sh` and `sample.sh` avoid bashisms; only POSIX sh and awk are
  used (plus busybox `nc`/`dd`/`timeout` in the shell engine).
- `--server` mode talks to an already-running iperf3 server; it does not start
  or stop anything on the peer. Only TCP/UDP scenarios are available there.
- The shell engine is useful for gate checks, not for line-rate numbers. Install
  `iperf3` on the router for 100/1000-flow cells.
- Keep the matrix duration long enough to leave the flow-learning phase
  (`accel_after_pkts`) before comparing; 10 s is a minimum, 30 s is better.
- Record the commit, kernel, NIC, qdisc/GRO/NAPI state with every run; see
  `docs/BENCHMARK.md`.
