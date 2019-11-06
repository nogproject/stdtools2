#!/bin/bash

# `stdtoolsYear` is the current stdtools generation, which is used at some
# places to avoid scattered changes when promoting stdtools to a new year.
stdtoolsYear=2019

case $(uname) in
MINGW*)
    cat >&2 <<EOF
fatal: stdtools ${stdtoolsYear} does not support MSYS Git anymore.  Use Ubuntu on Windows.
EOF
    exit 1
    ;;
esac

# The exit codes that indicate success of failure.  `cfg_exit_ok != 0` as a
# workaround for Putty problems; see `exec_ssh()` and `mapExitCode()`.
cfg_exit_ok=44
cfg_exit_err=1

cfg_stdhost() {
    local h

    # Use environment variable if set.
    h="${STDHOST:-}"
    if [ -n "${h}" ]; then
        printf '%s' "${h}"
        return
    fi

    # Use Git config if set.
    if git config stdtools.stdhost; then
        return
    fi

    die 'Failed to determine stdhost; set it with `git config --global stdtools.stdhost <host>`.'
}

# `cfg_stdhostPath` is prepended to PATH when running on stdhost.
cfg_stdhostPath() {
    local p

    # Use environment variable if set.
    p="${STDHOSTPATH:-}"
    if [ -n "${p}" ]; then
        printf '%s' "${p}"
        return
    fi

    # Use Git config if set.
    if git config stdtools.stdhostpath; then
        return
    fi

    die 'Missing stdhostpath; set it with `git config --global stdtools.stdhostpath <path>`.'
}

cfg_projects() {
    local p

    # Use environment variable if set.
    p="${STDHOSTPROJECTS:-}"
    if [ -n "${p}" ]; then
        printf '%s' "${p}"
        return
    fi

    # Use Git config if set.
    if git config stdtools.stdhostprojects; then
        return
    fi

    die 'Missing stdhostprojects; set it with `git config --global stdtools.stdhostprojects <path>`.'
}

lsActiveSubmodulesRecursive() {
    git submodule foreach --recursive 'true' | cut -d "'" -f 2
}

# `getRepoCommonName2()` tries to determine the full name of the repo in the
# current working directory from its remote URL.  It prints 'unknown' if the
# remote URL is not available.
getRepoCommonName2() {
    local url
    if ! url=$(git config remote.origin.url); then
        printf 'unknown'
        return
    fi
    repoFullnameFromURL2 "${url}"
}

# `repoFullnameFromURL2 <url>` tries to determine the full name of the repo for
# the given URL.  It prints `unknown` if the URL does not match our naming
# scheme.  Subrepos are reported as `<fullname>/<sub>`.
repoFullnameFromURL2() {
    local url="$1"
    local match fullname month date shortname projects ergxProjects

    if ! projects="$(cfg_projects)"; then
        return 1
    fi
    ergxProjects="$(egrepEscapePath "${projects}")"
    if match=$(
            printf '%s\n' "${url}" \
            | egrep '^.*'"${ergxProjects}"'/[^/]+/20[0-9]{2}/[^/]+(/[^/]+)?$' \
            | sed -e 's@^.*'"${ergxProjects}"'/@@'
        ); then
        read project year shortname subdir <<<"$(split / ${match})"
    elif match=$(
            printf '%s\n' "${url}" \
            | egrep '^.*'"${ergxProjects}"'/[^/]+/[a-zA-Z][a-zA-Z0-9-]*(/[^/]+)?$' \
            | sed -e 's@^.*'"${ergxProjects}"'/@@'
        ); then
        year=
        read project shortname subdir <<<"$(split / ${match})"
    elif match=$(matchMappedUrl "${url}"); then
        read project year shortname subdir <<<"$(split / ${match})"
    else
        printf 'unknown'
        return
    fi

    # 2013 repo subdir starts with <YEAR>[-<MONTH>]_.
    # 2014 and 2015 starts with [<MONTH>_].
    # 2016 and later may end with _<MONTH>
    if grep -q '_[0-1][0-9]$' <<< "${shortname}"; then
        read shortname month <<<"$(split _ ${shortname})"
        date="${year}-${month}"
    elif grep -q '^20[0-9][0-9]' <<< "${shortname}"; then
        read date shortname <<<"$(split _ ${shortname})"
    elif grep -q '^[0-9][0-9]_' <<< "${shortname}"; then
        read month shortname <<<"$(split _ ${shortname})"
        date="${year}-${month}"
    else
        date="${year}"
    fi

    if [ -z "${year}" ]; then
        fullname="${project}_${shortname}"
    elif [ ${year} -ge 2016 ]; then
        fullname="${project}_${shortname}_${date}"
    else
        fullname="${date}_${project}_${shortname}"
    fi

    if ! ( validateRepoName "${fullname}" ) 2>/dev/null; then
        printf 'unknown'
        return
    fi

    if [ -z "${subdir}" ]; then
        printf '%s' "${fullname}"
    else
        printf '%s' "${fullname}/${subdir}"
    fi
}

