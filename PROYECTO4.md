# Proyecto 4 — Pochoco Trader

**ICC3302 Arquitectura de Computadores** · Universidad de los Andes · 2026-2

Agente de inversión en assembly RV32E para el Espino Core. Recibe el precio por
SPI en cada tick y responde con un byte: comprar, vender o mantener, y cuánto.

> Estado: algoritmo, referencia, `trade.s` y mediciones por tick listos y
> verificados con el simulador de instrucciones. Falta correr el testbench en
> Verilog (`sim_p4`), las variantes de hardware y el informe.

## Archivos del Proyecto 4

| Archivo | Qué es |
|---|---|
| `ref/trader.py` | Versión de referencia del algoritmo y comparación con *no operar* y *comprar y mantener* |
| `sw/trade.s` | El agente en assembly (versión final de software) |
| `sw/trade_v0.s` | El mismo agente con multiplicación y división ingenuas (línea base de las mediciones) |
| `tools/espino_iss.py` | Simulador de instrucciones del Espino: compara con la referencia y mide IC, ciclos y CPI por tick |
| `tools/comparar.py` | Compara el `decisiones.csv` del testbench con la referencia |
| `tb/tb_proyecto_4.sv` | Testbench del curso (emula a la FPGA maestra) |
| `tb/practica_meta.csv` | Serie de práctica (20 000 ticks, precios entre 100 y 255) |
| `rtl/trade_top.v` | Módulo superior para la placa, con `sw/trade.hex` |
| `build_trade.bat`, `sim_p4.bat` | Windows: grabar la placa y correr el testbench |

## Comandos

Desde la raíz del repositorio, en la terminal de OSS CAD Suite.

| Qué | Windows | Linux / macOS |
|---|---|---|
| Ensamblar `trade.s` | `python asm\asm.py sw\trade.s -o sw\trade.hex` | `make trade` |
| Referencia del algoritmo | `python ref\trader.py tb\practica_meta.csv` | `make ref` |
| Decisiones, IC, ciclos y CPI | `python tools\espino_iss.py sw\trade.hex tb\practica_meta.csv --perfil` | `make iss` |
| Testbench del curso | `sim_p4` | `make sim-p4` |
| Sintetizar y grabar | `build_trade` | `make prog-trade` |

## Algoritmo

Escalera dentro del rango normalizado (100 a 255). La explicación completa está
en el encabezado de `ref/trader.py`.

- **Escalera:** acciones objetivo = (255 − p) / 155 × patrimonio / p. Compra
  cuando el precio baja y vende cuando sube. Opera solo si la diferencia con lo
  que tiene es de 12 acciones o más.
- **Extremos:** con p ≤ 101 compra todo; con p ≥ 254 vende todo.
- **Memoria de extremos:** si vio el mínimo y aún no el máximo, se queda
  comprado hasta el máximo; si vio el máximo y aún no el mínimo, se queda en
  caja hasta el mínimo.
- **Cantidad q:** objetivo menos acciones actuales, con tope 63 por orden.

### Resultados en la serie de práctica (20 000 ticks)

| | Patrimonio final | Órdenes | Comisiones | Pérdida máxima |
|---|---|---|---|---|
| Agente | 21 906 | 27 | 135 | 2 872 |
| No operar | 10 000 | 0 | 0 | 0 |
| Comprar y mantener | 9 695 | 1 | 5 | 9 300 |

## Mediciones por tick (simulador de instrucciones)

Del precio recibido a la escritura de `DECISION`, serie completa.

| Versión | IC prom. | Ciclos prom. | CPI | IC peor | Ciclos peor | Tiempo peor | Ronda 3 (2 262 ciclos) |
|---|---|---|---|---|---|---|---|
| `trade_v0.s` (sumas y restas repetidas) | 985,7 | 2 288,5 | 2,32 | 2 467 | 5 669 | 226,8 µs | no alcanza |
| `trade.s` (suma y duplica, tabla de dobles) | 140,1 | 311,3 | 2,22 | 355 | 788 | 31,5 µs | usa el 35 % |

Las dos versiones entregan el mismo byte que `ref/trader.py` en los 20 000 ticks.

## En la competencia

- Grabar con `build_trade`. La placa queda esperando precios.
- **Antes de cada ronda apretar un botón de la placa:** reinicia la caja propia
  (10 000) y las acciones (0), igual que la maestra.
- Display: último precio recibido, en hexadecimal. LED 0: ya vio el mínimo.
  LED 1: ya vio el máximo.
