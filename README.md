# Asynchronous FIFO (parameterized, Gray-coded pointers, two clocks)

A parameterized dual-clock FIFO in SystemVerilog. The write side and the read
side run on unrelated clocks. Data sits in a small memory and only the pointers
cross between the clock domains: each pointer is Gray coded and passes through a
2-flop synchronizer per bit. The design has status flags (full, empty, almost
full, almost empty, overflow, underflow), a self-checking testbench that is run
across eight clock configurations, and a script that sweeps the parameters and
runs the testbench against deliberately broken copies of the RTL.

## Repository layout

| Path | Contents |
|---|---|
| `rtl/async_FIFO.sv` | the FIFO |
| `tb/tb_async.sv` | self-checking testbench |
| `run_checks.ps1` | runs the parameter sweep and the mutation tests (Windows PowerShell) |
| `results.md` | tables produced by the last run of `run_checks.ps1` |
| `logs/` | raw simulator output of every run (not committed) |
| `.gitignore` | ignores the compiled simulation file, `logs/` and the temporary mutation file |

## Parameters

| Parameter | Default | Meaning |
|---|---|---|
| `DATA_WIDTH` | 32 | width of `write_data` / `read_data` |
| `MEM_DEPTH` | 32 | number of entries; must be a power of 2 and >= 4 |
| `ALMOST_EMPTY` | `MEM_DEPTH/4` | `almost_empty` is high for occupancy 1 to this value |
| `ALMOST_FULL` | `MEM_DEPTH - MEM_DEPTH/4` | `almost_full` is high from this occupancy to `MEM_DEPTH-1` |

Illegal settings are rejected at time 0 in simulation with an `$error`:
`MEM_DEPTH` not a power of 2 (or below 4), or thresholds that don't satisfy
`1 <= ALMOST_EMPTY < ALMOST_FULL <= MEM_DEPTH-1`. The minimum depth is 4 because
the `full` check compares the top two pointer bits. The check is fenced with
`synthesis translate_off/on`.

Defaults by depth:

| `MEM_DEPTH` | `almost_empty` | `almost_full` |
|---|---|---|
| 4 | 1 | 3 |
| 8 | 1 to 2 | 6 to 7 |
| 16 | 1 to 4 | 12 to 15 |
| 32 | 1 to 8 | 24 to 31 |
| 64 | 1 to 16 | 48 to 63 |

## Ports

| Port | Domain | Dir | Description |
|---|---|---|---|
| `clk_write_side` | write | in | write-domain clock |
| `clk_read_side` | read | in | read-domain clock |
| `reset_n_write_side` | write | in | asynchronous active-low reset for the write domain |
| `reset_n_read_side` | read | in | asynchronous active-low reset for the read domain |
| `write_en`, `write_data[DATA_WIDTH-1:0]` | write | in | write request and data |
| `read_en` | read | in | read request |
| `read_data[DATA_WIDTH-1:0]` | read | out | registered, valid one read-clock cycle after a valid read |
| `full`, `almost_full` | write | out | occupancy `MEM_DEPTH` / occupancy `ALMOST_FULL` to `MEM_DEPTH-1` |
| `empty`, `almost_empty` | read | out | occupancy 0 / occupancy 1 to `ALMOST_EMPTY` |
| `overflow` | write | out | a write is requested while `full` is high |
| `underflow` | read | out | a read is requested while `empty` is high |

`overflow` and `underflow` are combinational: they follow the request in the
same cycle, regardless of the other request, and are not latched.

## How it works

- **Pointers.** The write and read pointers are `$clog2(MEM_DEPTH) + 1` bits
  wide: the lower bits address the memory and the extra MSB tells full from
  empty. Both pointers are binary counters that live in their own clock domain.
- **Gray code across the boundary.** Each side converts its binary pointer to
  Gray code (`gray = bin ^ (bin >> 1)`), registers it, and sends that registered
  copy to the other domain. Gray code changes one bit per step, so a pointer
  sampled while it is changing is either the old value or the new one, never a
  value that was not on the bus.
- **Synchronizers.** In the receiving domain every bit of the incoming Gray
  pointer passes through two flip-flops on the receiving clock, which gives a
  metastable first flop a clock period to settle.
- **Flags.** `empty` is computed in the read domain: own Gray read pointer equals
  the synchronized Gray write pointer. `full` is computed in the write domain:
  own Gray write pointer against the synchronized Gray read pointer, where "full"
  means the top two Gray bits differ and the remaining bits are equal (the Gray
  form of "MSB differs, lower bits equal").
