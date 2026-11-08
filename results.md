### Clean RTL

| Run | Result |
|---|---|
| testbench on rtl/async_FIFO.sv | pass (all 8 clock configurations) |

### Mutation testing (current RTL)

| Mutation | First failure | Caught by |
|---|---|---|
| remove ~full from do_write | t=645000 (config 0, test 3) | full=0 but FIFO holds DEPTH words (write would overflow) |
| remove ~empty from do_read | t=911237 (config 0, test 3) | read_data changed without a valid read (got 2c, expected 33) |
| do_read ignores read_en | t=191237 (config 0, test 2) | read_data changed without a valid read (got 4, expected 0) |
| full: top two bits not inverted | t=12501 (config 0, test 1) | outputs did not clear on async reset without a clock edge |
| full ignores the top two bits | t=12501 (config 0, test 1) | outputs did not clear on async reset without a clock edge |
| empty uses != instead of == | t=12501 (config 0, test 1) | outputs did not clear on async reset without a clock edge |
| empty uses stale registered read pointer | t=276237 (config 0, test 2) | empty=0 but FIFO holds nothing (read would return junk) |
| full uses stale registered write pointer | t=635000 (config 0, test 3) | full=0 but FIFO holds DEPTH words (write would overflow) |
| Gray conversion shifts by 2 (both pointers) | t=605000 (config 0, test 3) | almost_full stuck high long after words were read |
| write_ptr increments by 2 | t=276237 (config 0, test 2) | empty=0 but FIFO holds nothing (read would return junk) |
| read_ptr increments by 2 | t=276237 (config 0, test 2) | empty=0 but FIFO holds nothing (read would return junk) |
| memory written at the wrong index | t=831237 (config 0, test 3) | read_data does not match the oldest word written (got 30, expected 2c) |
| memory read at the wrong index | t=271237 (config 0, test 2) | read_data does not match the oldest word written (got xx, expected 4) |
| no reset of read_data | t=12501 (config 0, test 1) | outputs did not clear on async reset without a clock edge |
| read-side reset made synchronous | t=12501 (config 0, test 1) | outputs did not clear on async reset without a clock edge |
| write-side reset made synchronous | t=12501 (config 0, test 1) | outputs did not clear on async reset without a clock edge |
| write-pointer synchronizer stage 2 stuck at 0 | t=206237 (config 0, test 2) | empty stuck high long after data was written |
| read-pointer synchronizer stage 2 stuck at 0 | t=585000 (config 0, test 3) | almost_full stuck high long after words were read |
| almost_full threshold > 4 (high from occupancy 5) | t=605000 (config 0, test 3) | almost_full stuck high long after words were read |
| almost_full threshold > 6 (misses occupancy 6) | t=615000 (config 0, test 3) | almost_full low while FIFO holds AF_MIN or more words |
| almost_full not masked by ~full | t=635000 (config 0, test 3) | almost_full and full are high together |
| almost_empty threshold < 4 (high at occupancy 3) | t=876237 (config 0, test 3) | almost_empty stuck high long after words were written |
| almost_empty threshold < 2 (misses occupancy 2) | t=386237 (config 0, test 2) | almost_empty low while FIFO holds 1 to AE_MAX words |
| almost_empty not masked by ~empty | t=12501 (config 0, test 1) | outputs did not clear on async reset without a clock edge |
| overflow = full && write_en && ~read_en | t=1635000 (config 0, test 4) | overflow does not equal full && write_en |
| underflow = empty (no read_en) | t=26237 (config 0, test 1) | underflow does not equal empty && read_en |
| almost_full subtracts Gray values | t=605000 (config 0, test 3) | almost_full stuck high long after words were read |
| almost_empty subtracts Gray values | t=476237 (config 0, test 2) | almost_empty low while FIFO holds 1 to AE_MAX words |
| Gray-to-binary decode drops a term | t=1115000 (config 0, test 3) | almost_full stuck high long after words were read |
| synchronizer stage 1 skipped (1 flop instead of 2) | not caught (expected) | CDC-only: correct in zero-delay RTL simulation |
| synchronizer input is the combinational Gray value | not caught (expected) | CDC-only: correct in zero-delay RTL simulation |
| almost_full reads read_ptr directly (no synchronizer) | not caught (expected) | CDC-only: correct in zero-delay RTL simulation |
| almost_empty reads write_ptr directly (no synchronizer) | not caught (expected) | CDC-only: correct in zero-delay RTL simulation |

Caught: 29 of 33. Not caught and expected (CDC-only): 4. Not caught, testbench gap: 0.
