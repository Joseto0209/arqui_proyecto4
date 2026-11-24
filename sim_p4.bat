@echo off
REM ============================================================
REM  sim_p4.bat - Corre el testbench del Proyecto 4 (la maestra
REM  emulada) y compara las decisiones con la referencia.
REM
REM  Uso:  sim_p4
REM
REM  [1/4] asm.py:      sw\trade.s -> sw\trade.hex
REM  [2/4] trader.py:   decisiones de referencia
REM  [3/4] iverilog:    tb\tb_proyecto_4.sv con todo rtl\
REM  [4/4] comparar.py: decisiones.csv contra la referencia
REM
REM  El periodo y la cantidad de ticks se cambian arriba en
REM  tb\tb_proyecto_4.sv (PERIODO_NS y NTICKS). Con los 20000
REM  ticks la simulacion tarda varios minutos.
REM ============================================================

setlocal

if not exist build mkdir build

echo.
echo   [1/4] Ensamblando sw\trade.s ...
python asm\asm.py sw\trade.s -o sw\trade.hex -l build\trade.lst
if errorlevel 1 (
    echo   FALLO EL ENSAMBLADO. Se detiene aqui.
    exit /b 1
)

echo.
echo   [2/4] Referencia en Python ...
python ref\trader.py tb\practica_meta.csv -o build\ref_decisiones.csv
if errorlevel 1 exit /b 1

echo.
echo   [3/4] Simulacion con iverilog ...
> build\srcs_p4.txt dir /b /s rtl\*.v
>>build\srcs_p4.txt echo tb\sb_ram40_4k.v
>>build\srcs_p4.txt echo tb\tb_proyecto_4.sv

iverilog -g2012 -o build\tb_proyecto_4.vvp -s tb_proyecto_4 -c build\srcs_p4.txt
if errorlevel 1 (
    echo.
    echo   COMPILACION FALLIDA. NO se ejecuta la simulacion.
    echo.
    exit /b 1
)
vvp -n build\tb_proyecto_4.vvp
if errorlevel 1 exit /b 1

echo.
echo   [4/4] Comparando con la referencia ...
python tools\comparar.py decisiones.csv build\ref_decisiones.csv

endlocal