- **Almost flags.** Gray code cannot be subtracted, so the synchronized pointer
  is decoded back to binary first (each binary bit is the XOR of the Gray bits at
  and above its position, written as a loop that works for any width). Occupancy
  is then `write_ptr - synchronized read_ptr` on the write side and
  `synchronized write_ptr - read_ptr` on the read side. `almost_full` is high for
  occupancy `ALMOST_FULL` to `MEM_DEPTH-1` and `almost_empty` for 1 to
  `ALMOST_EMPTY`; both are low when the FIFO is full or empty respectively.
- **Flags are conservative.** Each side sees the other side's pointer a few
  cycles late, so the flags can stay high slightly longer than the FIFO's true
  state, but never drop early: `full` and `empty` are never missed, and neither
  are the almost flags. The FIFO therefore never overflows or underflows, at the
  cost of lagging flags.
- **Memory.** The memory has its own write block with no reset (so it can map to
  a RAM) and is written on the write clock and read on the read clock.

## Behavior

- A write when `full` is high is ignored. A read when `empty` is high is
  ignored, and `read_data` holds its value.
- Reset clears both pointers, the synchronizers and `read_data`. The memory
  contents are not reset.
- Both resets are expected to be asserted together. Releasing them at different
  times is supported (and tested); resetting only one side is not.

## Run

From the repository root, default configuration (32-bit data, 32 entries):

    iverilog -g2012 -o sim_async rtl/async_FIFO.sv tb/tb_async.sv
    vvp sim_async

Other configurations (top-level testbench parameters can be overridden):

    iverilog -g2012 -Ptb_async.DEPTH=16 -Ptb_async.DATA_WIDTH=8 -o sim_async rtl/async_FIFO.sv tb/tb_async.sv
    vvp sim_async

A passing run prints `ALL CHECKS PASSED`. A failure stops the run at the first
problem and prints the simulation time, the clock configuration, the test
number and the reason. An illegal setting prints the DUT's `$error` and stops
without that line. `vvp sim_async +seed=5` changes the random traffic; without
it every run is identical.

To run the whole parameter sweep and all mutation tests in one go (Windows
PowerShell):

    powershell -ExecutionPolicy Bypass -File run_checks.ps1

This writes the summary tables to `results.md` and the full simulator output to
`logs/all_runs.log`.

## Verification

Because the flags lag, the testbench cannot compare them cycle by cycle the way
a single-clock testbench can. It keeps a queue-based reference model of the
words in the FIFO and checks safety properties instead:

| Check | Meaning |
|---|---|
| data order | every word read equals the oldest word written (no loss, no duplicates, no junk) |
| no early "not empty" | `empty=0` only when the model holds at least one word |
| no early "not full" | `full=0` only when the model holds fewer than `MEM_DEPTH` words |
| almost flags never miss | `almost_full` or `full` is high whenever the model holds `ALMOST_FULL` or more words; `almost_empty` or `empty` is high whenever it holds 1 to `ALMOST_EMPTY` |
| almost flags are exclusive | `almost_full` is never high together with `full`, `almost_empty` never with `empty` |
| overflow / underflow | `overflow` equals `full && write_en`, `underflow` equals `empty && read_en` |
| bounded flag latency | a flag may stay high after the state changed, but only for a bounded time: writer period + 4 reader periods for `empty` and `almost_empty`, reader period + 4 writer periods for `full` and `almost_full` |
| `read_data` holds | it does not change unless a valid read happens |
| async reset | outputs clear immediately on reset, without a clock edge |
| no X/Z | none of the flags is ever X or Z once out of reset |

Width, depth and thresholds are testbench parameters passed to the DUT; data
comes from a width-independent generator (random, counter and corner patterns
repeated across the width).

### Clock configurations

The whole test list runs once per configuration:

| Config | Write clock period | Read clock period | Note |
|---|---|---|---|
| 0 | 10000 ps | 10000 ps | equal clocks |
| 1 | 10000 ps | 10026 ps | almost equal: the phase drifts through every alignment |
| 2 | 5000 ps | 10006 ps | fast writer, slow reader |
| 3 | 10006 ps | 5000 ps | slow writer, fast reader |
| 4 | 6002 ps | 14006 ps | about 3:7 |
| 5 | 14006 ps | 6002 ps | about 7:3 |
| 6 | 2000 ps | 20014 ps | 1:10 |
| 7 | 20014 ps | 2000 ps | 10:1 |

