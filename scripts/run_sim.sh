#!/usr/bin/env bash
# Simulation runner for the hardware designs (Icarus Verilog).
# Usage: run_sim.sh [mdp3|all]   (default: all)
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

target="${1:-all}"
case "$target" in
    mdp3) run_one mdp3 hardware/mdp3_parser.sv hardware/tb_mdp3_parser.sv ;;
    all)  run_one mdp3 hardware/mdp3_parser.sv hardware/tb_mdp3_parser.sv ;;
    *)
        echo "error: unknown target '$target' (expected: mdp3 | all)" >&2
        exit 1
        ;;
esac
