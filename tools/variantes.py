#!/usr/bin/env python3
# variantes.py
# Genera las variantes de hardware de sw/trade.s. Proyecto 4, ICC3302, UANDES 2026-2
#
#   python tools/variantes.py           (o: make variantes)
#
# Escribe sw/trade_mul.s, sw/trade_div.s y sw/trade_muldiv.s. Las tres
# son sw/trade.s con el mismo ciclo principal, linea por linea; solo
# cambian las subrutinas multiplicar y/o dividir, que pasan a usar los
# aceleradores MMIO (rtl/pochoco_mul.v y rtl/pochoco_div.v).
#
# No hay que editar los archivos generados: se cambia sw/trade.s y se
# vuelve a correr este script.

import os
import sys

RAIZ = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")

MARCA_MUL = "# =====================================================================\n#  multiplicar:"
MARCA_DIV = "# =====================================================================\n#  dividir:"
MARCA_TABLA = "# Tabla de la division:"

CONSTANTES = """
# =====================================================================
#  Aceleradores MMIO (generado por tools/variantes.py)
# =====================================================================
.equ ACEL_BASE,  0x80020000
.equ MUL_A,      0x00     # multiplicando
.equ MUL_B,      0x04     # multiplicador; escribirlo arranca (8 pasos)
.equ MUL_R,      0x08     # resultado
.equ DIV_N,      0x10     # dividendo
.equ DIV_D,      0x14     # divisor; escribirlo arranca (24 pasos)
.equ DIV_Q,      0x18     # cociente
"""

MUL_HW = """# =====================================================================
#  multiplicar: a0 = a1 * a2, con a2 < 256  (multiplicador MMIO)
#  Usa a0, t0. No toca a1 ni a2.
#
#  El multiplicador da un paso por ciclo y necesita 8. El resultado
#  se puede leer 9 flancos despues del sw de B: cuatro nop (8 ciclos)
#  mas el primer ciclo del lw. Con tres nop leeria el resultado de 7
#  pasos (tb/tb_acel.v lo comprueba).
# =====================================================================
multiplicar:
    li   t0, ACEL_BASE
    sw   a1, MUL_A(t0)
    sw   a2, MUL_B(t0)             # arranca
    nop
    nop
    nop
    nop
    lw   a0, MUL_R(t0)
    ret

"""

DIV_HW = """# =====================================================================
#  dividir: a0 = a1 / a2  (divisor MMIO, cociente < 2^24)
#  Usa a0, t0. No toca a1 ni a2 (la version de software dejaba el
#  resto en a1; ningun llamado lo usa).
#
#  El divisor da un paso por ciclo y necesita 24. El cociente se puede
#  leer 25 flancos despues del sw de D: doce nop (24 ciclos) mas el
#  primer ciclo del lw (tb/tb_acel.v lo comprueba).
# =====================================================================
dividir:
    li   t0, ACEL_BASE
    sw   a1, DIV_N(t0)
    sw   a2, DIV_D(t0)             # arranca
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    nop
    lw   a0, DIV_Q(t0)
    ret
"""

DESCRIPCION = {
    "mul": "multiplicar usa el multiplicador MMIO (rtl/pochoco_mul.v)",
    "div": "dividir usa el divisor MMIO (rtl/pochoco_div.v)",
    "muldiv": "multiplicar y dividir usan los aceleradores MMIO\n#            (rtl/pochoco_mul.v y rtl/pochoco_div.v)",
}
ACELERADOR = {"mul": 1, "div": 2, "muldiv": 3}


def generar(base, variante):
    i_mul = base.index(MARCA_MUL)
    i_div = base.index(MARCA_DIV)
    i_tab = base.index(MARCA_TABLA)
    cuerpo = base[:i_mul]
    mul_sw = base[i_mul:i_div]
    div_sw = base[i_div:]              # incluye la tabla

    cab = ("# trade_%s.s  ---  ARCHIVO GENERADO por tools/variantes.py, no editar.\n"
           "# Variante de hardware (Acelerador = %d en rtl/trade_top.v): igual a\n"
           "# sw/trade.s, excepto que %s.\n#\n"
           % (variante, ACELERADOR[variante], DESCRIPCION[variante]))
    cuerpo = cab + cuerpo.replace("sw/trade.s -o sw/trade.hex",
                                  "sw/trade_%s.s -o build/trade_%s.hex" % (variante, variante))
    # las constantes de los aceleradores van justo antes del codigo
    cuerpo = cuerpo.replace("# =====================================================================\n#  Inicio",
                            CONSTANTES.lstrip("\n") + "\n# =====================================================================\n#  Inicio", 1)

    usa_mul = variante in ("mul", "muldiv")
    usa_div = variante in ("div", "muldiv")
    return (cuerpo
            + (MUL_HW if usa_mul else mul_sw)
            + (DIV_HW if usa_div else div_sw))


def main():
    ruta = os.path.join(RAIZ, "sw", "trade.s")
    with open(ruta, encoding="utf-8") as f:
        base = f.read()
    for v in ("mul", "div", "muldiv"):
        salida = os.path.join(RAIZ, "sw", "trade_%s.s" % v)
        with open(salida, "w", encoding="utf-8") as f:
            f.write(generar(base, v))
        print("sw/trade.s -> sw/trade_%s.s" % v)
    return 0


if __name__ == "__main__":
    sys.exit(main())
