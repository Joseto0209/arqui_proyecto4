// trade_top.v
// Proyecto 4 - Pochoco Trader
// ICC3302 Arquitectura de Computadores, Universidad de los Andes, 2026-2
//
// Modulo superior que se sintetiza y graba en la FPGA para la
// competencia. No agrega logica propia: instancia el Pochoco SoC con
// la imagen de memoria del agente (sw/trade.hex) y conecta los pines
// de la Go Board. Los pines del SPI (PMOD) van a la FPGA maestra.
//
// Variantes de hardware (seccion 5 del informe): Acelerador elige los
// perifericos MMIO, y MemFile tiene que ser el programa que los usa:
//   Acelerador 0  sw/trade.hex            solo software (version final)
//   Acelerador 1  build/trade_mul.hex     multiplicador
//   Acelerador 2  build/trade_div.hex     divisor
//   Acelerador 3  build/trade_muldiv.hex  ambos
// tools/sintesis.sh las sintetiza todas.

module trade_top #(
  parameter MemFile    = "sw/trade.hex",
  parameter Acelerador = 0,    // 0 software, 1 mul, 2 div, 3 ambos (ver pochoco_soc.v)
  parameter Contador   = 0     // el agente no usa el contador de ciclos del P2
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

  pochoco_soc #(
    .MemFile    (MemFile),
    .Acelerador (Acelerador),
    .Contador   (Contador)
  ) u_pochoco (
    .i_Clk        (i_Clk),

    .o_LED        (o_LED),
    .i_Switch     (i_Switch),

    .o_Segment1_A (o_Segment1_A),
    .o_Segment1_B (o_Segment1_B),
    .o_Segment1_C (o_Segment1_C),
    .o_Segment1_D (o_Segment1_D),
    .o_Segment1_E (o_Segment1_E),
    .o_Segment1_F (o_Segment1_F),
    .o_Segment1_G (o_Segment1_G),

    .o_Segment2_A (o_Segment2_A),
    .o_Segment2_B (o_Segment2_B),
    .o_Segment2_C (o_Segment2_C),
    .o_Segment2_D (o_Segment2_D),
    .o_Segment2_E (o_Segment2_E),
    .o_Segment2_F (o_Segment2_F),
    .o_Segment2_G (o_Segment2_G),

    .i_SPI_SCLK   (i_SPI_SCLK),
    .i_SPI_MOSI   (i_SPI_MOSI),
    .i_SPI_CS_n   (i_SPI_CS_n),
    .o_SPI_MISO   (o_SPI_MISO)
  );

endmodule
