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
REM Bundle and archive names (default: as in the AppVeyor artifacts):
if not defined NUT_BUNDLE_ARCH set NUT_BUNDLE_ARCH=x86_64
if not defined NUT_BUNDLE_VERSION set NUT_BUNDLE_VERSION=%APPVEYOR_BUILD_VERSION%
REM Oh the joys of shell scripting with strings passed through CMD:
REM The bundle gets stripped binaries; their debug information is saved
REM into .inst-debuginfo as "*.debug" files, in the same directory layout
REM (and top-level name) as the bundle, and published as a separate archive:
REM unpacking both into the same place puts each "*.debug" file next to its
REM EXE/DLL, where debuggers look for it.
REM Note: currently Python installation path with MSYS is buggy [#1584]
REM Time limit: see CI_DEADLINE_EPOCH in appveyor.yml
REM The "ccache -c" after the bundle build: see 04-build_script.bat
C:\msys64\usr\bin\bash -lc 'date -u; R=$(( ${CI_DEADLINE_EPOCH:-EPOCHSECONDS+3600} - EPOCHSECONDS )) ; echo "CI deadline: $R seconds left" ; if [ "$R" -le 0 ] ; then exit 124 ; fi ; if ! rm -rf ".inst" ".inst-debuginfo" ; then echo "WARNING: Failed to clean away .inst or .inst-debuginfo" ; fi ; PATH="${MINGW_PREFIX}/lib/ccache/bin:${MINGW_PREFIX}/bin:$PATH" timeout -k 30 "$R" make -s -j 8 install-win-bundle DESTDIR="`pwd`/.inst/NUT-for-Windows-%NUT_BUNDLE_ARCH%-SNAPSHOT-%NUT_BUNDLE_VERSION%" WIN_BUNDLE_DEBUGINFO_DIR="`pwd`/.inst-debuginfo/NUT-for-Windows-%NUT_BUNDLE_ARCH%-SNAPSHOT-%NUT_BUNDLE_VERSION%" ; RES=$? ; echo "`date -u`: make install-win-bundle finished ($RES), pruning ccache..."; R=$(( ${CI_DEADLINE_EPOCH:-EPOCHSECONDS+3600} - EPOCHSECONDS )) ; echo "CI deadline: $R seconds left" ; if ! PATH="${MINGW_PREFIX}/bin:$PATH" ccache -c ; then echo "SKIP: Could not clean up ccache" ; fi ; exit "$RES" '
if errorlevel 1 exit /b %ERRORLEVEL%
C:\msys64\usr\bin\bash -lc 'date -u'
pushd .inst
if errorlevel 1 exit /b %ERRORLEVEL%
REM 7z -snh: hoping for a version that can save hardlinks as such, and in 7z format to boot.
REM -mx=3 -mmt=on: the default level took about 4 minutes of the CI time limit
REM for this (then unstripped debug build) archive alone. Measured on a 679 MB bundle with two
REM threads: default 98s/52MB, -mx=3 10s/76MB, -mx=1 12s/199MB (other method).
7z a -snh -mx=3 -mmt=on ../NUT-for-Windows-%NUT_BUNDLE_ARCH%-SNAPSHOT-%NUT_BUNDLE_VERSION%.7z NUT*
if errorlevel 1 exit /b %ERRORLEVEL%
popd
pushd .inst-debuginfo
if errorlevel 1 exit /b %ERRORLEVEL%
7z a -mx=3 -mmt=on ../NUT-debuginfo-for-Windows-%NUT_BUNDLE_ARCH%-SNAPSHOT-%NUT_BUNDLE_VERSION%.7z NUT*
if errorlevel 1 exit /b %ERRORLEVEL%
popd

REM Report ccache stats (here rather than in a separate yml step after the
REM artifact message in 08-after_test.ps1, the order does not matter):
C:\msys64\usr\bin\bash -lc 'date -u; PATH="${MINGW_PREFIX}/bin:$PATH" ; export PATH ; if ! ccache -sv ; then if ! ccache -s ; then echo "SKIP: Could not query ccache stats" ; fi ; fi'
if errorlevel 1 exit /b %ERRORLEVEL%
C:\msys64\usr\bin\bash -lc 'date -u; PATH="${MINGW_PREFIX}/bin:$PATH" ; export PATH ; if ! ccache -x ; then echo "SKIP: Could not query ccache compression stats" ; fi'
if errorlevel 1 exit /b %ERRORLEVEL%
