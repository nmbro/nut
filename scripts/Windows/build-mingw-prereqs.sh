#!/bin/sh

# Copyright (C) 2022-2025 by Jim Klimov <jimklimov+nut@gmail.com>
# Licensed GPLv2+, same as NUT
#
# Helper automating the nuances from NUT::scripts/Windows/README.adoc
# to provide prerequisites needed in semi-native or cross-builds of NUT
# for Windows ("mingw" in the name stands for the MinGW-w64 toolchains
# used to build for Windows, not for a particular build environment).
#
# It has two modes, chosen by whether MSYS2_PATH is set:
# * MSYS2_PATH set (e.g. "export MSYS2_PATH" in the AppVeyor recipe, see
#   .github/scripts/appveyor/03-before_build.bat): a semi-native build in
#   the current MSYS2 environment (MSYSTEM, e.g. UCRT64 or MINGW32),
#   installing into its prefix (MINGW_PREFIX, e.g. /ucrt64 or /mingw32);
# * otherwise: a cross-build, assuming Debian/Ubuntu with the mingw
#   cross-compilers installed per README.adoc, for ARCH (default:
#   x86_64-w64-mingw32) into PREFIX (default: /usr/${ARCH}). Note this
#   is also what happens when running it in MSYS2 without MSYS2_PATH!
#
# NOTE: Each provide_*() method below builds a dependency from sources
# only where pkg-config does not know it yet (e.g. where MSYS2 does not
# package it for the current environment, as is common for 32-bit
# MINGW32), and stashes builds under DLDIR (default: ~/nut-win-deps) for
# re-use: a POSIX regex library (TRE with the MSYS2 "systre" wrapper),
# libusb (1.0), cppunit (only for "make check"), NSPR and NSS,
# neon, a minimal (PNG only) libgd, net-snmp, and a custom libmodbus from
# NUT Git (with USB RTU support: a packaged libmodbus is not used, and the
# stashed build is re-done when that Git source changes). Where MSYS2 does
# package a newer version (for UCRT64) than one built here, a warning says
# so (see warn_if_msys2_newer()).
#
# We can not rely on certain common shell facilities like `true`
# and `false` programs being available (in PATH or at all) so we
# `echo ""` instead.
# TODO: Support `make uninstall` attempts for older versions?..
#
# NOTE: Experimentally can use for prerequisites on other platforms, e.g.
#   SUDO=" " PREFIX_ROOT="${HOME}/nut-deps-inst" PREFIX="" \
#   ARCH="`uname -s`-`uname -p`" ./scripts/Windows/build-mingw-prereqs.sh

# GitHub Actions folds the log lines between these markers into a collapsed
# section with the given title; groups do not nest, so ci_group() closes an
# open one first. Elsewhere (e.g. AppVeyor) these print nothing. Same as in
# ci_build.sh; only call them from the main shell, not from provide_*().
CI_GROUP_OPEN=no
ci_group() {
	ci_endgroup
	if [ x"${GITHUB_ACTIONS-}" = xtrue ] ; then
		echo "::group::$*"
		CI_GROUP_OPEN=yes
	fi
}

ci_endgroup() {
	if [ x"${CI_GROUP_OPEN-}" = xyes ] ; then
		echo "::endgroup::"
		CI_GROUP_OPEN=no
	fi
}

# Run (and time) a build step: "time" is a keyword in bash (e.g. the /bin/sh
# of MSYS2), but neither a keyword nor a builtin in some other shells (e.g.
# dash, the /bin/sh of Debian), where the "time" program may be missing too
# (e.g. in minimal containers): then just run the command.
timed() {
	if (command -v time) >/dev/null 2>/dev/null ; then
		time "$@"
	else
		"$@"
	fi
}

prepareEnv() {
	[ -n "${GREP}" ] || {
		GREP="`command -v grep`" \
		&& [ x"${GREP}" != x ] \
		|| { echo "$0: FAILED to locate GREP tool" >&2 ; exit 1 ; }
	}
	export GREP

	[ -n "${EGREP}" ] || {
		if ( [ x"`echo a | $GREP -E '(a|b)'`" = xa ] ) 2>/dev/null ; then
			EGREP="$GREP -E"
		else
			EGREP="`command -v egrep`"
		fi \
		&& [ x"${EGREP}" != x ] \
		|| { echo "$0: FAILED to locate EGREP tool" >&2 ; exit 1 ; }
	}
	export EGREP

	[ -n "${MAKE-}" ] || {
		(command -v gmake) 2>/dev/null >/dev/null \
		&& MAKE="gmake" \
		|| MAKE="make"
	}
	export MAKE

	[ -n "${MAKEFLAGS-}" ] || {
		MAKEFLAGS="-j 8"
		export MAKEFLAGS
	}

	if [ -z "${SUDO-}" ] ; then
		SUDO=" " # avoid reeval
		if (command -v sudo) ; then
			case "`command -v sudo`" in
				# Windows 11 ships its own sudo.exe (in PATH under MSYS2)
				# which is not what we want for "make install" here
				*/[Ww][Ii][Nn][Dd][Oo][Ww][Ss]/*) ;;
				*) SUDO="sudo" ;;
			esac
		fi
	fi
	export SUDO

	[ -n "${DLDIR-}" ] || DLDIR=~/nut-win-deps

	if [ -n "${ARCH-}" ] && [ -n "${PREFIX-}" ] ; then
		[ -n "${WSDIR-}" ] || WSDIR="$DLDIR"/"$ARCH"
		mkdir -p "$WSDIR" "$DLDIR"
	else
		BUILD_FLAG=""
		HOST_FLAG=""
		export HOST_FLAG
		if [ -n "${MSYS2_PATH-}" ]; then
			# Assume semi-native build for same env
			[ -n "${ARCH-}" ] || ARCH="$MINGW_CHOST"
			[ -n "${PREFIX_ROOT-}" ] || PREFIX_ROOT="/"
			[ -n "${PREFIX-}" ] || PREFIX="${PREFIX_ROOT}/$MINGW_PREFIX"
			# Normalize away extra slashes, they confuse at least MSYS2 tools
			PREFIX="`echo \"${PREFIX}\" | sed 's,//*,/,g'`"
			case "${PATH}" in
				"${PREFIX}/bin"|"${PREFIX}/bin:"*|*":${PREFIX}/bin:"*|*":${PREFIX}/bin") ;;
				*) PATH="${PREFIX}/bin:${PATH}" ;;
			esac
			case "${PATH}" in
				*/ccache/*) ;;
				*) if [ -d "${PREFIX}/lib/ccache/bin" ] ; then
					# Potentionally customized by builder
					echo "Injecting MSYS2 ccache symlink collection (under PREFIX) into PATH" >&2
					PATH="${PREFIX}/lib/ccache/bin:${PATH}"
				   else
					if [ -d "${MINGW_PREFIX}/lib/ccache/bin" ] ; then
						echo "Injecting MSYS2 ccache symlink collection (under MINGW_PREFIX) into PATH" >&2
						PATH="${MINGW_PREFIX}/lib/ccache/bin:${PATH}"
					fi
				   fi ;;
			esac
			export ARCH PATH PREFIX

			if (command -v sudo) ; then true ; else sudo() ( "$@" ) ; fi
		else
			if [ -z "${ARCH-}" ] ; then
				# TODO: Select by args, envvars, directory presence...
				ARCH="x86_64-w64-mingw32"
				#ARCH="i686-w64-mingw32"
			fi

			# Assumes Ubuntu/Debian with mingw prepared, per README
			HOST_FLAG="--host=$ARCH"
			[ -n "${PREFIX_ROOT-}" ] || PREFIX_ROOT="/usr"
			[ -n "${PREFIX-}" ] || PREFIX="${PREFIX_ROOT}/${ARCH}"
			PREFIX="`echo \"${PREFIX}\" | sed 's,//*,/,g'`"

			export ARCH PREFIX

			if (command -v dpkg-architecture) ; then
				BUILD_FLAG="--build=`dpkg-architecture -qDEB_BUILD_GNU_TYPE`"
			fi
		fi
	fi

	if [ -z "${ARCH-}" ] || [ -z "${PREFIX-}" ] ; then
		echo "FAILED to determine ARCH and/or PREFIX!" >&2
		exit 1
	fi

	case "$CFLAGS" in
		*"${PREFIX}/include"*) ;;
		*) CFLAGS="$CFLAGS -D_POSIX=1 -I${PREFIX}/include/" ;;
	esac
	case "$CXXFLAGS" in
		*"${PREFIX}/include"*) ;;
		*) CXXFLAGS="$CXXFLAGS -D_POSIX=1 -I${PREFIX}/include/" ;;
	esac
	case "$LDFLAGS" in
		*"${PREFIX}/lib"*) ;;
		*) LDFLAGS="$LDFLAGS -L${PREFIX}/lib/" ;;
	esac
	case "$PKG_CONFIG_PATH" in
		*"${PREFIX}/lib"*) ;;
		*) PKG_CONFIG_PATH="${PREFIX}"/lib/pkgconfig ;;
	esac

	export CFLAGS CXXFLAGS LDFLAGS PKG_CONFIG_PATH

	[ -n "${WSDIR-}" ] || WSDIR="$DLDIR"/"$ARCH"
	mkdir -p "$WSDIR" "$DLDIR"
}

# Warn if the MSYS2 package for UCRT64 of a dependency (as a reference for the
# current release, even where we build for another environment) is newer than
# what the provide_*() method builds: $1 = package name without the MSYS2
# environment prefix, $2 = our version. On GitHub Actions also as a warning
# annotation and in the job summary. Silent where pacman is not available
# (e.g. Linux cross-builds), or MSYS2 does not package it.
warn_if_msys2_newer() {
	if (command -v pacman && command -v vercmp) >/dev/null 2>/dev/null ; then
		_pkgver="`pacman -Si \"mingw-w64-ucrt-x86_64-$1\" 2>/dev/null | sed -n 's/^Version *: *//p' | sed 's/-[0-9]*$//' | head -1`"
		if [ -n "${_pkgver}" ] && [ "`vercmp \"${_pkgver}\" \"$2\"`" -gt 0 ] ; then
			_msg="$1 ${_pkgver} is packaged by MSYS2 (UCRT64), but `basename \"$0\"` builds $1 $2: consider updating provide_$1()"
			echo "WARNING: ${_msg}" >&2
			if [ x"${GITHUB_ACTIONS-}" = xtrue ] ; then
				echo "::warning title=Prerequisite update available::${_msg}"
				if [ -n "${GITHUB_STEP_SUMMARY-}" ] ; then
					echo "* :warning: Prerequisite update available: ${_msg}" >> "${GITHUB_STEP_SUMMARY}" || echo ""
				fi
			fi
		fi
	fi
	return 0
}

