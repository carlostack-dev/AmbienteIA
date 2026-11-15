@echo off
setlocal EnableExtensions

set "SCRIPT_DIR=%~dp0%"
set "PS_SCRIPT=%SCRIPT_DIR%Iniciar-AmbienteIA.ps1"

if not exist "%PS_SCRIPT%" (
    echo [ERRO] Arquivo PowerShell nao encontrado: "%PS_SCRIPT%"
    echo Certifique-se de que todos os arquivos do projeto estejam na mesma pasta.
    echo.
    pause
    exit /b 1
)

rem Abre a interface grafica sem janela de terminal persistente.
rem Erros de abertura aparecem em uma caixa de mensagem e em Logs\interface-erro.log
start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%PS_SCRIPT%"
exit /b 0