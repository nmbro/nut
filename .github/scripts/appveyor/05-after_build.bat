REM Network UPS Tools: AppVeyor CI recipe step (see appveyor.yml), NUT for Windows
REM with MSYS2 (UCRT64 x64 by default). Called with the build folder as current
REM directory. AppVeyor checks each line of inline yml scripts, but only the
REM exit code of a called .bat file, so we check each command here.
REM
REM Copyright (C) 2022-2026	Jim Klimov <jimklimov+nut@gmail.com>

REM Preserve the current working directory:
set CHERE_INVOKING=yes
REM Start an MSYS2 environment: UCRT64 (64-bit) by default, or another one
REM named in NUT_MSYSTEM (e.g. MINGW32 in .github/workflows/09-windows-mingw32.yml):
if not defined NUT_MSYSTEM set NUT_MSYSTEM=UCRT64
set MSYSTEM=%NUT_MSYSTEM%
C:\msys64\usr\bin\bash -lc 'date -u; PATH="${MINGW_PREFIX}/bin:$PATH" ; export PATH ; if ! ccache -sv ; then if ! ccache -s ; then echo "SKIP: Could not query ccache stats" ; fi ; fi'
if errorlevel 1 exit /b %ERRORLEVEL%
