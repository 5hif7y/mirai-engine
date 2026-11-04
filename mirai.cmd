@echo off
rem Lets PowerShell and cmd find ./mirai: runs the bash launcher with Git Bash. The path goes with
rem forward slashes because the launcher finds the engine root from the slashes of $0.
setlocal
set "bash=%ProgramFiles%\Git\bin\bash.exe"
if exist "%bash%" goto run
set "bash=%ProgramFiles(x86)%\Git\bin\bash.exe"
if exist "%bash%" goto run
set "bash=%LocalAppData%\Programs\Git\bin\bash.exe"
if exist "%bash%" goto run
if defined GIT_INSTALL_ROOT set "bash=%GIT_INSTALL_ROOT%\bin\bash.exe"
if exist "%bash%" goto run
rem Git for Windows installed elsewhere: git.exe in PATH names its root.
set "bash="
for /f "delims=" %%i in ('git --exec-path 2^>nul') do call :from_exec "%%i"
if defined bash goto run
goto missing

:from_exec
for %%j in ("%~1\..\..\..") do (
    if exist "%%~fj\bin\bash.exe" set "bash=%%~fj\bin\bash.exe"
    if not defined bash if exist "%%~fj\usr\bin\bash.exe" set "bash=%%~fj\usr\bin\bash.exe" & set "bashopt=-l"
)
goto :eof

:run
set "launcher=%~dp0mirai"
"%bash%" %bashopt% "%launcher:\=/%" %*
exit /b %errorlevel%

:missing
echo mirai: Git Bash is missing; install Git for Windows or run ./mirai from bash 1>&2
exit /b 1
