# Running tests

`Pkg.test()` runs the complete suite with the normal Julia compiler. It no
longer restarts Julia with optimization disabled. The suite includes allocation
budgets; do not use a low-optimization run as release performance evidence.

```sh
julia --project=. -e 'using Pkg; Pkg.test()'
```

CI splits complete top-level test sets and included regression files into six
shards. To reproduce one shard, pass the same test arguments through `Pkg.test`:

```sh
julia --project=. -e 'using Pkg; Pkg.test(test_args=ARGS)' -- --shard=1/6 --require-optimized --report=/tmp/diff3d-shard.toml
```

Run every index from 1 through 6 to cover the entire suite. List a shard's units
without executing them with `julia --project=. test/runtests.jl --shard=1/6 --list`.
Shard indices are source-specific, so compare reports from the same revision.
The CI coverage job rejects missing/duplicate shards, different test inventories,
failed runs, and disabled optimization or allocation assertions.

For focused development work, existing regression files can still run directly:

```sh
julia --project=. -e 'include("test/public_contract.jl")'
julia --project=. --threads=4 -e 'include("test/tiled_cache_ownership.jl")'
```

The runner's structural/failure checks are `julia --project=. test/test_runner.jl`
and `python test/test_check_shards.py` (Python 3.11+).
