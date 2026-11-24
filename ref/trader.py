#!/usr/bin/env python3
# trader.py
# Version de referencia del agente de inversion del Proyecto 4.
# ICC3302 Arquitectura de Computadores, UANDES 2026-2
#
# Uso (desde la raiz del repositorio):
#
#   python ref/trader.py tb/practica_meta.csv
#   python ref/trader.py tb/practica_meta.csv -o build/ref_decisiones.csv
#   python ref/trader.py tb/practica_meta.csv -n 2000
#
# Solo usa aritmetica entera: sumas, restas, comparaciones, un producto
# por un numero de 8 bits y una division entera. Es exactamente lo que
# hace sw/trade.s, y tools/espino_iss.py comprueba que ambos entregan
# el mismo byte de decision en todos los ticks.
#
# ---------------------------------------------------------------------
#  Idea del algoritmo: escalera dentro de un rango conocido
# ---------------------------------------------------------------------
# El curso normaliza cada serie entre 100 y 255. Eso significa que el
# precio nunca baja de 100 ni sube de 255, y que en algun momento toca
# ambos extremos. El agente usa ese rango de tres formas:
#
#  1. Escalera (reversion a la media). La fraccion del patrimonio que
#     se quiere tener en acciones baja en linea recta con el precio:
#
#         f(p) = (255 - p) / 155        1 en p = 100, 0 en p = 255
#
#     acciones objetivo = f(p) * W / p,  con W = caja + acciones * p.
#     Si el precio baja, compra; si sube, vende. Solo opera cuando la
#     diferencia con lo que tiene es de BANDA acciones o mas, para no
#     pagar comision por ajustes chicos.
#
#  2. Extremos. Con p <= P_LO compra todo lo que alcance (no puede
#     bajar mas). Con p >= P_HI vende todo (no puede subir mas).
#
#  3. Memoria de extremos. Si ya vio el minimo pero todavia no el
#     maximo, sabe que el maximo esta por venir: se queda comprado
#     entero hasta P_HI. Si vio el maximo pero no el minimo, se queda
#     en caja hasta P_LO. Cuando ya vio los dos, vuelve a la escalera.
#
# La cantidad q de cada orden es la diferencia entre el objetivo y lo
# que tiene, con tope 63 (los 6 bits del byte). Si falta mas, sigue en
# el tick siguiente.
#
# El agente lleva su propia contabilidad (caja y acciones) con las
# mismas reglas de la maestra: la orden escrita tras el precio n-1 se
# ejecuta al precio n.

import argparse
import sys

# ---------------------------------------------------------------------
#  Constantes (las mismas .equ de sw/trade.s)
# ---------------------------------------------------------------------
CAJA0 = 10000      # caja inicial
COMISION = 5       # comision fija por orden ejecutada
P_LO = 101         # p <= P_LO: extremo inferior del rango
P_HI = 254         # p >= P_HI: extremo superior del rango
F_HI = 255         # precio donde la escalera llega a 0 acciones
F_RANGO = 155      # ancho de la escalera (255 - 100)
BANDA = 12         # diferencia minima, en acciones, para operar
QMAX = 63          # tope de una orden

MANTENER, COMPRAR, VENDER = 0x00, 0x40, 0x80


