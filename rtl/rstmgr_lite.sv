// Copyright 2026 Vyges Inc.
// SPDX-License-Identifier: Apache-2.0
//
// vyges-rstmgr-lite: Lightweight reset manager with TL-UL slave interface.
// Configurable reset domains, 2-FF synchronizers, software reset,
// watchdog timeout reset, reset cause tracking.

`ifndef RSTMGR_LITE_SV
`define RSTMGR_LITE_SV

module rstmgr_lite
  import tlul_pkg::*;
#(
  parameter int unsigned NUM_RESETS  = 4,
  parameter int unsigned HOLD_CYCLES = 16
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,

  // TL-UL device port
  input  tlul_pkg::tl_h2d_t      tl_i,
  output tlul_pkg::tl_d2h_t      tl_o,

  // Reset outputs (active-low, one per domain)
  output logic [NUM_RESETS-1:0]   rst_no,

  // Watchdog bark interrupt (active high)
  output logic                    intr_wdt_bark_o
);

  // ---------------------------------------------------------------------------
  // Register offsets
  // ---------------------------------------------------------------------------
  localparam logic [7:0] ADDR_RST_EN        = 8'h00;
  localparam logic [7:0] ADDR_RST_STATUS    = 8'h04;
  localparam logic [7:0] ADDR_SW_RST        = 8'h08;
  localparam logic [7:0] ADDR_RST_CAUSE     = 8'h0C;
  localparam logic [7:0] ADDR_RST_CAUSE_CLR = 8'h10;
  localparam logic [7:0] ADDR_WDT_CTRL      = 8'h14;
  localparam logic [7:0] ADDR_WDT_COUNT     = 8'h18;
  localparam logic [7:0] ADDR_WDT_KICK      = 8'h1C;

  // ---------------------------------------------------------------------------
  // Reset cause encoding
  // ---------------------------------------------------------------------------
  localparam logic [2:0] CAUSE_POR = 3'd0;
  localparam logic [2:0] CAUSE_SW  = 3'd1;
  localparam logic [2:0] CAUSE_WDT = 3'd2;

  // ---------------------------------------------------------------------------
  // TL-UL bus decode
  // ---------------------------------------------------------------------------
  logic        tl_req;
  logic        tl_we;
  logic [31:0] tl_addr;
  logic [31:0] tl_wdata;

  assign tl_req   = tl_i.a_valid;
  assign tl_we    = (tl_i.a_opcode == PutFullData) || (tl_i.a_opcode == PutPartialData);
  assign tl_addr  = tl_i.a_address;
  assign tl_wdata = tl_i.a_data;

  logic [7:0] addr_sel;
  assign addr_sel = tl_addr[7:0];

  // ---------------------------------------------------------------------------
  // Registers
  // ---------------------------------------------------------------------------
  logic [NUM_RESETS-1:0] reg_rst_en;
  logic [NUM_RESETS-1:0] reg_sw_rst;
  logic [2:0]            reg_rst_cause;
  logic                  rst_cause_valid;
  logic                  reg_wdt_en;
  logic                  reg_wdt_rst_en;
  logic [31:0]           reg_wdt_count;

  // ---------------------------------------------------------------------------
  // Watchdog counter
  // ---------------------------------------------------------------------------
  logic [31:0] wdt_counter;
  logic        wdt_expired;
  logic        wdt_kick;

  assign wdt_kick = tl_req && tl_we && (addr_sel == ADDR_WDT_KICK);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wdt_counter <= '0;
    end else if (!reg_wdt_en || wdt_kick) begin
      wdt_counter <= '0;
    end else if (wdt_counter >= reg_wdt_count && reg_wdt_count != '0) begin
      wdt_counter <= wdt_counter; // hold at expired
    end else begin
      wdt_counter <= wdt_counter + 1;
    end
  end

  assign wdt_expired = reg_wdt_en && (reg_wdt_count != '0) &&
                       (wdt_counter >= reg_wdt_count);

  assign intr_wdt_bark_o = wdt_expired;

  // ---------------------------------------------------------------------------
  // Reset request sources
  // ---------------------------------------------------------------------------
  logic [NUM_RESETS-1:0] rst_request;
  logic                  wdt_rst_req;

  assign wdt_rst_req = wdt_expired & reg_wdt_rst_en;
  assign rst_request = reg_sw_rst | {NUM_RESETS{wdt_rst_req}};

  // ---------------------------------------------------------------------------
  // Reset hold counter (minimum pulse width per domain)
  // ---------------------------------------------------------------------------
  logic [NUM_RESETS-1:0] hold_active;
  logic [$clog2(HOLD_CYCLES+1)-1:0] hold_cnt [NUM_RESETS];

  generate
    for (genvar i = 0; i < NUM_RESETS; i++) begin : g_hold
      always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
          hold_cnt[i]    <= '0;
          hold_active[i] <= 1'b0;
        end else if (rst_request[i]) begin
          hold_cnt[i]    <= HOLD_CYCLES[$clog2(HOLD_CYCLES+1)-1:0];
          hold_active[i] <= 1'b1;
        end else if (hold_cnt[i] != '0) begin
          hold_cnt[i]    <= hold_cnt[i] - 1;
          hold_active[i] <= 1'b1;
        end else begin
          hold_active[i] <= 1'b0;
        end
      end
    end
  endgenerate

  // ---------------------------------------------------------------------------
  // 2-FF reset synchronizer (async assert, sync deassert) per domain
  // ---------------------------------------------------------------------------
  logic [NUM_RESETS-1:0] rst_sync_q1, rst_sync_q2;
  logic [NUM_RESETS-1:0] rst_raw_n;

  // Active-low: domain is in reset when disabled OR hold counter active
  assign rst_raw_n = reg_rst_en & ~hold_active;

  generate
    for (genvar i = 0; i < NUM_RESETS; i++) begin : g_sync
      always_ff @(posedge clk_i or negedge rst_raw_n[i]) begin
        if (!rst_raw_n[i]) begin
          rst_sync_q1[i] <= 1'b0;
          rst_sync_q2[i] <= 1'b0;
        end else begin
          rst_sync_q1[i] <= 1'b1;
          rst_sync_q2[i] <= rst_sync_q1[i];
        end
      end
    end
  endgenerate

  assign rst_no = rst_sync_q2;

  // ---------------------------------------------------------------------------
  // Register read
  // ---------------------------------------------------------------------------
  logic [31:0] rdata;

  always_comb begin
    rdata = 32'h0;
    unique case (addr_sel)
      ADDR_RST_EN:        rdata = {{(32-NUM_RESETS){1'b0}}, reg_rst_en};
      ADDR_RST_STATUS:    rdata = {{(32-NUM_RESETS){1'b0}}, ~rst_sync_q2};
      ADDR_SW_RST:        rdata = {{(32-NUM_RESETS){1'b0}}, reg_sw_rst};
      ADDR_RST_CAUSE:     rdata = {29'h0, reg_rst_cause};
      ADDR_RST_CAUSE_CLR: rdata = 32'h0;
      ADDR_WDT_CTRL:      rdata = {30'h0, reg_wdt_rst_en, reg_wdt_en};
      ADDR_WDT_COUNT:     rdata = reg_wdt_count;
      ADDR_WDT_KICK:      rdata = 32'h0;
      default:             rdata = 32'h0;
    endcase
  end

  // ---------------------------------------------------------------------------
  // Register write + reset cause tracking (single always_ff to avoid multi-driver)
  // ---------------------------------------------------------------------------
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      reg_rst_en      <= {NUM_RESETS{1'b1}};
      reg_sw_rst      <= '0;
      reg_rst_cause   <= CAUSE_POR;
      rst_cause_valid <= 1'b1;
      reg_wdt_en      <= 1'b0;
      reg_wdt_rst_en  <= 1'b0;
      reg_wdt_count   <= '0;
    end else begin
      // Auto-clear software reset triggers after one cycle
      reg_sw_rst <= '0;

      // Reset cause tracking (sticky until cleared)
      if (|reg_sw_rst && !rst_cause_valid) begin
        reg_rst_cause   <= CAUSE_SW;
        rst_cause_valid <= 1'b1;
      end else if (wdt_rst_req && !rst_cause_valid) begin
        reg_rst_cause   <= CAUSE_WDT;
        rst_cause_valid <= 1'b1;
      end

      // Bus writes
      if (tl_req && tl_we) begin
        unique case (addr_sel)
          ADDR_RST_EN:        reg_rst_en     <= tl_wdata[NUM_RESETS-1:0];
          ADDR_SW_RST:        reg_sw_rst     <= tl_wdata[NUM_RESETS-1:0];
          ADDR_RST_CAUSE_CLR: begin
            if (tl_wdata[0])
              rst_cause_valid <= 1'b0;
          end
          ADDR_WDT_CTRL: begin
            reg_wdt_en     <= tl_wdata[0];
            reg_wdt_rst_en <= tl_wdata[1];
          end
          ADDR_WDT_COUNT:     reg_wdt_count <= tl_wdata;
          default: ;
        endcase
      end
    end
  end

  // ---------------------------------------------------------------------------
  // TL-UL response (single-cycle, always ready)
  // ---------------------------------------------------------------------------
  logic        rsp_valid_q;
  logic [31:0] rsp_data_q;
  logic [7:0]  rsp_source_q;
  logic [1:0]  rsp_size_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp_valid_q  <= 1'b0;
      rsp_data_q   <= 32'h0;
      rsp_source_q <= 8'h0;
      rsp_size_q   <= 2'h0;
    end else begin
      rsp_valid_q  <= tl_req;
      rsp_data_q   <= rdata;
      rsp_source_q <= tl_i.a_source;
      rsp_size_q   <= tl_i.a_size;
    end
  end

  assign tl_o.d_valid  = rsp_valid_q;
  assign tl_o.d_opcode = AccessAck;
  assign tl_o.d_param  = '0;
  assign tl_o.d_size   = rsp_size_q;
  assign tl_o.d_source = rsp_source_q;
  assign tl_o.d_sink   = '0;
  assign tl_o.d_data   = rsp_data_q;
  assign tl_o.d_user   = '0;
  assign tl_o.d_error  = 1'b0;
  assign tl_o.a_ready  = 1'b1;

endmodule

`endif // RSTMGR_LITE_SV
