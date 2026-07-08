from pathlib import Path
from cocotb_tools.runner import get_runner


def run_bridge_integration_tests():
    proj_path = Path(__file__).resolve().parent
    runner = get_runner("icarus")

    runner.build(
        sources=[
            proj_path / "uart_rx.v",
            proj_path / "uart_tx.v",
            proj_path / "spi_master.v",
            proj_path / "i2c_master.v",
            proj_path / "dispatcher.v",
            proj_path / "bridge_top.v",
        ],
        hdl_toplevel="bridge_top",
        always=True,
        timescale=("1ns", "1ps"),
        waves=True,
    )

    runner.test(
        hdl_toplevel="bridge_top",
        test_module="test_bridge_integration",
        timescale=("1ns", "1ps"),
        waves=True,
    )


if __name__ == "__main__":
    run_bridge_integration_tests()
