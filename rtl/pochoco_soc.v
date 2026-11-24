// Copyright 2026 Universidad de los Andes.
// Licensed under the Solderpad Hardware License, Version 0.51 (the "License");
// you may not use this file except in compliance with the License.
// SPDX-License-Identifier: SHL-0.51
//
// Course: Arquitectura de Computadores (2026)
// 
// Authors:
// - Nicolás Villegas <navillegas@miuandes.cl>

module pochoco_soc #(
  parameter NumWords   = 512,
  parameter MemFile    = "../sw/blink.hex",
  // Proyecto 4 (agregado por el grupo):
  //   Acelerador  bit 0: multiplicador MMIO (pochoco_mul)
  //               bit 1: divisor MMIO (pochoco_div)
  //               0 = sin aceleradores (el Pochoco de siempre)
  //   Contador    1 = contador de ciclos del Proyecto 2 en 0x8000_000C
  parameter Acelerador = 0,
  parameter Contador   = 1
) (
  input  wire       i_Clk,

  output wire [3:0] o_LED,
  input  wire [3:0] i_Switch,

  output wire       o_Segment1_A, o_Segment1_B, o_Segment1_C, o_Segment1_D,
  output wire       o_Segment1_E, o_Segment1_F, o_Segment1_G,
  output wire       o_Segment2_A, o_Segment2_B, o_Segment2_C, o_Segment2_D,
  output wire       o_Segment2_E, o_Segment2_F, o_Segment2_G,

  input  wire       i_SPI_SCLK,
  input  wire       i_SPI_MOSI,
  input  wire       i_SPI_CS_n,
  output wire       o_SPI_MISO
);

  wire clk;
  assign clk = i_Clk;

  // Power-on reset
  reg  [3:0] por_cnt = 4'b0;
  wire       rst_ni;
  always @(posedge clk) begin
    if (por_cnt != 4'hF) por_cnt <= por_cnt + 4'd1;
  end
  assign rst_ni = (por_cnt == 4'hF);

  // Core-memory wiring
  wire        instr_req;
  wire [31:0] instr_addr, instr_rdata;

  wire        data_req, data_we;
  wire [3:0]  data_be;
  wire [31:0] data_addr, data_wdata, data_rdata;

  espino_core #(.BootAddr(32'h0000_0000)) u_core (
    .clk_i         (clk),
    .rst_ni        (rst_ni),
    .instr_req_o   (instr_req),
    .instr_addr_o  (instr_addr),
    .instr_rdata_i (instr_rdata),
    .data_req_o    (data_req),
    .data_we_o     (data_we),
    .data_be_o     (data_be),
    .data_addr_o   (data_addr),
    .data_wdata_o  (data_wdata),
    .data_rdata_i  (data_rdata)
  );

  wire is_mmio, spi_sel, per_sel;
  assign is_mmio = data_addr[31];

  // Aceleradores (Proyecto 4): 0x8002_0000, bit 17 de la direccion.
  //   0x8002_0000 .. 0x8002_000C  multiplicador (bit 4 = 0)
  //   0x8002_0010 .. 0x8002_001C  divisor       (bit 4 = 1)
  // Con Acelerador = 0, acel_sel es una constante 0 y la decodificacion
  // queda igual a la del Pochoco original.
  wire acel_sel, mul_sel, div_sel;
  assign acel_sel = (Acelerador != 0) & is_mmio & data_addr[17];
  assign mul_sel  = acel_sel & ~data_addr[4] & ((Acelerador & 1) != 0);
  assign div_sel  = acel_sel &  data_addr[4] & ((Acelerador & 2) != 0);

  assign per_sel = is_mmio & ~data_addr[16] & ~acel_sel;
  assign spi_sel = is_mmio &  data_addr[16] & ~acel_sel;

  wire ram_b_req, per_req, spi_req;
  assign ram_b_req = data_req & ~is_mmio;
  assign per_req   = data_req &  per_sel;
  assign spi_req   = data_req &  spi_sel;

  wire mul_req, div_req;
  assign mul_req   = data_req &  mul_sel;
  assign div_req   = data_req &  div_sel;

  wire [31:0] ram_b_rdata, per_rdata, spi_rdata;

  reg rd_is_per, rd_is_spi, rd_is_mul, rd_is_div;
  always @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      rd_is_per <= 1'b0;
      rd_is_spi <= 1'b0;
      rd_is_mul <= 1'b0;
      rd_is_div <= 1'b0;
    end else if (data_req & ~data_we) begin
      rd_is_per <= per_sel;
      rd_is_spi <= spi_sel;
      rd_is_mul <= mul_sel;
      rd_is_div <= div_sel;
    end
  end
  wire [31:0] mul_rdata, div_rdata;
  assign data_rdata = rd_is_per ? per_rdata :
                      rd_is_spi ? spi_rdata :
                      rd_is_mul ? mul_rdata :
                      rd_is_div ? div_rdata : ram_b_rdata;

  pochoco_ram #(.NumWords(NumWords), .MemFile(MemFile)) u_ram (
    .clk_i     (clk),
    .a_req_i   (instr_req),
    .a_addr_i  (instr_addr),
    .a_rdata_o (instr_rdata),
    .b_req_i   (ram_b_req),
    .b_we_i    (data_we),
    .b_be_i    (data_be),
    .b_addr_i  (data_addr),
    .b_wdata_i (data_wdata),
    .b_rdata_o (ram_b_rdata)
  );

  // Peripherals
  wire [6:0] seg1, seg2;

  pochoco_periph #(.Contador(Contador)) u_periph (
    .clk_i     (clk),
    .rst_ni    (rst_ni),
    .sel_i     (per_sel),
    .req_i     (per_req),
    .we_i      (data_we),
    .addr_i    (data_addr[7:0]),
    .wdata_i   (data_wdata),
    .rdata_o   (per_rdata),
    .leds_o    (o_LED),
    .btn_i     (i_Switch),
    .seg1_o    (seg1),
    .seg2_o    (seg2)
  );

  // SPI Slave
  pochoco_spi_slave u_spi (
    .clk_i      (clk),
    .rst_ni     (rst_ni),
    .sel_i      (spi_sel),
    .req_i      (spi_req),
    .we_i       (data_we),
    .addr_i     (data_addr[7:0]),
    .wdata_i    (data_wdata),
    .rdata_o    (spi_rdata),
    .spi_sclk_i (i_SPI_SCLK),
    .spi_mosi_i (i_SPI_MOSI),
    .spi_cs_n_i (i_SPI_CS_n),
    .spi_miso_o (o_SPI_MISO)
  );

  // 7-seg is active-low on the board
  assign {o_Segment1_G, o_Segment1_F, o_Segment1_E, o_Segment1_D,
          o_Segment1_C, o_Segment1_B, o_Segment1_A} = ~seg1;
  assign {o_Segment2_G, o_Segment2_F, o_Segment2_E, o_Segment2_D,
          o_Segment2_C, o_Segment2_B, o_Segment2_A} = ~seg2;

  // Aceleradores (Proyecto 4)
  generate
    if ((Acelerador & 1) != 0) begin : g_mul
      pochoco_mul u_mul (
        .clk_i   (clk),
        .rst_ni  (rst_ni),
        .sel_i   (mul_sel),
        .req_i   (mul_req),
        .we_i    (data_we),
        .addr_i  (data_addr[7:0]),
        .wdata_i (data_wdata),
        .rdata_o (mul_rdata)
      );
    end else begin : g_sin_mul
      assign mul_rdata = 32'b0;
    end

    if ((Acelerador & 2) != 0) begin : g_div
      pochoco_div u_div (
        .clk_i   (clk),
        .rst_ni  (rst_ni),
        .sel_i   (div_sel),
        .req_i   (div_req),
        .we_i    (data_we),
        .addr_i  (data_addr[7:0]),
        .wdata_i (data_wdata),
        .rdata_o (div_rdata)
      );
    end else begin : g_sin_div
      assign div_rdata = 32'b0;
    end
  endgenerate

endmodule