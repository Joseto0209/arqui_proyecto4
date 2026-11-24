# Proyecto 4 — Pochoco Trader

**ICC3302 Arquitectura de Computadores** · Universidad de los Andes · 2026-2
Profesor: Jorge Gómez Mir

**Integrantes:** José Tomás Arévalo · Santiago Arenas · Danna Collazos

Agente de inversión escrito en assembly RV32E para el **Espino Core**, dentro del
**Pochoco SoC**, sobre la FPGA Lattice iCE40 HX1K de la Nandland Go Board. Una
FPGA maestra envía por SPI el precio de una acción en cada tick, y el programa
responde con un byte: comprar, vender o mantener, y cuántas acciones.

El repositorio parte del Pochoco SoC modificado por el grupo en el Proyecto 2
(que a su vez parte de
[nic0villegasc/pochoco_soc](https://github.com/nic0villegasc/pochoco_soc)). El
programa se traduce a código máquina con el **ensamblador del grupo**
(`asm/asm.py`), sin ensambladores externos.

---

## Estado

| Parte | Estado |
|---|---|
| Algoritmo y versión de referencia (`ref/trader.py`) | Listo |
| Agente en assembly (`sw/trade.s`) | Listo; mismas decisiones que la referencia en los 20 000 ticks |
| Mediciones por tick: IC, ciclos, CPI y tiempo | Listo (simulador de instrucciones) |
| Testbench del curso (`tb/tb_proyecto_4.sv`) | Compila y corre con `make sim-p4` |
| Alternativas de hardware (LUTs, frecuencia, Ops/s, roofline) | Pendiente |
| Informe | Pendiente |

---

## Qué hay en el repositorio

```
ref/
  trader.py                referencia del algoritmo y comparacion con las dos referencias
sw/
  trade.s                  el agente en assembly (version final de software)
  trade.hex                el agente ensamblado (lo que carga la RAM)
  trade_v0.s               el mismo agente con multiplicacion y division ingenuas
                           (linea base de las mediciones)
tools/
  espino_iss.py            simulador de instrucciones del Espino: compara con la
                           referencia y mide IC, ciclos y CPI por tick
  comparar.py              compara el decisiones.csv del testbench con la referencia
tb/
  tb_proyecto_4.sv         testbench del curso (emula a la FPGA maestra)
  practica_meta.csv        serie de practica: 20 000 ticks, precios entre 100 y 255
  sb_ram40_4k.v            modelo de la RAM de la iCE40, solo para simular
rtl/
  trade_top.v              top del proyecto (lo que se sintetiza), con sw/trade.hex
  pochoco_soc.v            SoC: Espino + RAM + perifericos + SPI
  pochoco_spi_slave.v      esclavo SPI: registros STATUS, PRICE y DECISION
  pochoco_periph.v         LEDs, botones, displays y contador de ciclos
  pochoco_ram.v
  espino_core/             el procesador RV32E
asm/
  asm.py                   el ensamblador del grupo
Makefile                   Linux / macOS
build_trade.bat, sim_p4.bat    Windows
goboard.pcf                pines de la Go Board
docs/proyecto2/            README, guia de demostracion e informe del Proyecto 2
```

Del Proyecto 2 también quedan `sw/game.s`, `rtl/game_top.v` y sus testbenches.
La carpeta `build/` se genera al compilar y no se sube.

---

## 1. Instalación

| Programa | Para qué |
|---|---|
| **OSS CAD Suite** (yosys, nextpnr-ice40, icepack, iceprog, iverilog, vvp) | Simular, sintetizar y grabar la placa |
| **Python 3** (sin bibliotecas extra) | Ensamblador, referencia y simulador de instrucciones |
| **Git** y **Make** | Clonar el repositorio y correr los comandos |

**Linux (Fedora):**

```bash
sudo dnf install -y git make
```

Bajar `oss-cad-suite-linux-x64-<fecha>.tgz` desde los
[releases de OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build/releases)
y descomprimirlo:

```bash
cd ~
tar -xzf ~/Descargas/oss-cad-suite-linux-x64-*.tgz
```

En cada terminal nueva, antes de trabajar:

```bash
source ~/oss-cad-suite/environment
```

Permiso para grabar la placa por USB (una sola vez; después reconectar la placa):

```bash
echo 'ACTION=="add", ATTR{idVendor}=="0403", ATTR{idProduct}=="6010", MODE:="666"' | sudo tee /etc/udev/rules.d/53-lattice-ftdi.rules
sudo udevadm control --reload-rules
```

**Windows:** descomprimir OSS CAD Suite, abrir `start.bat` e instalar el driver
de la placa con Zadig, igual que en el Proyecto 2 (`docs/proyecto2/README.md`).

### Versiones de las herramientas

| Herramienta | Versión usada |
|---|---|
| Python | *completar con `python3 --version`* |
| Yosys | *completar con `yosys -V`* |
| nextpnr-ice40 | *completar con `nextpnr-ice40 --version`* |
| Icarus Verilog | *completar con `iverilog -V`* |

---

## 2. Comandos

Todos desde la raíz del repositorio.

| Qué | Linux / macOS | Windows |
|---|---|---|
| Ensamblar `trade.s` | `make trade` | `python asm\asm.py sw\trade.s -o sw\trade.hex` |
| Versión de referencia del algoritmo | `make ref` | `python ref\trader.py tb\practica_meta.csv` |
| Decisiones, IC, ciclos y CPI por tick | `make iss` | `python tools\espino_iss.py sw\trade.hex tb\practica_meta.csv --perfil` |
| Testbench del curso | `make sim-p4` | `sim_p4` |
| Sintetizar y grabar la placa | `make prog-trade` | `build_trade` |

- `make trade` escribe `sw/trade.hex` y el listado `build/trade.lst`.
- `make ref` imprime la tabla de resultados y escribe `build/ref_decisiones.csv`.
- `make iss` corre `trade.s` y `trade_v0.s` en el simulador de instrucciones.
- `make sim-p4` ensambla, corre el testbench con iverilog y compara su
  `decisiones.csv` con la referencia. Con los 20 000 ticks tarda varios minutos.
  El período y la cantidad de ticks se cambian arriba en `tb/tb_proyecto_4.sv`
  (`PERIODO_NS` y `NTICKS`).

El aviso `$readmemh ... Not enough words in the file` es inofensivo: el programa
ocupa menos que las 512 palabras de la RAM.

---

## 3. Algoritmo

Escalera dentro de un rango conocido. El curso normaliza cada serie entre 100 y
255: el precio nunca sale de ese rango y en algún momento toca ambos extremos.

- **Escalera (reversión a la media).** La fracción del patrimonio que se quiere
  tener en acciones baja en línea recta con el precio:
  f(p) = (255 − p) / 155. Acciones objetivo = f(p) · W / p, con
  W = caja + acciones · p. Si el precio baja, compra; si sube, vende. Solo opera
  cuando la diferencia con lo que tiene es de 12 acciones o más, para no pagar
  comisión por ajustes chicos.
- **Extremos.** Con p ≤ 101 compra todo lo que alcance; con p ≥ 254 vende todo.
- **Memoria de extremos.** Si ya vio el mínimo pero no el máximo, se queda
  comprado entero hasta el máximo. Si vio el máximo pero no el mínimo, se queda
  en caja hasta el mínimo. Cuando ya vio los dos, vuelve a la escalera.
- **Cantidad q.** Objetivo menos acciones actuales, con tope 63 por orden. Si
  falta más, sigue en el tick siguiente.

El agente lleva su propia contabilidad (caja y acciones) con las mismas reglas
de la maestra: la orden escrita tras el precio n−1 se ejecuta al precio n.

### Resultados en la serie de práctica (20 000 ticks)

| | Patrimonio final | Órdenes | Comisiones | Pérdida máxima |
|---|---|---|---|---|
| Agente | 21 906 | 27 | 135 | 2 872 |
| No operar | 10 000 | 0 | 0 | 0 |
| Comprar y mantener | 9 695 | 1 | 5 | 9 300 |

---

## 4. Implementación en assembly

Ciclo principal de `sw/trade.s`:

1. **Esperar:** lee `STATUS` hasta que el bit 0 avisa que llegó un precio.
2. **Aplicar:** la orden del tick anterior se ejecutó a este precio; actualiza la
   caja y las acciones propias.
3. **Elegir:** extremo inferior, extremo superior o escalera.
4. **Decidir:** diferencia entre el objetivo y lo que se tiene → byte.
5. **Escribir:** guarda el byte en `DECISION`.

Todo el estado vive en registros (el detalle está en el encabezado de
`trade.s`). La memoria solo se usa para la tabla de la división.

El Espino no ejecuta shifts y RV32E no tiene multiplicación ni división:

- **Multiplicar:** suma y duplica. Por cada bit del multiplicador (8 bits), si
  está en 1 suma el multiplicando, y luego lo duplica con `add x, x, x`. El bit
  se prueba con `andi` y una máscara.
- **Dividir:** guarda divisor, 2·divisor, 4·divisor… en una tabla mientras no
  superen al dividendo, y la recorre hacia atrás restando el que quepa.
- **Punto fijo:** todos los valores son enteros. La fracción (255 − p) / 155
  nunca se calcula sola: se multiplica primero y se divide al final.

### Mediciones por tick

Del precio recibido a la escritura de `DECISION`, serie completa, medidas con
`tools/espino_iss.py` (2 ciclos por instrucción, 3 en los load y en los saltos
tomados, según el RTL del Espino).

| Versión | IC prom. | Ciclos prom. | CPI | IC peor | Ciclos peor | Tiempo peor |
|---|---|---|---|---|---|---|
| `trade_v0.s` (sumas y restas repetidas) | 985,7 | 2 288,5 | 2,32 | 2 467 | 5 669 | 226,8 µs |
| `trade.s` (suma y duplica, tabla de dobles) | 140,1 | 311,3 | 2,22 | 355 | 788 | 31,5 µs |

Peor caso contra el presupuesto de cada ronda (25 MHz, menos 9,5 µs de la
transacción SPI):

| Ronda | Período | Ciclos disponibles | `trade_v0.s` | `trade.s` |
|---|---|---|---|---|
| 1 | 10 ms | 249 762 | 2,3 % | 0,3 % |
| 2 | 1 ms | 24 762 | 22,9 % | 3,2 % |
| 3 | 0,1 ms | 2 262 | 250,6 % (no alcanza) | 34,8 % |

Dónde se van los ciclos:

| Parte | `trade_v0.s` | `trade.s` |
|---|---|---|
| Multiplicar | 88,0 % | 43,7 % |
| Dividir | 9,2 % | 35,0 % |
| Resto | 2,8 % | 21,3 % |

Las dos versiones entregan el mismo byte que `ref/trader.py` en los 20 000 ticks.

---

## 5. En la competencia

1. Grabar la placa con `make prog-trade` (o `build_trade` en Windows).
2. Conectar el PMOD a la FPGA maestra, compartiendo tierra.
3. **Antes de cada ronda, apretar un botón de la placa:** reinicia la caja
   propia (10 000) y las acciones (0), igual que la maestra.

Durante la ronda, el display muestra el último precio recibido en hexadecimal.
LED 0: ya vio el mínimo. LED 1: ya vio el máximo.

---

## Créditos

- Pochoco SoC y Espino Core: Nicolás Villegas, Universidad de los Andes
  ([pochoco_soc](https://github.com/nic0villegasc/pochoco_soc)), bajo la licencia
  Solderpad Hardware License 0.51. Se conservan sus avisos de copyright.
- Testbench `tb/tb_proyecto_4.sv` y serie de práctica: entregados por el curso.
- Agente, referencia, simulador de instrucciones, ensamblador y pruebas: el grupo.
