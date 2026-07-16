@ECHO OFF
REM Build EDIT and run it in the emulator from the run\ folder.
REM The run\ folder is the host filesystem root the editor sees, and holds
REM sample text files to open/save.
REM
REM Usage:  run.bat [source.p8]    (defaults to edit.p8)

SETLOCAL
SET SRC=%1
IF "%SRC%"=="" SET SRC=edit.p8

REM 1) compile (build.bat writes everything into build\; the project root stays source-only)
CALL "%~dp0build.bat" %SRC%
IF ERRORLEVEL 1 GOTO :EOF

REM 2) stage the fresh binaries out of build\ into the program folder run\MSEDIT (EDIT lives in
REM    its own directory; the fsroot stays run\, which is where the documents and ed.run are).
SET BUILDDIR=%~dp0build
SET RUNDIR=%~dp0run
SET PROGDIR=%RUNDIR%\MSEDIT
IF NOT EXIST "%PROGDIR%" MKDIR "%PROGDIR%"
COPY /Y "%BUILDDIR%\edit.prg" "%PROGDIR%\edit.prg" >NUL
REM    ...the misc overlay - About screen (EDIT loads MSEDIT/misc.ovl into bank 8 at startup)...
IF EXIST "%BUILDDIR%\misc.ovl" COPY /Y "%BUILDDIR%\misc.ovl" "%PROGDIR%\misc.ovl" >NUL
REM    ...the text/hex viewer overlay (bank 9)...
IF EXIST "%BUILDDIR%\tview.ovl" COPY /Y "%BUILDDIR%\tview.ovl" "%PROGDIR%\tview.ovl" >NUL
REM    ...the Open/View file-picker overlay (bank 6)...
IF EXIST "%BUILDDIR%\picker.ovl" COPY /Y "%BUILDDIR%\picker.ovl" "%PROGDIR%\picker.ovl" >NUL
REM    ...and the help text files the viewer shows for Help > Keyboard / Help > BASLOAD.
IF EXIST "%~dp0SRC\edit.md"    COPY /Y "%~dp0SRC\edit.md"    "%PROGDIR%\edit.md"    >NUL
IF EXIST "%~dp0SRC\basload.md" COPY /Y "%~dp0SRC\basload.md" "%PROGDIR%\basload.md" >NUL

REM 2a) the settings program (Help>Config chain-loads MSEDIT/EDCFG.PRG)
CALL "%~dp0build.bat" edcfg.p8
IF ERRORLEVEL 1 GOTO :EOF
COPY /Y "%BUILDDIR%\edcfg.prg" "%PROGDIR%\edcfg.prg" >NUL

REM 2b) write the /ED root launcher (a tokenized `10 LOAD"/MSEDIT/EDIT.PRG"`), if absent.
REM     After File>Run BASLOAD (F5), EDIT arms SHIFT+RUN to the DOS-wedge command ^/ED, which
REM     runs this launcher to reload EDIT. Modeled on XFMGR's /XT. Edit the path inside if
REM     edit.prg moves. Delete the file to have it regenerated.
IF NOT EXIST "%RUNDIR%\ED" powershell -NoProfile -Command "[System.IO.File]::WriteAllBytes('%RUNDIR%\ED',[byte[]](1,8,25,8,10,0,147,34,47,77,83,69,68,73,84,47,69,68,73,84,46,80,82,71,34,0,0,0))"

REM 3) launch with the run folder as the host filesystem root, so the emulator
REM    boots straight into MSEDIT\edit.prg while the editor still sees run\ as its cwd.
CALL "%~dp0LOCAL.BAT"
START "" /D "%RUNDIR%" "%x16%" -fsroot "%RUNDIR%" -prg "%PROGDIR%\edit.prg" -run -rtc -joy1
ENDLOCAL
