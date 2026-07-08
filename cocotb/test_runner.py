"""
test_runner.py

Replaces the Makefile-based flow. Run directly with:

    py -3.13 test_runner.py

This avoids `make` (and the Unix tools like `tr`/`sed` its cocotb Makefiles
rely on, which don't exist natively on Windows) entirely - cocotb's own
docs recommend this "Python Runner" approach for Windows users specifically
for this reason.

Requires: cocotb, Icarus Verilog (iverilog/vvp) both on PATH.
"""

from pathlib import Path
from cocotb_tools.runner import get_runner

def run_uart_rx_tests():
    proj_path = Path(__file__).resolve().parent

    runner = get_runner("icarus")

    runner.build(
        sources=[proj_path / "uart_rx.v"],
        hdl_toplevel="uart_rx",
        always=True,
    )

    runner.test(
        hdl_toplevel="uart_rx",
        test_module="test_uart_rx",
        timescale=("1ns", "1ps"),
    )

if __name__ == "__main__":
    run_uart_rx_tests()
