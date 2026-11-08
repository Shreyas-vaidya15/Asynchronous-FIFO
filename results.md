### Parameter sweep (clean RTL)

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
| depth 6 | rejected by $error | rejected by $error |
| depth 2 | rejected by $error | rejected by $error |
| depth 8, almost_empty 0 | rejected by $error | rejected by $error |
| depth 8, almost_full 8 | rejected by $error | rejected by $error |
| depth 8, almost_empty 5, almost_full 5 | rejected by $error | rejected by $error |

### Mutation testing (current RTL, default config: depth 32, width 32)

| Mutation | First failure | Caught by |
|---|---|---|
| remove ~full from do_write | t=885000 (config 0, test 3) | full=0 but FIFO holds DEPTH words (write would overflow) |
| remove ~empty from do_read | t=1391237 (config 0, test 3) | read_data changed without a valid read (got 2c, expected 4b) |
| do_read ignores read_en | t=191237 (config 0, test 2) | read_data changed without a valid read (got 4, expected 0) |
| full: top two bits not inverted | t=12501 (config 0, test 1) | outputs did not clear on async reset without a clock edge |
| full ignores the lower pointer bits | t=845000 (config 0, test 3) | full stuck high long after space was freed |
| full ignores the top two bits | t=12501 (config 0, test 1) | outputs did not clear on async reset without a clock edge |
| empty uses != instead of == | t=12501 (config 0, test 1) | outputs did not clear on async reset without a clock edge |
| empty uses stale registered read pointer | t=276237 (config 0, test 2) | empty=0 but FIFO holds nothing (read would return junk) |
| full uses stale registered write pointer (top bits) | t=46585000 (config 0, test 8) | full=0 but FIFO holds DEPTH words (write would overflow) |
| full uses stale registered write pointer (lower bits) | t=875000 (config 0, test 3) | full=0 but FIFO holds DEPTH words (write would overflow) |
| Gray conversion shifts by 2 (both pointers) | t=626237 (config 0, test 3) | almost_empty low while FIFO holds 1 to ALMOST_EMPTY words |
| write_ptr increments by 2 | t=276237 (config 0, test 2) | empty=0 but FIFO holds nothing (read would return junk) |
| read_ptr increments by 2 | t=276237 (config 0, test 2) | empty=0 but FIFO holds nothing (read would return junk) |
| memory written at the wrong index | t=1071237 (config 0, test 3) | read_data does not match the oldest word written (got 3c, expected 2c) |
| memory read at the wrong index | t=271237 (config 0, test 2) | read_data does not match the oldest word written (got xxxxxxxx, expected 4) |
| memory one entry too small | t=1351237 (config 0, test 3) | read_data does not match the oldest word written (got xxxxxxxx, expected 48) |
| write_data one bit too narrow | t=2001237 (config 0, test 3) | read_data does not match the oldest word written (got 6dcb69db, expected edcb69db) |
| read_data one bit too narrow | t=2001237 (config 0, test 3) | read_data does not match the oldest word written (got 6dcb69db, expected edcb69db) |
| ADDRESS_WIDTH one too wide | t=875000 (config 0, test 3) | full=0 but FIFO holds DEPTH words (write would overflow) |
| ADDRESS_WIDTH one too narrow | t=715000 (config 0, test 3) | full stuck high long after space was freed |
| no reset of read_data | t=12501 (config 0, test 1) | outputs did not clear on async reset without a clock edge |
| read-side reset made synchronous | t=12501 (config 0, test 1) | outputs did not clear on async reset without a clock edge |
| write-side reset made synchronous | t=12501 (config 0, test 1) | outputs did not clear on async reset without a clock edge |
| write-pointer synchronizer stage 2 stuck at 0 | t=206237 (config 0, test 2) | empty stuck high long after data was written |
| read-pointer synchronizer stage 2 stuck at 0 | t=765000 (config 0, test 3) | almost_full stuck high long after words were read |
| almost_full uses > instead of >= | t=795000 (config 0, test 3) | almost_full low while FIFO holds ALMOST_FULL or more words |
| almost_full starts one word too early | t=785000 (config 0, test 3) | almost_full stuck high long after words were read |
| almost_full threshold hard-coded to 6 | t=615000 (config 0, test 3) | almost_full stuck high long after words were read |
| almost_full not masked by ~full | t=875000 (config 0, test 3) | almost_full and full are high together |
| almost_empty uses < instead of <= | t=1306237 (config 0, test 3) | almost_empty low while FIFO holds 1 to ALMOST_EMPTY words |
| almost_empty extends one word too far | t=1296237 (config 0, test 3) | almost_empty stuck high long after words were written |
| almost_empty threshold hard-coded to 2 | t=606237 (config 0, test 3) | almost_empty low while FIFO holds 1 to ALMOST_EMPTY words |
| almost_empty not masked by ~empty | t=12501 (config 0, test 1) | outputs did not clear on async reset without a clock edge |
| overflow = full && write_en && ~read_en | t=2835000 (config 0, test 4) | overflow does not equal full && write_en |
| underflow = empty (no read_en) | t=26237 (config 0, test 1) | underflow does not equal empty && read_en |
| almost_full subtracts Gray values | t=705000 (config 0, test 3) | almost_full stuck high long after words were read |
| almost_empty subtracts Gray values | t=476237 (config 0, test 2) | almost_empty low while FIFO holds 1 to ALMOST_EMPTY words |
| Gray-to-binary decode missing for the read pointer | t=785000 (config 0, test 3) | almost_full stuck high long after words were read |
| Gray-to-binary decode missing for the write pointer | t=626237 (config 0, test 3) | almost_empty low while FIFO holds 1 to ALMOST_EMPTY words |
| Gray-to-binary decode shifted by one | t=775000 (config 0, test 3) | almost_full stuck high long after words were read |
| synchronizer stage 1 skipped (1 flop instead of 2) | not caught (expected) | CDC-only: correct in zero-delay RTL simulation |
| synchronizer input is the combinational Gray value | not caught (expected) | CDC-only: correct in zero-delay RTL simulation |
| almost_full reads read_ptr directly (no synchronizer) | not caught (expected) | CDC-only: correct in zero-delay RTL simulation |
| almost_empty reads write_ptr directly (no synchronizer) | not caught (expected) | CDC-only: correct in zero-delay RTL simulation |

Caught: 40 of 44. Not caught and expected (CDC-only): 4. Not caught, testbench gap: 0.
