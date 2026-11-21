REM Network UPS Tools: AppVeyor CI recipe step (see appveyor.yml), NUT for Windows
REM with MSYS2 (UCRT64 x64 by default). Called with the build folder as current
REM directory. AppVeyor checks each line of inline yml scripts, but only the
REM exit code of a called .bat file, so we check each command here.
REM
REM Copyright (C) 2022-2026	Jim Klimov <jimklimov+nut@gmail.com>

REM Do not give pacman cause for complaints:
C:\msys64\usr\bin\bash -lc "date -u; mkdir -p /var/cache/pacman/pkg; ls -la /"
if errorlevel 1 exit /b %ERRORLEVEL%

REM FIXME: Since Jan 2025, normal update below fails with the message:
REM   installing mingw-w64-i686-gdb (16.1-1) breaks dependency
REM   'mingw-w64-i686-gdb=15.2' required by mingw-w64-i686-gdb-multiarch
REM Currently we sweep it away by removing the conflicting package:
REM C:\msys64\usr\bin\bash -lc "date -u; pacman --noconfirm -R mingw-w64-i686-gdb-multiarch || true"

REM FIXME: Make this update or not of the ecosystem conditional?
REM  Store a copy of C:\msys64 elsewhere as a tarball?
REM  As of Aug 2025, the first update is quick (15sec, 18Mb DL, 91MB installed),
REM  the second is costlier (6.5min, 378MB DL, 2.5GB installed)
REM Core update (in case any core packages are outdated):
REM C:\msys64\usr\bin\bash -lc "date -u; pacman --noconfirm -Syuu"
REM Normal update (same command again):
REM C:\msys64\usr\bin\bash -lc "date -u; pacman --noconfirm -Syuu"

REM As of Aug 2025, with updates commented away above still in place
REM so many packages skipped, this step did cost additional 58MB DL,
REM 392MB installed (new data), 1min of work.
REM Without the ecosystem update above, the overhead of this step remained
REM similar. It did however use a smaller population (via deps) and older
REM versions of packages.
REM Preserve the current working directory:
set CHERE_INVOKING=yes
REM Start an MSYS2 environment: UCRT64 (64-bit) by default, or another one
REM named in NUT_MSYSTEM (e.g. MINGW32 in .github/workflows/09-windows-mingw32.yml):
if not defined NUT_MSYSTEM set NUT_MSYSTEM=UCRT64
set MSYSTEM=%NUT_MSYSTEM%
REM Prerequisites for NUT per https://github.com/networkupstools/nut/blob/master/docs/config-prereqs.txt :
REM (sqlite3, zlib, nsinstall and zip are needed to build NSS from sources with
REM scripts/Windows/build-mingw-prereqs.sh where it is not packaged, e.g. MINGW32)
REM The package installation is retried: download mirrors may refuse requests for
REM a while (e.g. HTTP 429 Too Many Requests), and pacman then fails the step.
C:\msys64\usr\bin\bash -lc "date -u; PKGS= ; for P in base-devel ${MINGW_PACKAGE_PREFIX}-binutils ${MINGW_PACKAGE_PREFIX}-crt ${MINGW_PACKAGE_PREFIX}-gcc ${MINGW_PACKAGE_PREFIX}-headers ${MINGW_PACKAGE_PREFIX}-libgomp ${MINGW_PACKAGE_PREFIX}-libstdc++ ${MINGW_PACKAGE_PREFIX}-libwinpthread ${MINGW_PACKAGE_PREFIX}-make ${MINGW_PACKAGE_PREFIX}-pkgconf ${MINGW_PACKAGE_PREFIX}-winpthreads autoconf-wrapper automake-wrapper libtool ${MINGW_PACKAGE_PREFIX}-libltdl ${MINGW_PACKAGE_PREFIX}-ccache git aspell aspell-en python ${MINGW_PACKAGE_PREFIX}-libusb ${MINGW_PACKAGE_PREFIX}-libsystre ${MINGW_PACKAGE_PREFIX}-neon ${MINGW_PACKAGE_PREFIX}-expat ${MINGW_PACKAGE_PREFIX}-libpng ${MINGW_PACKAGE_PREFIX}-cppunit ${MINGW_PACKAGE_PREFIX}-nss ${MINGW_PACKAGE_PREFIX}-sqlite3 ${MINGW_PACKAGE_PREFIX}-zlib nsinstall zip ${MINGW_PACKAGE_PREFIX}-openssl ; do if pacman -Sp $P >/dev/null 2>/dev/null ; then PKGS=$PKGS' '$P ; else echo SKIP: $P is not packaged for $MSYSTEM, build-mingw-prereqs.sh may build it ; fi ; done ; for TRY in 1 2 3 ; do if pacman --noconfirm -S --needed $PKGS ; then exit 0 ; fi ; echo RETRY: pacman failed, e.g. by a download mirror rate limit, retrying in a minute... ; sleep 60 ; done ; exit 1"
if errorlevel 1 exit /b %ERRORLEVEL%
REM SKIP ${MINGW_PACKAGE_PREFIX}-libmodbus-git : we custom-build one with USB support
REM SKIP ${MINGW_PACKAGE_PREFIX}-gdb ${MINGW_PACKAGE_PREFIX}-gdb-multiarch : part of the "toolchain" group (listed above without them), no debugger is used in CI
REM SKIP gcc ccache libneon-devel : MSYS environment variants, NUT and its prerequisites are built with those of MSYSTEM
REM SKIP ${MINGW_PACKAGE_PREFIX}-python-pygments : only highlights sources in docs, which CI builds without (the MSYS python suffices for the tests)
REM SKIP ${MINGW_PACKAGE_PREFIX}-libusb-compat : libusb-0.1 API, NUT for Windows uses libusb-1.0
REM SKIP ${MINGW_PACKAGE_PREFIX}-libgd : we custom-build a PNG-only one for upsimage.cgi (the packaged one needs ~30 more DLLs, e.g. video codecs, at run time)
REM SKIP for now NUT-Monitor prereqs (runtime Python would require similar modules; need to fix localization builds like "fr.po"): gettext ${MINGW_PACKAGE_PREFIX}-python-pyqt6

REM FIXME: Make these stats conditional for just troubleshooting sessions?
REM  It seems the first "du" call costs us about 1-2 minutes (different runs):
REM Assorted stats after package processing:
REM C:\msys64\usr\bin\bash -lc "date -u; ls -la / ; du -ksx / ; date -u; du -ks /var/cache/pacman/pkg; date -u"

C:\msys64\usr\bin\bash -lc 'PATH="${MINGW_PREFIX}/bin:$PATH" ; export PATH ; pwd ; if ! ccache -sv ; then echo "SKIP: Could not query ccache stats" ; fi ; ccache -o compression=true ; echo "ccache settings: max_size=`ccache -k max_size` compression=`ccache -k compression`" ; true '
if errorlevel 1 exit /b %ERRORLEVEL%
