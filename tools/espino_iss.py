#!/usr/bin/env python3
# espino_iss.py
# Simulador de instrucciones del Espino Core, con la maestra SPI del
# Proyecto 4 emulada. ICC3302 Arquitectura de Computadores, UANDES 2026-2
#
# Uso (desde la raiz del repositorio):
#
#   python tools/espino_iss.py sw/trade.hex tb/practica_meta.csv
#   python tools/espino_iss.py sw/trade.hex tb/practica_meta.csv -o build/iss_decisiones.csv
#   python tools/espino_iss.py sw/trade.hex tb/practica_meta.csv --perfil
#   python tools/espino_iss.py build/trade_v0.hex tb/practica_meta.csv --perfil sw/trade_v0.s
#
# Hace tres cosas:
#
#  1. Ejecuta el .hex instruccion por instruccion y entrega a cada tick
#     el precio de la serie, igual que tb/tb_proyecto_4.sv.
#  2. Compara el byte de decision de cada tick con ref/trader.py.
#  3. Cuenta instrucciones (IC) y ciclos por tick, desde que llega el
#     precio hasta que el programa escribe DECISION.
#
# Los ciclos salen del RTL del Espino (espino_controller.v,
# espino_id_stage.v, espino_load_store_unit.v):
#
#   toda instruccion          2 ciclos (1 de espera del banco de
#                                       registros + 1 de ejecucion)
#   (el store escribe y el load lee el bus en el flanco final de su
#    segundo ciclo)
#   load                      3 ciclos (uno mas: la RAM es sincrona)
#   salto o branch tomado     3 ciclos (uno mas: se descarta la
#                                       instruccion ya buscada)
#
# Tambien modela los aceleradores del Proyecto 4 (rtl/pochoco_mul.v y
# rtl/pochoco_div.v, en 0x8002_0000). El resultado se calcula al
# arrancar, pero leerlo antes de que el hardware termine (9 flancos
# despues de arrancar el multiplicador, 25 el divisor) es un error: asi
# se comprueba que los nop de trade_mul.s y trade_div.s alcanzan.
#
# No reemplaza al testbench en Verilog: es la herramienta para medir y
# comparar rapido. El numero oficial de ciclos es el de tb_proyecto_4.

import argparse
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "ref"))
import trader  # noqa: E402

M32 = 0xFFFFFFFF
SPI_BASE = 0x80010000
PER_BASE = 0x80000000
ACEL_BASE = 0x80020000

# Flancos entre la escritura que arranca un acelerador y el primer
# flanco de lectura que ve el resultado final (ver tools/../rtl)
LAT_MUL = 9
LAT_DIV = 25
PASOS_MUL = 8
PASOS_DIV = 24


def s32(x):
    x &= M32
    return x - (1 << 32) if x & 0x80000000 else x


def sx(v, bits):
    return v - (1 << bits) if v & (1 << (bits - 1)) else v


