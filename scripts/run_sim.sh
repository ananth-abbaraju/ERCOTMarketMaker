#!/usr/bin/env bash
# Simulation runner for the hardware designs (Icarus Verilog).
# Usage: run_sim.sh [mdp3|lob_pe|lob_array|uart|all]   (default: all)
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v iverilog >/dev/null 2>&1; then
    echo "error: iverilog not found. Install Icarus Verilog (e.g. 'brew install icarus-verilog')." >&2
    exit 1
fi

mkdir -p build/sim

# run_one <name> <rtl.sv ...> <tb.sv>   (rtl may be a space-separated list)
run_one() {
    local name="$1" rtl="$2" tb="$3"
    echo "== ${name} =="
    # shellcheck disable=SC2086  # intentional word-split: rtl may list multiple files
    iverilog -g2012 -Wall -o "build/sim/${name}_tb" $rtl "$tb"
    vvp "build/sim/${name}_tb"
    echo ""
}

# Source file groups (RTL only; the matching tb_<name>.sv is appended per target).
MDP3_RTL="hardware/mdp3_parser.sv"
LOB_PE_RTL="hardware/lob_pe.sv"
LOB_ARRAY_RTL="hardware/lob_array.sv hardware/lob_pe.sv"
UART_RTL="hardware/uart_rx.sv hardware/uart_tx.sv"

target="${1:-all}"
case "$target" in
    mdp3)      run_one mdp3      "$MDP3_RTL"      hardware/tb_mdp3_parser.sv ;;
    lob_pe)    run_one lob_pe    "$LOB_PE_RTL"    hardware/tb_lob_pe.sv ;;
    lob_array) run_one lob_array "$LOB_ARRAY_RTL" hardware/tb_lob_array.sv ;;
    uart)      run_one uart      "$UART_RTL"      hardware/tb_uart_loopback.sv ;;
    all)
        run_one mdp3      "$MDP3_RTL"      hardware/tb_mdp3_parser.sv
        run_one lob_pe    "$LOB_PE_RTL"    hardware/tb_lob_pe.sv
        run_one lob_array "$LOB_ARRAY_RTL" hardware/tb_lob_array.sv
        run_one uart      "$UART_RTL"      hardware/tb_uart_loopback.sv
        ;;
    *)
        echo "error: unknown target '$target' (expected: mdp3 | lob_pe | lob_array | uart | all)" >&2
        exit 1
        ;;
esac
