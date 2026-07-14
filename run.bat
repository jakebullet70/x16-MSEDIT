@ECHO OFF
REM Build EDIT and run it in the emulator from the run\ folder.
REM The run\ folder is the host filesystem root the editor sees, and holds
REM sample text files to open/save.
REM
REM Usage:  run.bat [source.p8]    (defaults to edit.p8)

SETLOCAL
SET SRC=%1
IF "%SRC%"=="" SET SRC=edit.p8

REM 1) compile (build.bat writes edit.prg to the project root)
CALL "%~dp0build.bat" %SRC%
IF ERRORLEVEL 1 GOTO :EOF

REM 2) stage the fresh .prg into the program folder run\MSEDIT (EDIT lives in its own
REM    directory; the fsroot stays run\, which is where the documents and ed.run are).
SET RUNDIR=%~dp0run
SET PROGDIR=%RUNDIR%\MSEDIT
IF NOT EXIST "%PROGDIR%" MKDIR "%PROGDIR%"
COPY /Y "%~dp0edit.prg" "%PROGDIR%\edit.prg" >NUL

REM 2a) the settings program (Help>Config chain-loads MSEDIT/EDCFG.PRG), built only when EDIT was
CALL "%~dp0build.bat" edcfg.p8
IF ERRORLEVEL 1 GOTO :EOF
COPY /Y "%~dp0edcfg.prg" "%PROGDIR%\edcfg.prg" >NUL

REM 2b) write the /ED root launcher (a tokenized `10 LOAD"MSEDIT/EDIT.PRG"`), if absent.
REM     After File>Run BASLOAD (F5), EDIT arms SHIFT+RUN to the DOS-wedge command ^/ED, which
REM     runs this launcher to reload EDIT. Modeled on XFMGR's /XT. Edit the path inside if
REM     edit.prg moves. Delete the file to have it regenerated.
IF NOT EXIST "%RUNDIR%\ED" powershell -NoProfile -Command "[System.IO.File]::WriteAllBytes('%RUNDIR%\ED',[byte[]](1,8,24,8,10,0,147,34,77,83,69,68,73,84,47,69,68,73,84,46,80,82,71,34,0,0,0))"

REM 3) launch with the run folder as the host filesystem root, so the emulator
REM    boots straight into MSEDIT\edit.prg while the editor still sees run\ as its cwd.
CALL "%~dp0LOCAL.BAT"
START "" /D "%RUNDIR%" "%x16%" -fsroot "%RUNDIR%" -prg "%PROGDIR%\edit.prg" -run -rtc -joy1
ENDLOCAL
