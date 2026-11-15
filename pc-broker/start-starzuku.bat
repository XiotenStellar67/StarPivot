@echo off
setlocal
cd /d "%~dp0"
title Starzuku HDC Broker
set "NODE_EXE=D:\Program Files\Huawei\DevEco Studio\tools\node\node.exe"
set "HDC_EXE=D:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
set "HDC=%HDC_EXE%"
if not exist "%NODE_EXE%" (
  echo [ERROR] node.exe not found:
  echo   %NODE_EXE%
  echo Try the system node instead: node broker.js
  pause
  exit /b 1
)
if not exist "%HDC_EXE%" (
  echo [WARN] hdc.exe not found, set HDC env var manually:
  echo   %HDC_EXE%
)
echo ==========================================
echo  Starzuku broker starting...
echo  Keep this window open. Close it to stop.
echo ==========================================
echo.
"%NODE_EXE%" broker.js
echo.
echo Broker exited with code %ERRORLEVEL%
pause
