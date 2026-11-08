# Run from the repository root (the folder that contains rtl and tb):
#   powershell -ExecutionPolicy Bypass -File run_checks.ps1
#
# Part 1 runs the clean RTL over a sweep of parameters (each run already covers
# eight clock configurations inside the testbench). Illegal settings must be
# rejected with an $error and must not print ALL CHECKS PASSED.
# Part 2 breaks the RTL on purpose, one change at a time, starting from the
# clean file each time, and checks that the testbench fails on every one.
# The mutation runs use the default configuration (depth 32, width 32).

$rtl = "rtl/async_FIFO.sv"
$tb  = "tb/tb_async.sv"
$report = @()

# raw output of every simulation goes here (gitignored), nothing gets cut off
New-Item -ItemType Directory -Force logs | Out-Null
Set-Content logs/all_runs.log ""

function Say($s) { Write-Host $s; $script:report += $s }

function Simulate($label, $rtlFile, $extra) {
    Remove-Item sim_async -ErrorAction SilentlyContinue
    $cout = & iverilog -g2012 @extra -o sim_async $rtlFile $tb 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Add-Content logs/all_runs.log ("===== " + $label + " (COMPILE ERROR) =====`n" + $cout)
        return @("COMPILE ERROR", $cout)
    }
    $out = & vvp sim_async 2>&1 | Out-String
    Add-Content logs/all_runs.log ("===== " + $label + " =====`n" + $out)
    return @("OK", $out)
}

# ---------------------------------------------------------------
# Part 1: parameter sweep on the clean RTL
# ---------------------------------------------------------------
# label, extra iverilog arguments, expected ("pass" or "reject")
$sweep = @(
    @("depth 32, width 32 (default)",        @(), "pass"),
    @("depth 4, width 32",                   @("-Ptb_async.DEPTH=4"), "pass"),
    @("depth 8, width 32",                   @("-Ptb_async.DEPTH=8"), "pass"),
    @("depth 16, width 32",                  @("-Ptb_async.DEPTH=16"), "pass"),
    @("depth 64, width 32",                  @("-Ptb_async.DEPTH=64"), "pass"),
    @("depth 8, width 8",                    @("-Ptb_async.DEPTH=8", "-Ptb_async.DATA_WIDTH=8"), "pass"),
    @("depth 16, width 1",                   @("-Ptb_async.DEPTH=16", "-Ptb_async.DATA_WIDTH=1"), "pass"),
    @("depth 32, width 100",                 @("-Ptb_async.DATA_WIDTH=100"), "pass"),
    @("depth 8, almost_empty 3, almost_full 5", @("-Ptb_async.DEPTH=8", "-Ptb_async.ALMOST_EMPTY=3", "-Ptb_async.ALMOST_FULL=5"), "pass"),
    @("depth 6",                             @("-Ptb_async.DEPTH=6"), "reject"),
    @("depth 2",                             @("-Ptb_async.DEPTH=2"), "reject"),
    @("depth 8, almost_empty 0",             @("-Ptb_async.DEPTH=8", "-Ptb_async.ALMOST_EMPTY=0"), "reject"),
    @("depth 8, almost_full 8",              @("-Ptb_async.DEPTH=8", "-Ptb_async.ALMOST_FULL=8"), "reject"),
    @("depth 8, almost_empty 5, almost_full 5", @("-Ptb_async.DEPTH=8", "-Ptb_async.ALMOST_EMPTY=5", "-Ptb_async.ALMOST_FULL=5"), "reject")
)

Say "### Parameter sweep (clean RTL)"
Say ""
Say "| Config | Expected | Result |"
Say "|---|---|---|"
foreach ($c in $sweep) {
    $r = Simulate ("sweep: " + $c[0]) $rtl $c[1]
    if ($r[0] -ne "OK") {
        $res = "COMPILE ERROR (see logs/all_runs.log)"
    }
    elseif ($r[1] -match "ALL CHECKS PASSED") { $res = "pass" }
    elseif ($r[1] -match "must be a power of 2|Bad thresholds") { $res = "rejected by `$error" }
    else { $res = "FAIL (see logs/all_runs.log)" }

    if ($c[2] -eq "pass") { $expected = "pass" } else { $expected = "rejected by `$error" }
    Say ("| " + $c[0] + " | " + $expected + " | " + $res + " |")
}

# ---------------------------------------------------------------
# Part 2: mutation testing on the current RTL (default configuration)
# ---------------------------------------------------------------
$orig = Get-Content $rtl -Raw

