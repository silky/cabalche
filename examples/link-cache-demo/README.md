# link-cache-demo

A small self-contained multi-package cabal project used to demonstrate
this fork's link-output cache on a realistic dependency cone.

```
demo-core              (no internal deps)
   ↑       ↑
demo-codec   demo-graph
       ↑    ↑
       demo-engine
            ↑
         demo-app      (executable)
```

A single edit in `demo-core` cascades through five link steps
(`demo-core.a` → `demo-codec.a` → `demo-graph.a` → `demo-engine.a` →
`demo-app`), so the link-cache's effect is visible across the entire
build, not just at the root.

## Building

```sh
cabal build all --project-file=examples/link-cache-demo/cabal.project
cabal test  all --project-file=examples/link-cache-demo/cabal.project
```

## Benchmarking the link cache

`scripts/link-cache-demo-bench.sh` drives this project through five
edit shapes the cache has never seen before — each timed cache-on
build starts from a cache pre-populated with only the *baseline*
link outputs, so the measurement reflects what a developer making a
real first-time edit experiences. Results land in `REPORT.md` here.

```sh
scripts/link-cache-demo-bench.sh --cabal=/path/to/forked/cabal
```

Scenarios (all edits target `demo-core/src/Demo/Core/Util.hs`):

| Scenario          | Edit shape                                           | Expected cache |
| ----------------- | ---------------------------------------------------- | -------------- |
| body-stable       | wrap a function body in a no-op `let`                | full HIT       |
| add-unexported    | append a new private binding                         | mixed          |
| add-exported      | append a new binding + extend the export list       | mostly MISS    |
| modify-type       | strengthen the constraint on `describe`              | MISS           |
| refactor-internal | eta-expand a private helper                          | mixed          |

The script restores the file with `git checkout` after every measurement;
do not run it with uncommitted edits to `Util.hs`.
