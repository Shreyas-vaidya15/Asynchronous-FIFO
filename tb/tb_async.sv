// =============================================================================
// tb_async.sv - self-checking testbench for async_FIFO (8-bit data, depth 8)
//
// Run:  iverilog -g2012 -o sim_async async_FIFO.sv tb_async.sv && vvp sim_async
//       A passing run prints ALL CHECKS PASSED. It stops at the first failure.
//
// Why this is not cycle-exact like the sync FIFO testbench:
//   full / empty see the other clock domain's pointer a few cycles late, so
//   they lag. The checks are therefore SAFETY properties, plus a bounded
//   latency check so a flag cannot stay stuck:
//     1. every word read is the oldest word written (order, no loss, no junk)
//     2. empty=0  =>  the model holds at least 1 word   (no early "not empty")
//     3. full=0   =>  the model holds fewer than DEPTH  (no early "not full")
//     4. a flag may be late, but only by a bounded time (never stuck)
//     5. read_data holds its value when no valid read happens
//     6. async reset clears the outputs immediately, with no clock edge
//     7. full / empty / almost_full / almost_empty / overflow / underflow are
//        never X or Z once out of reset
//     8. overflow  == full  && write_en, underflow == empty && read_en
//     9. almost_full / almost_empty can be late but never miss: whenever the
//        FIFO really holds AF_MIN or more words, almost_full or full is high;
//        whenever it holds 1 to AE_MAX words, almost_empty or empty is high.
//        Both are also never high together with full / empty, and never stuck.
//
// The whole test list runs once per clock configuration (equal clocks, slow
// drift between clocks, fast/slow in both directions, odd ratios 3:7 and 7:3,
// 1:10 and 10:1). One run also changes both clock frequencies while traffic runs.
//
// Limits (RTL simulation cannot show these): metastability, and glitches on
// the Gray pointers. A broken synchronizer that is still "logically" correct
// passes here. Catch those with CDC lint, formal, or a gate-level run.
// =============================================================================
`timescale 1ps/1ps

module tb_async;

  localparam int DEPTH  = 8;
  localparam int AF_MIN = 6;   // almost_full  is high for occupancy AF_MIN .. DEPTH-1
  localparam int AE_MAX = 2;   // almost_empty is high for occupancy 1 .. AE_MAX

  // ---------------------------------------------------------------- DUT ----
  logic wclk = 0, rclk = 0;
  logic wrst_n = 1, rrst_n = 1;
  logic wen = 0, ren = 0;
  logic [7:0] wd = 0;
  logic [7:0] rd;
  logic full, empty;
  logic almost_full, almost_empty, overflow, underflow;

  async_FIFO dut (
    .clk_write_side     (wclk),
    .clk_read_side      (rclk),
    .reset_n_write_side (wrst_n),
    .reset_n_read_side  (rrst_n),
    .write_en           (wen),
    .read_en            (ren),
    .write_data         (wd),
    .read_data          (rd),
    .full               (full),
    .almost_full        (almost_full),
    .empty              (empty),
    .almost_empty       (almost_empty),
    .overflow           (overflow),
    .underflow          (underflow)
  );

  // -------------------------------------------------------------- clocks ----
  // Half periods in ps; they can be changed while the simulation runs.
  int w_half = 5000, r_half = 5000;
  // Largest half periods in use: the flag-latency bounds are derived from them.
  int w_half_max = 5000, r_half_max = 5000;

  initial forever #(w_half) wclk = ~wclk;
  initial begin
    #1237;                                 // fixed phase offset between the clocks
    forever #(r_half) rclk = ~rclk;
  end

  // ------------------------------------------------------ failure handling --
  bit failed = 0;
  int cur_test = 0;                        // number of the test that is running

  task automatic fail0(input [8*80-1:0] msg);
    if (!failed) begin
      failed = 1;
      $display("FAIL t=%0t (config %0d, test %0d): %0s", $time, cfg_idx, cur_test, msg);
    end
  endtask

  task automatic fail2(input [8*80-1:0] msg, input [31:0] got, input [31:0] expd);
    if (!failed) begin
      failed = 1;
      $display("FAIL t=%0t (config %0d, test %0d): %0s (got %0h, expected %0h)", $time, cfg_idx, cur_test, msg, got, expd);
    end
  endtask

  initial begin
    wait (failed);
    #1 $finish;
  end

  // ------------------------------------------------------ reference model ---
  logic [7:0] model_q[$];                  // words written and not yet read
  bit   w_armed = 0, r_armed = 0;          // checks are on while a side is out of reset
  time  last_push_t = 0, last_pop_t = 0, wrel_t = 0, rrel_t = 0;
  int   w_limit = -1, r_limit = -1;        // accepted words still wanted (-1 = no limit)
  int   cfg_idx = 0;

  function automatic time tmax3(input time a, input time b, input time c);
    time m;
    m = a;
    if (b > m) m = b;
    if (c > m) m = c;
    tmax3 = m;
  endfunction

  function automatic int bound_empty();   // how late empty may drop after a push
    bound_empty = 2*w_half_max + 4*(2*r_half_max);
  endfunction
  function automatic int bound_full();    // how late full may drop after a pop
    bound_full = 2*r_half_max + 4*(2*w_half_max);
  endfunction

  // -------------------------------------------------------- stimulus knobs --
  int w_mode = 0, r_mode = 0;   // 0 idle, 1 random (w_prob / r_prob), 2 steer by occupancy
  int w_prob = 0, r_prob = 0;   // percent chance of a request per cycle (mode 1)
  int w_hi = DEPTH, r_lo = 0;   // mode 2: write while occupancy < w_hi, read while > r_lo
  int w_over = 0, r_under = 0;  // mode 2: percent chance to request anyway (overflow / underflow attempts)
  int d_mode = 0;               // data: 0 random, 1 counter, 2 corner patterns
  logic [7:0] d_ctr = 0;
  int pat_i = 0;

  function automatic logic [7:0] pattern(input int i);
    case (i % 12)
      0: pattern = 8'h00;  1: pattern = 8'hFF;  2: pattern = 8'hAA;  3: pattern = 8'h55;
      4: pattern = 8'h01;  5: pattern = 8'h80;  6: pattern = 8'hFE;  7: pattern = 8'h7F;
      8: pattern = 8'h0F;  9: pattern = 8'hF0; 10: pattern = 8'h33; default: pattern = 8'hCC;
    endcase
  endfunction

  function automatic logic [7:0] next_data();
    case (d_mode)
      1:       begin d_ctr = d_ctr + 8'd1; next_data = d_ctr; end
      2:       begin pat_i = pat_i + 1;    next_data = pattern(pat_i); end
      default: next_data = $urandom;
    endcase
  endfunction

  // Inputs change on the falling edge, so they are stable at the sampling edge.
  always @(negedge wclk) begin
    case (w_mode)
      1:       wen = (($urandom % 100) < w_prob);
      2:       wen = (model_q.size() < w_hi) ? 1'b1 : (($urandom % 100) < w_over);
      default: wen = 1'b0;
    endcase
    if (w_limit == 0) wen = 1'b0;
    wd = next_data();
  end

  always @(negedge rclk) begin
    case (r_mode)
      1:       ren = (($urandom % 100) < r_prob);
      2:       ren = (model_q.size() > r_lo) ? 1'b1 : (($urandom % 100) < r_under);
      default: ren = 1'b0;
    endcase
    if (r_limit == 0) ren = 1'b0;
  end

  // ------------------------------------------------------------- coverage --
  int cov_full, cov_empty, cov_over, cov_under;
  int cov_full_rise, cov_full_fall, cov_empty_rise, cov_empty_fall;
  int cov_pushes, cov_pops, cov_maxocc, cov_drained, cov_conc;
  int cov_bw, cov_br, cov_d00, cov_dff;
  int cov_rst_full, cov_rst_part, cov_rst_empty, cov_rst_traffic, cov_pulse;
  int cov_stag_w, cov_stag_r, cov_clkchg;
  int cov_af, cov_ae, cov_ovf, cov_unf, cov_af_rise, cov_ae_rise;

  task automatic clear_cov();
    cov_full = 0; cov_empty = 0; cov_over = 0; cov_under = 0;
    cov_full_rise = 0; cov_full_fall = 0; cov_empty_rise = 0; cov_empty_fall = 0;
    cov_pushes = 0; cov_pops = 0; cov_maxocc = 0; cov_drained = 0; cov_conc = 0;
    cov_bw = 0; cov_br = 0; cov_d00 = 0; cov_dff = 0;
    cov_rst_full = 0; cov_rst_part = 0; cov_rst_empty = 0; cov_rst_traffic = 0; cov_pulse = 0;
    cov_stag_w = 0; cov_stag_r = 0; cov_clkchg = 0;
    cov_af = 0; cov_ae = 0; cov_ovf = 0; cov_unf = 0; cov_af_rise = 0; cov_ae_rise = 0;
  endtask

  // -------------------------------------------------------- write monitor --
  bit  full_q = 0;
  bit  af_q = 0;
  int  burst_w = 0;

  always @(posedge wclk) begin
    if (w_armed) begin
      if (full !== 1'b0 && full !== 1'b1) fail0("full is X or Z");
      if (almost_full !== 1'b0 && almost_full !== 1'b1) fail0("almost_full is X or Z");
      if (overflow !== 1'b0 && overflow !== 1'b1) fail0("overflow is X or Z");

      // overflow is the illegal-request flag: a write requested while full is high
      if (overflow !== (full && wen)) fail0("overflow does not equal full && write_en");
      if (overflow) cov_ovf = cov_ovf + 1;

      // almost_full: never together with full, never missing, never stuck
      if (almost_full && full) fail0("almost_full and full are high together");
      if (!almost_full && !full && model_q.size() >= AF_MIN)
        fail0("almost_full low while FIFO holds AF_MIN or more words");
      if (almost_full && model_q.size() < AF_MIN &&
          ($time - tmax3(last_pop_t, wrel_t, rrel_t)) > bound_full())
        fail0("almost_full stuck high long after words were read");
      if (almost_full) cov_af = cov_af + 1;
      if (almost_full && !af_q) cov_af_rise = cov_af_rise + 1;
      af_q = almost_full;

      if (full) begin
        cov_full = cov_full + 1;
        if (wen) cov_over = cov_over + 1;
      end
      if (full && !full_q)  cov_full_rise = cov_full_rise + 1;
      if (!full && full_q)  cov_full_fall = cov_full_fall + 1;
      full_q = full;

      // safety: full must be high whenever the FIFO really holds DEPTH words
      if (!full && model_q.size() >= DEPTH)
        fail0("full=0 but FIFO holds DEPTH words (write would overflow)");

      // bounded latency: full may be late to drop, but not stuck
      if (full && model_q.size() < DEPTH &&
          ($time - tmax3(last_pop_t, wrel_t, rrel_t)) > bound_full())
        fail0("full stuck high long after space was freed");

      if (wen && !full) begin
        model_q.push_back(wd);
        last_push_t = $time;
        cov_pushes = cov_pushes + 1;
        if (w_limit > 0) w_limit = w_limit - 1;
        if (wd == 8'h00) cov_d00 = cov_d00 + 1;
        if (wd == 8'hFF) cov_dff = cov_dff + 1;
        if (model_q.size() == DEPTH) cov_maxocc = cov_maxocc + 1;
        if (($time - last_pop_t) < (2*w_half_max + 2*r_half_max)) cov_conc = cov_conc + 1;
        burst_w = burst_w + 1;
        if (burst_w == 4) cov_bw = cov_bw + 1;
      end else begin
        burst_w = 0;
      end
    end
  end

  // --------------------------------------------------------- read monitor --
  bit         empty_q = 1;
  bit         ae_q = 0;
  int         burst_r = 0;
  logic [7:0] exp_data, prev_rd = 0;
  bit         chk_pending = 0, hold_pending = 0;

  always @(posedge rclk) begin
    chk_pending  = 0;
    hold_pending = 0;
    if (r_armed) begin
      if (empty !== 1'b0 && empty !== 1'b1) fail0("empty is X or Z");
      if (almost_empty !== 1'b0 && almost_empty !== 1'b1) fail0("almost_empty is X or Z");
      if (underflow !== 1'b0 && underflow !== 1'b1) fail0("underflow is X or Z");

      // underflow is the illegal-request flag: a read requested while empty is high
      if (underflow !== (empty && ren)) fail0("underflow does not equal empty && read_en");
      if (underflow) cov_unf = cov_unf + 1;

      // almost_empty: never together with empty, never missing, never stuck
      if (almost_empty && empty) fail0("almost_empty and empty are high together");
      if (!almost_empty && !empty && model_q.size() >= 1 && model_q.size() <= AE_MAX)
        fail0("almost_empty low while FIFO holds 1 to AE_MAX words");
      if (almost_empty && model_q.size() > AE_MAX &&
          ($time - tmax3(last_push_t, wrel_t, rrel_t)) > bound_empty())
        fail0("almost_empty stuck high long after words were written");
      if (almost_empty) cov_ae = cov_ae + 1;
      if (almost_empty && !ae_q) cov_ae_rise = cov_ae_rise + 1;
      ae_q = almost_empty;

      if (empty) begin
        cov_empty = cov_empty + 1;
        if (ren) cov_under = cov_under + 1;
      end
      if (empty && !empty_q)  cov_empty_rise = cov_empty_rise + 1;
      if (!empty && empty_q)  cov_empty_fall = cov_empty_fall + 1;
      empty_q = empty;

      // safety: empty must be high whenever the FIFO really holds nothing
      if (!empty && model_q.size() == 0)
        fail0("empty=0 but FIFO holds nothing (read would return junk)");

      // bounded latency: empty may be late to drop, but not stuck
      if (empty && model_q.size() > 0 &&
          ($time - tmax3(last_push_t, wrel_t, rrel_t)) > bound_empty())
        fail0("empty stuck high long after data was written");

      if (ren && !empty && model_q.size() > 0) begin
        exp_data    = model_q.pop_front();
        chk_pending = 1;
        last_pop_t  = $time;
        cov_pops    = cov_pops + 1;
        if (r_limit > 0) r_limit = r_limit - 1;
        if (model_q.size() == 0) cov_drained = cov_drained + 1;
        burst_r = burst_r + 1;
        if (burst_r == 4) cov_br = cov_br + 1;
      end else begin
        hold_pending = 1;
        burst_r = 0;
      end
    end
  end

  // read_data is registered: check it after the edge that updated it.
  always @(negedge rclk) begin
    if (r_armed) begin
      if (chk_pending) begin
        if (rd !== exp_data) fail2("read_data does not match the oldest word written", rd, exp_data);
        prev_rd = rd;
      end else if (hold_pending) begin
        if (rd !== prev_rd) fail2("read_data changed without a valid read", rd, prev_rd);
      end
    end
    chk_pending  = 0;
    hold_pending = 0;
  end

  // ----------------------------------------------------------- utilities ----
  task automatic slow_edge();             // wait one edge of the slower clock
    if (w_half >= r_half) @(posedge wclk);
    else                  @(posedge rclk);
  endtask

  task automatic run_cycles(input int n); // n cycles of the slower clock
    repeat (n) slow_edge();
  endtask

  task automatic idle_all();
    w_mode = 0; r_mode = 0; w_limit = -1; r_limit = -1;
  endtask

  task automatic wait_count(input int n, input int limit);
    int c;
    c = 0;
    while (model_q.size() != n && !failed) begin
      slow_edge();
      c = c + 1;
      if (c > limit) fail2("timeout waiting for FIFO occupancy", model_q.size(), n);
    end
  endtask

  task automatic fill_to_full();          // keeps requesting writes while full
    r_mode = 0; w_mode = 1; w_prob = 100; w_limit = -1;
    wait_count(DEPTH, 300);
    run_cycles(6);
  endtask

  task automatic drain_all();             // keeps requesting reads while empty
    idle_all();
    run_cycles(3);
    r_mode = 1; r_prob = 100;
    wait_count(0, 400);
    run_cycles(6);
    idle_all();
    run_cycles(10);
    if (!failed && (empty !== 1'b1 || full !== 1'b0))
      fail0("after draining, expected empty=1 and full=0");
  endtask

  // ---------------------------------------------------------------- reset ---
  // Both sides, asserted asynchronously between clock edges.
  task automatic do_async_reset(input int hold_ps);
    @(negedge wclk);
    #(w_half / 2);
    if      (model_q.size() >= DEPTH) cov_rst_full  = cov_rst_full  + 1;
    else if (model_q.size() >  0)     cov_rst_part  = cov_rst_part  + 1;
    else                              cov_rst_empty = cov_rst_empty + 1;
    w_armed = 0; r_armed = 0;
    wrst_n = 0;  rrst_n = 0;
    model_q.delete();
    chk_pending = 0; hold_pending = 0;     // a reset cancels the read check still waiting for its falling edge
    #1;                                   // no clock edge needed for the outputs to clear
    if (rd !== 8'h00 || empty !== 1'b1 || full !== 1'b0 || almost_full !== 1'b0 || almost_empty !== 1'b0)
      fail0("outputs did not clear on async reset without a clock edge");
    #(hold_ps);
  endtask

  task automatic release_both();
    @(negedge wclk);
    wrst_n = 1; rrst_n = 1;
    wrel_t = $time; rrel_t = $time;
    prev_rd = 0; full_q = 0; empty_q = 1; af_q = 0; ae_q = 0;
    w_armed = 1; r_armed = 1;
  endtask

  task automatic release_w_only();
    @(negedge wclk);
    wrst_n = 1;
    wrel_t = $time; full_q = 0;
    w_armed = 1;
  endtask

  task automatic release_r_only();
    @(negedge rclk);
    rrst_n = 1;
    rrel_t = $time; prev_rd = 0; empty_q = 1;
    r_armed = 1;
  endtask

  task automatic post_reset_sanity();      // the FIFO must be empty and fully usable
    idle_all();
    d_mode = 1;
    run_cycles(6);
    if (!failed && (empty !== 1'b1 || full !== 1'b0))
      fail0("after reset, expected empty=1 and full=0");
    w_mode = 1; w_prob = 100; w_limit = 3;
    wait_count(3, 200);
    idle_all();
    run_cycles(4);
    r_mode = 1; r_prob = 100; r_limit = 3;
    wait_count(0, 300);
    idle_all();
    run_cycles(4);
  endtask

  // ---------------------------------------------------------------- tests ---
  `define TEST(n, msg) begin cur_test = n; if (cfg_idx == 0) $display(msg); end

  task automatic t_reset_state();
    `TEST(1, "Test 1: reset state, flags stable while idle")
    do_async_reset(300);
    release_both();
    idle_all();
    run_cycles(10);
    if (!failed && (empty !== 1'b1 || full !== 1'b0 || rd !== 8'h00))
      fail0("idle after reset: expected empty=1 full=0 read_data=0");
  endtask

  task automatic t_single();
    `TEST(2, "Test 2: single words, back-to-back words")
    idle_all(); d_mode = 1; run_cycles(3);
    w_limit = 1; w_mode = 1; w_prob = 100;
    wait_count(1, 100);
    idle_all(); run_cycles(10);
    r_limit = 1; r_mode = 1; r_prob = 100;
    wait_count(0, 200);
    idle_all(); run_cycles(6);
    w_limit = 2; w_mode = 1; w_prob = 100;
    wait_count(2, 100);
    idle_all(); run_cycles(10);
    r_limit = 2; r_mode = 1; r_prob = 100;
    wait_count(0, 200);
    idle_all(); run_cycles(6);
  endtask

  task automatic t_fill_drain();
    `TEST(3, "Test 3: fill to full with extra writes, drain with extra reads")
    d_mode = 1;
    fill_to_full();
    idle_all(); run_cycles(10);              // stays full with no reader
    drain_all();
    d_mode = 0;
    fill_to_full();
    drain_all();
  endtask

  task automatic t_simultaneous();
    `TEST(4, "Test 4: simultaneous write+read at full, at empty, mid-occupancy")
    d_mode = 0;
    fill_to_full();                          // at full: reader starts, writer keeps pushing
    r_mode = 1; r_prob = 100; w_mode = 1; w_prob = 100;
    run_cycles(120);
    drain_all();
    w_mode = 1; r_mode = 1; w_prob = 100; r_prob = 100;   // from empty
    run_cycles(120);
    drain_all();
    w_limit = 4; w_mode = 1; w_prob = 100;               // mid
    wait_count(4, 100);
    idle_all(); run_cycles(8);
    w_mode = 1; r_mode = 1; w_prob = 100; r_prob = 100;
    run_cycles(150);
    drain_all();
  endtask

  task automatic t_boundary();
    `TEST(5, "Test 5: oscillate around the full, empty and middle boundaries")
    d_mode = 0;
    w_mode = 2; r_mode = 2;
    w_hi = DEPTH; r_lo = DEPTH - 2; w_over = 35; r_under = 35;   // near full
    run_cycles(300);
    w_hi = 2; r_lo = 0;                                          // near empty
    run_cycles(300);
    w_hi = 4; r_lo = 3;                                          // middle
    run_cycles(200);
    w_hi = DEPTH; r_lo = 0; w_over = 0; r_under = 0;             // sweep the full range
    run_cycles(200);
    drain_all();
  endtask

  task automatic t_wrap_patterns();
    `TEST(6, "Test 6: pointer wrap-around (incrementing data), corner data patterns")
    d_mode = 1; w_mode = 1; r_mode = 1; w_prob = 60; r_prob = 60;
    run_cycles(600);
    drain_all();
    d_mode = 2; w_prob = 60; r_prob = 60; w_mode = 1; r_mode = 1;
    run_cycles(300);
    drain_all();
    d_mode = 0;
  endtask

  task automatic t_resets();
    `TEST(7, "Test 7: resets: while full / partial / empty, pulse, in traffic, staggered release")
    // while full
    idle_all(); d_mode = 1;
    fill_to_full();
    idle_all();
    do_async_reset(150);  release_both();  post_reset_sanity();
    // while partially full
    w_limit = 5; w_mode = 1; w_prob = 100;
    wait_count(5, 100);
    idle_all(); run_cycles(4);
    do_async_reset(150);  release_both();  post_reset_sanity();
    // while empty
    do_async_reset(150);  release_both();  post_reset_sanity();
    // short reset pulse (shorter than a clock period) while partially full
    w_limit = 3; w_mode = 1; w_prob = 100;
    wait_count(3, 100);
    idle_all(); run_cycles(4);
    cov_pulse = cov_pulse + 1;
    do_async_reset(40);   release_both();  post_reset_sanity();
    // reset in the middle of random traffic, traffic keeps running afterwards
    d_mode = 0;
    w_mode = 1; r_mode = 1; w_prob = 70; r_prob = 70;
    run_cycles(60);
    cov_rst_traffic = cov_rst_traffic + 1;
    do_async_reset(50);   release_both();
    run_cycles(100);
    drain_all();
    // write side comes out of reset first; words are written before the reader wakes up
    d_mode = 1;
    do_async_reset(100);
    w_mode = 1; w_prob = 100; w_limit = 5;
    release_w_only();
    run_cycles(15);
    release_r_only();
    cov_stag_w = cov_stag_w + 1;
    idle_all();
    r_mode = 1; r_prob = 100;
    wait_count(0, 300);
    idle_all(); run_cycles(6);
    // read side comes out of reset first; it keeps asking for data from an empty FIFO
    do_async_reset(100);
    r_mode = 1; r_prob = 100;
    release_r_only();
    run_cycles(15);
    release_w_only();
    cov_stag_r = cov_stag_r + 1;
    r_mode = 0;
    w_mode = 1; w_prob = 100; w_limit = 5;
    wait_count(5, 200);
    idle_all(); run_cycles(4);
    drain_all();
    d_mode = 0;
  endtask

  task automatic t_random();
    `TEST(8, "Test 8: random traffic: balanced, write-heavy, read-heavy, full-rate, bursty")
    d_mode = 0; w_mode = 1; r_mode = 1;
    w_prob = 50; r_prob = 50;   run_cycles(2000);
    w_prob = 85; r_prob = 30;   run_cycles(2000);
    w_prob = 30; r_prob = 85;   run_cycles(2000);
    w_prob = 100; r_prob = 100; run_cycles(1000);
    for (int i = 0; i < 40; i++) begin
      w_prob = (($urandom % 2) == 0) ? 100 : 0;
      r_prob = (($urandom % 2) == 0) ? 100 : 0;
      run_cycles(1 + ($urandom % 60));
    end
    drain_all();
  endtask

  task automatic t_clock_change(input int wh, input int rh);
    `TEST(9, "Test 9: both clock frequencies change while traffic runs")
    w_half_max = 12000; r_half_max = 12000;
    d_mode = 0; w_mode = 1; r_mode = 1; w_prob = 60; r_prob = 60;
    repeat (30) begin
      w_half = 1000 + ($urandom % 11001);
      r_half = 1000 + ($urandom % 11001);
      run_cycles(40);
    end
    cov_clkchg = cov_clkchg + 1;
    w_half = wh; r_half = rh;
    w_half_max = wh; r_half_max = rh;
    drain_all();
  endtask

  // ------------------------------------------------------ coverage check ----
  int holes;
  `define COV(c, msg) if ((c) == 0) begin holes = holes + 1; $display("  COVERAGE HOLE: %0s", msg); end

  task automatic check_cov();
    holes = 0;
    `COV(cov_full,        "full flag never seen high")
    `COV(cov_empty,       "empty flag never seen high")
    `COV(cov_over,        "never requested a write while full (overflow attempt)")
    `COV(cov_under,       "never requested a read while empty (underflow attempt)")
    `COV(cov_full_rise,   "full never rose")
    `COV(cov_full_fall,   "full never fell")
    `COV(cov_empty_rise,  "empty never rose")
    `COV(cov_empty_fall,  "empty never fell")
    `COV(cov_maxocc,      "occupancy DEPTH never reached")
    `COV(cov_drained,     "FIFO never drained back to 0")
    `COV(cov_conc,        "no concurrent write and read traffic")
    `COV(cov_bw,          "no burst of 4 accepted writes in a row")
    `COV(cov_br,          "no burst of 4 accepted reads in a row")
    `COV(cov_d00,         "data 00 never written")
    `COV(cov_dff,         "data FF never written")
    `COV(cov_rst_full,    "reset while full not exercised")
    `COV(cov_rst_part,    "reset while partially full not exercised")
    `COV(cov_rst_empty,   "reset while empty not exercised")
    `COV(cov_rst_traffic, "reset during traffic not exercised")
    `COV(cov_pulse,       "short reset pulse not exercised")
    `COV(cov_stag_w,      "staggered reset, write side first, not exercised")
    `COV(cov_stag_r,      "staggered reset, read side first, not exercised")
    `COV(cov_clkchg,      "clock frequency change not exercised")
    `COV(cov_af,          "almost_full never seen high")
    `COV(cov_ae,          "almost_empty never seen high")
    `COV(cov_af_rise,     "almost_full never rose")
    `COV(cov_ae_rise,     "almost_empty never rose")
    `COV(cov_ovf,         "overflow flag never high")
    `COV(cov_unf,         "underflow flag never high")
    if (cov_pushes < 48)
      begin holes = holes + 1; $display("  COVERAGE HOLE: too few words for the pointers to wrap"); end
    $display("  words written=%0d read=%0d | full seen=%0d empty seen=%0d | overflow attempts=%0d underflow attempts=%0d",
             cov_pushes, cov_pops, cov_full, cov_empty, cov_over, cov_under);
    if (holes != 0) fail0("coverage holes (listed above)");
  endtask

  // ----------------------------------------------------------------- main ---
  task automatic run_config(input int wh, input int rh, input int idx);
    cfg_idx = idx;
    $display("Config %0d: write clock period %0d ps, read clock period %0d ps", idx, 2*wh, 2*rh);
    idle_all();
    w_half = wh; r_half = rh; w_half_max = wh; r_half_max = rh;
    clear_cov();

    t_reset_state();
    t_single();
    t_fill_drain();
    t_simultaneous();
    t_boundary();
    t_wrap_patterns();
    t_resets();
    t_random();
    t_clock_change(wh, rh);

    if (!failed) begin
      if (model_q.size() != 0)   fail2("model not empty at end of config", model_q.size(), 0);
      if (empty !== 1'b1)        fail0("empty not high at end of config");
      check_cov();
    end
  endtask

  initial begin : main
    run_config(5000,  5000, 0);   // equal clocks
    run_config(5000,  5013, 1);   // almost equal: the phase drifts through every alignment
    run_config(2500,  5003, 2);   // fast writer, slow reader
    run_config(5003,  2500, 3);   // slow writer, fast reader
    run_config(3001,  7003, 4);   // 3:7
    run_config(7003,  3001, 5);   // 7:3
    run_config(1000, 10007, 6);   // 1:10
    run_config(10007, 1000, 7);   // 10:1
    if (!failed) begin
      $display("ALL CHECKS PASSED");
      $finish;
    end
  end

  // Watchdog: a hung test must not run forever.
  initial begin
    #5_000_000_000;
    fail0("watchdog: simulation did not finish");
  end

endmodule