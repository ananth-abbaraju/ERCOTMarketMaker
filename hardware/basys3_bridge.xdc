# Basys 3 (Artix-7 XC7A35T-1CPG236C) constraints for fpga_bridge_top.
# Clock: 100 MHz on-board oscillator (W5). Reset: center push-button (U18), active-low
# in the design, so it is inverted at the top if wired to the (active-high) button --
# here rst_n is driven directly; hold the button to assert reset only if you invert it
# in a thin board shim. UART: the FT2232 USB-UART bridge (RsRx=B18 into the FPGA,
# RsTx=A18 out of the FPGA), 115200 8N1.

## 100 MHz system clock
set_property -dict { PACKAGE_PIN W5  IOSTANDARD LVCMOS33 } [get_ports { clk }]
create_clock -add -name sys_clk -period 10.00 -waveform {0 5} [get_ports { clk }]

## Reset (active-low). Mapped to the center button (U18); drive through an inverter shim
## if you want "press = reset", since the raw button is active-high.
set_property -dict { PACKAGE_PIN U18 IOSTANDARD LVCMOS33 } [get_ports { rst_n }]

## USB-UART (FT2232). From the host's perspective TX/RX are crossed at the bridge.
set_property -dict { PACKAGE_PIN B18 IOSTANDARD LVCMOS33 } [get_ports { i_uart_rx }]
set_property -dict { PACKAGE_PIN A18 IOSTANDARD LVCMOS33 } [get_ports { o_uart_tx }]
