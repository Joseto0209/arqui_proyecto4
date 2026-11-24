# trade_muldiv.s  ---  ARCHIVO GENERADO por tools/variantes.py, no editar.
# Variante de hardware (Acelerador = 3 en rtl/trade_top.v): igual a
# sw/trade.s, excepto que multiplicar y dividir usan los aceleradores MMIO
#            (rtl/pochoco_mul.v y rtl/pochoco_div.v).
#
# trade.s
# Agente de inversion para el Espino Core (Pochoco SoC, Go Board).
# Proyecto 4 - ICC3302 Arquitectura de Computadores, UANDES 2026-2
#
# Se ensambla con el ensamblador del grupo:
#   python asm/asm.py sw/trade_muldiv.s -o build/trade_muldiv.hex
#
# Toma las mismas decisiones que ref/trader.py (ver ahi la explicacion
# del algoritmo). tools/espino_iss.py lo comprueba tick a tick.
#
# ---------------------------------------------------------------------
#  Ciclo principal
# ---------------------------------------------------------------------
#  esperar   lee STATUS hasta que el bit 0 avisa que llego un precio.
#            Si se aprieta un boton, vuelve a inicio: caja 10000 y 0
#            acciones, para empezar una ronda nueva sin regrabar.
#  aplicar   la orden escrita en el tick anterior se ejecuto a este
#            precio: actualiza la caja y las acciones propias
#  elegir    extremo inferior / extremo superior / escalera
#  decidir   diferencia entre el objetivo y lo que se tiene -> byte
#  escribir  guarda el byte en DECISION y vuelve a esperar
#
# ---------------------------------------------------------------------
#  Uso de registros
# ---------------------------------------------------------------------
#   s0  base del SPI (0x8001_0000), fija todo el programa
#   s1  caja propia
#   gp  acciones propias
#   tp  ultimo byte escrito en DECISION
#   sp  extremos vistos: bit 0 = minimo, bit 1 = maximo (no hay pila)
#   a5  precio del tick
#   a4  cantidad q de la orden que se esta aplicando
#   a3  numerador de la escalera
#   a0, a1, a2  argumentos y resultado de multiplicar / dividir
#   t0, t1, t2  temporales
#   ra  direccion de retorno
#
#  Memoria: solo la tabla de la division (18 palabras al final del
#  programa). Todo el estado vive en registros.
#
# ---------------------------------------------------------------------
#  Operaciones que el Espino no tiene
# ---------------------------------------------------------------------
#  Multiplicar: suma y duplica. Para cada bit del multiplicador (8
#  bits), si esta en 1 suma el multiplicando, y luego lo duplica con
#  add x,x,x. El bit se prueba con andi y una mascara, sin shifts.
#
#  Dividir: guarda divisor, 2*divisor, 4*divisor... en una tabla
#  mientras no superen al dividendo, y despues la recorre hacia atras
#  restando el que quepa. Cada paso entrega un bit del cociente. No
#  necesita shift a la derecha.
#
#  Todos los valores son enteros sin parte fraccionaria: la fraccion
#  (255 - p) / 155 nunca se calcula sola, se multiplica primero y se
#  divide al final.

# =====================================================================
#  Constantes (las mismas de ref/trader.py)
# =====================================================================
.equ CAJA0,    10000      # caja inicial
.equ COMISION, 5          # comision fija por orden ejecutada
.equ P_LO,     101        # p <= P_LO: extremo inferior del rango
.equ P_HI,     254        # p >= P_HI: extremo superior del rango
.equ F_HI,     255        # precio donde la escalera llega a 0 acciones
.equ F_RANGO,  155        # ancho de la escalera (255 - 100)
.equ BANDA,    12         # diferencia minima, en acciones, para operar
.equ QMAX,     63         # tope de una orden

.equ COMPRAR,  0x40       # accion 01 en los bits [7:6]
.equ VENDER,   0x80       # accion 10 en los bits [7:6]

# =====================================================================
#  Mapa de memoria del Pochoco
# =====================================================================
.equ SPI_BASE,     0x80010000
.equ SPI_STATUS,   0      # bit 0: hay un precio nuevo
.equ SPI_PRICE,    4      # precio recibido (leerlo baja el aviso)
.equ SPI_DECISION, 8      # byte que la maestra lee en el proximo tick
.equ PER_BASE,     0x80000000
.equ PER_DISPLAY,  0      # displays de 7 segmentos
.equ PER_LEDS,     4      # LEDs
.equ PER_BOTONES,  8      # botones

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

# =====================================================================
#  Inicio
# =====================================================================
inicio:
    li   s0, SPI_BASE
    li   s1, CAJA0
    li   gp, 0
    li   tp, 0
    li   sp, 0
    sw   zero, SPI_DECISION(s0)