matchMappedUrl() {
    local url="$1"
    git config --get-regexp '^stdtools[.]projectsPath[.].*$' \
    | cut -d . -f 3- \
    | (
        while read -r project rootdir; do
            if match=$(
                    printf '%s\n' "${url}" \
                    | egrep "^.*${rootdir}/20[0-9]{2}/[^/]+(/[^/]+)?$" \
                    | sed -e "s@^.*${rootdir}/@@"
                ); then
                printf '%s/%s' "${project}" "${match}"
                return 0
            fi
        done
        return 1
    )
}

# `stdhostSubdir <shortname> <date>` returns the subdirectory below the project
# toplevel or year dir.  `<date>` may be empty.
stdhostSubdir() {
    local shortname="$1"
    local date="$2"
    case ${date} in
    2013*)
        printf '%s_%s' "${date}" "${shortname}"
        ;;
    2014-* | 2015-*)
        read year month <<<"$(split - ${date})"
        printf '%s_%s' "${month}" "${shortname}"
        ;;
    *-*)
        read year month <<<"$(split - ${date})"
        printf '%s_%s' "${shortname}" "${month}"
        ;;
    *)
        printf '%s' "${shortname}"
        ;;
    esac
}

# `projectDir <project>` prints the project directory.  It uses the Git config
# `stdtools.projectsPath.<project>`, if available, to resolve the path.
projectDir() {
    local project="$1"
    if git config "stdtools.projectsPath.${project}"; then
        true
    else
        if ! projects="$(cfg_projects)"; then
            return 1
        fi
        printf '%s/%s' "${projects}" "${project}"
    fi
}

# `stdhostSuperdir <project> <date>` prints the full path to the project parent
# directory:
#
#   if <date> == '': '.../projects/<project>'
#   if <date> != '': '.../projects/<project>/<year>'
#
stdhostSuperdir() {
    local project="$1"
    local date="$2"
    local year=$(cut -d - -f 1 <<<"${date}")
    if [ -z "${year}" ]; then
        projectDir "${project}"
    else
        printf '%s/%s' "$(projectDir "${project}")" "${year}"
    fi
}

# repoPath <fullname>
#
# Print full remote repository path.
repoPath() {
    read shortname project date _ <<<"$(parseRepoName $1)"
    echo "$(stdhostSuperdir ${project} "${date}")/$(stdhostSubdir ${shortname} "${date}")"
}

# `parseRepoName` tokenizes a full repo name:
#
#      read shortname project date year month <<<"$(parseRepoName ${fullname})"
#
parseRepoName() {
    local shortname project date year month
    # Use `split` instead of `IFS=_ read ...` to avoid parsing problems on
    # Linux.  For unknown reasons, parsing fails sometimes when using IFS.
    case $(nameFormat "$1") in
    pnd)
        read project shortname date <<<"$(split _ $1)"
        read year month <<<"$(split - ${date})"
        ;;
    dpn)
        read date project shortname <<<"$(split _ $1)"
        read year month <<<"$(split - ${date})"
        ;;
    pn)
        read project shortname <<<"$(split _ $1)"
        date=
        year=
        month=
        ;;
    esac
    echo "${shortname} ${project} ${date} ${year} ${month}"
}

nameFormat() {
    case $1 in
    *_*_20*)
        printf 'pnd'
        ;;
    20*_*_*)
        printf 'dpn'
        ;;
    *_*)
        printf 'pn'
        ;;
    *)
        die "Failed to determine name format for '$1'."
        ;;
    esac
}

validateRepoName() {
    if ! isValidRepoFullname "$1"; then
        die "'$1' is not a valid repo fullname."
    fi
}

ergxRepoFullname='
    ^(
        201[345] (-(0[1-9]|1[0-2]))? _ [a-zA-Z0-9-]+ _ [a-zA-Z0-9-]+
        |
        [a-zA-Z0-9-]+ _ [a-zA-Z0-9-]+ _ 201[6-9] (-(0[1-9]|1[0-2]))?
        |
        [a-zA-Z][a-zA-Z0-9-]* _ [a-zA-Z][a-zA-Z0-9-]*
    )$
'
ergxRepoFullname="$(tr -d ' \n' <<<"${ergxRepoFullname}")"

grepRepoFullname() {
    egrep "${ergxRepoFullname}"
}

isValidRepoFullname() {
    egrep -q "${ergxRepoFullname}" <<<"$1"
}

split() {
    sed -e "s@$1@ @g" <<<"$2"
}

# `egrepEscapePath <string>` quotes special regex chars that are common in
# paths such that egrep matches them without special meaning.
egrepEscapePath() {
    sed -e 's/\./[.]/g' <<< "$1"
}

