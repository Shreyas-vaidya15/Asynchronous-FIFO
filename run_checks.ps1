# Run from the repository root (the folder that contains rtl and tb):
#   powershell -ExecutionPolicy Bypass -File run_checks.ps1
#
# Part 1 runs the clean RTL once. The testbench itself loops over the eight
# clock configurations, so no separate sweep is needed.
# Part 2 breaks the RTL on purpose, one change at a time, starting from the
# clean file each time, and checks that the testbench fails on every one.

$rtl = "rtl/async_FIFO.sv"
$tb  = "tb/tb_async.sv"
$report = @()

# raw output of every simulation goes here (gitignored), nothing gets cut off
New-Item -ItemType Directory -Force logs | Out-Null
Set-Content logs/all_runs.log ""

function Say($s) { Write-Host $s; $script:report += $s }

function Simulate($label, $rtlFile) {
    Remove-Item sim_async -ErrorAction SilentlyContinue
    $cout = & iverilog -g2012 -o sim_async $rtlFile $tb 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        Add-Content logs/all_runs.log ("===== " + $label + " (COMPILE ERROR) =====`n" + $cout)
        return @("COMPILE ERROR", $cout)
    }
    $out = & vvp sim_async 2>&1 | Out-String
    Add-Content logs/all_runs.log ("===== " + $label + " =====`n" + $out)
    return @("OK", $out)
}

# ---------------------------------------------------------------
# Part 1: clean RTL, all clock configurations
# ---------------------------------------------------------------
Say "### Clean RTL"
Say ""
Say "| Run | Result |"
Say "|---|---|"
$r = Simulate "clean RTL" $rtl
if ($r[0] -ne "OK") {
    $res = "COMPILE ERROR (see below)"
    Write-Host $r[1]
}
elseif ($r[1] -match "ALL CHECKS PASSED") { $res = "pass (all 8 clock configurations)" }
else { $res = "FAIL (run it by hand to see why)" }
Say ("| testbench on rtl/async_FIFO.sv | " + $res + " |")

# ---------------------------------------------------------------
# Part 2: mutation testing on the current RTL
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
      "(gray_write_ptr[3:2] == ~gray_read_ptr_ff2[3:2])",
      "(gray_write_ptr[3:2] == gray_read_ptr_ff2[3:2])", ""),
    @("full ignores the top two bits",
      "(gray_write_ptr[3:2] == ~gray_read_ptr_ff2[3:2]) && ",
      "", ""),
    @("empty uses != instead of ==",
      "(gray_write_ptr_ff2 == gray_read_ptr)",
      "(gray_write_ptr_ff2 != gray_read_ptr)", ""),
    @("empty uses stale registered read pointer",
      "(gray_write_ptr_ff2 == gray_read_ptr)",
      "(gray_write_ptr_ff2 == gray_read_ptr_reg)", ""),
    @("full uses stale registered write pointer",
      "(gray_write_ptr[3:2] == ~gray_read_ptr_ff2[3:2]) && (gray_write_ptr[1:0] == gray_read_ptr_ff2[1:0])",
      "(gray_write_ptr_reg[3:2] == ~gray_read_ptr_ff2[3:2]) && (gray_write_ptr_reg[1:0] == gray_read_ptr_ff2[1:0])", ""),
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
      "mem[write_ptr[2:0]] <= write_data;",
      "mem[write_ptr[1:0]] <= write_data;", ""),
    @("memory read at the wrong index",
      "read_data <= mem[read_ptr[2:0]];",
      "read_data <= mem[read_ptr[2:0] + 3'd1];", ""),
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
    @("almost_full threshold > 4 (high from occupancy 5)",
      "difference_full > 4'd5",
      "difference_full > 4'd4", ""),
    @("almost_full threshold > 6 (misses occupancy 6)",
      "difference_full > 4'd5",
      "difference_full > 4'd6", ""),
    @("almost_full not masked by ~full",
      "(~full && difference_full > 4'd5)",
      "(difference_full > 4'd5)", ""),
    @("almost_empty threshold < 4 (high at occupancy 3)",
      "difference_empty < 4'd3",
      "difference_empty < 4'd4", ""),
    @("almost_empty threshold < 2 (misses occupancy 2)",
      "difference_empty < 4'd3",
      "difference_empty < 4'd2", ""),
    @("almost_empty not masked by ~empty",
      "(~empty && difference_empty < 4'd3)",
      "(difference_empty < 4'd3)", ""),
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
    @("Gray-to-binary decode drops a term",
      "^gray_read_ptr_ff2[3:1]",
      "^gray_read_ptr_ff2[2:1]", ""),
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
Say "### Mutation testing (current RTL)"
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
    $r = Simulate ("mutation: " + $m[0]) "mut.sv"
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