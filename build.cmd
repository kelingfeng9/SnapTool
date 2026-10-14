@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0build.ps1" %*
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" echo [FAIL] Build or tests failed.
if "%~1"=="" pause
exit /b %RESULT%
