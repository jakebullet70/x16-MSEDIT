@ECHO OFF
REM Build an EDIT Prog8 source (in SRC\) to a .prg for the Commander X16.
REM Usage:  build.bat <source.p8>          (defaults to edit.p8)
REM         build.bat tools\fktest.p8      (the one-off diagnostics live in SRC\tools\)
REM         The source name is resolved inside the SRC\ directory.
REM Needs:  java (JRE) and the 64tass assembler. Paths set below.
REM
REM WHERE THINGS GO: build\ (gitignored) holds EVERYTHING the compiler emits - the .prg, the .asm
REM listing (~800KB for edit.p8), the .vice-mon-list symbol file, and help.ovl. Nothing is copied
REM to the project root: run.bat / dbg.bat / dist.bat all stage out of build\, and the binaries are
REM not tracked (the build number auto-increments, so a committed .prg churns on every compile).
REM
REM After a successful compile it prints a memory-stats block: the program image
REM (code+data), variable (BSS) and slab sizes, the main-RAM high-water address and
REM how much low RAM is free below the I/O area at $9F00, plus the .prg size on disk.
REM Banked HIRAM ($A000+) is NOT counted - that is used dynamically by the document
REM arena and grows as the text document does.

SETLOCAL
SET JAVABIN=C:\dev\b4x\java19\bin
SET TASSBIN=C:\8bitProgramming\64tass-1.60
SET "PATH=%JAVABIN%;%TASSBIN%;%PATH%"

SET SRCDIR=%~dp0SRC
SET BUILDDIR=%~dp0build
SET SRC=%1
IF "%SRC%"=="" SET SRC=edit.p8
IF NOT EXIST "%BUILDDIR%" MKDIR "%BUILDDIR%"
REM the .prg is named after the source (edit.p8 -> edit.prg), built into build\
FOR %%F IN ("%SRC%") DO SET NAME=%%~nF
SET PRGFILE=%BUILDDIR%\%NAME%.prg

REM --- auto-increment the build number in SRC\edit.p8 (BUILD_NUM) and README.md ("Version 0.9.N")
REM     by 1 on every compile. Runs BEFORE the compile so this build's binary shows the bumped number.
REM     Full builds of edit.p8 only.
IF /I "%SRC%"=="edit.p8" powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0syncbuild.ps1" -Src "%SRCDIR%\edit.p8" -Readme "%~dp0README.md"

SET BUILDLOG=%TEMP%\edit_build.txt
java -jar "%~dp0prog8c.jar" -target cx16 -out "%BUILDDIR%" "%SRCDIR%\%SRC%" > "%BUILDLOG%" 2>&1
SET ERR=%ERRORLEVEL%
TYPE "%BUILDLOG%"
IF NOT "%ERR%"=="0" ( ENDLOCAL & EXIT /B %ERR% )

REM --- memory-stats block parsed from the segment map ---
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0memstats.ps1" -Log "%BUILDLOG%" -Prg "%PRGFILE%"

REM --- companion builds: the banked overlays (%output library -> headerless .bin, renamed .ovl)
REM     at $A000, loaded into their HIRAM banks at runtime and called via extsub @bank. %memtop
REM     $C000 fails the build if an overlay outgrows its bank. edit.p8 builds only: edit.prg still
REM     runs without the .ovl files beside it, the affected menu items just report them missing.
REM       misc.ovl  = About screen (bank 8)      tview.ovl = text/hex viewer (bank 9)
IF /I "%SRC%"=="edit.p8" (
    java -jar "%~dp0prog8c.jar" -target cx16 -out "%BUILDDIR%" "%SRCDIR%\misc.p8" > "%TEMP%\edit_misc_build.txt" 2>&1
    IF ERRORLEVEL 1 ( TYPE "%TEMP%\edit_misc_build.txt" & ECHO *** misc overlay build FAILED *** & ENDLOCAL & EXIT /B 1 )
    MOVE /Y "%BUILDDIR%\misc.bin" "%BUILDDIR%\misc.ovl" >NUL
    ECHO   misc overlay      : build\misc.ovl built ^($A000 HIRAM bank overlay^)
    java -jar "%~dp0prog8c.jar" -target cx16 -out "%BUILDDIR%" "%SRCDIR%\tview.p8" > "%TEMP%\edit_tview_build.txt" 2>&1
    IF ERRORLEVEL 1 ( TYPE "%TEMP%\edit_tview_build.txt" & ECHO *** tview overlay build FAILED *** & ENDLOCAL & EXIT /B 1 )
    MOVE /Y "%BUILDDIR%\tview.bin" "%BUILDDIR%\tview.ovl" >NUL
    ECHO   viewer overlay    : build\tview.ovl built ^($A000 HIRAM bank overlay^)
    java -jar "%~dp0prog8c.jar" -target cx16 -out "%BUILDDIR%" "%SRCDIR%\picker.p8" > "%TEMP%\edit_picker_build.txt" 2>&1
    IF ERRORLEVEL 1 ( TYPE "%TEMP%\edit_picker_build.txt" & ECHO *** picker overlay build FAILED *** & ENDLOCAL & EXIT /B 1 )
    MOVE /Y "%BUILDDIR%\picker.bin" "%BUILDDIR%\picker.ovl" >NUL
    ECHO   picker overlay    : build\picker.ovl built ^($A000 HIRAM bank overlay^)
)

ENDLOCAL & EXIT /B 0
