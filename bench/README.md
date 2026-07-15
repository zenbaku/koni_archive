# bench

Benchmark harness for the koni_archive ecosystem. Workspace member, **never
published**.

Planned benchmarks (§10) — each compared against
`package:archive` as the baseline:

- list a 20k-entry archive
- random-read one page from a large CBZ
- full sequential extract

The harness lands with the first hot-path milestone; results are committed
under [`results/`](results/). Performance is measured, not asserted.
