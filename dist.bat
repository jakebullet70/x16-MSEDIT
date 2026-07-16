@ECHO OFF
REM Build the release files and stage them as an unpacked release folder, then boot the emulator so
REM the INSTALLER can be exercised exactly the way a user would run it.
REM
REM Layout it produces (run\ is the emulator's filesystem root):
REM   run\DIST\install.prg  edit.prg  edcfg.prg  help.ovl   <- the "unpacked release" copied to the SD
REM
REM In the emulator, at the BASIC READY prompt:
REM     CD"DIST"        (enter the release folder - the installer copies FROM the folder it runs in)
REM     ^INSTALL        (run the installer; answer Y, or T for a dry run)
REM Then launch the installed editor from anywhere with:   ^/ED
REM
REM The installer creates /MSEDIT, copies the programs in, and writes the /ED launcher. It preserves
REM an existing MSEDIT\edit.cfg, so a reinstall keeps the user's settings.
REM
REM NOTE: this does NOT stage run\MSEDIT itself - that is the installer's job, and leaving it out is
REM the point of the test. run.bat still stages MSEDIT directly for the normal dev loop.

SETLOCAL
CALL "%~dp0build.bat" edit.p8
IF ERRORLEVEL 1 GOTO :EOF
CALL "%~dp0build.bat" edcfg.p8
IF ERRORLEVEL 1 GOTO :EOF
CALL "%~dp0build.bat" install.p8
IF ERRORLEVEL 1 GOTO :EOF

SET BUILDDIR=%~dp0build
SET RUNDIR=%~dp0run
SET DISTDIR=%RUNDIR%\DIST
REM Wipe and recreate DIST so the filenames land UPPERCASE. COPY onto an existing lowercase entry
REM overwrites the bytes but keeps the old directory-entry case on Windows, so a fresh folder is the
REM only reliable way to force the case shown in the X16's DIR listing.
IF EXIST "%DISTDIR%" RMDIR /S /Q "%DISTDIR%"
MKDIR "%DISTDIR%"
COPY /Y "%BUILDDIR%\edit.prg"    "%DISTDIR%\EDIT.PRG"    >NUL
COPY /Y "%BUILDDIR%\edcfg.prg"   "%DISTDIR%\EDCFG.PRG"   >NUL
COPY /Y "%BUILDDIR%\misc.ovl"    "%DISTDIR%\MISC.OVL"    >NUL
COPY /Y "%BUILDDIR%\tview.ovl"   "%DISTDIR%\TVIEW.OVL"   >NUL
COPY /Y "%BUILDDIR%\picker.ovl"  "%DISTDIR%\PICKER.OVL"  >NUL
COPY /Y "%BUILDDIR%\menus.ovl"    "%DISTDIR%\MENUS.OVL"   >NUL
COPY /Y "%~dp0SRC\edit.md"       "%DISTDIR%\EDIT.MD"     >NUL
COPY /Y "%~dp0SRC\basload.md"    "%DISTDIR%\BASLOAD.MD"  >NUL
COPY /Y "%BUILDDIR%\install.prg" "%DISTDIR%\INSTALL.PRG" >NUL
ECHO   staged release: %DISTDIR%

CALL "%~dp0LOCAL.BAT"
START "" /D "%RUNDIR%" "%x16%" -fsroot "%RUNDIR%" -rtc -joy1
ENDLOCAL
