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
REM Time limits: see CI_DEADLINE_EPOCH in appveyor.yml
REM The "ccache -c" after "make check": see 04-build_script.bat
REM Start Mingw-based integration and unit checks (in parallel: measured locally,
REM 16 tests passed in all of 7 runs, with -j2 taking ~30% less time than serial).
REM On GitHub Actions (GITHUB_ACTIONS=true) the "make check" output and each dumped
REM test log are folded into log groups, with the failed tests listed outside them
REM (no pipes or "||" here: cmd.exe would interpret them outside double quotes;
REM and "%%" for each "%" which bash should see, also within double quotes):
C:\msys64\usr\bin\bash -lc 'date -u; R=$(( ${CI_DEADLINE_EPOCH:-EPOCHSECONDS+3600} - EPOCHSECONDS )) ; echo "CI deadline: $R seconds left" ; if [ "$R" -le 0 ] ; then exit 124 ; fi ; NUT_STATEPATH="${NUT_STATEPATH:-C:\\Users\\appveyor\\AppData\\Local\\Temp\\nut-test}"; mkdir -p "${NUT_STATEPATH}"; export NUT_STATEPATH; G=false ; if [ "${GITHUB_ACTIONS-}" = true ] ; then G=true ; echo "::group::make check" ; fi ; PATH="${MINGW_PREFIX}/lib/ccache/bin:${MINGW_PREFIX}/bin:$PATH" timeout -k 30 "$R" make -s -j 2 check ; RES=$? ; echo "`date -u`: make check finished ($RES), pruning ccache..."; R=$(( ${CI_DEADLINE_EPOCH:-EPOCHSECONDS+3600} - EPOCHSECONDS )) ; echo "CI deadline: $R seconds left" ; if ! PATH="${MINGW_PREFIX}/bin:$PATH" ccache -c ; then echo "SKIP: Could not clean up ccache" ; fi ; if $G ; then echo "::endgroup::" ; fi ; if [ "$RES" -ne 0 ] ; then echo "FAILED ($RES): make check; tests which did not pass (other failures, e.g. of check-NIT, are in the make check log):" ; grep -l -e "^:test-result: FAIL" -e "^:test-result: ERROR" -e "^:test-result: XPASS" tests/*.trs ; for F in tests/*.log ; do T="${F%%.log}" ; S="" ; if [ -s "$T.trs" ] ; then S=$(sed -n "s/^:test-result: //p" "$T.trs") ; fi ; if $G ; then echo "::group::$F $S" ; fi ; echo "===---=== $F :" ; cat "$F" ; if [ -s "$T.trs" ] ; then echo "===---=== $T.trs :" ; cat "$T.trs" ; fi ; if $G ; then echo "::endgroup::" ; fi ; done ; exit "$RES" ; fi '
if errorlevel 1 exit /b %ERRORLEVEL%
REM Start a Mingw-based documentation spellcheck (note that "make check" above could cover some documents in path of artifact delivery, but maybe not all that we have):
C:\msys64\usr\bin\bash -lc 'date -u; R=$(( ${CI_DEADLINE_EPOCH:-EPOCHSECONDS+3600} - EPOCHSECONDS )) ; echo "CI deadline: $R seconds left" ; if [ "$R" -le 0 ] ; then exit 124 ; fi ; PATH="${MINGW_PREFIX}/lib/ccache/bin:${MINGW_PREFIX}/bin:$PATH" timeout -k 30 "$R" make -s -j 8 spellcheck'
if errorlevel 1 exit /b %ERRORLEVEL%
