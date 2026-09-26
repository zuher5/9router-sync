@echo off
setlocal EnableDelayedExpansion
title 9Router CLI Tools Sync (PC)

REM sync-9router.bat
REM   Tanpa argumen  -> menu interaktif (TUI)
REM
REM sync-9router.bat --cli
REM sync-9router.bat --cli -WhatIf
REM sync-9router.bat --cli -Tools opencode,omp
REM sync-9router.bat --cli -DefaultModel provider/model-name
REM sync-9router.bat --cli -SetupFile C:\path\to\9sync-setup.local.md
REM
REM Ada argumen apa pun -> mode CLI, semua argumen diteruskan ke script.
REM "--cli" boleh ditulis di depan dan akan dibuang.

where powershell >nul 2>&1
if errorlevel 1 (
    echo [X] PowerShell not found.
    pause
    exit /b 1
)

set "SCRIPT_DIR=%~dp0"

if "%~1"=="" goto tui

REM Kumpulkan argumen untuk mode CLI, buang "--cli".
REM
REM cmd memecah argumen di koma, jadi "-Tools opencode,omp" tiba sebagai tiga
REM token terpisah. Kalau dibiarkan, token terakhir mengikat posisional ke
REM parameter String pertama (RemoteUrl) dan sync diarahkan ke URL sampah tanpa
REM error. Jadi nama tool dikumpulkan terpisah lalu disambung ulang dengan koma.
REM
REM Kumpulan tool berhenti di token berikutnya yang diawali "-", karena nama
REM tool tidak pernah diawali "-". Tanpa itu, "-Tools a,b -WhatIf" menelan
REM -WhatIf sebagai nama tool dan dry-run diam-diam berubah jadi sync sungguhan.
REM
REM Catatan: tidak ada "goto" di dalam blok (...). cmd.exe membaca blok sebagai
REM satu unit dan label di belakangnya belum di-scan waktu blok dieksekusi,
REM jadi lompatan dari dalam blok gagal dengan "cannot find the batch label".
REM Karena itu pengecekan tanda "-" lewat "call :checkdash".
REM
REM Token tool disambung dengan koma apa adanya. Kalau tokennya sendiri sudah
REM berisi koma (argumen yang diapit tanda kutip), disambung dengan koma juga
REM dan hasilnya tetap valid: "a,b" lalu "c" -> "a,b,c".
set "ARGS="
set "TOOLS="
set "INTOOLS=0"
:collect
if "%~1"=="" goto collected
if /i "%~1"=="--cli" goto next
if /i "%~1"=="-Tools" goto toolstart
if "%INTOOLS%"=="1" call :checkdash "%~1"
if "%INTOOLS%"=="1" goto tooladd
goto passthrough

:checkdash
if "%~1"=="" exit /b 0
set "TOK=%~1"
if "!TOK:~0,1!"=="-" set "INTOOLS=0"
exit /b 0

:passthrough
set "ARGS=%ARGS% %1"
goto next

:toolstart
set "INTOOLS=1"
goto next

:tooladd
if defined TOOLS (set "TOOLS=!TOOLS!,%~1") else (set "TOOLS=%~1")
goto next

:next
shift
goto collect

:collected
if defined TOOLS set "ARGS=!ARGS! -Tools !TOOLS!"

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%sync-9router.ps1"%ARGS%
set RC=%errorlevel%
echo.
if "%RC%"=="0" (
    echo [OK] Done.
) else (
    echo [X] Sync failed, no files written. See error above.
)
exit /b %RC%

:tui
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%sync-9router-tui.ps1"
exit /b %errorlevel%