# name, exact text to find (every occurrence is replaced), replacement,
# and "cdc" for bugs that only show up in real hardware, not in RTL simulation
$mutations = @(
    @("remove ~full from do_write",
      "assign do_write = write_en && ~full;",
      "assign do_write = write_en;", ""),
    @("remove ~empty from do_read",
      "assign do_read  = read_en && ~empty;",
      "assign do_read  = read_en;", ""),
    @("do_read ignores read_en",
      "assign do_read  = read_en && ~empty;",
      "assign do_read  = ~empty;", ""),
    @("full: top two bits not inverted",
      "== ~gray_read_ptr_ff2[ADDRESS_WIDTH:ADDRESS_WIDTH - 1]",
      "== gray_read_ptr_ff2[ADDRESS_WIDTH:ADDRESS_WIDTH - 1]", ""),
    @("full ignores the lower pointer bits",
      "(gray_write_ptr[FULL_LOW_MSB:0] == gray_read_ptr_ff2[FULL_LOW_MSB:0])",
      "1'b1", ""),
    @("full ignores the top two bits",
      "(gray_write_ptr[ADDRESS_WIDTH:ADDRESS_WIDTH - 1] == ~gray_read_ptr_ff2[ADDRESS_WIDTH:ADDRESS_WIDTH - 1])",
      "1'b1", ""),
    @("empty uses != instead of ==",
      "(gray_write_ptr_ff2 == gray_read_ptr)",
      "(gray_write_ptr_ff2 != gray_read_ptr)", ""),
    @("empty uses stale registered read pointer",
      "(gray_write_ptr_ff2 == gray_read_ptr)",
      "(gray_write_ptr_ff2 == gray_read_ptr_reg)", ""),
    @("full uses stale registered write pointer (top bits)",
      "(gray_write_ptr[ADDRESS_WIDTH:",
      "(gray_write_ptr_reg[ADDRESS_WIDTH:", ""),
    @("full uses stale registered write pointer (lower bits)",
      "(gray_write_ptr[FULL_LOW_MSB:0]",
      "(gray_write_ptr_reg[FULL_LOW_MSB:0]", ""),
    @("Gray conversion shifts by 2 (both pointers)",
      ">> 1'b1",
      ">> 2'd2", ""),
    @("write_ptr increments by 2",
      "write_ptr <= write_ptr + 1'b1",
      "write_ptr <= write_ptr + 2'd2", ""),
    @("read_ptr increments by 2",
      "read_ptr <= read_ptr + 1'b1",
      "read_ptr <= read_ptr + 2'd2", ""),
    @("memory written at the wrong index",
      "mem[write_ptr[ADDRESS_WIDTH - 1:0]] <= write_data;",
      "mem[write_ptr[ADDRESS_WIDTH - 2:0]] <= write_data;", ""),
    @("memory read at the wrong index",
      "read_data <= mem[read_ptr[ADDRESS_WIDTH - 1:0]];",
      "read_data <= mem[read_ptr[ADDRESS_WIDTH - 1:0] + 1'b1];", ""),
    @("memory one entry too small",
      "[0:MEM_DEPTH - 1]",
      "[0:MEM_DEPTH - 2]", ""),
    @("write_data one bit too narrow",
      "input logic [DATA_WIDTH - 1:0] write_data",
      "input logic [DATA_WIDTH - 2:0] write_data", ""),
    @("read_data one bit too narrow",
      "output logic [DATA_WIDTH - 1:0] read_data",
      "output logic [DATA_WIDTH - 2:0] read_data", ""),
    @("ADDRESS_WIDTH one too wide",
      "localparam int ADDRESS_WIDTH = `$clog2(MEM_DEPTH);",
      "localparam int ADDRESS_WIDTH = `$clog2(MEM_DEPTH) + 1;", ""),
    @("ADDRESS_WIDTH one too narrow",
      "localparam int ADDRESS_WIDTH = `$clog2(MEM_DEPTH);",
      "localparam int ADDRESS_WIDTH = `$clog2(MEM_DEPTH) - 1;", ""),
    @("no reset of read_data",
      "read_data <= '0;",
      "", ""),
    @("read-side reset made synchronous",
      "@(posedge clk_read_side or negedge reset_n_read_side)",
      "@(posedge clk_read_side)", ""),
    @("write-side reset made synchronous",
      "@(posedge clk_write_side or negedge reset_n_write_side)",
      "@(posedge clk_write_side)", ""),
    @("write-pointer synchronizer stage 2 stuck at 0",
      "gray_write_ptr_ff2 <= gray_write_ptr_ff1;",
      "gray_write_ptr_ff2 <= '0;", ""),
    @("read-pointer synchronizer stage 2 stuck at 0",
      "gray_read_ptr_ff2 <= gray_read_ptr_ff1;",
      "gray_read_ptr_ff2 <= '0;", ""),
    @("almost_full uses > instead of >=",
      "difference_full >= ALMOST_FULL",
      "difference_full > ALMOST_FULL", ""),
    @("almost_full starts one word too early",
      "difference_full >= ALMOST_FULL",
      "difference_full >= ALMOST_FULL - 1", ""),
    @("almost_full threshold hard-coded to 6",
      "difference_full >= ALMOST_FULL",
      "difference_full >= 6", ""),
    @("almost_full not masked by ~full",
      "(~full && difference_full >= ALMOST_FULL)",
      "(difference_full >= ALMOST_FULL)", ""),
    @("almost_empty uses < instead of <=",
      "difference_empty <= ALMOST_EMPTY",
      "difference_empty < ALMOST_EMPTY", ""),
    @("almost_empty extends one word too far",
      "difference_empty <= ALMOST_EMPTY",
      "difference_empty <= ALMOST_EMPTY + 1", ""),
    @("almost_empty threshold hard-coded to 2",
      "difference_empty <= ALMOST_EMPTY",
      "difference_empty <= 2", ""),
    @("almost_empty not masked by ~empty",
      "(~empty && difference_empty <= ALMOST_EMPTY)",
      "(difference_empty <= ALMOST_EMPTY)", ""),
    @("overflow = full && write_en && ~read_en",
      "(full && write_en)",
      "(full && write_en && ~read_en)", ""),
    @("underflow = empty (no read_en)",
      "(empty && read_en)",
      "(empty)", ""),
    @("almost_full subtracts Gray values",
      "write_ptr - read_ptr_sync_bin",
      "gray_write_ptr - gray_read_ptr_ff2", ""),
    @("almost_empty subtracts Gray values",
      "write_ptr_sync_bin - read_ptr;",
      "gray_write_ptr_ff2 - gray_read_ptr;", ""),
    @("Gray-to-binary decode missing for the read pointer",
      "read_ptr_sync_bin[i]  = ^(gray_read_ptr_ff2  >> i);",
      "read_ptr_sync_bin[i]  = gray_read_ptr_ff2[i];", ""),
    @("Gray-to-binary decode missing for the write pointer",
      "write_ptr_sync_bin[i] = ^(gray_write_ptr_ff2 >> i);",
      "write_ptr_sync_bin[i] = gray_write_ptr_ff2[i];", ""),
    @("Gray-to-binary decode shifted by one",
      "^(gray_read_ptr_ff2  >> i)",
      "^(gray_read_ptr_ff2  >> (i + 1))", ""),
    @("synchronizer stage 1 skipped (1 flop instead of 2)",
      "gray_write_ptr_ff2 <= gray_write_ptr_ff1;",
      "gray_write_ptr_ff2 <= gray_write_ptr_reg;", "cdc"),
    @("synchronizer input is the combinational Gray value",
      "gray_write_ptr_ff1 <= gray_write_ptr_reg;",
      "gray_write_ptr_ff1 <= gray_write_ptr;", "cdc"),
    @("almost_full reads read_ptr directly (no synchronizer)",
      "write_ptr - read_ptr_sync_bin",
      "write_ptr - read_ptr", "cdc"),
    @("almost_empty reads write_ptr directly (no synchronizer)",
      "write_ptr_sync_bin - read_ptr;",
      "write_ptr - read_ptr;", "cdc")
)

