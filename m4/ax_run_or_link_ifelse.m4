dnl By default, AC_RUN_IFELSE() fails if it detects cross-compilation
dnl but it provides the fourth argument to customize the handling.
dnl In our case, we would fall back to trying just to link then -
dnl the result would not be as relevant regarding run-time behavior
dnl of the code, but at least we would know that API and ABI are ok.
dnl Here the fourth and fifth arguments can be used to pass custom
dnl CFLAGS and CXXFLAGS options (e.g. warnings to cover or ignore),
dnl respectively. For the test to succeed, the build/link must pass
dnl without warnings.

dnl Per original /usr/share/autoconf/autoconf/general.m4 which makes
dnl a similar wrapper:
dnl # AC_TRY_RUN(PROGRAM,
dnl #            [ACTION-IF-TRUE], [ACTION-IF-FALSE],
dnl #            [ACTION-IF-CROSS-COMPILING = RUNTIME-ERROR])
dnl # -------------------------------------------------------
dnl The original CFLAGS and CXXFLAGS are saved into variables of their own for
dnl each expansion of the macro (numbered by an m4 counter), so that a nested
dnl call (e.g. in the ACTION-IF-FALSE of another one, to retry with other
dnl libraries) does not overwrite what the outer one restores: with shared
dnl variables, the "-Werror..." options of the test leaked into the build
dnl flags, but only when the outer check was not answered from config.cache.
m4_define([_AX_RUN_OR_LINK_IFELSE_COUNT], [0])
AC_DEFUN([AX_RUN_OR_LINK_IFELSE],
[m4_define([_AX_RUN_OR_LINK_IFELSE_COUNT], m4_incr(_AX_RUN_OR_LINK_IFELSE_COUNT))dnl
m4_pushdef([_AX_ROL_CFLAGS], [ax_run_or_link_saved_CFLAGS_]_AX_RUN_OR_LINK_IFELSE_COUNT)dnl
m4_pushdef([_AX_ROL_CXXFLAGS], [ax_run_or_link_saved_CXXFLAGS_]_AX_RUN_OR_LINK_IFELSE_COUNT)dnl
	_AX_ROL_CFLAGS="$CFLAGS"
	_AX_ROL_CXXFLAGS="$CXXFLAGS"
	AS_IF([test "${GCC}" = "yes" || test "${CLANGCC}" = "yes"], [
		CFLAGS="$_AX_ROL_CFLAGS -Werror -Werror=implicit-function-declaration $4"
		dnl # cc1plus: error: '-Werror=' argument '-Werror=implicit-function-declaration' is not valid for C++ [-Werror]
		CXXFLAGS="$_AX_ROL_CXXFLAGS -Werror $5"
	], [
		dnl # Don't know what to complain about for unknown compilers
		dnl # FIXME: Presume here they have at least a "-Werror" option
		CFLAGS="$_AX_ROL_CFLAGS -Werror $4"
		CXXFLAGS="$_AX_ROL_CXXFLAGS -Werror $5"
	])
	AC_RUN_IFELSE([$1], [$2], [$3],
		[
		AC_MSG_WARN([Current build is a cross-build, so not running test binaries, just linking them])
		AC_LINK_IFELSE([$1], [$2], [$3])
		]
	)
	CFLAGS="$_AX_ROL_CFLAGS"
	CXXFLAGS="$_AX_ROL_CXXFLAGS"
	AS_UNSET([_AX_ROL_CFLAGS])
	AS_UNSET([_AX_ROL_CXXFLAGS])
m4_popdef([_AX_ROL_CFLAGS])dnl
m4_popdef([_AX_ROL_CXXFLAGS])dnl
])
