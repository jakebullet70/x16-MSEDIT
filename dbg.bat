@ECHO OFF
REM Build EDIT and run it under Box16 with the prog8 symbols loaded, for debugging.
REM Same as run.bat, but launches Box16 instead of x16emu and feeds it the
REM .vice-mon-list that prog8c emits next to the .prg. That is a VICE label file,
REM which Box16 reads with -sym, so every prog8 label (p8b_main:p8s_ed_pgdn, ...)
REM shows up by name in the disassembly, breakpoint and memory views.
REM
REM Usage:  dbg.bat [-n] [-b addr] [source.p8]
REM           -n        no rebuild - launch the existing .prg
REM           -b addr   break at a HEX address on startup, e.g. -b ae1 (main.start).
REM                     Look the address up in <name>.vice-mon-list.
REM           source    defaults to edit.p8
REM
REM In the emulator:  F12 breaks into the debugger, F9 sets a breakpoint at the
REM                   current position, F11 steps into, F10 steps over.
REM
REM Gotchas learned the hard way:
REM  * -joy1 works on x16emu but Box16 REJECTS it and exits immediately. Not used here.
REM  * -stds loads the ROM labels (kernal.sym, basic.sym, ...) from the folder holding
REM    the rom.bin. Box16's own folder ships NO .sym files, so we point -rom at the
REM    x16emu folder, which has all 13 - and whose rom.bin is byte-identical to Box16's.
REM    Without this, breaking inside a KERNAL call shows bare addresses and it looks
REM    like symbols are broken when they are not.
REM  * EDIT idles inside a KERNAL key-wait, so a plain F12 lands in ROM, not in our
REM    code. To see prog8 labels, type an EDIT address into the disassembly window's
REM    address box (or use -b), rather than trusting wherever F12 happened to stop.
REM  * The symbols must match the binary: after a rebuild, relaunch. Always use dbg.bat.

SETLOCAL
SET NOBUILD=
SET BRK=

:parse
REM (quote the SET so the space before "&" does not land in the value)
IF /I "%1"=="-n" ( SET "NOBUILD=1" & SHIFT & GOTO parse )
IF /I "%1"=="-b" ( SET "BRK=%2" & SHIFT & SHIFT & GOTO parse )

SET SRC=%1
IF "%SRC%"=="" SET SRC=edit.p8
FOR %%F IN ("%SRC%") DO SET NAME=%%~nF

REM 1) compile (build.bat writes <name>.prg and <name>.vice-mon-list to the project root)
IF NOT DEFINED NOBUILD (
  CALL "%~dp0build.bat" %SRC%
  IF ERRORLEVEL 1 GOTO :EOF
)

SET PRGFILE=%~dp0%NAME%.prg
SET SYMFILE=%~dp0%NAME%.vice-mon-list
IF NOT EXIST "%PRGFILE%" (
  ECHO dbg: %PRGFILE% not found - build it first ^(drop the -n flag^).
  GOTO :EOF
)

REM 2) stage the .prg into the run folder (the host fs root the editor sees)
SET RUNDIR=%~dp0run
IF NOT EXIST "%RUNDIR%" MKDIR "%RUNDIR%"
COPY /Y "%PRGFILE%" "%RUNDIR%\%NAME%.prg" >NUL

REM 2b) the /ED root launcher, same as run.bat (SHIFT+RUN after F5 BASLOAD reloads EDIT)
IF NOT EXIST "%RUNDIR%\ED" powershell -NoProfile -Command "[System.IO.File]::WriteAllBytes('%RUNDIR%\ED',[byte[]](1,8,17,8,10,0,147,34,69,68,73,84,46,80,82,71,34,0,0,0))"

CALL "%~dp0LOCAL.BAT"
IF NOT EXIST "%box16%" (
  ECHO dbg: Box16 not found at "%box16%" - fix the box16= path in LOCAL.BAT.
  GOTO :EOF
)

REM 3) our program symbols
SET SYMARG=
IF EXIST "%SYMFILE%" SET SYMARG=-sym "%SYMFILE%"
IF NOT EXIST "%SYMFILE%" ECHO dbg: no %NAME%.vice-mon-list - launching without program symbols.

REM 4) ROM symbols: use the x16emu rom.bin so -stds finds the .sym files beside it
SET ROMARG=
FOR %%R IN ("%x16%") DO SET X16DIR=%%~dpR
IF EXIST "%X16DIR%kernal.sym" SET ROMARG=-rom "%X16DIR%rom.bin" -stds
IF NOT EXIST "%X16DIR%kernal.sym" ECHO dbg: no kernal.sym next to x16emu - ROM calls will show as bare addresses.

REM 5) optional startup breakpoint
SET BRKARG=
IF DEFINED BRK SET BRKARG=-debug %BRK%
IF DEFINED BRK ECHO dbg: breaking at $%BRK% on startup.

REM 6) launch, then enlarge the window. The debugger panels are ImGui windows drawn
REM    INSIDE the emulator window; at Box16's default 658x558 they overlap and the
REM    Disassembler's symbol column is clipped, so symbols look like they never loaded.
REM    -scale does NOT change the window size (it is a render setting - measured
REM    identical at 1, 2 and 3), so dbgwin.ps1 resizes the OS window instead.
START "" /D "%RUNDIR%" "%box16%" -prg "%NAME%.prg" -run -rtc %ROMARG% %SYMARG% %BRKARG%
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0dbgwin.ps1"
ENDLOCAL & EXIT /B 0