Say ""
Say "### Mutation testing (current RTL, default config: depth 32, width 32)"
Say ""
Say "| Mutation | First failure | Caught by |"
Say "|---|---|---|"

$caught = 0
$escaped = 0
$cdcEscaped = 0
foreach ($m in $mutations) {
    $mutated = $orig.Replace($m[1], $m[2])
    if ($mutated -eq $orig) {
        Say ("| " + $m[0] + " | MUTATION DID NOT APPLY (text not found) | |")
        continue
    }
    Set-Content -Path "mut.sv" -Value $mutated -NoNewline
    $r = Simulate ("mutation: " + $m[0]) "mut.sv" @()
    $out = $r[1]
    if ($r[0] -ne "OK") {
        Say ("| " + $m[0] + " | COMPILE ERROR (mutation is invalid) | |")
        continue
    }
    $lines = $out -split "`r?`n"
    $failLine = $lines | Where-Object { $_ -match "^FAIL " } | Select-Object -First 1
    if ($failLine -match "^FAIL t=(\d+) \(config (\d+), test (\d+)\): (.*)$") {
        $when = "t=" + $Matches[1] + " (config " + $Matches[2] + ", test " + $Matches[3] + ")"
        Say ("| " + $m[0] + " | " + $when + " | " + $Matches[4].Trim() + " |")
        $caught++
    }
    elseif ($out -match "ALL CHECKS PASSED") {
        if ($m[3] -eq "cdc") {
            Say ("| " + $m[0] + " | not caught (expected) | CDC-only: correct in zero-delay RTL simulation |")
            $cdcEscaped++
        }
        else {
            Say ("| " + $m[0] + " | NOT CAUGHT (testbench passed) | testbench gap |")
            $escaped++
        }
    }
    else {
        Say ("| " + $m[0] + " | stopped without ALL CHECKS PASSED | " + $failLine + " |")
        $caught++
    }
}

Say ""
Say ("Caught: " + $caught + " of " + ($caught + $escaped + $cdcEscaped) + ". Not caught and expected (CDC-only): " + $cdcEscaped + ". Not caught, testbench gap: " + $escaped + ".")

Remove-Item mut.sv, sim_async -ErrorAction SilentlyContinue
$report | Set-Content results.md
Write-Host ""
Write-Host "Summary tables saved to results.md"
Write-Host "Full raw output of every run saved to logs/all_runs.log"