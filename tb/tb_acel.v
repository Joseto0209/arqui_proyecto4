// tb_acel.v
// Testbench de los aceleradores del Proyecto 4: rtl/pochoco_mul.v y
// rtl/pochoco_div.v. ICC3302 Arquitectura de Computadores, UANDES 2026-2
//
//   make tb-acel
//
// Maneja el bus de cada periferico igual que la LSU del Espino: las
// senales se ponen en el flanco de bajada y el periferico las toma en
// el flanco de subida siguiente. La lectura queda registrada en
// rdata_o y se revisa en el flanco de bajada posterior.
//
// Revisa:
//   1. 3000 multiplicaciones al azar, leyendo el resultado 9 flancos
//      despues de escribir B (la latencia que usa sw/trade_mul.s).
//   2. Que 8 flancos NO alcanzan (asi se sabe que 9 es el minimo).
//   3. 3000 divisiones al azar (cociente y resto), leyendo el cociente
//      25 flancos despues de escribir D (la de sw/trade_div.s).
//   4. Que 24 flancos NO alcanzan.
//   5. Casos borde: B = 0, B = 255, N < D, D = 1, cociente maximo.

`timescale 1ns/1ps

module tb_acel;

  localparam LAT_MUL = 9;
  localparam LAT_DIV = 25;

  reg clk = 1'b0;
  always #20 clk = ~clk;                      // 25 MHz, como la Go Board

  reg        rst_n = 1'b0;
  reg        sel_mul = 1'b0, sel_div = 1'b0;
  reg        req = 1'b0, we = 1'b0;
  reg [7:0]  addr = 8'h00;
  reg [31:0] wdata = 32'h0;
  wire [31:0] rdata_mul, rdata_div;

  pochoco_mul u_mul (
    .clk_i (clk), .rst_ni (rst_n),
    .sel_i (sel_mul), .req_i (req), .we_i (we),
    .addr_i (addr), .wdata_i (wdata), .rdata_o (rdata_mul));

  pochoco_div u_div (
    .clk_i (clk), .rst_ni (rst_n),
    .sel_i (sel_div), .req_i (req), .we_i (we),
    .addr_i (addr), .wdata_i (wdata), .rdata_o (rdata_div));

  // Escritura: el flanco de subida entre las dos bajadas es el flanco E
  // en que el periferico toma el dato. Termina justo despues de E.
  task escribir(input es_div, input [7:0] a, input [31:0] d);
    begin
      @(negedge clk);
      sel_mul = ~es_div; sel_div = es_div; req = 1'b1; we = 1'b1; addr = a; wdata = d;
      @(negedge clk);
      sel_mul = 1'b0; sel_div = 1'b0; req = 1'b0; we = 1'b0;
    end
  endtask

  // Lectura tomada en el flanco E + k, contando desde la ultima escritura
  task leer_en(input es_div, input [7:0] a, input integer k, output [31:0] v);
    begin
      repeat (k - 1) @(negedge clk);
      sel_mul = ~es_div; sel_div = es_div; req = 1'b1; we = 1'b0; addr = a;
      @(negedge clk);
      sel_mul = 1'b0; sel_div = 1'b0; req = 1'b0;
      v = es_div ? rdata_div : rdata_mul;
    end
  endtask

  integer total = 0, aprobadas = 0;
  task chequear(input ok, input [8*48-1:0] nombre);
    begin
      total = total + 1;
      if (ok) begin aprobadas = aprobadas + 1; $display("PASS %0s", nombre); end
      else            $display("FAIL %0s", nombre);
    end
  endtask

  integer    i, malos;
  reg [31:0] a, b, n, d, q, r, v, esperado;
  reg [63:0] lim;

  // Una multiplicacion completa con la latencia del programa
  task multiplicar(input [31:0] x, input [31:0] y, output [31:0] res);
    begin
      escribir(1'b0, 8'h00, x);
      escribir(1'b0, 8'h04, y);
      leer_en(1'b0, 8'h08, LAT_MUL, res);
    end
  endtask

  // Una division completa: cociente con la latencia del programa, resto despues
  task dividir(input [31:0] x, input [31:0] y, output [31:0] coc, output [31:0] res);
    begin
      escribir(1'b1, 8'h10, x);
      escribir(1'b1, 8'h14, y);
      leer_en(1'b1, 8'h18, LAT_DIV, coc);
      leer_en(1'b1, 8'h1C, 1, res);
    end
  endtask

  initial begin
    repeat (3) @(negedge clk);
    rst_n = 1'b1;

    // 1. Multiplicaciones al azar (B trae basura en los bits altos: se ignoran)
    malos = 0;
    for (i = 0; i < 3000; i = i + 1) begin
      a = (i % 2) ? $urandom : ($urandom % 32'h40000);
      b = $urandom;
      multiplicar(a, b, v);
      esperado = a * {24'b0, b[7:0]};
      if (v !== esperado) begin
        if (malos < 5) $display("  mul %0d * %0d = %0d, se esperaba %0d", a, b[7:0], v, esperado);
        malos = malos + 1;
      end
    end
    chequear(malos == 0, "multiplicador: 3000 productos al azar");

    // 5. Casos borde del multiplicador
    multiplicar(32'd12345, 32'd0, v);    chequear(v == 32'd0,         "multiplicador: B = 0");
    multiplicar(32'd39525, 32'd255, v);  chequear(v == 32'd10078875,  "multiplicador: B = 255");
    multiplicar(32'hFFFFFFFF, 32'd2, v); chequear(v == 32'hFFFFFFFE,  "multiplicador: desborde mod 2^32");
    leer_en(1'b0, 8'h0C, 1, v);          chequear(v == 32'd0,         "multiplicador: ESTADO = 0 al terminar");

    // 2. Con 8 flancos el ultimo paso no alcanza (B con el bit 7 en 1)
    escribir(1'b0, 8'h00, 32'd1000);
    escribir(1'b0, 8'h04, 32'd200);
    leer_en(1'b0, 8'h08, LAT_MUL - 1, v);
    chequear(v != 32'd200000, "multiplicador: 8 flancos no alcanzan");
    leer_en(1'b0, 8'h08, 1, v);
    chequear(v == 32'd200000, "multiplicador: 9 flancos alcanzan");

    // 3. Divisiones al azar
    malos = 0;
    for (i = 0; i < 3000; i = i + 1) begin
      case (i % 4)
        0: d = 32'd1 + ($urandom % 255);                  // p
        1: d = 32'd155 * (32'd1 + ($urandom % 255));      // 155 * p
        2: d = 32'd1 + ($urandom % 32'h100000);           // hasta 2^20
        default: d = 32'd1 + ($urandom % 7);
      endcase
      lim = {32'b0, d} << 24;                             // N < D * 2^24
      if (lim > 64'hFFFFFFFF) n = $urandom;
      else                    n = $urandom % lim[31:0];
      dividir(n, d, q, r);
      if (q !== n / d || r !== n % d) begin
        if (malos < 5) $display("  div %0d / %0d = %0d resto %0d, se esperaba %0d resto %0d",
                                n, d, q, r, n / d, n % d);
        malos = malos + 1;
      end
    end
    chequear(malos == 0, "divisor: 3000 cocientes y restos al azar");

    // 5. Casos borde del divisor
    dividir(32'd99, 32'd100, q, r);            chequear(q == 0 && r == 99,          "divisor: N < D");
    dividir(32'h00FFFFFF, 32'd1, q, r);        chequear(q == 32'h00FFFFFF && r == 0, "divisor: D = 1, cociente maximo");
    dividir(32'd0, 32'd155, q, r);             chequear(q == 0 && r == 0,           "divisor: N = 0");
    dividir(32'd1000000000, 32'd39525, q, r);  chequear(q == 32'd25300 && r == 32'd17500, "divisor: N grande, D = 155 * 255");

    // 4. Con 24 flancos falta el ultimo bit del cociente
    escribir(1'b1, 8'h10, 32'h00800000);
    escribir(1'b1, 8'h14, 32'd1);
    leer_en(1'b1, 8'h18, LAT_DIV - 1, v);
    chequear(v != 32'h00800000, "divisor: 24 flancos no alcanzan");
    leer_en(1'b1, 8'h18, 1, v);
    chequear(v == 32'h00800000, "divisor: 25 flancos alcanzan");

    $display("Pruebas aprobadas: %0d/%0d", aprobadas, total);
    $finish;
  end

endmodule
