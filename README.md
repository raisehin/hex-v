# hex-v — the Dot scope speaking indicator, outside the Rust app

Small program that reproduces hex 3.4.0's speaking indicator (Dot scope) on
Windows, written in V. Nothing in `C:\Users\rhais\documents\odin-hex` changes:
`bin\hex.exe` keeps its own HUD so the two can be compared side by side.

```
oracle/     Rust: hex 3.4.0's own simulation sources, compiled standalone,
            emits the reference u16 dot buffer. Not part of the product.
v/          the program (V), added next.
```

## The oracle

`oracle/src` contains **verbatim copies** of

| file | from |
|---|---|
| `rune_hud/dot_scope.rs` | `src/rune_hud/dot_scope.rs` |
| `rune_hud/dot_scope/scope.rs` | `src/rune_hud/dot_scope/scope.rs` |
| `rune_hud/spring.rs` | `src/rune_hud/spring.rs` |
| `rune_hud/hud_placement.rs` | `src/rune_hud/hud_placement.rs` |
| `dictation/indicator.rs` | `src/dictation/indicator.rs` |

The only additions are shims for four app-only items the copied files touch:
`app_paths::support_dir`, `durable::write`, `app_settings::IndicatorPosition`,
`macos_rune::wake_pump`, plus a 20-line `color-eyre` stub (`Result<T>`) because
0.6.5 is not in the local cargo cache and there is no network here.

`src/main.rs` replicates `src/rune_hud/tests.rs:50-77` exactly: a 330-frame
schedule at 1/60 s, `demo_loudness(t)` as the meter for the first 3 s, then
`Submitted { job_id: 1 }` at 3.0, `Processing { job_id: 1 }` at 3.6,
`JobCompleted { job_id: 1 }` at 4.4, `step(now, 1.0/60.0, false)` per frame.

Build and run (offline, 16 s, no network):

```
cd oracle && cargo build --offline --release
./target/release/hex-v-oracle.exe out
```

### Why not `cargo test --bin hex rune_hud_frames`

That is the real command and it cannot run on this machine:

- there is no network (`github.com` and `static.crates.io` are unreachable);
- `Cargo.toml` patches `transcribe-cpp` to `anomalyco/transcribe.cpp@bcb639f`,
  which is **not** in `~/.cargo/git` (only `7045d1c` is, and that revision is a
  single `transcribe-cpp-sys` package, so it cannot satisfy `transcribe-cpp`).

So the hex binary cannot be built here at all. The simulation can: those five
files depend only on each other, `serde` and `std`. Copying them compiles the
same arithmetic, so `dots.bin` is the same bytes the real test would write.

What is still missing as a consequence: the **PNG golden frames** (gate (b)),
which need wgpu and therefore the whole app. Unblock: one machine with network,
`cargo test --bin hex rune_hud_frames`, then copy the `NNNN.png` files here.

## `oracle/out/dots.bin`

330 frames × 4096 bytes = 1,351,680 bytes,
sha256 `a8d6f7c484fc376dbb18c113782e74ec…`

Per frame, `rune_hud.rs:824 packed_dots` layout: up to `MAX_DOTS` (1024) dots,
row by row, each one little-endian `u16 power, u16 fresh`, zero-padded to
4096 bytes. `power` and `fresh` are
`(v.clamp(0.0, 1.0) * 65535.0).round() as u16` (`indicator.rs:452`).

Default tuning gives `columns = 43`, `rows = 9` — the same field the Odin HUD
draws.

Sanity samples: frame 90 has all 387 dots lit with `fresh = 65535` (mid
recording, braid travelling); frame 0 has 117 fading in; frame 329 has 26
fading out.

## `oracle/out/meta.tsv`

One row per frame: `frame, t, columns, rows` then the `Pose` fields
(`width, height, opacity, scale, softness, cool, glow, grid, live, done,
reveal`). These are the plate terms the rasteriser needs.

## Next

1. `v/` — `tuning.v`, `spring.v`, `scope.v`, `pack.v`: replay this schedule,
   diff `dots.bin` byte for byte. Build with `-cc gcc -cflags -ffp-contract=off`.
2. `v/render/raster.v` — the fragment maths from `rune_hud.wgsl:244-343`,
   compared against 3.4.0's PNGs once they can be produced.
3. Present through `UpdateLayeredWindow` and measure the inter-paint interval
   against the current `SetTimer(42)` HUD.