# =====================================================================
#  Esperar el precio
# =====================================================================
esperar:
    li   t1, PER_BASE
    lw   t1, PER_BOTONES(t1)
    bnez t1, inicio                # cualquier boton: partir de cero (nueva ronda)
    lw   t0, SPI_STATUS(s0)
    andi t0, t0, 1
    beqz t0, esperar
    lw   a5, SPI_PRICE(s0)
    beqz a5, nada                  # precio 0: no deberia llegar

# =====================================================================
#  1) Aplicar la orden anterior al precio de este tick
# =====================================================================
    andi a4, tp, 63                # q de la orden anterior
    beqz a4, elegir
    andi t0, tp, COMPRAR
    beqz t0, aplicar_venta

aplicar_compra:
    li   t0, COMISION
    blt  s1, t0, elegir            # sin caja ni para la comision
    addi a1, s1, -COMISION
    mv   a2, a5
    jal  ra, dividir               # a0 = (caja - comision) / p
    bgeu a0, a4, compra_q
    mv   a4, a0                    # no alcanza: se compra el maximo
compra_q:
    beqz a4, elegir
    mv   a1, a5
    mv   a2, a4
    jal  ra, multiplicar           # a0 = q * p
    sub  s1, s1, a0
    addi s1, s1, -COMISION
    add  gp, gp, a4
    j    elegir

aplicar_venta:
    bgeu gp, a4, venta_q
    mv   a4, gp                    # no se vende mas de lo que hay
venta_q:
    beqz a4, elegir
    mv   a1, a5
    mv   a2, a4
    jal  ra, multiplicar           # a0 = q * p
    add  t0, s1, a0
    li   t1, COMISION
    blt  t0, t1, elegir
    addi s1, t0, -COMISION
    sub  gp, gp, a4

# =====================================================================
#  2) Elegir el objetivo
# =====================================================================
elegir:
    li   t0, P_LO
    bltu t0, a5, no_minimo         # p > P_LO
    ori  sp, sp, 1                 # vio el minimo
    j    objetivo_lleno
no_minimo:
    li   t0, P_HI
    bltu a5, t0, no_maximo         # p < P_HI
    ori  sp, sp, 2                 # vio el maximo
    j    objetivo_cero
no_maximo:
    li   t0, 1
    beq  sp, t0, objetivo_lleno    # falta el maximo: comprado entero
    li   t0, 2
    beq  sp, t0, objetivo_cero     # falta el minimo: en caja

# ---------------------------------------------------------------------
#  Escalera: objetivo = (F_HI - p) * W / (F_RANGO * p)
# ---------------------------------------------------------------------
escalera:
    mv   a1, gp
    mv   a2, a5
    jal  ra, multiplicar           # a0 = acciones * p
    add  a1, s1, a0                # a1 = W = caja + acciones * p
    li   t0, F_HI
    sub  a2, t0, a5                # a2 = 255 - p (cabe en 8 bits)
    jal  ra, multiplicar
    mv   a3, a0                    # a3 = (255 - p) * W
    mv   a1, a5
    li   a2, F_RANGO
    jal  ra, multiplicar           # a0 = 155 * p
    mv   a2, a0
    mv   a1, a3
    jal  ra, dividir               # a0 = acciones objetivo
    sub  a0, a0, gp                # d = objetivo - acciones
    li   t0, BANDA
    bge  a0, t0, comprar
    sub  a0, zero, a0
    bge  a0, t0, vender
    j    nada

# ---------------------------------------------------------------------
#  Comprar todo lo que alcance
# ---------------------------------------------------------------------
objetivo_lleno:
    li   t0, COMISION
    blt  s1, t0, nada
    addi a1, s1, -COMISION
    mv   a2, a5
    jal  ra, dividir               # a0 = acciones que alcanzan
    beqz a0, nada

# =====================================================================
#  3) Armar el byte de decision
# =====================================================================
comprar:
    li   t0, QMAX
    bgeu t0, a0, comprar_byte
    mv   a0, t0
comprar_byte:
    ori  tp, a0, COMPRAR
    j    escribir

# ---------------------------------------------------------------------
#  Vender todo
# ---------------------------------------------------------------------
objetivo_cero:
    mv   a0, gp
    beqz a0, nada
vender:
    li   t0, QMAX
    bgeu t0, a0, vender_byte
    mv   a0, t0
vender_byte:
    ori  tp, a0, VENDER
    j    escribir

nada:
    li   tp, 0

# =====================================================================
#  4) Escribir DECISION
# =====================================================================
escribir:
    sw   tp, SPI_DECISION(s0)
    li   t0, PER_BASE
    sw   a5, PER_DISPLAY(t0)       # display: ultimo precio (hex)
    sw   sp, PER_LEDS(t0)          # LED 0: vio el minimo, LED 1: vio el maximo
    j    esperar

# =====================================================================
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

# =====================================================================
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
