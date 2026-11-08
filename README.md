# Asynchronous FIFO (Gray-coded pointers, two clocks)

A dual-clock FIFO in SystemVerilog. The write side and the read side run on
unrelated clocks. Data sits in a small memory and only the pointers cross
between the clock domains: each pointer is Gray coded and passes through a
2-flop synchronizer per bit. The design has a self-checking testbench that is
run across eight clock configurations.

Fixed configuration: 8-bit data, 8 entries.

## Repository layout

| Path | Contents |
|---|---|
| `rtl/async_FIFO.sv` | the FIFO |
| `tb/tb_async.sv` | self-checking testbench |
| `.gitignore` | ignores the compiled simulation file |

## Ports

| Port | Dir | Description |
|---|---|---|
| `clk_write_side` | in | write-domain clock |
| `clk_read_side` | in | read-domain clock |
| `reset_n_write_side` | in | asynchronous active-low reset for the write domain |
| `reset_n_read_side` | in | asynchronous active-low reset for the read domain |
| `write_en`, `write_data[7:0]` | in | write request and data (write clock domain) |
| `read_en` | in | read request (read clock domain) |
| `read_data[7:0]` | out | registered, valid one read-clock cycle after a valid read |
| `full` | out | write clock domain: no room for another word |
| `empty` | out | read clock domain: nothing to read |

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
- **Flags are conservative.** Each side sees the other side's pointer a few
  cycles late, so `full` and `empty` can stay high slightly longer than the
  FIFO's true state, but never drop early. The FIFO therefore never overflows or
  underflows, at the cost of lagging flags.
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

## Verification

Because the flags lag, the testbench cannot compare them cycle by cycle the way
a single-clock testbench can. It keeps a queue-based reference model of the
words in the FIFO and checks safety properties instead:

| Check | Meaning |
|---|---|
| data order | every word read equals the oldest word written (no loss, no duplicates, no junk) |
| no early "not empty" | `empty=0` only when the model holds at least one word |
| no early "not full" | `full=0` only when the model holds fewer than 8 words |
| bounded flag latency | `empty` may stay high after a write and `full` after a read, but only for a bounded time: writer period + 4 reader periods for `empty`, reader period + 4 writer periods for `full` |
| `read_data` holds | it does not change unless a valid read happens |
| async reset | outputs clear immediately on reset, without a clock edge |
| no X/Z | `full` and `empty` are never X or Z once out of reset |

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

A coverage check fails a configuration if something was never exercised: full or
empty never seen, no overflow or underflow attempt, no flag rise or fall, no
occupancy of 8, no drain to 0, no pointer wrap, no concurrent traffic, no data
00 or FF, or any of the reset scenarios above.

### Results

All eight configurations pass.

### Mutation testing

To check that the testbench can fail, the RTL was broken on purpose and the
testbench run on each broken copy:

| Mutation | First failure (sim time) | Caught by |
|---|---|---|
| remove `~full` from `do_write` | 645000 ps | `full=0 but FIFO holds DEPTH words (write would overflow)` |
| Gray conversion `>> 2` instead of `>> 1` (both pointers) | 635000 ps | `full=0 but FIFO holds DEPTH words (write would overflow)` |
| read-side reset made synchronous (`negedge reset_n_read_side` removed) | 12501 ps | `outputs did not clear on async reset without a clock edge` |

All three were caught, each by a different check.

## Limitations

- Simulated with Icarus Verilog only.
- Fixed 8-bit data and 8 entries; there are no overflow, underflow, almost-full
  or almost-empty outputs.
- The testbench checks safety properties and bounded flag latency, not exact flag
  timing, because the flags depend on how the two clock edges line up.
- RTL simulation does not model metastability or glitches. A bug such as a
  missing synchronizer flop, or a combinational Gray value fed straight into a
  synchronizer, still behaves correctly in zero-delay simulation and would not be
  caught here. Finding those needs CDC lint, formal verification, or a gate-level
  simulation with delays.
- Mutation testing was done manually on three mutations, not scripted across the
  sweep.
- The design has no reset synchronizer: each reset is assumed to be released
  synchronously to its own clock by the system.
- No formal verification and no synthesis run.