class Espino:
    def __init__(self, hex_path, palabras=512):
        self.mem = [0] * palabras
        with open(hex_path) as f:
            i = 0
            for linea in f:
                linea = linea.strip()
                if linea:
                    self.mem[i] = int(linea, 16)
                    i += 1
        self.n_prog = i
        self.x = [0] * 16
        self.pc = 0
        self.ic = 0
        self.ciclos = 0
        # SPI
        self.precio = 0
        self.nuevo = 0
        self.decision = 0
        self.escribio = False
        self.leds = 0
        self.display = 0
        self.cuenta_pc = {}      # pc -> ciclos
        self.ic_pc = {}          # pc -> instrucciones
        self.ops_pc = {}         # pc -> operaciones aritmeticas (core + acelerador)
        self.bytes_pc = {}       # pc -> bytes leidos o escritos en el bus de datos
        # aceleradores
        self.mul_a = self.mul_r = 0
        self.div_n = self.div_q = self.div_r = 0
        self.mul_flanco = self.div_flanco = None
        self.flanco = 0          # flanco en que la instruccion actual usa el bus

    # --- bus de datos ------------------------------------------------
    def leer(self, addr):
        if addr & 0x80000000 and addr & 0x20000:
            off = addr & 0x1C
            if off == 0x08:
                self.revisar(self.mul_flanco, LAT_MUL, "multiplicador")
                return self.mul_r
            if off == 0x0C:
                return 0 if self.mul_flanco is None else max(0, PASOS_MUL - (self.flanco - self.mul_flanco - 1))
            if off == 0x18:
                self.revisar(self.div_flanco, LAT_DIV, "divisor")
                return self.div_q
            if off == 0x1C:
                self.revisar(self.div_flanco, LAT_DIV, "divisor")
                return self.div_r
            return 0
        if addr & 0x80000000:
            if addr & 0x10000:
                off = addr & 0xFC
                if off == 0:
                    return self.nuevo
                if off == 4:
                    self.nuevo = 0
                    return self.precio
                return 0
            return 0
        return self.mem[(addr >> 2) % len(self.mem)]

    def revisar(self, inicio, latencia, nombre):
        if inicio is None or self.flanco - inicio < latencia:
            raise RuntimeError("pc=%x: lee el %s %s flancos despues de arrancarlo (necesita %d)"
                               % (self.pc, nombre, "?" if inicio is None else self.flanco - inicio, latencia))

    def escribir(self, addr, valor):
        if addr & 0x80000000 and addr & 0x20000:
            off = addr & 0x1C
            valor &= M32
            if off == 0x00:
                self.mul_a = valor
            elif off == 0x04:
                self.mul_r = (self.mul_a * (valor & 0xFF)) & M32
                self.mul_flanco = self.flanco
                self.ops_pc[self.pc] = self.ops_pc.get(self.pc, 0) + PASOS_MUL
            elif off == 0x10:
                self.div_n = valor
            elif off == 0x14:
                if valor == 0 or self.div_n >= (valor << 24) or valor >= (1 << 31):
                    raise RuntimeError("pc=%x: division fuera del rango del divisor (%d / %d)"
                                       % (self.pc, self.div_n, valor))
                self.div_q, self.div_r = divmod(self.div_n, valor)
                self.div_flanco = self.flanco
                self.ops_pc[self.pc] = self.ops_pc.get(self.pc, 0) + PASOS_DIV
            return
        if addr & 0x80000000:
            if addr & 0x10000:
                if addr & 0xFC == 8:
                    self.decision = valor & 0xFF
                    self.escribio = True
            else:
                off = addr & 0xFC
                if off == 0:
                    self.display = valor & 0xFF
                elif off == 4:
                    self.leds = valor & 0xF
            return
        self.mem[(addr >> 2) % len(self.mem)] = valor & M32

    # --- una instruccion ---------------------------------------------
    def paso(self):
        pc = self.pc
        ins = self.mem[(pc >> 2) % len(self.mem)]
        op = ins & 0x7F
        rd = (ins >> 7) & 0xF
        f3 = (ins >> 12) & 7
        rs1 = (ins >> 15) & 0xF
        rs2 = (ins >> 20) & 0xF
        f7 = ins >> 25
        a = self.x[rs1]
        b = self.x[rs2]
        imm_i = sx(ins >> 20, 12)
        sig = pc + 4
        ciclos = 2
        res = None
        self.flanco = self.ciclos + 2        # segundo ciclo de la instruccion
        bus = 0

        if op == 0x37:                                   # lui
            res = ins & 0xFFFFF000
        elif op == 0x17:                                 # auipc
            res = pc + (ins & 0xFFFFF000)
        elif op == 0x6F:                                 # jal
            imm = ((ins >> 31) << 20) | (((ins >> 12) & 0xFF) << 12) | (((ins >> 20) & 1) << 11) | (((ins >> 21) & 0x3FF) << 1)
            res = pc + 4
            sig = pc + sx(imm, 21)
            ciclos = 3
        elif op == 0x67:                                 # jalr
            res = pc + 4
            sig = (a + imm_i) & ~1
            ciclos = 3
        elif op == 0x63:                                 # branch
            imm = ((ins >> 31) << 12) | (((ins >> 7) & 1) << 11) | (((ins >> 25) & 0x3F) << 5) | (((ins >> 8) & 0xF) << 1)
            t = {0: a == b, 1: a != b, 4: s32(a) < s32(b), 5: s32(a) >= s32(b), 6: a < b, 7: a >= b}[f3]
            if t:
                sig = pc + sx(imm, 13)
                ciclos = 3
        elif op == 0x03:                                 # load
            if f3 != 2:
                raise RuntimeError("load no soportado por el simulador en pc=%x" % pc)
            res = self.leer((a + imm_i) & M32)
            ciclos = 3
            bus = 4
        elif op == 0x23:                                 # store
            if f3 != 2:
                raise RuntimeError("store no soportado por el simulador en pc=%x" % pc)
            imm = sx(((ins >> 25) << 5) | ((ins >> 7) & 0x1F), 12)
            self.escribir((a + imm) & M32, b)
            bus = 4
        elif op in (0x13, 0x33):                         # aritmetica
            o2 = b if op == 0x33 else imm_i & M32
            if f3 == 0:
                res = a - o2 if (op == 0x33 and f7 == 0x20) else a + o2
            elif f3 == 2:
                res = int(s32(a) < s32(o2))
            elif f3 == 3:
                res = int(a < (o2 & M32))
            elif f3 == 4:
                res = a ^ o2
            elif f3 == 6:
                res = a | o2
            elif f3 == 7:
                res = a & o2
            else:
                raise RuntimeError("shift en pc=%x: el Espino lo ejecuta como add" % pc)
        else:
            raise RuntimeError("instruccion ilegal %08x en pc=%x" % (ins, pc))

        if op in (0x13, 0x33) and rd != 0:
            self.ops_pc[pc] = self.ops_pc.get(pc, 0) + 1
        if bus:
            self.bytes_pc[pc] = self.bytes_pc.get(pc, 0) + bus
        self.ic_pc[pc] = self.ic_pc.get(pc, 0) + 1
        if res is not None and rd != 0:
            self.x[rd] = res & M32
        self.pc = sig & M32
        self.ic += 1
        self.ciclos += ciclos
        self.cuenta_pc[pc] = self.cuenta_pc.get(pc, 0) + ciclos


