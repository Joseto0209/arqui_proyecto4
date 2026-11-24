// pochoco_mul.v
// Proyecto 4 - Pochoco Trader. ICC3302 Arquitectura de Computadores, UANDES 2026-2
//
// Multiplicador secuencial de 32 x 8 bits, como periferico MMIO.
// Es la misma "suma y duplica" de multiplicar en sw/trade.s, pero en
// hardware: un paso por ciclo de reloj en vez de unas 9 instrucciones.
//
// Registros (base 0x8002_0000, ver pochoco_soc.v):
//
//   0x00  A       escritura   multiplicando (32 bits)
//   0x04  B       escritura   multiplicador (bits [7:0]); escribirlo ARRANCA
//   0x08  R       lectura     resultado A * B (32 bits bajos)
//   0x0C  ESTADO  lectura     ciclos que faltan (0 = listo)
//
// Cada paso: si el bit 0 de B es 1, R = R + A. Luego A se duplica
// (A << 1) y B se divide por 2 (B >> 1). En hardware los shifts son
// solo cables. Son 8 pasos fijos, en los 8 flancos que siguen al
// flanco en que se escribe B.
//
// Latencia vista desde el programa: entre el sw de B y el lw de R
// tiene que haber al menos 4 instrucciones de 2 ciclos (por ejemplo,
// 4 nop). Con 3 el lw lee el resultado de 7 pasos. tb/tb_acel.v
// comprueba esa latencia exacta.

module pochoco_mul (
  input  wire        clk_i,
  input  wire        rst_ni,

  input  wire        sel_i,
  input  wire        req_i,
  input  wire        we_i,
  input  wire [7:0]  addr_i,
  input  wire [31:0] wdata_i,
  output reg  [31:0] rdata_o
);

  localparam [1:0] OFF_A = 2'd0, OFF_B = 2'd1, OFF_R = 2'd2;

  wire [1:0] off    = addr_i[3:2];
  wire       access = sel_i & req_i;
  wire       wr     = access &  we_i;
  wire       rd     = access & ~we_i;

  reg [31:0] mc_q;     // multiplicando, se duplica en cada paso
  reg [7:0]  mp_q;     // multiplicador, se divide por 2 en cada paso
  reg [31:0] acc_q;    // resultado parcial
  reg [3:0]  cnt_q;    // pasos que faltan

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mc_q  <= 32'b0;
      mp_q  <= 8'b0;
      acc_q <= 32'b0;
      cnt_q <= 4'd0;
    end else if (wr && off == OFF_A) begin
      mc_q  <= wdata_i;
    end else if (wr && off == OFF_B) begin
      mp_q  <= wdata_i[7:0];
      acc_q <= 32'b0;
      cnt_q <= 4'd8;
    end else if (cnt_q != 4'd0) begin
      if (mp_q[0]) acc_q <= acc_q + mc_q;
      mc_q  <= {mc_q[30:0], 1'b0};
      mp_q  <= {1'b0, mp_q[7:1]};
      cnt_q <= cnt_q - 4'd1;
    end
  end

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni)  rdata_o <= 32'b0;
    else if (rd)  rdata_o <= (off == OFF_R) ? acc_q : {28'b0, cnt_q};
  end

endmodule
