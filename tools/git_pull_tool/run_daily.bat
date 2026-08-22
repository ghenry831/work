@echo off
chcp 65001 >nul

REM 切换到工具所在目录
set "TOOL_DIR=C:\path\to\git_pull_tool"
cd /d "%TOOL_DIR%"

REM 指定 Python 解释器路径
set "PYTHON=C:\Python38\python.exe"

REM 执行拉取
"%PYTHON%" git_pull.py --config config.json

pause