# `exec_ssh` works as `ssh` but uses PuTTY's plink if configured in `GIT_SSH`.
# Because plink under some conditions returns an exit code 0 even if a
# connection failed, remote scripts are required to indicate success by exit
# code `$cfg_exit_ok`.  The success code is mapped to 0, so that callers can
# use the normal shell convention.
exec_ssh() {
    local ec
    local defaultargs=
    local ssh=${GIT_SSH:-ssh}
    case "$ssh" in
    *plink*)
        defaultargs=-batch
        ;;
    esac

    # Try to explicitly specify the ssh identity to avoid `too many
    # authentication failures`.  If an ssh-agent is available, get a key
    # listing and grep for the current user.  Store its public key to a temp
    # file and pass it to `ssh -i`.  See <http://serverfault.com/a/401749> for
    # the idea.  Clean up afterwards.
    opt_id=
    IFS='@' read -r user host <<<"$1"
    if [ -n "${host}" ] && [ -n "${SSH_AUTH_SOCK:-}" ]; then
        SSH_ID_FILE="/tmp/stdtools-id-${user}-$$-${RANDOM}.pub"
        if ssh-add -L | grep "${user}\$" >"${SSH_ID_FILE}"; then
            printf >&2 'Using ssh-agent identity %s\n' \
                "$(ssh-keygen -l -f "${SSH_ID_FILE}")"
            opt_id="-i ${SSH_ID_FILE}"
        fi
    fi

    # Use && || compound command to capture exit code with option errexit.
    # With a naked `ssh ...`, bash would stop on error.
    "$ssh" $defaultargs ${opt_id} "$@" && ec=$? || ec=$?

    if [ -n "${opt_id}" ]; then
        rm -f "${SSH_ID_FILE}"
    fi

    mapExitCode ${ec}
}

mapExitCode() {
    local ec=$1
    case ${ec} in
    ${cfg_exit_ok})
        return 0
        ;;
    0)
        return 1
        ;;
    *)
        return ${ec}
        ;;
    esac
}

genprgSameGitAuthorAtRemote() {
    echo "export GIT_AUTHOR_NAME='$(git config user.name)'"
    echo "export GIT_AUTHOR_EMAIL='$(git config user.email)'"
}

genprgSameGitCommitter() {
    echo "export GIT_COMMITTER_NAME='$(git config user.name)'"
    echo "export GIT_COMMITTER_EMAIL='$(git config user.email)'"
}

genprgSameGitCommitterAsUser() {
    local user="$1"
    echo "export GIT_COMMITTER_NAME='$(git config user.name) as ${user}'"
    echo "export GIT_COMMITTER_EMAIL='$(git config user.email)'"
}

# `callStdhost <cmd> <args>...` execute `lib/call/<cmd>` on the host
# `$(cfg_stdhost)` with a reasonable environment:  PATH is set to
# `$(cfg_stdhostPath)`.  The toolslib is sourced.  The local values of the
# variables `opt_*` are passed to the remote shell.  The `<args>...` are passed
# as positional args to the remote shell.
callStdhost() {
    local cmd="$1"
    shift

    local stdhost
    if ! stdhost="$(cfg_stdhost)"; then
        return 1
    fi

    (
        tr -d '\r' <"${toolsdir}/lib/lib.sh" &&
        genprgDecodeArgs &&
        genprgOpts &&
        genprgStdhostEnv &&
        genprgSameGitAuthorAtRemote &&
        genprgSameGitCommitter &&
        tr -d '\r' <"${toolsdir}/lib/call/${cmd}"
    ) | exec_ssh "${stdhost}" bash -s $(encodeArgs "$@")
}

# `encodeArgs` encode the positional args as base64urlsafe strings, so that
# msysgit leaves them alone.  The args are decoded at the remote by the shell
# snippet from `genprgDecodeArgs`.
encodeArgs() {
    for a in "$@"; do
        printf ' %s' $(printf '%s' "${a}" | openssl base64 | tr -d '\n' | tr '+/' '_-')
    done
}

genprgDecodeArgs() {
    cat <<\EOF
decodeArg() {
    printf '%s\n' "$1" | tr '_-' '+/' | openssl base64 -d
}

eval set -- $(printf ' "$(decodeArg "${%d}")"' $(seq 1 $#))
EOF
}

genprgOpts() {
    for o in ${!opt_*}; do
        printf "%s='%s'\n" "${o}" "${!o}"
    done
}

genprgStdhostEnv() {
    local path
    if ! path="$(cfg_stdhostPath)"; then
        return 1
    fi
    cat <<EOF
export PATH=$(printf '%q' ${path}):\$PATH
EOF
}

die() {
    printf >&2 'Error: %s\n' "$1"
    exit ${cfg_exit_err}
}

warn() {
    printf >&2 'Warning: %s\n' "$1"
}

exitok() {
    exit ${cfg_exit_ok}
}
