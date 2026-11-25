@echo off
cd /d "%~dp0"
setlocal
set "PYTHON=.venv\Scripts\python.exe"
if not exist "%PYTHON%" (
    py -3.12 -m venv .venv || goto :failed
)
"%PYTHON%" -c "import sys; sys.exit(sys.version_info[:2] != (3, 12))" || (
    echo Pulse wymaga srodowiska .venv z Pythonem 3.12.
    goto :failed
)
"%PYTHON%" -c "import customtkinter, matplotlib, psutil" >nul 2>&1 || (
    "%PYTHON%" -m pip install -r requirements.txt || goto :failed
)
if /i "%~1"=="--prepare" exit /b 0
"%PYTHON%" monitor.py || goto :failed
exit /b 0

:failed
if /i not "%~1"=="--prepare" pause
exit /b 1
