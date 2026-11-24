#!/usr/bin/env bash
# sintesis.sh
# Sintetiza y rutea las cuatro variantes del agente y junta sus recursos.
# Proyecto 4, ICC3302 Arquitectura de Computadores, UANDES 2026-2
#
#   make recursos          (o: bash tools/sintesis.sh)
#
# Para cada variante corre Yosys (synth_ice40) y nextpnr-ice40 a 25 MHz,
# con la misma semilla, y escribe build/recursos.txt con:
#   SB_LUT4       LUTs despues de la sintesis (Yosys)
#   LC            celdas logicas usadas despues del ruteo (nextpnr), de 1280
#   RAM           bloques SB_RAM40_4K, de 16
#   Fmax          frecuencia maxima que informa nextpnr tras el ruteo
#
# Todas usan Contador = 0 (sin el contador de ciclos del Proyecto 2), asi
# la unica diferencia entre variantes son los aceleradores.

set -u
cd "$(dirname "$0")/.."
mkdir -p build

SRC="$(ls rtl/*.v rtl/espino_core/*.v | tr '\n' ' ')"
SEMILLA=1

# nombre:Acelerador:programa
VARIANTES="sw:0:sw/trade.hex mul:1:build/trade_mul.hex div:2:build/trade_div.hex muldiv:3:build/trade_muldiv.hex"

printf "%-8s %11s %8s %13s %6s %11s\n" "Variante" "Acelerador" "SB_LUT4" "LC (de 1280)" "RAM" "Fmax (MHz)" | tee build/recursos.txt

for v in $VARIANTES; do
  nombre=${v%%:*}; resto=${v#*:}; acel=${resto%%:*}; hex=${resto#*:}
  if [ ! -f "$hex" ]; then
    echo "Falta $hex: corre primero make trade variantes" >&2
    exit 1
  fi

  yosys -q -p "read_verilog $SRC; chparam -set MemFile \"$hex\" -set Acelerador $acel -set Contador 0 trade_top; synth_ice40 -top trade_top -dffe_min_ce_use 4 -json build/rec_$nombre.json; tee -q -o build/rec_$nombre.stat stat" \
    > build/rec_$nombre.yosys.log 2>&1 || { echo "FALLO yosys en $nombre (build/rec_$nombre.yosys.log)"; exit 1; }

  nextpnr-ice40 --hx1k --package vq100 --freq 25 --seed $SEMILLA \
    --json build/rec_$nombre.json --pcf goboard.pcf --asc build/rec_$nombre.asc \
    > build/rec_$nombre.pnr.log 2>&1
  pnr=$?

  lut=$(awk '/SB_LUT4/{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+$/){print $i; exit}}' build/rec_$nombre.stat)
  lc=$(awk '/ICESTORM_LC:/{x=$3} END{gsub("/","",x); print x}' build/rec_$nombre.pnr.log)
  ram=$(awk '/ICESTORM_RAM:/{x=$3} END{gsub("/","",x); print x}' build/rec_$nombre.pnr.log)
  fmax=$(awk '/Max frequency for clock/{for(i=1;i<=NF;i++) if($i=="MHz"){f=$(i-1)}} END{print f}' build/rec_$nombre.pnr.log)
  [ $pnr -ne 0 ] && fmax="NO RUTEA"

  printf "%-8s %11s %8s %13s %6s %11s\n" "$nombre" "$acel" "${lut:-?}" "${lc:-?}" "${ram:-?}" "${fmax:-?}" | tee -a build/recursos.txt
done

echo
echo "Logs: build/rec_<variante>.yosys.log y build/rec_<variante>.pnr.log"