class Agente:
    """Estado del agente: lo mismo que trade.s guarda en registros."""

    def __init__(self):
        self.caja = CAJA0      # s1
        self.acc = 0           # gp
        self.dec = 0           # tp   ultimo byte escrito en DECISION
        self.vistos = 0        # sp   bit 0: vio el minimo, bit 1: vio el maximo

    def tick(self, p):
        """Recibe el precio p y devuelve el byte de decision."""
        if p == 0:                      # no deberia llegar; evita dividir por 0
            self.dec = MANTENER
            return self.dec

        # 1) La orden anterior se ejecuto a este precio: replicar a la maestra
        q = self.dec & 63
        if q:
            if self.dec & COMPRAR:
                if self.caja >= COMISION:
                    q = min(q, (self.caja - COMISION) // p)
                    if q:
                        self.caja -= q * p + COMISION
                        self.acc += q
            else:
                q = min(q, self.acc)
                if q and self.caja + q * p >= COMISION:
                    self.caja += q * p - COMISION
                    self.acc -= q

        # 2) Elegir el objetivo
        if p <= P_LO:
            self.vistos |= 1
            modo = "lleno"
        elif p >= P_HI:
            self.vistos |= 2
            modo = "cero"
        elif self.vistos == 1:
            modo = "lleno"
        elif self.vistos == 2:
            modo = "cero"
        else:
            modo = "escalera"

        # 3) Diferencia d entre el objetivo y lo que se tiene
        if modo == "lleno":
            d = (self.caja - COMISION) // p if self.caja >= COMISION else 0
            umbral = 1
        elif modo == "cero":
            d = -self.acc
            umbral = 1
        else:
            w = self.caja + self.acc * p
            objetivo = ((F_HI - p) * w) // (F_RANGO * p)
            d = objetivo - self.acc
            umbral = BANDA

        # 4) Byte de decision
        if d >= umbral:
            self.dec = COMPRAR | min(QMAX, d)
        elif -d >= umbral:
            self.dec = VENDER | min(QMAX, -d)
        else:
            self.dec = MANTENER
        return self.dec


# ---------------------------------------------------------------------
#  Maestra: la misma contabilidad de tb/tb_proyecto_4.sv
# ---------------------------------------------------------------------
class Maestra:
    def __init__(self):
        self.caja, self.acc = CAJA0, 0
        self.w = self.peak = CAJA0
        self.max_dd = 0
        self.ordenes = 0

    def ejecutar(self, decision, p):
        q = decision & 63
        accion = decision >> 6
        if accion == 1:
            q = min(q, (self.caja - COMISION) // p) if self.caja >= COMISION else 0
            if q > 0:
                self.caja -= q * p + COMISION
                self.acc += q
                self.ordenes += 1
        elif accion == 2:
            q = min(q, self.acc)
            if q > 0 and self.caja + q * p >= COMISION:
                self.caja += q * p - COMISION
                self.acc -= q
                self.ordenes += 1
        self.w = self.caja + self.acc * p
        self.peak = max(self.peak, self.w)
        self.max_dd = max(self.max_dd, self.peak - self.w)


def leer_serie(ruta, n=None):
    precios = []
    with open(ruta) as f:
        next(f)                                   # encabezado "tick,price"
        for linea in f:
            linea = linea.strip()
            if linea:
                precios.append(int(linea.split(",")[1]))
    return precios[:n] if n else precios


def simular(precios, decidir):
    """decidir(p) -> byte. La decision tras p[n-1] se ejecuta a p[n]."""
    m = Maestra()
    decision = 0                                   # DECISION vale 0 tras el reset
    filas = []
    for n, p in enumerate(precios):
        m.ejecutar(decision, p)
        filas.append((n, p, decision, m.caja, m.acc, m.w))
        decision = decidir(p)
    return m, filas


def referencia_cym(precios):
    """La formula del testbench: compra todo al precio[0] y mantiene."""
    q = (CAJA0 - COMISION) // precios[0]
    return CAJA0 - COMISION - q * precios[0] + q * precios[-1], q


def main():
    ap = argparse.ArgumentParser(description="Referencia del agente del Proyecto 4")
    ap.add_argument("serie", help="CSV tick,price")
    ap.add_argument("-n", type=int, default=None, help="usar solo los primeros N ticks")
    ap.add_argument("-o", default=None, help="CSV de salida con la decision de cada tick")
    a = ap.parse_args()

    precios = leer_serie(a.serie, a.n)
    agente = Agente()
    m, filas = simular(precios, agente.tick)
    cym, q_cym = referencia_cym(precios)

    if a.o:
        with open(a.o, "w") as f:
            f.write("tick,precio,decision,caja,acciones,patrimonio\n")
            for n, p, d, caja, acc, w in filas:
                f.write("%d,%d,%02x,%d,%d,%d\n" % (n, p, d, caja, acc, w))

    # perdida maxima de comprar y mantener
    peak = dd_cym = 0
    caja_cym = CAJA0 - COMISION - q_cym * precios[0]
    for p in precios:
        w = caja_cym + q_cym * p
        peak = max(peak, w)
        dd_cym = max(dd_cym, peak - w)

    print("Ticks: %d   precio inicial %d, final %d, min %d, max %d"
          % (len(precios), precios[0], precios[-1], min(precios), max(precios)))
    print()
    print("%-22s %12s %9s %11s %15s" % ("", "Patrimonio", "Ordenes", "Comisiones", "Perdida maxima"))
    print("%-22s %12d %9d %11d %15d" % ("Agente (escalera)", m.w, m.ordenes, m.ordenes * COMISION, m.max_dd))
    print("%-22s %12d %9d %11d %15d" % ("No operar", CAJA0, 0, 0, 0))
    print("%-22s %12d %9d %11d %15d" % ("Comprar y mantener", cym, 1, COMISION, dd_cym))
    if a.o:
        print("\nDetalle por tick en", a.o)


if __name__ == "__main__":
    sys.exit(main())
