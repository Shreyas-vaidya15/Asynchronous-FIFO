# Asynchronous FIFO (Gray-coded pointers, two clocks)

A dual-clock FIFO in SystemVerilog. The write side and the read side run on
unrelated clocks. Data sits in a small memory and only the pointers cross
between the clock domains: each pointer is Gray coded and passes through a
2-flop synchronizer per bit. The design has status flags (full, empty,
almost full, almost empty, overflow, underflow) and a self-checking testbench
that is run across eight clock configurations, plus a script that runs the
testbench against deliberately broken copies of the RTL.

Fixed configuration: 8-bit data, 8 entries.

## Repository layout

| Path | Contents |
|---|---|
| `rtl/async_FIFO.sv` | the FIFO |
| `tb/tb_async.sv` | self-checking testbench |
| `run_checks.ps1` | runs the clean RTL and all mutation tests (Windows PowerShell) |
| `results.md` | tables produced by the last run of `run_checks.ps1` |
| `logs/` | raw simulator output of every run (not committed) |
| `.gitignore` | ignores the compiled simulation file, `logs/` and the temporary mutation file |

## Ports

| Port | Domain | Dir | Description |
|---|---|---|---|
| `clk_write_side` | write | in | write-domain clock |
| `clk_read_side` | read | in | read-domain clock |
| `reset_n_write_side` | write | in | asynchronous active-low reset for the write domain |
| `reset_n_read_side` | read | in | asynchronous active-low reset for the read domain |
| `write_en`, `write_data[7:0]` | write | in | write request and data |
| `read_en` | read | in | read request |
| `read_data[7:0]` | read | out | registered, valid one read-clock cycle after a valid read |
| `full`, `almost_full` | write | out | occupancy 8 / occupancy 6 to 7 |
| `empty`, `almost_empty` | read | out | occupancy 0 / occupancy 1 to 2 |
| `overflow` | write | out | a write is requested while `full` is high |
| `underflow` | read | out | a read is requested while `empty` is high |

`overflow` and `underflow` are combinational: they follow the request in the
same cycle, regardless of the other request, and are not latched.

## How it works

- **Pointers.** The write and read pointers are 4 bits wide: 3 bits address the
  8-entry memory and the extra MSB tells full from empty. Both pointers are
  binary counters that live in their own clock domain.
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
  and above its position). Occupancy is then `write_ptr - synchronized read_ptr`
  on the write side and `synchronized write_ptr - read_ptr` on the read side.
  `almost_full` is high for occupancy 6 to 7 and `almost_empty` for 1 to 2; both
  are low when the FIFO is full or empty respectively.
- **Flags are conservative.** Each side sees the other side's pointer a few
  cycles late, so the flags can stay high slightly longer than the FIFO's true
  state, but never drop early: `full` and `empty` are never missed, and neither
  are the almost flags (`almost_full` or `full` is high whenever 6 or more words
  are stored, `almost_empty` or `empty` is high whenever 1 or 2 are). The FIFO
  therefore never overflows or underflows, at the cost of lagging flags.
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

From the repository root:

    iverilog -g2012 -o sim_async rtl/async_FIFO.sv tb/tb_async.sv
    vvp sim_async

A passing run prints `ALL CHECKS PASSED`. A failure stops the run at the first
problem and prints the simulation time, the clock configuration, the test
number and the reason.

To run the clean RTL and every mutation test in one go (Windows PowerShell):

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
| no early "not full" | `full=0` only when the model holds fewer than 8 words |
| almost flags never miss | `almost_full` or `full` is high whenever the model holds 6 or more words; `almost_empty` or `empty` is high whenever it holds 1 or 2 |
| almost flags are exclusive | `almost_full` is never high together with `full`, `almost_empty` never with `empty` |
| overflow / underflow | `overflow` equals `full && write_en`, `underflow` equals `empty && read_en` |
| bounded flag latency | a flag may stay high after the state changed, but only for a bounded time: writer period + 4 reader periods for `empty` and `almost_empty`, reader period + 4 writer periods for `full` and `almost_full` |
| `read_data` holds | it does not change unless a valid read happens |
| async reset | outputs clear immediately on reset, without a clock edge |
| no X/Z | none of the flags is ever X or Z once out of reset |

The almost-flag thresholds in the testbench (6 and 2) are constants written in
the testbench, not derived from the RTL expressions.

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
6. Pointer wrap-around with incrementing data, and corner data patterns (00, FF, AA, 55 and others).
7. Resets: while full, partially full and empty; a reset pulse shorter than a clock period; a reset in the middle of traffic; staggered release with the write side first and with the read side first.
8. Random traffic: balanced, write-heavy, read-heavy, full-rate and bursty.
9. Both clock frequencies change while traffic runs.

A coverage check fails a configuration if something was never exercised: any
flag never seen high, no flag rise or fall, no overflow or underflow attempt,
no occupancy of 8, no drain to 0, no pointer wrap, no concurrent traffic, no
data 00 or FF, or any of the reset scenarios above.

### Results

All eight clock configurations pass.

### Mutation testing

To check that the testbench can fail, `run_checks.ps1` breaks the RTL on
purpose, one change at a time, starting from the clean file each time, and runs
the testbench on every broken copy. There are 33 mutations. **29 are caught**,
each at the first failing check; the full table with the time and reason of
every failure is in `results.md`. The mutations cover:

| Area | Mutations | Caught |
|---|---|---|
| flow control (`~full` in `do_write`, `~empty` in `do_read`, `read_en` in `do_read`) | 3 | 3 |
| `full` / `empty` logic (inversion, missing bits, `!=`, stale registered pointers) | 5 | 5 |
| Gray conversion and pointer steps (`>> 2`, pointers step by 2) | 3 | 3 |
| memory indexing (write and read) | 2 | 2 |
| resets (`read_data` not reset, synchronous instead of asynchronous) | 3 | 3 |
| synchronizer second stage stuck at 0 | 2 | 2 |
| almost-flag thresholds and masks | 6 | 6 |
| overflow / underflow | 2 | 2 |
| Gray subtraction and a broken Gray-to-binary decode | 3 | 3 |
| CDC-only (skipped synchronizer flop, combinational Gray into the synchronizer, almost flags reading the other side's pointer directly) | 4 | 0 (expected) |

The four CDC-only mutations are not caught on purpose: they still behave
correctly in zero-delay RTL simulation, so only CDC lint, formal verification or
a gate-level simulation with delays can find them.

## Limitations

- Simulated with Icarus Verilog only.
- Fixed 8-bit data and 8 entries; the almost-flag thresholds are fixed at 6 and 2.
- The testbench checks safety properties and bounded flag latency, not exact flag
  timing, because the flags depend on how the two clock edges line up.
- RTL simulation does not model metastability or glitches, so CDC bugs like the
  four listed above are invisible to it.
- The design has no reset synchronizer: each reset is assumed to be released
  synchronously to its own clock by the system.
- No formal verification, no CDC lint and no synthesis run.