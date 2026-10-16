@echo off
REM 9sync - one command. No arguments opens the web UI; --cli syncs once.
REM
REM   9sync                    web UI in a browser
REM   9sync --cli              one-shot sync, output in the terminal
REM   9sync --cli -WhatIf      preview, writes nothing
REM   9sync --cli -Tools opencode,hermes
REM   9sync --cli -ListModels  show the models the phone would sync
REM   9sync --cli -PickDefault choose which model the tools default to
REM   9sync --cli -SetupFile <path>
REM
REM To call it from any folder, add this folder to PATH once:
REM   [Environment]::SetEnvironmentVariable("Path",
REM     [Environment]::GetEnvironmentVariable("Path","User") + ";$PWD", "User")

setlocal EnableExtensions EnableDelayedExpansion
set "ROOT=%~dp0"

if "%~1"=="--cli" goto :cli
if "%~1"=="-cli"  goto :cli
if "%~1"=="/cli" goto :cli
goto :web

:cli
REM Strip the flag textually and pass the rest through untouched. Re-collecting
REM the arguments with %~1 in a loop splits "-Tools opencode,hermes" into two
REM separate arguments, which silently syncs only the first tool.
set ARGS=%*
set ARGS=!ARGS:--cli=!
powershell -NoProfile -ExecutionPolicy Bypass -File "%ROOT%engine\sync.ps1" !ARGS!
set "RC=%errorlevel%"
echo.
if "%RC%"=="0" (
    echo [OK] Done.
) else (
    echo [X] Sync failed. See the message above.
)
exit /b %RC%

:web
where node >nul 2>&1
if errorlevel 1 (
    echo [X] Node.js is not installed.
    echo     The web UI needs it for the server only; a one-shot sync does not:
    echo     9sync --cli
    echo     https://nodejs.org/
    pause
    exit /b 1
)

if not exist "%ROOT%web\server.mjs" (
    echo [X] web\server.mjs not found next to this file.
    pause
    exit /b 1
)

start "" node "%ROOT%web\server.mjs"
if errorlevel 1 pause
exit /b 0