### Tests (run in every configuration)

1. Reset state, flags stable while idle.
2. Single words and back-to-back words.
3. Fill to full with extra write attempts, drain to empty with extra read attempts.
4. Simultaneous write and read at full, at empty, and at mid occupancy.
5. Traffic that oscillates around the full, empty and middle boundaries.
6. Pointer wrap-around with incrementing data, and corner data patterns (all zeros, all ones, alternating bits, a single bit set or cleared, and others).
7. Resets: while full, partially full and empty; a reset pulse shorter than a clock period; a reset in the middle of traffic; staggered release with the write side first and with the read side first.
8. Random traffic: balanced, write-heavy, read-heavy, full-rate and bursty.
9. Both clock frequencies change while traffic runs.

A coverage check fails a configuration if something was never exercised: any
flag never seen high, no flag rise or fall, no overflow or underflow attempt,
no occupancy of `MEM_DEPTH`, no drain to 0, no pointer wrap, no concurrent
traffic, no all-zero or all-ones data, or any of the reset scenarios above.

### Parameter sweep

Simulator: Icarus Verilog (`iverilog -g2012`). Each run covers all eight clock
configurations above.

| Config | Expected | Result |
|---|---|---|
| depth 32, width 32 (default) | pass | pass |
| depth 4, width 32 | pass | pass |
| depth 8, width 32 | pass | pass |
| depth 16, width 32 | pass | pass |
| depth 64, width 32 | pass | pass |
| depth 8, width 8 | pass | pass |
| depth 16, width 1 | pass | pass |
| depth 32, width 100 | pass | pass |
| depth 8, almost_empty 3, almost_full 5 | pass | pass |
| depth 6 | rejected by `$error` | rejected by `$error` |
| depth 2 | rejected by `$error` | rejected by `$error` |
| depth 8, almost_empty 0 | rejected by `$error` | rejected by `$error` |
| depth 8, almost_full 8 | rejected by `$error` | rejected by `$error` |
| depth 8, almost_empty 5, almost_full 5 | rejected by `$error` | rejected by `$error` |

### Mutation testing

To check the testbench itself, `run_checks.ps1` breaks the RTL on purpose, one
change at a time, starting from the clean file each time, and runs the testbench
on every broken copy in the default configuration (depth 32, width 32). There
are 44 mutations. **40 are caught**, each at the first failing check; the full
table with the time and reason of every failure is in `results.md`. The
mutations cover:

| Area | Mutations | Caught |
|---|---|---|
| flow control (`~full` in `do_write`, `~empty` in `do_read`, `read_en` in `do_read`) | 3 | 3 |
| `full` / `empty` logic (inversion, ignored bits, `!=`, stale registered pointers) | 7 | 7 |
| Gray conversion and pointer steps (`>> 2`, pointers step by 2) | 3 | 3 |
| memory and widths (wrong index, memory or data ports one too small, `ADDRESS_WIDTH` off by one) | 7 | 7 |
| resets (`read_data` not reset, synchronous instead of asynchronous) | 3 | 3 |
| synchronizer second stage stuck at 0 | 2 | 2 |
| almost-flag thresholds (off by one, hard-coded, masks removed) | 8 | 8 |
| overflow / underflow | 2 | 2 |
| Gray subtraction and a missing or wrong Gray-to-binary decode | 5 | 5 |
| CDC-only (skipped synchronizer flop, combinational Gray into the synchronizer, almost flags reading the other side's pointer directly) | 4 | 0 (expected) |

The four CDC-only mutations are not caught on purpose: they still behave
correctly in zero-delay RTL simulation, so only CDC lint, formal verification or
a gate-level simulation with delays can find them.

## Limitations

- Simulated with Icarus Verilog only.
- Mutation tests run at the default configuration (depth 32, width 32), not
  across the sweep.
- The expected almost-flag thresholds in the testbench use the same formulas as
  the RTL defaults, so threshold values are checked against the documented spec
  above, not independently derived.
- The testbench checks safety properties and bounded flag latency, not exact flag
  timing, because the flags depend on how the two clock edges line up. It
  supports `DATA_WIDTH` up to 128 and `MEM_DEPTH` of at least 4.
- RTL simulation does not model metastability or glitches, so CDC bugs like the
  four listed above are invisible to it.
- The design has no reset synchronizer: each reset is assumed to be released
  synchronously to its own clock by the system.
- No formal verification, no CDC lint and no synthesis run.