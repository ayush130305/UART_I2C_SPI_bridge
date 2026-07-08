from pathlib import Path
from cocotb_tools.runner import get_runner


def run_spi_master_tests():
    proj_path = Path(__file__).resolve().parent
    runner = get_runner("icarus")

    runner.build(
        sources=[proj_path / "spi_master.v"],
        hdl_toplevel="spi_master",
        always=True,
        timescale=("1ns", "1ps"),
        waves=True,
    )

    runner.test(
        hdl_toplevel="spi_master",
        test_module="test_spi_master",
        timescale=("1ns", "1ps"),
        waves=True,
    )


if __name__ == "__main__":
    run_spi_master_tests()