def correr(hex_path, precios, limite=2_000_000):
    """Devuelve (maestra, filas, medidas) con medidas = [(ic, ciclos)] por tick."""
    cpu = Espino(hex_path)
    # arranque: hasta que el programa queda esperando el primer precio
    for _ in range(1000):
        cpu.paso()
    m = trader.Maestra()
    filas, medidas = [], []
    for n, p in enumerate(precios):
        m.ejecutar(cpu.decision, p)                      # la maestra lee DECISION y ejecuta
        filas.append((n, p, cpu.decision, m.caja, m.acc, m.w))
        cpu.precio, cpu.nuevo, cpu.escribio = p, 1, False
        ic0, c0 = cpu.ic, cpu.ciclos
        pasos = 0
        while not cpu.escribio:
            cpu.paso()
            pasos += 1
            if pasos > limite:
                raise RuntimeError("tick %d: el programa no escribio DECISION" % n)
        medidas.append((cpu.ic - ic0, cpu.ciclos - c0))
        for _ in range(12):                              # termina el tick y vuelve a esperar
            cpu.paso()
    return cpu, m, filas, medidas


def main():
    ap = argparse.ArgumentParser(description="Simulador del Espino con la maestra del Proyecto 4")
    ap.add_argument("hex")
    ap.add_argument("serie")
    ap.add_argument("-n", type=int, default=None, help="usar solo los primeros N ticks")
    ap.add_argument("-o", default=None, help="CSV con la decision de cada tick")
    ap.add_argument("--perfil", nargs="?", const="", default=None, metavar="FUENTE.s",
                    help="ciclos por rutina; sin argumento usa el .s que esta junto al .hex")
    a = ap.parse_args()

    precios = trader.leer_serie(a.serie, a.n)
    cpu, m, filas, medidas = correr(a.hex, precios)

    # --- comparacion con la referencia
    agente = trader.Agente()
    m_ref, filas_ref = trader.simular(precios, agente.tick)
    distintos = [(x[0], x[2], y[2]) for x, y in zip(filas, filas_ref) if x[2] != y[2]]

    if a.o:
        with open(a.o, "w") as f:
            f.write("tick,precio,decision,caja,acciones,patrimonio\n")
            for n, p, d, caja, acc, w in filas:
                f.write("%d,%d,%02x,%d,%d,%d\n" % (n, p, d, caja, acc, w))

    print("Programa: %s (%d palabras)   Serie: %s (%d ticks)" % (a.hex, cpu.n_prog, a.serie, len(precios)))
    print()
    print("Patrimonio final:   %d   (referencia: %d)" % (m.w, m_ref.w))
    print("Ordenes ejecutadas: %d   (referencia: %d)" % (m.ordenes, m_ref.ordenes))
    print("Perdida maxima:     %d" % m.max_dd)
    if distintos:
        print("FAIL decisiones: %d ticks distintos. Primeros: %s" % (len(distintos), distintos[:5]))
    else:
        print("PASS decisiones: los %d ticks son iguales a ref/trader.py" % len(precios))
    ok_estado = (cpu.x[9], cpu.x[3]) == (agente.caja, agente.acc)
    print("%s contabilidad propia: caja=%d acciones=%d (referencia %d, %d)"
          % ("PASS" if ok_estado else "FAIL", cpu.x[9], cpu.x[3], agente.caja, agente.acc))

    # --- mediciones por tick
    ics = [x[0] for x in medidas]
    cic = [x[1] for x in medidas]
    n = len(medidas)
    print()
    print("Por tick (del precio a la escritura de DECISION):")
    print("%-10s %8s %8s %6s %12s" % ("", "IC", "ciclos", "CPI", "tiempo"))
    prom_ic, prom_c = sum(ics) / n, sum(cic) / n
    k = max(range(n), key=lambda i: cic[i])
    print("%-10s %8.1f %8.1f %6.2f %9.2f us" % ("promedio", prom_ic, prom_c, prom_c / prom_ic, prom_c * 0.04))
    print("%-10s %8d %8d %6.2f %9.2f us   (tick %d)" % ("peor caso", ics[k], cic[k], cic[k] / ics[k], cic[k] * 0.04, k))
    print()
    print("Presupuesto por ronda (25 MHz, menos 9,5 us de la transaccion SPI):")
    for ronda, periodo_ns in ((1, 10_000_000), (2, 1_000_000), (3, 100_000)):
        disp = (periodo_ns - 9500) // 40
        print("  ronda %d: %7d ciclos disponibles, peor caso usa %5.1f %%  %s"
              % (ronda, disp, 100.0 * cic[k] / disp, "OK" if cic[k] < disp else "NO ALCANZA"))

    # --- perfil por rutina
    if a.perfil is not None:
        fuente = a.perfil or a.hex.replace(".hex", ".s")
        etiquetas = etiquetas_de(fuente)
        def nombre_de(pc):
            nombre = "inicio"
            for dir_, et in etiquetas:
                if dir_ <= pc:
                    nombre = et
                else:
                    break
            return grupo(nombre)

        grupos = {}
        for pc in cpu.ic_pc:
            g = grupos.setdefault(nombre_de(pc), dict(ciclos=0, ic=0, ops=0, bytes=0, llamadas=0))
            g["ciclos"] += cpu.cuenta_pc.get(pc, 0)
            g["ic"] += cpu.ic_pc.get(pc, 0)
            g["ops"] += cpu.ops_pc.get(pc, 0)
            g["bytes"] += cpu.bytes_pc.get(pc, 0)
        for et in ("multiplicar", "dividir"):
            pc = dict((e, d) for d, e in etiquetas).get(et)
            if pc is not None and et in grupos:
                grupos[et]["llamadas"] = cpu.ic_pc.get(pc, 0)
        grupos.pop("esperar", None)
        total = sum(g["ciclos"] for g in grupos.values())
        print()
        print("Ciclos por parte del programa (toda la corrida, sin contar la espera):")
        for g, d in sorted(grupos.items(), key=lambda kv: -kv[1]["ciclos"]):
            print("  %-12s %10d  %5.1f %%" % (g, d["ciclos"], 100.0 * d["ciclos"] / total))
        print("  %-12s %10d" % ("total", total))
        print()
        print("Kernels (op = instruccion aritmetica del core o paso de un acelerador;")
        print("bytes = lw y sw, incluidos los registros MMIO; rendimiento a 25 MHz):")
        print("  %-12s %9s %12s %8s %9s %8s %10s %12s"
              % ("", "llamadas", "ciclos/llam", "CPI", "ops/llam", "B/llam", "ops/byte", "Mops/s"))
        for g in ("multiplicar", "dividir"):
            d = grupos.get(g)
            if not d or not d["llamadas"]:
                continue
            n = d["llamadas"]
            ai = d["ops"] / d["bytes"] if d["bytes"] else float("inf")
            print("  %-12s %9d %12.1f %8.2f %9.1f %8.1f %10s %12.2f"
                  % (g, n, d["ciclos"] / n, d["ciclos"] / d["ic"], d["ops"] / n, d["bytes"] / n,
                     "infinito" if ai == float("inf") else "%.2f" % ai,
                     d["ops"] / (d["ciclos"] / 25e6) / 1e6))
    return 1 if distintos or not ok_estado else 0


def grupo(etiqueta):
    if etiqueta.startswith("mul"):
        return "multiplicar"
    if etiqueta.startswith("div"):
        return "dividir"
    if etiqueta == "esperar":
        return "esperar"
    return "resto"


def etiquetas_de(fuente):
    """Direccion de cada etiqueta, usando el ensamblador del grupo."""
    raiz = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    sys.path.insert(0, os.path.join(raiz, "asm"))
    import asm
    ens = asm.Ensamblador()
    with open(fuente, encoding="utf-8") as f:
        ens.ensamblar(f.read())
    return sorted((d, e) for e, d in ens.etiquetas.items())


if __name__ == "__main__":
    sys.exit(main())
