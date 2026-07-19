@ECHO OFF
REM Build a BASLOAD source (SRC\<NAME>.BASL) into run\<NAME>.PRG, and optionally run it.
REM Usage:  buildbasl.bat PRG2BASLOAD           tokenise only
REM         buildbasl.bat PRG2BASLOAD --run     tokenise, then launch it in the emulator
REM
REM This is the BASLOAD half of the build system and has nothing in common with build.bat:
REM no java, no prog8c.jar, no 64tass. BASLOAD is an X16 ROM utility, so the only tokeniser
REM that exists runs on the machine itself - buildbasl.py boots the emulator headless with
REM run\ as its drive and lets the source's own #SAVEAS write the .PRG. See buildbasl.py.
REM
REM WHERE THINGS GO: unlike build.bat (which emits into build\ and leaves staging to
REM run.bat / dist.bat), this writes straight into run\ - that IS the emulator's drive, so
REM it is where BASLOAD has to read and write. run\ is gitignored; SRC\<NAME>.BASL is the
REM tracked master and run\<NAME>.BASL is a staged copy the build overwrites every time.

SETLOCAL
IF "%~1"=="" (
    ECHO usage: buildbasl.bat ^<NAME^> [--run]      e.g. buildbasl.bat PRG2BASLOAD --run
    ENDLOCAL & EXIT /B 1
)
python "%~dp0buildbasl.py" %*
ENDLOCAL & EXIT /B %ERRORLEVEL%
