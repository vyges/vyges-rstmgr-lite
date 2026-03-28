# vyges-rstmgr-lite

Lightweight reset manager with a native TL-UL (TileLink Uncached Lightweight)
slave interface. Designed as a drop-in infrastructure IP for OpenTitan-based and
TileLink SoCs without requiring RACL, alert, or lifecycle dependencies.

## Features

- Configurable number of reset domains (1--4, default 4)
- 2-FF reset synchronizer per domain (async assert, sync deassert)
- Software reset trigger per domain (auto-clearing)
- Watchdog timeout counter with configurable threshold
- Watchdog bark interrupt output
- Reset cause register (POR, software, watchdog) -- sticky until cleared
- Configurable minimum reset pulse width (HOLD_CYCLES)
- Single-cycle TL-UL response (always ready)

## Register Map

| Offset | Name          | Access | Description                                      |
|--------|---------------|--------|--------------------------------------------------|
| 0x00   | RST_EN        | RW     | Reset domain enable (1 = active, deasserted)     |
| 0x04   | RST_STATUS    | RO     | Reset domain status (1 = in reset)               |
| 0x08   | SW_RST        | RW     | Software reset trigger (write 1, auto-clears)    |
| 0x0C   | RST_CAUSE     | RO     | Last reset cause: 0=POR, 1=SW, 2=WDT (sticky)   |
| 0x10   | RST_CAUSE_CLR | WO     | Write 1 to clear RST_CAUSE                       |
| 0x14   | WDT_CTRL      | RW     | [0] WDT enable, [1] WDT reset enable             |
| 0x18   | WDT_COUNT     | RW     | Watchdog timeout value (clk_i cycles)            |
| 0x1C   | WDT_KICK      | WO     | Write any value to reset watchdog counter        |

## Parameters

| Parameter   | Type         | Default | Description                          |
|-------------|--------------|---------|--------------------------------------|
| NUM_RESETS  | int unsigned | 4       | Number of reset domains (1..4)       |
| HOLD_CYCLES | int unsigned | 16      | Minimum reset pulse width (cycles)   |

## SoC Integration Example (soc-spec.yaml)

```yaml
peripherals:
  - name: rstmgr0
    ip: vyges-rstmgr-lite
    base_addr: 0x4001_0000
    parameters:
      NUM_RESETS: 4
      HOLD_CYCLES: 32
    connections:
      rst_no[0]: core_rst_n
      rst_no[1]: periph_rst_n
      rst_no[2]: mem_rst_n
      rst_no[3]: debug_rst_n
      intr_wdt_bark_o: intr[0]
```

## Dependencies

- `opentitan-tlul` -- provides `tlul_pkg` (TL-UL struct types and opcodes).

## License

Apache-2.0. See [LICENSE](LICENSE).
