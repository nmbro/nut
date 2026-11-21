REM Network UPS Tools: AppVeyor CI recipe step (see appveyor.yml), NUT for Windows
REM with MSYS2 (UCRT64 x64 by default). Called with the build folder as current
REM directory. AppVeyor checks each line of inline yml scripts, but only the
REM exit code of a called .bat file, so we check each command here.
REM
REM Copyright (C) 2022-2026	Jim Klimov <jimklimov+nut@gmail.com>

REM NOTE: The script aims to configure for minimal build results, e.g.
REM no tools and docs, and to ensure parallel builds via MAKEFLAGS...
REM As of Aug 2025, in cases these artifacts (and ~/.ccache) were not cached
REM and the step did run, it cost us 22min (before disabling tools and docs).

REM Ensure we have a net-snmp to build against
REM Adapted from scripts/Windows/README.adoc document.
REM Here we hope to build it once, then use the
REM stashed version across Appveyor rebuilds.
REM Time limit: see CI_DEADLINE_EPOCH in appveyor.yml
REM Preserve the current working directory:
set CHERE_INVOKING=yes
REM Start an MSYS2 environment: UCRT64 (64-bit) by default, or another one
REM named in NUT_MSYSTEM (e.g. MINGW32 in .github/workflows/09-windows-mingw32.yml):
if not defined NUT_MSYSTEM set NUT_MSYSTEM=UCRT64
set MSYSTEM=%NUT_MSYSTEM%
REM Zero the ccache statistics (02-install.bat printed the restored ones),
REM so that reports of later steps (05, 08, 12) count just this build:
C:\msys64\usr\bin\bash -lc 'PATH="${MINGW_PREFIX}/bin:$PATH" ; export PATH ; ccache -z ; true '
if errorlevel 1 exit /b %ERRORLEVEL%
C:\msys64\usr\bin\bash -lc 'date -u; R=$(( ${CI_DEADLINE_EPOCH:-EPOCHSECONDS+3600} - EPOCHSECONDS )) ; echo "CI deadline: $R seconds left" ; if [ "$R" -le 0 ] ; then exit 124 ; fi ; export MSYS2_PATH ; PATH="${MINGW_PREFIX}/lib/ccache/bin:${MINGW_PREFIX}/bin:$PATH" timeout -k 30 "$R" bash ./scripts/Windows/build-mingw-prereqs.sh'
if errorlevel 1 exit /b %ERRORLEVEL%
