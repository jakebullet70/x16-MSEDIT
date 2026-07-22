@ECHO OFF
REM Copy the freshly built EDIT artifacts into the X16INSPECTOR test folder.
REM Run AFTER build.bat (this only stages build\ -> the test dir; it does not compile).
REM Mirrors the fileset run.bat stages into run\MSEDIT, with UPPERCASE host names, and
REM deliberately does NOT touch EDIT.CFG (user settings, app-written).

SET BUILDDIR=%~dp0build
SET DEST=C:\dev\CmdrX16\X16INSPECTOR\RUN\MSEDIT
IF NOT EXIST "%DEST%" MKDIR "%DEST%"

COPY /Y "%BUILDDIR%\edit.prg"  "%DEST%\EDIT.PRG"  >NUL
IF EXIST "%BUILDDIR%\misc.ovl"   COPY /Y "%BUILDDIR%\misc.ovl"   "%DEST%\MISC.OVL"   >NUL
IF EXIST "%BUILDDIR%\tview.ovl"  COPY /Y "%BUILDDIR%\tview.ovl"  "%DEST%\TVIEW.OVL"  >NUL
IF EXIST "%BUILDDIR%\picker.ovl" COPY /Y "%BUILDDIR%\picker.ovl" "%DEST%\PICKER.OVL" >NUL
IF EXIST "%BUILDDIR%\menus.ovl"  COPY /Y "%BUILDDIR%\menus.ovl"  "%DEST%\MENUS.OVL"  >NUL
IF EXIST "%BUILDDIR%\edcfg.prg"  COPY /Y "%BUILDDIR%\edcfg.prg"  "%DEST%\EDCFG.PRG"  >NUL
IF EXIST "%~dp0SRC\edit.md"    COPY /Y "%~dp0SRC\edit.md"    "%DEST%\EDIT.MD"    >NUL
IF EXIST "%~dp0SRC\basload.md" COPY /Y "%~dp0SRC\basload.md" "%DEST%\BASLOAD.MD" >NUL
IF EXIST "%~dp0SRC\hints.md"   COPY /Y "%~dp0SRC\hints.md"   "%DEST%\HINTS.MD"   >NUL

ECHO Deployed build to %DEST%
