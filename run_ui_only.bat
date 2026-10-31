@echo off
setlocal

set "GODOT_EXE=D:\imopara1\godot\Godot_v4.7.2-stable_win64.exe"
set "PROJECT_DIR=%~dp0apps\godot_app"
set "AETHERKIRI_UI_TEST_MODE=1"

if not exist "%GODOT_EXE%" (
    echo Godot executable not found:
    echo %GODOT_EXE%
    pause
    exit /b 1
)

if not exist "%PROJECT_DIR%\project.godot" (
    echo Aether Godot project not found:
    echo %PROJECT_DIR%
    pause
    exit /b 1
)

start "Aether UI-only test mode" "%GODOT_EXE%" --path "%PROJECT_DIR%"
endlocal
