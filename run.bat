@ECHO OFF
REM Stage the already-built EDIT binaries and run them in the emulator from the run\ folder.
REM This DOES NOT compile - run `build.bat` yourself when the sources change. run.bat only
REM copies whatever is currently in build\ into run\MSEDIT and launches.
REM The run\ folder is the host filesystem root the editor sees, and holds
REM sample text files to open/save.
REM
REM Usage:  run.bat

SETLOCAL

REM 1) require a prior build - build.bat writes edit.prg + the overlays into build\.
SET BUILDDIR=%~dp0build
IF NOT EXIST "%BUILDDIR%\edit.prg" (
    ECHO build\edit.prg not found - run build.bat first.
    GOTO :EOF
)

REM 2) stage the built binaries out of build\ into the program folder run\MSEDIT (EDIT lives in
REM    its own directory; the fsroot stays run\, which is where the documents and ed.run are).
SET RUNDIR=%~dp0run
SET PROGDIR=%RUNDIR%\MSEDIT
IF NOT EXIST "%PROGDIR%" MKDIR "%PROGDIR%"
REM Stage with UPPERCASE names so the X16 DIR listing matches the release (and how the X16 itself
REM writes files: lowercase source literals encode to upper-case host names). COPY onto an existing
REM lower-case entry keeps the OLD case, so wipe the staged program files first to force the rename.
REM EDIT.CFG (user settings, app-written = already upper) is deliberately NOT deleted.
DEL /Q "%PROGDIR%\*.prg" "%PROGDIR%\*.ovl" "%PROGDIR%\*.md" 2>NUL
COPY /Y "%BUILDDIR%\edit.prg" "%PROGDIR%\EDIT.PRG" >NUL
REM    ...the misc overlay - About screen (EDIT loads MSEDIT/misc.ovl into bank 8 at startup)...
IF EXIST "%BUILDDIR%\misc.ovl" COPY /Y "%BUILDDIR%\misc.ovl" "%PROGDIR%\MISC.OVL" >NUL
REM    ...the text/hex viewer overlay (bank 9)...
IF EXIST "%BUILDDIR%\tview.ovl" COPY /Y "%BUILDDIR%\tview.ovl" "%PROGDIR%\TVIEW.OVL" >NUL
REM    ...the Open/View file-picker overlay (bank 6)...
IF EXIST "%BUILDDIR%\picker.ovl" COPY /Y "%BUILDDIR%\picker.ovl" "%PROGDIR%\PICKER.OVL" >NUL
REM    ...the dropdown-menu label overlay (bank 11)...
IF EXIST "%BUILDDIR%\menus.ovl" COPY /Y "%BUILDDIR%\menus.ovl" "%PROGDIR%\MENUS.OVL" >NUL
REM    ...and the help text files the viewer shows for Help > Keyboard / Help > BASLOAD.
IF EXIST "%~dp0SRC\edit.md"    COPY /Y "%~dp0SRC\edit.md"    "%PROGDIR%\EDIT.MD"    >NUL
IF EXIST "%~dp0SRC\basload.md" COPY /Y "%~dp0SRC\basload.md" "%PROGDIR%\BASLOAD.MD" >NUL
IF EXIST "%~dp0SRC\hints.md"   COPY /Y "%~dp0SRC\hints.md"   "%PROGDIR%\HINTS.MD"   >NUL
REM    ...and the stand-alone PRG-to-BASLOAD converter, so the dev folder matches what the
REM    installer lays down. This one comes from the TRACKED bin\ copy, not from build\ - it is
REM    GPC-compiled inside the emulator and no part of build.bat produces it. See dist.bat, which
REM    is where a freshly compiled run\C.PRG2BASLOAD.PRG gets promoted into bin\.
IF EXIST "%~dp0bin\PRG2BASLOAD.PRG" COPY /Y "%~dp0bin\PRG2BASLOAD.PRG" "%PROGDIR%\PRG2BASLOAD.PRG" >NUL

REM 2a) the settings program (Help>Config chain-loads MSEDIT/EDCFG.PRG), if it was built.
IF EXIST "%BUILDDIR%\edcfg.prg" COPY /Y "%BUILDDIR%\edcfg.prg" "%PROGDIR%\EDCFG.PRG" >NUL

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
