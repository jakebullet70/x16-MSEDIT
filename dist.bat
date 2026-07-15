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
IF NOT EXIST "%DISTDIR%" MKDIR "%DISTDIR%"
COPY /Y "%BUILDDIR%\edit.prg"    "%DISTDIR%\edit.prg"    >NUL
COPY /Y "%BUILDDIR%\edcfg.prg"   "%DISTDIR%\edcfg.prg"   >NUL
COPY /Y "%BUILDDIR%\misc.ovl"    "%DISTDIR%\misc.ovl"    >NUL
COPY /Y "%BUILDDIR%\tview.ovl"   "%DISTDIR%\tview.ovl"   >NUL
COPY /Y "%~dp0edit.hlp"          "%DISTDIR%\edit.hlp"    >NUL
COPY /Y "%~dp0basload.hlp"       "%DISTDIR%\basload.hlp" >NUL
COPY /Y "%BUILDDIR%\install.prg" "%DISTDIR%\install.prg" >NUL
ECHO   staged release: %DISTDIR%

CALL "%~dp0LOCAL.BAT"
START "" /D "%RUNDIR%" "%x16%" -fsroot "%RUNDIR%" -rtc -joy1
ENDLOCAL