# Fetch and verify a patch of an MSYS2 MINGW-packages recipe (at the commit in
# MSYS2_RECIPE_COMMIT): $1 = recipe directory, $2 = file name, $3 = SHA-256
# checksum (as in the PKGBUILD); into $DLDIR/$DEP_DIRNAME-patches/
MSYS2_RECIPES_URL="https://raw.githubusercontent.com/msys2/MINGW-packages"
fetch_msys2_patch() {
	_pdir="$DLDIR/${DEP_DIRNAME}-patches"
	mkdir -p "${_pdir}"
	if [ -s "${_pdir}/$2" ] && echo "$3  $2" | (cd "${_pdir}" && sha256sum -c - >/dev/null) ; then
		return 0
	fi
	echo "FETCH: $2 (MSYS2 recipe ${MSYS2_RECIPE_COMMIT})..." >&2
	rm -f "${_pdir}/$2"
	( cd "${_pdir}" && curl -fL "${MSYS2_RECIPES_URL}/${MSYS2_RECIPE_COMMIT}/$1/$2" > "$2" ) || \
	( cd "${_pdir}" && wget -c "${MSYS2_RECIPES_URL}/${MSYS2_RECIPE_COMMIT}/$1/$2" -O "$2" )
	echo "$3  $2" | (cd "${_pdir}" && sha256sum -c -) \
	|| { echo "FAILED: checksum mismatch for ${_pdir}/$2" >&2 ; exit 1 ; }
}

# Provide prerequisites; reentrant (quick skip if installed; quick install if built)
provide_libregex() (
	# POSIX regular expressions (regex.h, regcomp() et al), needed by NUT and
	# net-snmp: where not packaged, e.g. Linux cross-builds (MSYS2 packages
	# mingw-w64-*-libsystre for all its environments, including MINGW32).
	# Built like the MSYS2 libtre and libsystre recipes: the TRE library,
	# and the "systre" wrapper (a regex.h and a few functions calling TRE)
	# installed also as libregex and libgnurx, with regex.pc and gnurx.pc.
	# Only the narrow-character API is used, so the MSYS2 TRE patch which
	# enables wide characters for MinGW (needing autoreconf) is not applied.
	PKGCFG_NAME="regex"
	DEP_PRJNAME="tre"
	DEP_VERSION="0.9.0"
	DEP_DIRNAME="${DEP_PRJNAME}-${DEP_VERSION}"
	DEP_ARCHIVE="${DEP_DIRNAME}.tar.gz"
	DEP_SHA256="f57f5698cafdfe516d11fb0b71705916fe1162f14b08cf69d7cf86923b5a2477"
	TRE_RECIPE_COMMIT="34d592ba9f4f1fc1153f09b1398032003c4e45b8"
	SYSTRE_VERSION="1.0.2"
	SYSTRE_RECIPE_COMMIT="df797f59a639388c26c489dd76f44ce36c1b6e53"

	warn_if_msys2_newer libtre "${DEP_VERSION}"
	warn_if_msys2_newer libsystre "${SYSTRE_VERSION}"

	FORCE=false
	if [ x"${1-}" = x"-f" ] ; then FORCE=true ; fi

	set +e
	if [ x"$FORCE" = x"false" ] ; then
		# TODO: Check version
		if pkg-config --exists "$PKGCFG_NAME" ; then
			echo "SKIP: pkg-config says '$PKGCFG_NAME' exists" >&2
			return 0
		fi

		# Quickly install if prebuilt
		if [ -d "${WSDIR}/${DEP_DIRNAME}/.inst" ]; then (
			cd "${WSDIR}/${DEP_DIRNAME}/.inst" || exit
			(command -v rsync) && $SUDO rsync -cavPHK ./ / && exit
			$SUDO cp -pr ./ / && exit
			exit 1
		) && {
			echo "INST: (re-)applied '${WSDIR}/${DEP_DIRNAME}/.inst'" >&2
			return 0
		}
		fi

		# Not pre-built, fall through
	fi

	# (Re-)make and install from scratch
	set -e

	check_archive() {
		if (command -v sha256sum) >/dev/null 2>/dev/null ; then
			echo "${DEP_SHA256}  ${DEP_ARCHIVE}" | (cd "$DLDIR" && sha256sum -c -)
		else
			echo "WARNING: sha256sum not found, can not verify ${DEP_ARCHIVE}" >&2
		fi
	}

	DEP_URL="https://github.com/laurikari/tre/releases/download/v${DEP_VERSION}/${DEP_ARCHIVE}"
	if [ -s "$DLDIR/${DEP_ARCHIVE}" ] && check_archive ; then
		echo "FETCH: reusing verified '$DLDIR/${DEP_ARCHIVE}'" >&2
	else
		echo "FETCH: ${DEP_ARCHIVE}..." >&2
		rm -f "$DLDIR/${DEP_ARCHIVE}"
		( cd "$DLDIR" && curl -fL "${DEP_URL}" > "${DEP_ARCHIVE}" ) || \
		( cd "$DLDIR" && wget -c "${DEP_URL}" -O "${DEP_ARCHIVE}" )
		check_archive || { echo "FAILED: checksum mismatch for $DLDIR/${DEP_ARCHIVE}" >&2 ; exit 1 ; }
	fi

	MSYS2_RECIPE_COMMIT="${TRE_RECIPE_COMMIT}"
	fetch_msys2_patch mingw-w64-libtre 002-pointer-cast.patch 72c87b956eade17ed5444c3c6eae7be09b93d145573f20017ec590d9c2516c52
	MSYS2_RECIPE_COMMIT="${SYSTRE_RECIPE_COMMIT}"
	fetch_msys2_patch mingw-w64-libsystre regex.h 5c06d602f089fe1f2a95a59dfe7866e90a3358c714b22f6aafd7c14bd5a0f7c4
	fetch_msys2_patch mingw-w64-libsystre systre.c 454cdacd0a31d15c1a7b7e9fa8d81d0137a1b628d157cb49071a8cf7f5537827
	fetch_msys2_patch mingw-w64-libsystre COPYING 3200024286eb0a33c22da3a31c470df07c7b8cfbead2b9528195d67d107264ec
	SRCDIR_SYSTRE="$DLDIR/${DEP_DIRNAME}-patches"

	echo "BUILD: '${WSDIR}/${DEP_DIRNAME}'..." >&2
	cd "${WSDIR}" || exit
	rm -rf ${DEP_DIRNAME} || echo ""

	tar xzf "$DLDIR/${DEP_ARCHIVE}" || exit
	cd "./${DEP_DIRNAME}" || exit
	echo "PATCH: 002-pointer-cast.patch" >&2
	patch -p1 -i "${SRCDIR_SYSTRE}/002-pointer-cast.patch" || exit

	date -u || true
	timed ./configure --prefix="${PREFIX}" ${HOST_FLAG-} ${BUILD_FLAG-} \
		--enable-shared --enable-static --disable-nls --without-libintl-prefix \
		|| { cat config.log ; exit 1; }

	date -u || true
	timed $MAKE || exit

	INSTDIR="${WSDIR}/${DEP_DIRNAME}/.inst"
	rm -rf "${INSTDIR}" || echo ""
	timed $MAKE DESTDIR="${INSTDIR}" install || exit

	# The systre wrapper (MSYS2 builds it with meson, but it is one file):
	# a static library and a DLL, named and aliased like in the MSYS2 package
	if [ -n "${HOST_FLAG-}" ] ; then
		SYSTRE_CC="${CC:-${ARCH}-gcc}"
		SYSTRE_AR="${AR:-${ARCH}-ar}"
	else
		SYSTRE_CC="${CC:-gcc}"
		SYSTRE_AR="${AR:-ar}"
	fi
	mkdir -p .systre && cd .systre || exit
	cp -f "${SRCDIR_SYSTRE}/regex.h" "${SRCDIR_SYSTRE}/systre.c" ./
	$SYSTRE_CC -O2 -I. -I"${INSTDIR}${PREFIX}/include" -c systre.c -o systre.o || exit
	$SYSTRE_AR rcs libsystre.a systre.o || exit
	$SYSTRE_CC -shared -o libsystre-0.dll systre.o \
		-L"${INSTDIR}${PREFIX}/lib" -ltre \
		-Wl,--out-implib,libsystre.dll.a || exit

	mkdir -p "${INSTDIR}${PREFIX}/bin" "${INSTDIR}${PREFIX}/lib/pkgconfig" \
		"${INSTDIR}${PREFIX}/include" "${INSTDIR}${PREFIX}/share/licenses/libsystre"
	cp -f libsystre-0.dll "${INSTDIR}${PREFIX}/bin/"
	cp -f regex.h "${INSTDIR}${PREFIX}/include/"
	cp -f "${SRCDIR_SYSTRE}/COPYING" "${INSTDIR}${PREFIX}/share/licenses/libsystre/"
	for L in systre regex gnurx ; do
		cp -f libsystre.a "${INSTDIR}${PREFIX}/lib/lib${L}.a"
		cp -f libsystre.dll.a "${INSTDIR}${PREFIX}/lib/lib${L}.dll.a"
	done
	for PC in regex gnurx ; do
		cat > "${INSTDIR}${PREFIX}/lib/pkgconfig/${PC}.pc" << EOF
prefix=${PREFIX}
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: regex
Description: Regular Expressions library
Version: ${SYSTRE_VERSION}
Requires: tre
Libs: -L\${libdir} -lsystre
Cflags: -I\${includedir}
EOF
	done
	cd .. || exit

	# Summarize what we have got
	date -u || true
	find "${INSTDIR}" -type f -name "*.dll" -o -name "*.dll.a" -o -name "*.pc"

	date -u || true
	( cd "${INSTDIR}" && $SUDO cp -pr ./ / ) || exit
	echo "INST: applied '${INSTDIR}'" >&2
)

