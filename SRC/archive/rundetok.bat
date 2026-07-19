@ECHO OFF
REM Build the ARCHIVED prog8 DETOK (detok.p8 + basdet.p8) and run it in the emulator.
REM
REM SUPERSEDED - the live tool is the BASLOAD one: SRC\PRG2BASLOAD.BASL, built with
REM buildbasl.bat PRG2BASLOAD. This is kept only so the prog8 version can still be built
REM for comparison. See SRC\archive\README.md.
REM
REM This still writes run\DETOK.PRG; the live tool writes run\PRG2BASLOAD.PRG, so the two
REM no longer overwrite each other.
REM
REM Unlike run.bat, this stages into the fsroot run\ itself rather than run\MSEDIT:
REM DETOK is not part of EDIT, has no overlays and no settings file, and it reads and
REM writes files in the current directory - which is where the test .PRG files live.
REM
REM Usage:  SRC\archive\rundetok.bat

SETLOCAL
REM %~dp0 is SRC\archive\ - the project root is two levels up.
SET ROOT=%~dp0..\..\

REM build.bat resolves its source argument inside SRC\, so the archived source is reached
REM as archive\detok.p8. prog8 resolves detok.p8's %import basdet relative to the source
REM file, so basdet.p8 is picked up from archive\ too.
CALL "%ROOT%build.bat" archive\detok.p8
IF ERRORLEVEL 1 GOTO :EOF

SET BUILDDIR=%ROOT%build
SET RUNDIR=%ROOT%run

REM Upper-case name so the X16 DIR listing matches how the machine itself writes files.
REM COPY onto an existing lower-case entry keeps the OLD case, so wipe it first.
DEL /Q "%RUNDIR%\DETOK.PRG" 2>NUL
COPY /Y "%BUILDDIR%\detok.prg" "%RUNDIR%\DETOK.PRG" >NUL

REM A couple of tokenized programs to try it on, staged next to it so the bare names
REM DETOK prompts for resolve without any path typing.
IF EXIST "%RUNDIR%\BASIC-MISC\BOXES.PRG" COPY /Y "%RUNDIR%\BASIC-MISC\BOXES.PRG" "%RUNDIR%\BOXES.PRG" >NUL
IF EXIST "%RUNDIR%\BASIC-MISC\PAINT16C\PAINT16C.PRG" COPY /Y "%RUNDIR%\BASIC-MISC\PAINT16C\PAINT16C.PRG" "%RUNDIR%\PAINT16C.PRG" >NUL

CALL "%ROOT%LOCAL.BAT"
START "" /D "%RUNDIR%" "%x16%" -fsroot "%RUNDIR%" -prg "%RUNDIR%\DETOK.PRG" -run -rtc -joy1
ENDLOCAL
