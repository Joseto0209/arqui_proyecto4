# Copyright 2026 Universidad de los Andes.
# Licensed under the Solderpad Hardware License, Version 0.51 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: SHL-0.51
#
# Course: Arquitectura de Computadores (2026)
#
# Authors:
# - Nicolás Villegas <navillegas@miuandes.cl>   (flujo original del Pochoco)
#
# Adaptado para el Proyecto 2 (juego de reflejos): el top ahora es
# game_top, el programa se ensambla con asm/asm.py y hay objetivos de
# simulacion. En Windows, build.bat y sim.bat hacen lo mismo.
#
#   make            ensambla, sintetiza, rutea y graba la FPGA
#   make hex        solo regenera sw/game.hex desde sw/game.s
#   make bin        todo menos grabar
#   make test       pruebas del ensamblador y las tres simulaciones
#   make sim TB=tb_game
#   make clean

# Configuration
TOP   := game_top
PCF   := goboard.pcf
PY    ?= python3
BUILD := build

# RTL Sources (rtl/ y rtl/espino_core/)
SRC  := $(wildcard rtl/*.v rtl/espino_core/*.v)

# Build Targets
HEX  := sw/game.hex
JSON := $(BUILD)/$(TOP).json
ASC  := $(BUILD)/$(TOP).asc
BIN  := $(BUILD)/$(TOP).bin

# Simulacion: el juego con una decima de 2.500 ciclos (1000 veces mas rapido)
SIM_SRC := $(SRC) tb/sb_ram40_4k.v

.PHONY: all hex bin prog test sim clean trade ref iss sim-p4 prog-trade variantes iss-hw tb-acel sim-hw recursos

# Default target
all: prog

$(BUILD):
	mkdir -p $(BUILD)

# Step 0: Assemble the game with the group's assembler
hex: $(HEX)
$(HEX): sw/game.s asm/asm.py | $(BUILD)
	$(PY) asm/asm.py sw/game.s -o $(HEX) -l $(BUILD)/game.lst

# Step 1: Synthesis using Yosys
$(JSON): $(SRC) $(HEX) | $(BUILD)
	yosys -p "read_verilog $(SRC); synth_ice40 -top $(TOP) -dffe_min_ce_use 4 -json $(JSON); stat"

# Step 2: Place and Route using NextPNR
$(ASC): $(JSON) $(PCF)
	nextpnr-ice40 --hx1k --package vq100 --freq 25 --json $(JSON) --pcf $(PCF) --asc $(ASC)

# Step 3: Bitstream Generation
bin: $(BIN)
$(BIN): $(ASC)
	icepack $(ASC) $(BIN)

# Step 4: Flash the Board
prog: $(BIN)
	iceprog $(BIN)

# Programas que usan las simulaciones
$(BUILD)/prueba_cpu.hex: sw/prueba_cpu.s asm/asm.py | $(BUILD)
	$(PY) asm/asm.py sw/prueba_cpu.s -o $@
$(BUILD)/game_sim.hex: sw/game.s asm/asm.py | $(BUILD)
	$(PY) asm/asm.py sw/game.s -o $@ -D CICLOS_DECIMA=2500

# Una simulacion: make sim TB=tb_game
TB ?= tb_game
sim: $(BUILD)/prueba_cpu.hex $(BUILD)/game_sim.hex
	iverilog -g2012 -o $(BUILD)/$(TB).vvp -s $(TB) $(SIM_SRC) tb/$(TB).v
	vvp -n $(BUILD)/$(TB).vvp

# Todas las pruebas
test: $(BUILD)/prueba_cpu.hex $(BUILD)/game_sim.hex
	$(PY) asm/pruebas/probar_asm.py
	$(MAKE) --no-print-directory sim TB=tb_periph
	$(MAKE) --no-print-directory sim TB=tb_soc
	$(MAKE) --no-print-directory sim TB=tb_game

# Clean up generated files
clean:
	rm -rf $(BUILD)

# ---------------------------------------------------------------------
#  Proyecto 4: Pochoco Trader
# ---------------------------------------------------------------------
#   make trade              ensambla sw/trade.s y sw/trade_v0.s
#   make ref                corre la referencia en Python
#   make iss                simulador de instrucciones: decisiones, IC, ciclos y CPI
#   make sim-p4             testbench del curso (iverilog) + comparacion con la referencia
#   make prog-trade         sintetiza trade_top y graba la placa (PROG=sw|mul|div|muldiv)
#
#  Co-diseno hardware/software (seccion 5 del informe):
#   make variantes          genera y ensambla sw/trade_mul.s, trade_div.s, trade_muldiv.s
#   make iss-hw             mediciones de las 5 versiones (v0, sw, mul, div, muldiv)
#   make tb-acel            testbench de los aceleradores (rtl/pochoco_mul.v, pochoco_div.v)
#   make sim-hw VAR=mul     testbench del curso con una variante (TICKS=2000 por defecto)
#   make recursos           LUTs, celdas, BRAM y Fmax de las 4 variantes (tools/sintesis.sh)
SERIE ?= tb/practica_meta.csv
VAR   ?= muldiv
TICKS ?= 2000
PROG  ?= sw

ACEL_sw     := 0
ACEL_mul    := 1
ACEL_div    := 2
ACEL_muldiv := 3
HEX_sw      := sw/trade.hex
HEX_mul     := $(BUILD)/trade_mul.hex
HEX_div     := $(BUILD)/trade_div.hex
HEX_muldiv  := $(BUILD)/trade_muldiv.hex

trade: | $(BUILD)
	$(PY) asm/asm.py sw/trade.s -o sw/trade.hex -l $(BUILD)/trade.lst
	$(PY) asm/asm.py sw/trade_v0.s -o $(BUILD)/trade_v0.hex

variantes: | $(BUILD)
	$(PY) tools/variantes.py
	$(PY) asm/asm.py sw/trade_mul.s    -o $(BUILD)/trade_mul.hex    -l $(BUILD)/trade_mul.lst
	$(PY) asm/asm.py sw/trade_div.s    -o $(BUILD)/trade_div.hex    -l $(BUILD)/trade_div.lst
	$(PY) asm/asm.py sw/trade_muldiv.s -o $(BUILD)/trade_muldiv.hex -l $(BUILD)/trade_muldiv.lst

ref: | $(BUILD)
	$(PY) ref/trader.py $(SERIE) -o $(BUILD)/ref_decisiones.csv

iss: trade
	$(PY) tools/espino_iss.py sw/trade.hex $(SERIE) --perfil
	$(PY) tools/espino_iss.py $(BUILD)/trade_v0.hex $(SERIE) --perfil sw/trade_v0.s

iss-hw: trade variantes
	$(PY) tools/espino_iss.py $(BUILD)/trade_v0.hex     $(SERIE) --perfil sw/trade_v0.s
	$(PY) tools/espino_iss.py sw/trade.hex              $(SERIE) --perfil sw/trade.s
	$(PY) tools/espino_iss.py $(BUILD)/trade_mul.hex    $(SERIE) --perfil sw/trade_mul.s
	$(PY) tools/espino_iss.py $(BUILD)/trade_div.hex    $(SERIE) --perfil sw/trade_div.s
	$(PY) tools/espino_iss.py $(BUILD)/trade_muldiv.hex $(SERIE) --perfil sw/trade_muldiv.s

sim-p4: trade ref
	iverilog -g2012 -o $(BUILD)/tb_proyecto_4.vvp -s tb_proyecto_4 $(SIM_SRC) tb/tb_proyecto_4.sv
	vvp -n $(BUILD)/tb_proyecto_4.vvp
	$(PY) tools/comparar.py decisiones.csv $(BUILD)/ref_decisiones.csv

tb-acel: | $(BUILD)
	iverilog -g2012 -o $(BUILD)/tb_acel.vvp -s tb_acel rtl/pochoco_mul.v rtl/pochoco_div.v tb/tb_acel.v
	vvp -n $(BUILD)/tb_acel.vvp

sim-hw: variantes ref
	cp $(HEX_$(VAR)) $(BUILD)/variante.hex
	iverilog -g2012 -Ptb_proyecto_4_hw.ACEL=$(ACEL_$(VAR)) -Ptb_proyecto_4_hw.NTICKS=$(TICKS) \
	  -o $(BUILD)/tb_proyecto_4_hw.vvp -s tb_proyecto_4_hw $(SIM_SRC) tb/tb_proyecto_4_hw.sv
	vvp -n $(BUILD)/tb_proyecto_4_hw.vvp
	$(PY) tools/comparar.py $(BUILD)/decisiones_hw.csv $(BUILD)/ref_decisiones.csv

recursos: trade variantes
	bash tools/sintesis.sh

prog-trade: trade variantes
	yosys -q -p "read_verilog $(SRC); chparam -set MemFile \"$(HEX_$(PROG))\" -set Acelerador $(ACEL_$(PROG)) trade_top; synth_ice40 -top trade_top -dffe_min_ce_use 4 -json $(BUILD)/trade_top.json; tee -o $(BUILD)/stat_trade.txt stat"
	nextpnr-ice40 --hx1k --package vq100 --freq 25 --json $(BUILD)/trade_top.json --pcf $(PCF) --asc $(BUILD)/trade_top.asc
	icepack $(BUILD)/trade_top.asc $(BUILD)/trade_top.bin
	iceprog $(BUILD)/trade_top.bin
