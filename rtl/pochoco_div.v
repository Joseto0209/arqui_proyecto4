// pochoco_div.v
// Proyecto 4 - Pochoco Trader. ICC3302 Arquitectura de Computadores, UANDES 2026-2
//
// Divisor secuencial sin signo (division con restauracion), como
// periferico MMIO. Entrega un bit del cociente por ciclo de reloj.
//
// Registros (base 0x8002_0000 + 0x10, ver pochoco_soc.v):
//
//   0x10  N       escritura   dividendo (32 bits)
//   0x14  D       escritura   divisor (32 bits, > 0); escribirlo ARRANCA
//   0x18  Q       lectura     cociente N / D
//   0x1C  R       lectura     resto N mod D
//
// Calcula 24 bits de cociente. Es correcto siempre que el cociente
// sea menor que 2^24 (N < D * 2^24) y D < 2^31. En sw/trade.s los
// dividendos son menores que 2^30 y los divisores son p (>= 1) o
// 155 * p, asi que se cumple mientras la caja sea menor que 2^24.
//
// Cada paso: el resto parcial se duplica y recibe el siguiente bit
// del dividendo; si el resultado es >= D, se resta D y el bit del
// cociente es 1. Son 24 pasos, en los 24 flancos que siguen al flanco
// en que se escribe D.
//
// Latencia vista desde el programa: entre el sw de D y el lw de Q
// tiene que haber al menos 12 instrucciones de 2 ciclos (12 nop).
// tb/tb_acel.v comprueba esa latencia exacta.

module pochoco_div (
  input  wire        clk_i,
  input  wire        rst_ni,

  input  wire        sel_i,
  input  wire        req_i,
  input  wire        we_i,
  input  wire [7:0]  addr_i,
  input  wire [31:0] wdata_i,
  output reg  [31:0] rdata_o
);

  localparam [1:0] OFF_N = 2'd0, OFF_D = 2'd1, OFF_Q = 2'd2;

  wire [1:0] off    = addr_i[3:2];
  wire       access = sel_i & req_i;
  wire       wr     = access &  we_i;
  wire       rd     = access & ~we_i;

  reg [31:0] r_q;      // resto parcial
  reg [23:0] qs_q;     // bits del dividendo que faltan; al final, el cociente
  reg [31:0] d_q;      // divisor
  reg [4:0]  cnt_q;    // pasos que faltan

  // Un paso de la division con restauracion
  wire [31:0] rs   = {r_q[30:0], qs_q[23]};          // resto * 2 + siguiente bit
  wire [32:0] dif  = {1'b0, rs} - {1'b0, d_q};
  wire        cabe = ~dif[32];                        // rs >= d_q

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      r_q   <= 32'b0;
      qs_q  <= 24'b0;
      d_q   <= 32'b0;
      cnt_q <= 5'd0;
    end else if (wr && off == OFF_N) begin
      r_q   <= {24'b0, wdata_i[31:24]};               // los 8 bits altos ya son resto
      qs_q  <= wdata_i[23:0];
    end else if (wr && off == OFF_D) begin
      d_q   <= wdata_i;
      cnt_q <= 5'd24;
    end else if (cnt_q != 5'd0) begin
      r_q   <= cabe ? dif[31:0] : rs;
      qs_q  <= {qs_q[22:0], cabe};
      cnt_q <= cnt_q - 5'd1;
    end
  end

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)  rdata_o <= 32'b0;
    else if (rd)  rdata_o <= (off == OFF_Q) ? {8'b0, qs_q} : r_q;
  end

endmodule