provide_libusb() (
	# Needed where not packaged, e.g. MSYS2 MINGW32 or Linux cross-builds;
	# MSYS2 UCRT64, CLANG64 and MINGW64 ship mingw-w64-*-libusb packages.
	# Also needed by libmodbus RTU USB support, so provide it first.
	PKGCFG_NAME="libusb-1.0"
	DEP_PRJNAME="libusb"
	DEP_VERSION="1.0.30"
	DEP_DIRNAME="${DEP_PRJNAME}-${DEP_VERSION}"
	DEP_ARCHIVE="${DEP_DIRNAME}.tar.bz2"
	DEP_SHA256="fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf"

	warn_if_msys2_newer "${DEP_PRJNAME}" "${DEP_VERSION}"

	FORCE=false
	if [ x"${1-}" = x"-f" ] ; then FORCE=true ; fi

	set +e
	if [ x"$FORCE" = x"false" ] ; then
		# TODO: Check version
		if pkg-config --exists "$PKGCFG_NAME" ; then
			echo "SKIP: pkg-config says '$PKGCFG_NAME' exists" >&2
			return 0
		fi

		# Quickly install if prebuilt
		if [ -d "${WSDIR}/${DEP_DIRNAME}/.inst" ]; then (
			cd "${WSDIR}/${DEP_DIRNAME}/.inst" || exit
			(command -v rsync) && $SUDO rsync -cavPHK ./ / && exit
			$SUDO cp -pr ./ / && exit
			exit 1
		) && {
			echo "INST: (re-)applied '${WSDIR}/${DEP_DIRNAME}/.inst'" >&2
			return 0
		}
		fi

		# no stashed .inst; any Makefile at least?
		if [ -s "${WSDIR}/${DEP_DIRNAME}/Makefile" ]; then (
			cd "${WSDIR}/${DEP_DIRNAME}" && $SUDO $MAKE install
		) && {
			echo "INST: ran 'make install' from '${WSDIR}/${DEP_DIRNAME}'" >&2
			return
		}
		fi

		# Not pre-built, fall through
	fi

	# (Re-)make and install from scratch
	set -e

	check_archive() {
		if (command -v sha256sum) >/dev/null 2>/dev/null ; then
			echo "${DEP_SHA256}  ${DEP_ARCHIVE}" | (cd "$DLDIR" && sha256sum -c -)
		else
			echo "WARNING: sha256sum not found, can not verify ${DEP_ARCHIVE}" >&2
		fi
	}

	if [ -s "$DLDIR/${DEP_ARCHIVE}" ] && check_archive ; then
		echo "FETCH: reusing verified '$DLDIR/${DEP_ARCHIVE}'" >&2
	else
		echo "FETCH: ${DEP_ARCHIVE}..." >&2
		rm -f "$DLDIR/${DEP_ARCHIVE}"
		( cd "$DLDIR" && curl -fL "https://github.com/libusb/libusb/releases/download/v${DEP_VERSION}/${DEP_ARCHIVE}" > "${DEP_ARCHIVE}" ) || \
		( cd "$DLDIR" && wget -c "https://github.com/libusb/libusb/releases/download/v${DEP_VERSION}/${DEP_ARCHIVE}" -O "${DEP_ARCHIVE}" )
		check_archive || { echo "FAILED: checksum mismatch for $DLDIR/${DEP_ARCHIVE}" >&2 ; exit 1 ; }
	fi

	echo "BUILD: '${WSDIR}/${DEP_DIRNAME}'..." >&2
	cd "${WSDIR}" || exit
	rm -rf ${DEP_DIRNAME} || echo ""

	tar xjf "$DLDIR/${DEP_ARCHIVE}" || exit
	cd "./${DEP_DIRNAME}" || exit

	date -u || true
	timed ./configure --prefix="${PREFIX}" ${HOST_FLAG-} ${BUILD_FLAG-} \
		--disable-examples-build --disable-tests-build \
		|| { cat config.log ; exit 1; }

	date -u || true
	timed $MAKE || exit

	# Beside leaving a pre-install location for future runs,
	# this may build some more artifacts:
	date -u || true
	rm -rf "`pwd`/.inst" || echo ""
	timed $MAKE DESTDIR="`pwd`/.inst" install || exit

	# Summarize what we have got
	date -u || true
	find ./ -type f -name "*.dll" -o -name "*.dll.a";

	date -u || true
	timed $SUDO $MAKE install
	date -u || true
	echo "INST: ran 'make install' from '${WSDIR}/${DEP_DIRNAME}'" >&2
)

