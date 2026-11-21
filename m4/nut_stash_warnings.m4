dnl Callers like CI or developers can enable various warning flags
dnl including those that would be fatal to the configure script
dnl itself passing (autotools probing code is rather sloppy by
dnl strict standards). These routines try to stash away the warning
dnl flags from CFLAGS and CXXFLAGS passed by user, to re-apply in
dnl the end of configure script run.

AC_DEFUN([NUT_STASH_WARNINGS],
[
    dnl WARNING: This code assumes that there are no whitespaces
    dnl inside C*FLAGS values (e.g. no spacey include paths)
    dnl NOTE: Do not use TMP (or TEMP, TMPDIR) as the scratch variable:
    dnl it is often exported (e.g. on MSYS2), and compilers use it as the
    dnl temporary directory, so "Cannot create temporary file in ..." errors
    dnl would follow when probing with C*FLAGS set.
    CFLAGS_STASHED_WARNINGS=""
    CPPFLAGS_STASHED_WARNINGS=""
    CXXFLAGS_STASHED_WARNINGS=""

    AS_IF([test -z "$CFLAGS"],[],[
            NUT_STASH_TMP=""
            for V in ${CFLAGS} ; do
                case "$V" in
                    -W*|-*pedantic*) CFLAGS_STASHED_WARNINGS="${CFLAGS_STASHED_WARNINGS} ${V}" ;;
                    *) NUT_STASH_TMP="${NUT_STASH_TMP} ${V}" ;;
                esac
            done
            CFLAGS="$NUT_STASH_TMP"
        ])
    AS_IF([test -n "${CFLAGS_STASHED_WARNINGS}"],
        [AC_MSG_NOTICE([Stashed CFLAGS warnings to not confuse autotools probes: ${CFLAGS_STASHED_WARNINGS}])])

    AS_IF([test -z "$CPPFLAGS"],[],[
            NUT_STASH_TMP=""
            for V in ${CPPFLAGS} ; do
                case "$V" in
                    -W*|-*pedantic*) CPPFLAGS_STASHED_WARNINGS="${CPPFLAGS_STASHED_WARNINGS} ${V}" ;;
                    *) NUT_STASH_TMP="${NUT_STASH_TMP} ${V}" ;;
                esac
            done
            CPPFLAGS="$NUT_STASH_TMP"
        ])
    AS_IF([test -n "${CPPFLAGS_STASHED_WARNINGS}"],
        [AC_MSG_NOTICE([Stashed CPPFLAGS warnings to not confuse autotools probes: ${CPPFLAGS_STASHED_WARNINGS}])])


    AS_IF([test -z "$CXXFLAGS"],[],[
            NUT_STASH_TMP=""
            for V in ${CXXFLAGS} ; do
                case "$V" in
                    -W*|-*pedantic*) CXXFLAGS_STASHED_WARNINGS="${CXXFLAGS_STASHED_WARNINGS} ${V}" ;;
                    *) NUT_STASH_TMP="${NUT_STASH_TMP} ${V}" ;;
                esac
            done
            CXXFLAGS="$NUT_STASH_TMP"
        ])
    AS_IF([test -n "${CXXFLAGS_STASHED_WARNINGS}"],
        [AC_MSG_NOTICE([Stashed CXXFLAGS warnings to not confuse autotools probes: ${CXXFLAGS_STASHED_WARNINGS}])])

])

AC_DEFUN([NUT_POP_WARNINGS],
[
    AS_IF([test -n "${CFLAGS_STASHED_WARNINGS}"],[
            AC_MSG_NOTICE([Applying back the stashed CFLAGS warnings])
            CFLAGS="${CFLAGS} ${CFLAGS_STASHED_WARNINGS}"
            AC_MSG_NOTICE([Ended up with: '${CFLAGS}'])
        ])

    AS_IF([test -n "${CPPFLAGS_STASHED_WARNINGS}"],[
            AC_MSG_NOTICE([Applying back the stashed CPPFLAGS warnings])
            CPPFLAGS="${CPPFLAGS} ${CPPFLAGS_STASHED_WARNINGS}"
            AC_MSG_NOTICE([Ended up with: '${CPPFLAGS}'])
        ])

    AS_IF([test -n "${CXXFLAGS_STASHED_WARNINGS}"],[
            AC_MSG_NOTICE([Applying back the stashed CXXFLAGS warnings])
            CXXFLAGS="${CXXFLAGS} ${CXXFLAGS_STASHED_WARNINGS}"
            AC_MSG_NOTICE([Ended up with: '${CXXFLAGS}'])
        ])
])
