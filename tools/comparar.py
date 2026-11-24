#!/usr/bin/env python3
# comparar.py
# Compara el decisiones.csv que escribe tb_proyecto_4 (Verilog) con el
# de la referencia (ref/trader.py). Proyecto 4, ICC3302, UANDES 2026-2
#
#   python tools/comparar.py decisiones.csv build/ref_decisiones.csv
#
# Los dos archivos tienen las mismas columnas:
#   tick,precio,decision,caja,acciones,patrimonio

import sys


def leer(ruta):
    with open(ruta) as f:
        return [linea.strip().lower() for linea in f if linea.strip()][1:]


def main():
    if len(sys.argv) != 3:
        print("Uso: python tools/comparar.py decisiones.csv build/ref_decisiones.csv")
        return 2
    a, b = leer(sys.argv[1]), leer(sys.argv[2])
    n = min(len(a), len(b))
    distintos = [i for i in range(n) if a[i] != b[i]]
    if len(a) != len(b):
        print("AVISO: %s tiene %d ticks y %s tiene %d; se comparan los primeros %d"
              % (sys.argv[1], len(a), sys.argv[2], len(b), n))
    if distintos:
        i = distintos[0]
        print("FAIL %d de %d ticks distintos. Primer tick distinto:" % (len(distintos), n))
        print("   simulacion: " + a[i])
        print("   referencia: " + b[i])
        return 1
    print("PASS los %d ticks son iguales (decision, caja, acciones y patrimonio)" % n)
    return 0


if __name__ == "__main__":
    sys.exit(main())