provide_cppunit() (
	# Needed for "make check" of the C++ client library (cppunittest,
	# cppnit) where not packaged, e.g. MSYS2 MINGW32 or Linux cross-builds;
	# MSYS2 UCRT64, CLANG64 and MINGW64 ship mingw-w64-*-cppunit packages.
	# Only used by tests, so nothing of it is delivered with NUT for Windows.
	PKGCFG_NAME="cppunit"
	DEP_PRJNAME="cppunit"
	DEP_VERSION="1.15.1"
	DEP_DIRNAME="${DEP_PRJNAME}-${DEP_VERSION}"
	DEP_ARCHIVE="${DEP_DIRNAME}.tar.gz"
	DEP_SHA256="89c5c6665337f56fd2db36bc3805a5619709d51fb136e51937072f63fcc717a7"

	warn_if_msys2_newer "${DEP_PRJNAME}" "${DEP_VERSION}"

	FORCE=false
	if [ x"${1-}" = x"-f" ] ; then FORCE=true ; fi

	set +e
	if [ x"$FORCE" = x"false" ] ; then
		# TODO: Check version
		if pkg-config --exists "$PKGCFG_NAME" ; then
			echo "SKIP: pkg-config says '$PKGCFG_NAME' exists" >&2
			return 0
		fi

		# Quickly install if prebuilt
		if [ -d "${WSDIR}/${DEP_DIRNAME}/.inst" ]; then (
			cd "${WSDIR}/${DEP_DIRNAME}/.inst" || exit
			(command -v rsync) && $SUDO rsync -cavPHK ./ / && exit
			$SUDO cp -pr ./ / && exit
			exit 1
		) && {
			echo "INST: (re-)applied '${WSDIR}/${DEP_DIRNAME}/.inst'" >&2
			return 0
		}
		fi

		# no stashed .inst; any Makefile at least?
		if [ -s "${WSDIR}/${DEP_DIRNAME}/Makefile" ]; then (
			cd "${WSDIR}/${DEP_DIRNAME}" && $SUDO $MAKE install
		) && {
			echo "INST: ran 'make install' from '${WSDIR}/${DEP_DIRNAME}'" >&2
			return
		}
		fi

		# Not pre-built, fall through
	fi

	# (Re-)make and install from scratch
	set -e

	check_archive() {
		if (command -v sha256sum) >/dev/null 2>/dev/null ; then
			echo "${DEP_SHA256}  ${DEP_ARCHIVE}" | (cd "$DLDIR" && sha256sum -c -)
		else
			echo "WARNING: sha256sum not found, can not verify ${DEP_ARCHIVE}" >&2
		fi
	}

	if [ -s "$DLDIR/${DEP_ARCHIVE}" ] && check_archive ; then
		echo "FETCH: reusing verified '$DLDIR/${DEP_ARCHIVE}'" >&2
	else
		echo "FETCH: ${DEP_ARCHIVE}..." >&2
		rm -f "$DLDIR/${DEP_ARCHIVE}"
		( cd "$DLDIR" && curl -fL "https://dev-www.libreoffice.org/src/${DEP_ARCHIVE}" > "${DEP_ARCHIVE}" ) || \
		( cd "$DLDIR" && wget -c "https://dev-www.libreoffice.org/src/${DEP_ARCHIVE}" -O "${DEP_ARCHIVE}" )
		check_archive || { echo "FAILED: checksum mismatch for $DLDIR/${DEP_ARCHIVE}" >&2 ; exit 1 ; }
	fi

	echo "BUILD: '${WSDIR}/${DEP_DIRNAME}'..." >&2
	cd "${WSDIR}" || exit
	rm -rf ${DEP_DIRNAME} || echo ""

	tar xzf "$DLDIR/${DEP_ARCHIVE}" || exit
	cd "./${DEP_DIRNAME}" || exit

	date -u || true
	timed ./configure --prefix="${PREFIX}" ${HOST_FLAG-} ${BUILD_FLAG-} \
		--disable-doxygen \
		|| { cat config.log ; exit 1; }

	date -u || true
	timed $MAKE || exit

	# Beside leaving a pre-install location for future runs,
	# this may build some more artifacts:
	date -u || true
	rm -rf "`pwd`/.inst" || echo ""
	timed $MAKE DESTDIR="`pwd`/.inst" install || exit

	# Summarize what we have got
	date -u || true
	find ./ -type f -name "*.dll" -o -name "*.dll.a";

	date -u || true
	timed $SUDO $MAKE install
	date -u || true
	echo "INST: ran 'make install' from '${WSDIR}/${DEP_DIRNAME}'" >&2
)

provide_neon() (
	# HTTP/WebDAV client library for the netxml-ups driver and the XML/HTTP
	# scan of nut-scanner; needed where not packaged, e.g. MSYS2 MINGW32 or
	# Linux cross-builds (MSYS2 UCRT64, CLANG64 and MINGW64 ship packages).
	# Requires OpenSSL and expat. Built without NLS (gettext is not packaged
	# for MSYS2 MINGW32 either), and without a built-in CA bundle path: that
	# of the build host would not exist on the systems running NUT.
	PKGCFG_NAME="neon"
	DEP_PRJNAME="neon"
	DEP_VERSION="0.37.1"
	DEP_DIRNAME="${DEP_PRJNAME}-${DEP_VERSION}"
	DEP_ARCHIVE="${DEP_DIRNAME}.tar.gz"
	DEP_SHA256="a99b7262525a454d1065cf76dd17240fd808dfc4ef15636990ff83a5d0d9e740"

	warn_if_msys2_newer "${DEP_PRJNAME}" "${DEP_VERSION}"

	FORCE=false
	if [ x"${1-}" = x"-f" ] ; then FORCE=true ; fi

	set +e
	if [ x"$FORCE" = x"false" ] ; then
		# TODO: Check version
		if pkg-config --exists "$PKGCFG_NAME" ; then
			echo "SKIP: pkg-config says '$PKGCFG_NAME' exists" >&2
			return 0
		fi

		# Quickly install if prebuilt
		if [ -d "${WSDIR}/${DEP_DIRNAME}/.inst" ]; then (
			cd "${WSDIR}/${DEP_DIRNAME}/.inst" || exit
			(command -v rsync) && $SUDO rsync -cavPHK ./ / && exit
			$SUDO cp -pr ./ / && exit
			exit 1
		) && {
			echo "INST: (re-)applied '${WSDIR}/${DEP_DIRNAME}/.inst'" >&2
			return 0
		}
		fi

		# no stashed .inst; any Makefile at least?
		if [ -s "${WSDIR}/${DEP_DIRNAME}/Makefile" ]; then (
			cd "${WSDIR}/${DEP_DIRNAME}" && $SUDO $MAKE install
		) && {
			echo "INST: ran 'make install' from '${WSDIR}/${DEP_DIRNAME}'" >&2
			return
		}
		fi

		# Not pre-built, fall through
	fi

	# (Re-)make and install from scratch
	set -e

	check_archive() {
		if (command -v sha256sum) >/dev/null 2>/dev/null ; then
			echo "${DEP_SHA256}  ${DEP_ARCHIVE}" | (cd "$DLDIR" && sha256sum -c -)
		else
			echo "WARNING: sha256sum not found, can not verify ${DEP_ARCHIVE}" >&2
		fi
	}

	if [ -s "$DLDIR/${DEP_ARCHIVE}" ] && check_archive ; then
		echo "FETCH: reusing verified '$DLDIR/${DEP_ARCHIVE}'" >&2
	else
		echo "FETCH: ${DEP_ARCHIVE}..." >&2
		rm -f "$DLDIR/${DEP_ARCHIVE}"
		( cd "$DLDIR" && curl -fL "https://notroj.github.io/neon/${DEP_ARCHIVE}" > "${DEP_ARCHIVE}" ) || \
		( cd "$DLDIR" && wget -c "https://notroj.github.io/neon/${DEP_ARCHIVE}" -O "${DEP_ARCHIVE}" )
		check_archive || { echo "FAILED: checksum mismatch for $DLDIR/${DEP_ARCHIVE}" >&2 ; exit 1 ; }
	fi

	echo "BUILD: '${WSDIR}/${DEP_DIRNAME}'..." >&2
	cd "${WSDIR}" || exit
	rm -rf ${DEP_DIRNAME} || echo ""

	tar xzf "$DLDIR/${DEP_ARCHIVE}" || exit
	cd "./${DEP_DIRNAME}" || exit

	date -u || true
	timed ./configure --prefix="${PREFIX}" ${HOST_FLAG-} ${BUILD_FLAG-} \
		--with-ssl=openssl --with-expat --disable-nls \
		--enable-shared --disable-static \
		|| { cat config.log ; exit 1; }

	date -u || true
	timed $MAKE || exit

	# Beside leaving a pre-install location for future runs,
	# this may build some more artifacts:
	date -u || true
	rm -rf "`pwd`/.inst" || echo ""
	timed $MAKE DESTDIR="`pwd`/.inst" install || exit

	# Summarize what we have got
	date -u || true
	find ./ -type f -name "*.dll" -o -name "*.dll.a";

	date -u || true
	timed $SUDO $MAKE install
	date -u || true
	echo "INST: ran 'make install' from '${WSDIR}/${DEP_DIRNAME}'" >&2
)

# NSPR and NSS (the default SSL/TLS library of NUT for Windows CI builds) are
# built like the MSYS2 MINGW-packages recipes (mingw-w64-nspr, mingw-w64-nss)
# do for UCRT64 et al, with their patches; MSYS2 stopped packaging them for
# MINGW32 in 2026, while still packaging the same versions for 64-bit builds.
# As these are security libraries, keep DEP_VERSION, the archive checksum and
# the recipe commit (MSYS2_RECIPE_COMMIT, with the patch checksums from its
# PKGBUILD) in sync with the current MSYS2 recipe; warn_if_msys2_newer() above
# reports when MSYS2 packages a newer version than we build.

provide_nspr() (
	# Netscape Portable Runtime, needed by NSS (see the comment above).
	PKGCFG_NAME="nspr"
	DEP_PRJNAME="nspr"
	DEP_VERSION="4.40"
	DEP_DIRNAME="${DEP_PRJNAME}-${DEP_VERSION}"
	DEP_ARCHIVE="${DEP_DIRNAME}.tar.gz"
	DEP_SHA256="c0c1884c627f3db7a783f7c7314c695226b2043696791d15519e7e0578c19bdc"
	MSYS2_RECIPE_COMMIT="c2f733acfc1b9ca50cae4d5d5b4a70f89bc23543"

	warn_if_msys2_newer "${DEP_PRJNAME}" "${DEP_VERSION}"

	FORCE=false
	if [ x"${1-}" = x"-f" ] ; then FORCE=true ; fi

	set +e
	if [ x"$FORCE" = x"false" ] ; then
		# TODO: Check version
		if pkg-config --exists "$PKGCFG_NAME" ; then
			echo "SKIP: pkg-config says '$PKGCFG_NAME' exists" >&2
			return 0
		fi

		# Quickly install if prebuilt
		if [ -d "${WSDIR}/${DEP_DIRNAME}/.inst" ]; then (
			cd "${WSDIR}/${DEP_DIRNAME}/.inst" || exit
			(command -v rsync) && $SUDO rsync -cavPHK ./ / && exit
			$SUDO cp -pr ./ / && exit
			exit 1
		) && {
			echo "INST: (re-)applied '${WSDIR}/${DEP_DIRNAME}/.inst'" >&2
			return 0
		}
		fi

		# Not pre-built, fall through
	fi

	# (Re-)make and install from scratch
	set -e

	check_archive() {
		if (command -v sha256sum) >/dev/null 2>/dev/null ; then
			echo "${DEP_SHA256}  ${DEP_ARCHIVE}" | (cd "$DLDIR" && sha256sum -c -)
		else
			echo "WARNING: sha256sum not found, can not verify ${DEP_ARCHIVE}" >&2
		fi
	}

	if [ -s "$DLDIR/${DEP_ARCHIVE}" ] && check_archive ; then
		echo "FETCH: reusing verified '$DLDIR/${DEP_ARCHIVE}'" >&2
	else
		echo "FETCH: ${DEP_ARCHIVE}..." >&2
		rm -f "$DLDIR/${DEP_ARCHIVE}"
		( cd "$DLDIR" && curl -fL "https://ftp.mozilla.org/pub/nspr/releases/v${DEP_VERSION}/src/${DEP_ARCHIVE}" > "${DEP_ARCHIVE}" ) || \
		( cd "$DLDIR" && wget -c "https://ftp.mozilla.org/pub/nspr/releases/v${DEP_VERSION}/src/${DEP_ARCHIVE}" -O "${DEP_ARCHIVE}" )
		check_archive || { echo "FAILED: checksum mismatch for $DLDIR/${DEP_ARCHIVE}" >&2 ; exit 1 ; }
	fi

	fetch_msys2_patch mingw-w64-nspr 0001-fix-integer-casting.patch 23b01b1d3f0c46b232ac3996b1990587a83fe567d6db46771f79d0e034ecedd4
	fetch_msys2_patch mingw-w64-nspr 0002-fix-autotools.patch 09db781de5606974bc7dd6b0b173f910b027015bb20fddb78ce452ee15d55364
	fetch_msys2_patch mingw-w64-nspr 0003-mingw.patch b68ccd918d0a8a4f28cc09c9e63cb5772e22af69f55576340315a933c236da94
	fetch_msys2_patch mingw-w64-nspr 0004-static-build.patch 61ad5b61084e23ea8e4ba59e481ac681917d61257545c3f70937ae6170fad91f
	fetch_msys2_patch mingw-w64-nspr 0005-fix-x64.patch 2614000b78bf245c9542d6e174071d078dd3290519409ead1256d4a8350d3316
	fetch_msys2_patch mingw-w64-nspr 0006-aarch64.patch 31eabbfbd8d80ea24e8dab7a8e7aa31f0cd1754c308465dc04a58bc1b6f7207f

	echo "BUILD: '${WSDIR}/${DEP_DIRNAME}'..." >&2
	cd "${WSDIR}" || exit
	rm -rf ${DEP_DIRNAME} || echo ""

	tar xzf "$DLDIR/${DEP_ARCHIVE}" || exit
	# The sources are in a "nspr" subdirectory, which the patches apply to
	cd "./${DEP_DIRNAME}/nspr" || exit
	for P in "$DLDIR/${DEP_DIRNAME}-patches"/0*.patch ; do
		echo "PATCH: `basename \"$P\"`" >&2
		patch -Nbp1 -i "$P" || exit
	done

	NSPR_CONF64=""
	case "${ARCH}" in
		x86_64-*) NSPR_CONF64="--enable-64bit" ;;
	esac

	mkdir -p .build && cd .build || exit
	date -u || true
	CFLAGS="$CFLAGS -std=gnu17 -Wno-incompatible-pointer-types" \
	timed ../configure --prefix="${PREFIX}" ${HOST_FLAG-} ${BUILD_FLAG-} \
		--target="${ARCH}" \
		--includedir="${PREFIX}/include/nspr" \
		--enable-optimize --disable-debug ${NSPR_CONF64} \
		|| { cat config.log ; exit 1; }

	date -u || true
	timed $MAKE || exit

	# The pre-install location for future runs, laid out like the MSYS2
	# package (DLLs in bin/)
	date -u || true
	INSTDIR="${WSDIR}/${DEP_DIRNAME}/.inst"
	rm -rf "${INSTDIR}" || echo ""
	timed $MAKE DESTDIR="${INSTDIR}" install || exit
	mkdir -p "${INSTDIR}${PREFIX}/bin"
	mv -f "${INSTDIR}${PREFIX}"/lib/*.dll "${INSTDIR}${PREFIX}/bin/"
	rm -rf "${INSTDIR}${PREFIX}/bin/compile-et.pl" "${INSTDIR}${PREFIX}/bin/prerr.properties" \
		"${INSTDIR}${PREFIX}/include/nspr/md" || echo ""

	# Summarize what we have got
	date -u || true
	find "${INSTDIR}" -type f -name "*.dll" -o -name "*.dll.a" -o -name "*.pc"

	date -u || true
	( cd "${INSTDIR}" && $SUDO cp -pr ./ / ) || exit
	echo "INST: applied '${INSTDIR}'" >&2
)

provide_nss() (
	# Network Security Services (see the comment above); needs NSPR, and
	# sqlite3 and zlib (packaged by MSYS2 also for MINGW32), and the MSYS2
	# "nsinstall" and "zip" tools to build. Also provides the certutil and
	# pk12util tools used by NIT ("make check-NIT") to prepare certificates.
	PKGCFG_NAME="nss"
	DEP_PRJNAME="nss"
	DEP_VERSION="3.132"
	DEP_DIRNAME="${DEP_PRJNAME}-${DEP_VERSION}"
	DEP_ARCHIVE="${DEP_DIRNAME}.tar.gz"
	DEP_SHA256="ee9cf4837ba801141a804321c4462ad8f452ff4314275c6d5108a6b05af227ff"
	MSYS2_RECIPE_COMMIT="7d75007446b5b0ee3a05b9af6c2930fbd80e929e"

	warn_if_msys2_newer "${DEP_PRJNAME}" "${DEP_VERSION}"

	FORCE=false
	if [ x"${1-}" = x"-f" ] ; then FORCE=true ; fi

	set +e
	if [ x"$FORCE" = x"false" ] ; then
		# TODO: Check version
		if pkg-config --exists "$PKGCFG_NAME" ; then
			echo "SKIP: pkg-config says '$PKGCFG_NAME' exists" >&2
			return 0
		fi

		# Quickly install if prebuilt
		if [ -d "${WSDIR}/${DEP_DIRNAME}/.inst" ]; then (
			cd "${WSDIR}/${DEP_DIRNAME}/.inst" || exit
			(command -v rsync) && $SUDO rsync -cavPHK ./ / && exit
			$SUDO cp -pr ./ / && exit
			exit 1
		) && {
			echo "INST: (re-)applied '${WSDIR}/${DEP_DIRNAME}/.inst'" >&2
			return 0
		}
		fi

		# Not pre-built, fall through
	fi

	# (Re-)make and install from scratch
	set -e

	check_archive() {
		if (command -v sha256sum) >/dev/null 2>/dev/null ; then
			echo "${DEP_SHA256}  ${DEP_ARCHIVE}" | (cd "$DLDIR" && sha256sum -c -)
		else
			echo "WARNING: sha256sum not found, can not verify ${DEP_ARCHIVE}" >&2
		fi
	}

	DEP_URL="https://ftp.mozilla.org/pub/security/nss/releases/NSS_`echo \"${DEP_VERSION}\" | tr . _`_RTM/src/${DEP_ARCHIVE}"
	if [ -s "$DLDIR/${DEP_ARCHIVE}" ] && check_archive ; then
		echo "FETCH: reusing verified '$DLDIR/${DEP_ARCHIVE}'" >&2
	else
		echo "FETCH: ${DEP_ARCHIVE}..." >&2
		rm -f "$DLDIR/${DEP_ARCHIVE}"
		( cd "$DLDIR" && curl -fL "${DEP_URL}" > "${DEP_ARCHIVE}" ) || \
		( cd "$DLDIR" && wget -c "${DEP_URL}" -O "${DEP_ARCHIVE}" )
		check_archive || { echo "FAILED: checksum mismatch for $DLDIR/${DEP_ARCHIVE}" >&2 ; exit 1 ; }
	fi

	fetch_msys2_patch mingw-w64-nss nss-build.patch ef34f0c8fff8808d466804a779391ad99bb7f67dbdbdca0d1b526d88b5d0c3b2
	fetch_msys2_patch mingw-w64-nss nss-3.20.1-headers.patch ed0a0a234b443113bff5fe6bea70dbf7fe7f1206acd1129eeed5cff78e3c0503
	fetch_msys2_patch mingw-w64-nss nss-3.81-aarch64.patch 45664249c0dab17986c47ca3cdf5165d1f2f64838a2f0b340b97e05427ce47cb

	echo "BUILD: '${WSDIR}/${DEP_DIRNAME}'..." >&2
	cd "${WSDIR}" || exit
	rm -rf ${DEP_DIRNAME} || echo ""

	tar xzf "$DLDIR/${DEP_ARCHIVE}" || exit
	cd "./${DEP_DIRNAME}" || exit
	for P in nss-build.patch nss-3.20.1-headers.patch nss-3.81-aarch64.patch ; do
		echo "PATCH: $P" >&2
		patch -p1 -i "$DLDIR/${DEP_DIRNAME}-patches/$P" || exit
	done

	NSS_CONF64=""
	case "${ARCH}" in
		x86_64-*) NSS_CONF64="USE_64=1" ;;
	esac

	BUILD_OPT=1
	NSS_NO_SSL2_NO_EXPORT=1
	NSS_USE_SYSTEM_SQLITE=1
	IMPORT_LIB_SUFFIX=.dll.a
	NSS_DISABLE_GTESTS=1
	NSS_ENABLE_ECC=1
	NSS_DISABLE_DBM=1
	NSPR_INCLUDE_DIR="`nspr-config --includedir`"
	NSPR_LIB_DIR="`nspr-config --libdir`"
	SQLITE_LIB_DIR="${PREFIX}/lib"
	EXTRA_SHARED_LIBS="-lplc4 -lplds4 -lnspr4 -lz -lcrypt32 -lws2_32"
	export BUILD_OPT NSS_NO_SSL2_NO_EXPORT NSS_USE_SYSTEM_SQLITE IMPORT_LIB_SUFFIX \
		NSS_DISABLE_GTESTS NSS_ENABLE_ECC NSS_DISABLE_DBM \
		NSPR_INCLUDE_DIR NSPR_LIB_DIR SQLITE_LIB_DIR EXTRA_SHARED_LIBS

	date -u || true
	timed $MAKE -C nss OS_TARGET=WINNT OS_RELEASE=5.0 XP_WIN=1 \
		NS_USE_GCC=1 ${NSS_CONF64} \
		NSS_USE_SYSTEM_SQLITE=1 USE_SYSTEM_ZLIB=1 ZLIB_LIBS="${PREFIX}/lib/libz.dll.a" \
		|| exit

	# NSS has no "make install": lay out the pre-install location for future
	# runs like the MSYS2 package does (without the blank NSS databases and
	# the "unsupported" tools)
	date -u || true
	INSTDIR="${WSDIR}/${DEP_DIRNAME}/.inst"
	rm -rf "${INSTDIR}" || echo ""
	mkdir -p "${INSTDIR}${PREFIX}/bin" "${INSTDIR}${PREFIX}/include/nss3" "${INSTDIR}${PREFIX}/lib/pkgconfig"

	NSPR_VERSION="`pkg-config --modversion nspr`"
	sed nss/pkg/pkg-config/nss.pc.in \
		-e "s,%libdir%,${PREFIX}/lib,g" \
		-e "s,%prefix%,${PREFIX},g" \
		-e "s,%exec_prefix%,${PREFIX}/bin,g" \
		-e "s,%includedir%,${PREFIX}/include/nss3,g" \
		-e "s,%NSPR_VERSION%,${NSPR_VERSION},g" \
		-e "s,%NSS_VERSION%,${DEP_VERSION},g" \
		> "${INSTDIR}${PREFIX}/lib/pkgconfig/nss.pc"
	cp -f "${INSTDIR}${PREFIX}/lib/pkgconfig/nss.pc" "${INSTDIR}${PREFIX}/lib/pkgconfig/mozilla-nss.pc"

	VMAJOR="`awk '/#define.*NSS_VMAJOR/ {print $3}' nss/lib/nss/nss.h`"
	VMINOR="`awk '/#define.*NSS_VMINOR/ {print $3}' nss/lib/nss/nss.h`"
	VPATCH="`awk '/#define.*NSS_VPATCH/ {print $3}' nss/lib/nss/nss.h`"
	sed nss/pkg/pkg-config/nss-config.in \
		-e "s,@libdir@,${PREFIX}/lib,g" \
		-e "s,@prefix@,${PREFIX}/bin,g" \
		-e "s,@exec_prefix@,${PREFIX}/bin,g" \
		-e "s,@includedir@,${PREFIX}/include/nss3,g" \
		-e "s,@MOD_MAJOR_VERSION@,${VMAJOR},g" \
		-e "s,@MOD_MINOR_VERSION@,${VMINOR},g" \
		-e "s,@MOD_PATCH_VERSION@,${VPATCH},g" \
		> "${INSTDIR}${PREFIX}/bin/nss-config"
	chmod 755 "${INSTDIR}${PREFIX}/bin/nss-config"

	for F in softokn nss nssutil ssl smime ; do
		cp -pf dist/*.OBJ/lib/${F}3.dll "${INSTDIR}${PREFIX}/bin/"
		cp -pf dist/*.OBJ/lib/lib${F}3.dll.a "${INSTDIR}${PREFIX}/lib/"
	done
	cp -pf dist/*.OBJ/lib/nssckbi.dll dist/*.OBJ/lib/freebl3.dll "${INSTDIR}${PREFIX}/bin/"
	for F in libnssb.dll.a libnssckfw.dll.a libfreebl.dll.a libcryptohi.dll.a libcerthi.dll.a libcertdb.dll.a libsoftokn.dll.a libpkixutil.dll.a ; do
		cp -pf dist/*.OBJ/lib/${F} "${INSTDIR}${PREFIX}/lib/"
	done
	for F in certutil cmsutil crlutil modutil pk12util signtool signver ssltap ; do
		cp -pf dist/*.OBJ/bin/${F}.exe "${INSTDIR}${PREFIX}/bin/"
	done
	cp -pf dist/public/nss/*.h "${INSTDIR}${PREFIX}/include/nss3/"

	# Summarize what we have got
	date -u || true
	find "${INSTDIR}" -type f -name "*.dll" -o -name "*.dll.a" -o -name "*.pc"

	date -u || true
	( cd "${INSTDIR}" && $SUDO cp -pr ./ / ) || exit
	echo "INST: applied '${INSTDIR}'" >&2
)

provide_libgd() (
	# A minimal libgd for the upsimage.cgi program, which only needs PNG
	# output with built-in fonts. Packaged libgd builds (e.g. in MSYS2)
	# typically enable all image formats, so their DLLs (and those of the
	# codecs behind HEIF and AVIF support) would all have to be bundled
	# with NUT for Windows, as load-time dependencies of libgd.dll.
	# Requires libpng and zlib to be available.
	PKGCFG_NAME="gdlib"
	DEP_PRJNAME="libgd"
	DEP_VERSION="2.3.3"
	DEP_DIRNAME="${DEP_PRJNAME}-${DEP_VERSION}"
	DEP_ARCHIVE="${DEP_DIRNAME}.tar.gz"
	DEP_SHA256="dd3f1f0bb016edcc0b2d082e8229c822ad1d02223511997c80461481759b1ed2"

	warn_if_msys2_newer "${DEP_PRJNAME}" "${DEP_VERSION}"

	FORCE=false
	if [ x"${1-}" = x"-f" ] ; then FORCE=true ; fi

	set +e
	if [ x"$FORCE" = x"false" ] ; then
		# TODO: Check version
		if pkg-config --exists "$PKGCFG_NAME" ; then
			echo "SKIP: pkg-config says '$PKGCFG_NAME' exists" >&2
			return 0
		fi

		# Quickly install if prebuilt
		if [ -d "${WSDIR}/${DEP_DIRNAME}/.inst" ]; then (
			cd "${WSDIR}/${DEP_DIRNAME}/.inst" || exit
			(command -v rsync) && $SUDO rsync -cavPHK ./ / && exit
			$SUDO cp -pr ./ / && exit
			exit 1
		) && {
			echo "INST: (re-)applied '${WSDIR}/${DEP_DIRNAME}/.inst'" >&2
			return 0
		}
		fi

		# no stashed .inst; any Makefile at least?
		if [ -s "${WSDIR}/${DEP_DIRNAME}/Makefile" ]; then (
			cd "${WSDIR}/${DEP_DIRNAME}" && $SUDO $MAKE install
		) && {
			echo "INST: ran 'make install' from '${WSDIR}/${DEP_DIRNAME}'" >&2
			return
		}
		fi

		# Not pre-built, fall through
	fi

	# (Re-)make and install from scratch
	set -e

	check_archive() {
		if (command -v sha256sum) >/dev/null 2>/dev/null ; then
			echo "${DEP_SHA256}  ${DEP_ARCHIVE}" | (cd "$DLDIR" && sha256sum -c -)
		else
			echo "WARNING: sha256sum not found, can not verify ${DEP_ARCHIVE}" >&2
		fi
	}

	if [ -s "$DLDIR/${DEP_ARCHIVE}" ] && check_archive ; then
		echo "FETCH: reusing verified '$DLDIR/${DEP_ARCHIVE}'" >&2
	else
		echo "FETCH: ${DEP_ARCHIVE}..." >&2
		rm -f "$DLDIR/${DEP_ARCHIVE}"
		( cd "$DLDIR" && curl -fL "https://github.com/libgd/libgd/releases/download/gd-${DEP_VERSION}/${DEP_ARCHIVE}" > "${DEP_ARCHIVE}" ) || \
		( cd "$DLDIR" && wget -c "https://github.com/libgd/libgd/releases/download/gd-${DEP_VERSION}/${DEP_ARCHIVE}" -O "${DEP_ARCHIVE}" )
		check_archive || { echo "FAILED: checksum mismatch for $DLDIR/${DEP_ARCHIVE}" >&2 ; exit 1 ; }
	fi

	echo "BUILD: '${WSDIR}/${DEP_DIRNAME}'..." >&2
	cd "${WSDIR}" || exit
	rm -rf ${DEP_DIRNAME} || echo ""

	tar xzf "$DLDIR/${DEP_ARCHIVE}" || exit
	cd "./${DEP_DIRNAME}" || exit

	date -u || true
	timed ./configure --prefix="${PREFIX}" ${HOST_FLAG-} ${BUILD_FLAG-} \
		--with-png --with-zlib \
		--without-freetype --without-fontconfig --without-raqm \
		--without-jpeg --without-tiff --without-webp --without-xpm \
		--without-liq --without-heif --without-avif --without-x \
		|| { cat config.log ; exit 1; }

	date -u || true
	timed $MAKE || exit

	# Beside leaving a pre-install location for future runs,
	# this may build some more artifacts:
	date -u || true
	rm -rf "`pwd`/.inst" || echo ""
	timed $MAKE DESTDIR="`pwd`/.inst" install || exit

	# Summarize what we have got
	date -u || true
	find ./ -type f -name "*.dll" -o -name "*.dll.a";

	date -u || true
	timed $SUDO $MAKE install
	date -u || true
	echo "INST: ran 'make install' from '${WSDIR}/${DEP_DIRNAME}'" >&2
)

provide_netsnmp() (
	PKGCFG_NAME="netsnmp"
	DEP_PRJNAME="net-snmp"
	DEP_VERSION="5.9.1"
	DEP_DIRNAME="${DEP_PRJNAME}-${DEP_VERSION}"
	DEP_ARCHIVE="${DEP_DIRNAME}.tar.gz"

	FORCE=false
	if [ x"${1-}" = x"-f" ] ; then FORCE=true ; fi

	set +e
	if [ x"$FORCE" = x"false" ] ; then
		# TODO: Check version
		if pkg-config --exists "$PKGCFG_NAME" ; then
			echo "SKIP: pkg-config says '$PKGCFG_NAME' exists" >&2
			return 0
		fi

		# Quickly install if prebuilt
		if [ -d "${WSDIR}/${DEP_DIRNAME}/.inst" ]; then (
			cd "${WSDIR}/${DEP_DIRNAME}/.inst" || exit
			(command -v rsync) && $SUDO rsync -cavPHK ./ / && exit
			$SUDO cp -pr ./ / && exit
			exit 1
		) && {
			echo "INST: (re-)applied '${WSDIR}/${DEP_DIRNAME}/.inst'" >&2
			return 0
		}
		fi

		# no stashed .inst; any Makefile at least?
		if [ -s "${WSDIR}/${DEP_DIRNAME}/Makefile" ]; then (
			cd "${WSDIR}/${DEP_DIRNAME}" && $SUDO $MAKE install
		) && {
			echo "INST: ran 'make install' from '${WSDIR}/${DEP_DIRNAME}'" >&2
			return
		}
		fi

		# Not pre-built, fall through
	fi

	# (Re-)make and install from scratch
	set -e

	# Funny ways to fetch from Sourceforge help get the archive,
	# not the download page... For some reason, this bites CI
	# builds on Appveyor but not local runs:
	echo "FETCH: ${DEP_ARCHIVE}..." >&2
	( cd "$DLDIR" && curl -L "https://sourceforge.net/projects/${DEP_PRJNAME}/files/${DEP_PRJNAME}/${DEP_VERSION}/${DEP_ARCHIVE}"  > "${DEP_ARCHIVE}" ) || \
	( cd "$DLDIR" && wget -c "https://sourceforge.net/projects/${DEP_PRJNAME}/files/${DEP_PRJNAME}/${DEP_VERSION}/${DEP_ARCHIVE}" -O "${DEP_ARCHIVE}" )

	echo "BUILD: '${WSDIR}/${DEP_DIRNAME}'..." >&2
	cd "${WSDIR}" || exit
	rm -rf ${DEP_DIRNAME} || echo ""

	tar xzf "$DLDIR/${DEP_ARCHIVE}" || exit
	cd "./${DEP_DIRNAME}" || exit

	# NOTE: --disable-daemon may be from a different version,
	# just in case present here to simplify variant builds.
	date -u || true
	yes "" | timed ./configure --prefix="${PREFIX}" --with-default-snmp-version=3 \
		--disable-agent --disable-daemon --with-sys-contact="" --with-sys-location="" \
		--with-logfile=none --with-persistent-directory="${PREFIX}/var/net-snmp" \
		--disable-embedded-perl --without-perl-modules --disable-perl-cc-checks \
		--disable-applications --disable-manuals --disable-mibs --disable-scripts \
		--enable-shared || { cat config.log ; exit 1; }

	date -u || true
	timed $MAKE LDFLAGS="-no-undefined -lws2_32 -lregex -Xlinker --ignore-unresolved-symbol=_app_name_long -Xlinker --ignore-unresolved-symbol=app_name_long" || exit

	# Beside leaving a pre-install location for future runs,
	# this may build some more artifacts:
	date -u || true
	rm -rf "`pwd`/.inst" || echo ""
	timed $MAKE DESTDIR="`pwd`/.inst" install || exit

	# Summarize what we have got
	date -u || true
	find ./ -type f -name "*.dll" -o -name "*.dll.a";

	date -u || true
	timed $SUDO $MAKE install
	date -u || true
	echo "INST: ran 'make install' from '${WSDIR}/${DEP_DIRNAME}'" >&2
)

provide_libmodbus_git() (
	# Provide the libmodbus version with RTU USB support
	PKGCFG_NAME="libmodbus"
	DEP_PRJNAME="libmodbus-git"
	DEP_GITREPO="https://github.com/networkupstools/libmodbus"
	DEP_VERSION="rtu_usb"	# Git branch/tag/commit point
	# Use PR #3 temporarily:
	#DEP_GITREPO="https://github.com/jimklimov/libmodbus"	# TEMP
	#DEP_VERSION="fix-mingw-build"	# TEMP
	DEP_DIRNAME="${DEP_PRJNAME}-${DEP_VERSION}"

	FORCE=false
	if [ x"${1-}" = x"-f" ] ; then FORCE=true ; fi

	# Make sure we have current repo code checked out
	cd "${DLDIR}"
	if [ -d "${DEP_DIRNAME}" ] ; then
		{
			# NOTE: Use `git ls-remote {URL|.}` to not modify the local FS if
			# there's nothing to change (avoid re-packaging of CI artifact cache)
			cd "${DEP_DIRNAME}" && \
			LOCAL_HASH="`git log -1 --format='%H'`" && \
			OTHER_HASH="`git ls-remote \"${DEP_GITREPO}\" | ${EGREP} '(refs/(heads|tags)/'\"${DEP_VERSION}\"'$|^'\"${DEP_VERSION}\"')' | awk '{print $1}'`" && \
			if [ x"${LOCAL_HASH}" = x"${OTHER_HASH}" ] ; then
				echo "FETCH: Current git commit in '`pwd`' matches current '${DEP_VERSION}' in '${DEP_GITREPO}'" >&2
			else
				echo "FETCH: Update git workspace in `pwd`..." >&2
				git fetch --tags && \
				git fetch --all && \
				git checkout "${DEP_VERSION}" && \
				_GITDIFF="`git diff \"origin/${DEP_VERSION}\"`" && \
				if [ -n "${_GITDIFF}" ] ; then
					# Ensure rebase etc. or fail
					git pull && \
					./autogen.sh && \
					FORCE=true
				else
					echo "Current content in '`pwd`' matches current '${DEP_VERSION}' in '${DEP_GITREPO}'" >&2
				fi
			fi
		} || { cd "${DLDIR}" ; chmod -R +w "${DEP_DIRNAME}" || echo "" ; rm -rf "${DEP_DIRNAME}" ; }
	fi

	cd "${DLDIR}"
	if [ ! -d "${DEP_DIRNAME}/.git" ] ; then
		echo "FETCH: Clone git workspace in '${DLDIR}/${DEP_DIRNAME}' from '${DEP_VERSION}' in '${DEP_GITREPO}'..." >&2
		FORCE=true
		chmod -R +w "${DEP_DIRNAME}" || echo ""
		rm -rf "${DEP_DIRNAME}"
		git clone "${DEP_GITREPO}" -b "${DEP_VERSION}" "${DEP_DIRNAME}" || exit
	fi
	if [ ! -s "${DEP_DIRNAME}/configure" ] || [ x"$FORCE" = x"true" ] ; then
		echo "FETCH: (Re-)bootstrap git workspace in '${DLDIR}/${DEP_DIRNAME}'..." >&2
		(cd "${DEP_DIRNAME}" && ./autogen.sh) || exit
		FORCE=true
	fi

	set +e
	if [ x"$FORCE" = x"false" ] ; then
		# TODO: Check version - harder with git rolling, so no-op for now
		if false && pkg-config --exists "$PKGCFG_NAME" ; then
			echo "SKIP: pkg-config says '$PKGCFG_NAME' exists" >&2
			return 0
		fi

		# Quickly install if prebuilt
		if [ -d "${WSDIR}/${DEP_DIRNAME}/.inst" ]; then (
			cd "${WSDIR}/${DEP_DIRNAME}/.inst" || exit
			(command -v rsync) && $SUDO rsync -cavPHK ./ / && exit
			$SUDO cp -pr ./ / && exit
			exit 1
		) && {
			echo "INST: (re-)applied '${WSDIR}/${DEP_DIRNAME}/.inst'" >&2
			return 0
		}
		fi

		# no stashed .inst; any Makefile at least?
		if [ -s "${WSDIR}/${DEP_DIRNAME}/Makefile" ]; then (
			cd "${WSDIR}/${DEP_DIRNAME}" && $SUDO $MAKE install
		) && {
			echo "INST: ran 'make install' from '${WSDIR}/${DEP_DIRNAME}'" >&2
			return
		}
		fi

		# Not pre-built, fall through
	fi

	# (Re-)make and install from scratch
	set -e

	echo "BUILD: '${WSDIR}/${DEP_DIRNAME}'..." >&2
	cd "${WSDIR}"
	if [ -e "./${DEP_DIRNAME}" ] ; then
		# Take care of read-only destdir pieces
		chmod -R +w "./${DEP_DIRNAME}" || echo ""
		rm -rf "./${DEP_DIRNAME}" || echo ""
	fi
	mkdir -p "./${DEP_DIRNAME}" || exit
	cd "./${DEP_DIRNAME}" || exit

	date -u || true
	timed "${DLDIR}/${DEP_DIRNAME}/configure" --prefix="${PREFIX}" --with-libusb --enable-static --disable-shared --enable-Werror \
		|| { cat config.log ; exit 1 ; }

	date -u || true
	timed $MAKE || exit

	date -u || true
	timed $MAKE check || echo "WARNING: make check is flaky or failed outright" >&2

	# Beside leaving a pre-install location for future runs,
	# this may build some more artifacts:
	date -u || true
	rm -rf "`pwd`/.inst" || echo ""
	timed $MAKE DESTDIR="`pwd`/.inst" install || exit

	# Summarize what we have got
	date -u || true
	find ./ -type f -name "*.dll" -o -name "*.a"

	date -u || true
	timed $SUDO $MAKE install
	date -u || true
	echo "INST: ran 'make install' from '${WSDIR}/${DEP_DIRNAME}'" >&2
)

prepareEnv || exit

echo "Prepared environment for $0:" >&2
set | ${EGREP} '^(ARCH|PREFIX|PREFIX_ROOT|PATH|MAKE|MAKEFLAGS|SUDO|DLDIR|WSDIR|CFLAGS|CXXFLAGS|LDFLAGS|PKG_CONFIG_PATH|BUILD_FLAG|HOST_FLAG|MINGW_CHOST|MINGW_PREFIX|MSYS2_PATH)=' >&2

# Provide one prerequisite, if selected: $1 = provide_*() method name suffix,
# $2 = pkg-config module (to report its file), $3 = title (for the CI log
# group), the rest is passed to the method (e.g. "-f" to force a rebuild).
# NUT_PREREQS_ONLY may list the method name suffixes to provide (default:
# all), e.g. NUT_PREREQS_ONLY="libregex libusb" for a quick cross-build.
RES=0
provide_one() {
	_name="$1" ; _pc="$2" ; _title="$3" ; shift 3
	if [ -n "${NUT_PREREQS_ONLY-}" ] ; then
		case " ${NUT_PREREQS_ONLY} " in
			*" ${_name} "*) ;;
			*) echo "SKIP: provide_${_name} (not in NUT_PREREQS_ONLY)" >&2 ; return 0 ;;
		esac
	fi
	ci_group "Prerequisite: ${_title}"
	"provide_${_name}" "$@"
	ls -la "${PREFIX}/lib/pkgconfig/${_pc}.pc"
	cat "${PREFIX}/lib/pkgconfig/${_pc}.pc"
	RES=$?
}

# TODO: params, help, etc...
# For now, let it pass "-f" to the builder
provide_one libregex regex "regex (TRE, systre)" "$@"
provide_one libusb libusb-1.0 "libusb-1.0" "$@"
provide_one cppunit cppunit "cppunit" "$@"
provide_one nspr nspr "nspr" "$@"
provide_one nss nss "nss" "$@"
provide_one neon neon "neon" "$@"
provide_one libgd gdlib "libgd" "$@"
provide_one netsnmp netsnmp "net-snmp" "$@"
provide_one libmodbus_git libmodbus "libmodbus (NUT Git)" "$@"
ci_endgroup
exit $RES
