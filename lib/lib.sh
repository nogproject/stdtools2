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

# We use `LC_ALL=C` to ensure that sort behaves as expected when sorting files;
# the expected sort order is '.git/ .git/HEAD .gitignore'.  See
# <https://unix.stackexchange.com/a/87763> for other things that may be
# unexpected without `LC_ALL=C`.
#
# `LC_ALL=C` unfortunately also configures Python to use ASCII when encoding
# filenames; see Python documentation `sys.getfilesystemencoding`,
# <https://docs.python.org/3/library/sys.html#sys.getfilesystemencoding>.  But
# we do want to use UTF-8 there.  So we set `export LC_ALL=en_US.UTF-8` before
# calling programs that are implemented in Python.  Most programs that are
# known to be affected are helpers like `git lfs-x`, which are executed via
# `git <program>` and never directly as `git-<program>`.  So it is sufficient
# to wrap `git()`.  One exception is `lib/call/dedup_global`, which explicitly
# sets `LC_ALL`.
#
# # Rejected Alternatives
#
# We could leave the environment unmodified, assuming that it is configured to
# UTF-8 on Linux, and instead set `LC_ALL=C` only for individual operations
# when we known that we need to control the environment, e.g. when calling
# `sort`.  This alternative could work in principle, but it would be difficult
# to implement, because the entire stdtools codebase would need to be reviewed.
#
# We could change Python implementation to preserve bytes on Linux.  Instead of
# decoding paths from external programs, like `git ls-files -z`, they bytes
# could be preserved and later passed to `os` functions.  The Python
# implementation would become independent of the encoding by completely avoid
# it.  The approach, however, may cause problems on Window and Mac, which use
# Unicode for file paths.  See:
# <https://docs.python.org/3/library/sys.html#sys.getfilesystemencoding> and
# <https://www.python.org/dev/peps/pep-0529/>.  The Python recommendation is to
# use `str` for paths.  We follow it.

# Enforce byte sorting, as discussed above.
export LC_ALL=C

# Ensure Python uses UTF-8 paths, as discussed above.
git() {
    ( export LC_ALL=en_US.UTF-8 && exec 'git' "$@" )
}

# These keys are used in `DATAPLAN.md`
purgeConfigKeyPrefix='Git-silo-'
purgeConfigPathKey='Git-silo-purge-path'
masterstoreKey='Git-silo-masterstore-stdrepo'

# Two separate lists for Python modules and Pip requirements, since there is no
# one-to-one correspondence.
requiredPythonModules='
    attr
    dateutil
    docopt
    requests
'
pipRequirements='
    attrs
    dateutils
    docopt
    requests
'

# The expected tool versions; used when checking the environment.
expectedLfsTransferSshSemver='0.4.0'
expectedLfsStandaloneTransferSshSemver='0.4.0'

# `opt_global_skip_*` can be used to globally disable LFS code paths.  The
# mechanism will be incrementally implement over time.
opt_global_skip_lfs_ssh=

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

cfg_releases() {
    echo 'releases'
}

# `activateToolsEnv` activates the environment without slow sanity checks.
#
# `activateToolsEnvChecked` does the same but with additional sanity checks to
# confirm that the tools from the bundled bin dirs work as expected.
#
# The sanity checks may take up to 2 seconds.  Fast commands, therefore, may
# skip them.
#
# The `activate*` functions can only be used locally, and must not be used in
# `lib/call/` remote code.
activateToolsEnv() {
    checkToolsdirVar
    checkUserGitconfig
    activateBundledBindirs
}

activateToolsEnvChecked() {
    checkPython3
    activateToolsEnv
    checkGitLfsTransferToolsStandalone
}

checkToolsdirVar() {
    if [ -z "${toolsdir:-}" ]; then
        die "\`toolsdir\` is unset."
    fi
}

# `activateBundledBindirs` ensures that the bundled `bin/` dirs are active.
# `lib.sh` does not directly modify the path on loading, since the lib source
# is also used during remote calls, when `toolsdir` might be meaningless.
# `main()` must call `activateToolsdirBinPaths` if it later relies on the tools
# from the bin dirs.
activateBundledBindirs() {
    local prefix p
    prefix=
    for sub in git-lfs-transfer git-lfs-x; do
        p="${toolsdir}/${sub}"
        if [ -d "${p}" ]; then
            prefix="${p}:${prefix}"
            continue
        fi
        # Also try side-by-side directory layout.
        p="$(realpath "${toolsdir}/../${sub}")"
        if [ -d "${p}" ]; then
            prefix="${p}:${prefix}"
            continue
        fi
    done
    if [ "${PATH#${prefix}}" = "${PATH}" ]; then
        PATH="${prefix}${PATH}"
    fi
}

findDataplan() {
    for p in DATAPLAN.md README-data.md; do
        if [ -e "${p}" ]; then
            printf '%s' "${p}"
            return
        fi
    done
    printf 'DATAPLAN.md'
}

# `isActiveLfsSsh` is true if the repo contains LFS filter attributes and LFS
# SSH is not globally disabled.
isActiveLfsSsh() {
    if test ${opt_global_skip_lfs_ssh}; then
        return 1
    fi
    isConfiguredLfsSsh
}

# There is no special configuration for LFS SSH transfer.  LFS attributes alone
# are sufficient indication that it can be used.
isConfiguredLfsSsh() {
    gitattributesContainLfs
}

gitattributesContainLfs() {
    local gitattributes
    gitattributes="$(git rev-parse --show-toplevel)/.gitattributes"
    if ! [ -e "${gitattributes}" ]; then
        return 1
    fi

    if ! grep -q 'filter=lfs' "${gitattributes}"; then
        return 1
    fi

    return 0
}

hasConfigLfsStandalonetransferSsh() {
    git config lfs.customtransfer.ssh.path \
    | grep -q 'git-lfs-standalonetransfer-ssh'
}

hasLfsStandaloneTransferUrlPrefixConfig() {
    git config --get-regexp \
        '^lfs\.https://'"$(cfg_stdhost)"'/.*\.standalonetransferagent$' '^ssh$' \
        >/dev/null 2>&1
}

gitConfigHasAllLfsSshSettings() {
    if lfsHasStandaloneTransfer; then
        git config lfs.customtransfer.ssh.path >/dev/null 2>&1 \
        && hasLfsStandaloneTransferUrlPrefixConfig \
        && ! git config remote.origin.lfsurl >/dev/null 2>&1
    else
        git config lfs.customtransfer.ssh.path >/dev/null 2>&1 \
        && ! hasLfsStandaloneTransferUrlPrefixConfig \
        && git config remote.origin.lfsurl >/dev/null 2>&1
    fi
}

gitConfigHasAnyLfsSshSetting() {
    git config remote.origin.lfsurl >/dev/null 2>&1 \
    || git config lfs.customtransfer.ssh.path >/dev/null 2>&1 \
    || git config lfs.standalonetransferagent >/dev/null 2>&1
}

setLfsSshConfig() {
    setLfsSshConfigStandalone
}

setLfsSshConfigStandalone() {
    local url
    if ! url=$(parseOriginUrlSsh); then
        die "Failed to parse remote origin URL in \`$(pwd)\` as SSH."
    fi
    local host="${url%%:*}"
    git config lfs.customtransfer.ssh.path git-lfs-standalonetransfer-ssh
    git config "lfs.https://${host}/.standalonetransferagent" ssh
    git config --unset remote.origin.lfsurl || true
}

unsetLfsSshConfig() {
    local url
    if ! url=$(parseOriginUrlSsh); then
        die "Failed to parse remote origin URL in \`$(pwd)\` as SSH."
    fi
    git config --unset remote.origin.lfsurl || true
    git config --unset lfs.customtransfer.ssh.path || true
    configUnsetLfsStandalone
}

configUnsetLfsStandalone() {
    (
        git config -z --local \
            --get-regexp '^lfs\..*\.standalonetransferagent$' \
        || true
    ) \
    | while read -r -d '' k v; do
        git config --local --unset "${k}"
    done
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
    git config --get-regexp '^stdtools[.]projectsPath[.][a-z0-9]*$' \
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

parseRemoteURL() {
    local url host path

    if ! url="$(git config remote.origin.url)"; then
        die "Failed to get 'remote.origin.url'."
    fi
    case "$url" in
        ssh://*)
            host="$(cut -d / -f 3 <<<"${url}")"
            path=/"$(cut -d / -f 4- <<<"${url}")"
            ;;
        /*)
            host=localhost
            path="$url"
            ;;
        *)
            die "Unsupported url '${url}'."
            ;;
    esac
    # Normalize multiple / at beginning of path.
    path="$(sed -e 's@^//*@/@' <<<"${path}")"

    if ! projects="$(cfg_projects)"; then
        die 'Missing projects path.'
    fi
    ergxProjects="$(egrepEscapePath "${projects}")"

    local ergxPath2013='^'"${ergxProjects}"'/[^/]+/[0-9]{4}/[0-9]{4}(-[0-9]{2})?_[^/_]+$'
    local ergxPath2014='^'"${ergxProjects}"'/[^/]+/[0-9]{4}/([0-9]{2}_)?[^/_]+$'
    local ergxPath2016='^'"${ergxProjects}"'/[^/]+/[0-9]{4}/[^/_]+(_[0-9]{2})?$'
    local ergxPathTimeless='^'"${ergxProjects}"'/[^/]+/[a-zA-Z][a-zA-Z0-9-]*$'

    if ! (
        egrep -q "${ergxPath2013}" <<<"$path" \
        || egrep -q "${ergxPath2014}" <<<"$path" \
        || egrep -q "${ergxPath2016}" <<<"$path" \
        || egrep -q "${ergxPathTimeless}" <<<"$path" \
        || isListedNonStandardPath "${path}"
    ); then
        confirmWarning "
The path of 'remote.origin.url' is '${path}'.  It
does neither match the regex for 2013 '${ergxPath2013}'
nor for 2014 and 2015 '${ergxPath2014}',
nor for 2016 and later '${ergxPath2016}',
nor for timeless repos '${ergxPathTimeless}',
nor is it listed as a non-standard path in 'stdtools.projectsPath.*'.
" "Do you want to continue"
    fi

    printf '%s:%s\n' "${host}" "${path}"
}

parseOriginUrlSsh() {
    local url host path
    if ! url=$(git config remote.origin.url); then
        die "Failed to get 'remote.origin.url'."
    fi
    case "$url" in
        ssh://*)
            host=$(cut -d / -f 3 <<<"${url}")
            path=/$(cut -d / -f 4- <<<"${url}")
            ;;
        *)
            die "Unsupported remote.origin.url \`${url}\`; expected \`ssh://<host>/...\`."
            ;;
    esac
    # Normalize multiple slashes at beginning of path.
    path=$(sed -e 's@^//*@/@' <<<"${path}")
    printf '%s:%s\n' "${host}" "${path}"
}

isListedNonStandardPath() {
    local path="$1"
    git config --get-regexp '^stdtools[.]projectsPath[.][a-z0-9]*$' \
    | (
        while read -r _ root; do
            if egrep -q "^$(egrepEscapePath "${root}")" <<<"${path}"; then
                return 0
            fi
        done
        return 1
    )
}

haveChanges() {
    haveStagedChanges || haveUnstagedChanges
}

haveStagedChanges() {
    ! git diff-index --quiet --cached HEAD
}

haveUnstagedChanges() {
    ! git diff-files --quiet
}

gitStatusIsClean() {
    [ -z "$(git status -s)" ]
}

haveUntrackedFiles() {
    [ "$(git ls-files --other --exclude-per-directory=.gitignore)" != "" ]
}

requireIsToplevelDir() {
    isTopLevelDir || die "Directory '$(pwd)' is not toplevel of working copy."
}

isInsideWorkTree() {
    [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ]
}

isTopLevelDir() {
    isInsideWorkTree && [ -z "$(git rev-parse --show-prefix 2>/dev/null)" ]
}

opt_yes=
confirmNotice() {
    printf >&2 '%s\n' "$1"
    printf >&2 "%s [Y/n] ? " "$2"
    if test ${opt_yes}; then
        echo "assuming yes"
        return 0
    fi
    read ans
    [ "$ans" = n -o "$ans" = N ] && die "Missing confirmation."
    true
}

confirmWarning() {
    printf >&2 '%s\n' "$1"
    printf >&2 "%s [y/N] ? " "$2"
    if test ${opt_yes}; then
        echo "assuming yes"
        return 0
    fi
    read ans
    [ "$ans" = Y -o "$ans" = y ] || die "Missing confirmation."
    true
}

diffTreeSubmodules() {
    local range="$1"
    git diff-tree --no-renames --raw "${range}" \
    | ( grep '^:160000 160000 ' || true )
}

diffTreeNumSubmodules() {
    local range="$1"
    diffTreeSubmodules "${range}" | wc -l | tr -d ' '
}

changesSubmodules() {
    local range="$1"
    diffTreeSubmodules "${range}" \
    | while read -r aMode bMode aSha bSha op path; do
        changesPath "${path}" "${aSha:0:10}..${bSha:0:10}" "${aSha}" "${bSha}"
    done
}

changesPath() {
    local path="$1"
    local rangeHuman="$2"
    local base="$3"
    local head="$4"
    local range nCommits nSignedOff nSigs signedOffWarn sigsWarn

    range="${base}..${head}"
    nCommits=$(git -C "${path}" rev-list --count --no-merges "${range}")
    nSignedOff=$(git -C "${path}" rev-list --count --no-merges --grep '^Signed-off-by:' "${range}")
    nSigs=$(
        git -C "${path}" log --pretty='format:%G?' --no-merges "${range}" |
        ( grep G || true ) | wc -l | tr -d ' '
    )
    signedOffWarn=
    if [ ${nSignedOff} != ${nCommits} ]; then
        signedOffWarn=", SOME NOT SIGNED-OFF"
    fi
    sigsWarn=
    if [ ${nSigs} != ${nCommits} ]; then
        sigsWarn=", SOME NOT GPG-SIGNED"
    fi

    echo
    echo "in ${path} ${rangeHuman}: $(pluralize ${nCommits} commit) excluding merges, ${nSignedOff} signed-off, ${nSigs} gpg${signedOffWarn}${sigsWarn}"
    git -C "${path}" diff --stat "${range}"
    git -C "${path}" log --abbrev=10 --color=always --pretty='format:%C(auto)%h %G? %ae %d %s' "${range}"
    echo
    git -C "${path}" log --abbrev=10 --oneline --decorate --color=never --first-parent "${base}^..${base}"
}

pluralize() {
    local n=$1
    local stem=$2
    case $n in
    1)
        printf '%d %s' "${n}" "${stem}"
        ;;
    *)
        printf '%d %ss' "${n}" "${stem}"
        ;;
    esac
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

checkRemoteNotDeinit() {
    local repo
    case $# in
    0)
        repo="$(getRepoCommonName2)"
        ;;
    1)
        repo="$1"
        ;;
    esac
    if ! isValidRepoFullname "${repo}"; then
        die "Failed to determine repo name for current directory."
    fi
    path="$(repoPath "${repo}")"

    callStdhost check-not-deinit "${repo}" "${path}"
}

checkUserGitconfig() {
    err=
    if [ "$(git config --global filter.lfs.clean)" != 'git-lfs clean -- %f' ]; then
        echo 'Unexpected `filter.lfs.clean`.'
        err=t
    fi
    if [ "$(git config --global filter.lfs.smudge)" != 'git-lfs smudge --skip -- %f' ]; then
        echo 'Unexpected `filter.lfs.smudge`.'
        err=t
    fi
    if [ "$(git config --global filter.lfs.process)" != 'git-lfs filter-process --skip' ]; then
        echo 'Unexpected `filter.lfs.process`.'
        err=t
    fi

    if ! test ${err}; then
        return 0
    fi

    die 'Git LFS is incorrectly configured.  Stdtools require that your
`~/.gitconfig` LFS section is:

```
[filter "lfs"]
    clean = git-lfs clean -- %f
    smudge = git-lfs smudge --skip -- %f
    process = git-lfs filter-process --skip
    required = true
```

If you have not installed Git LFS before, you can update your `.gitconfig`
with:

```
git lfs install --skip-smudge --skip-repo
```

If you already have installed Git LFS, you need to manually update your
`.gitconfig`.
'
}

checkPython3() {
    if export | grep PYTHONPATH.*2.7; then
        echo >&2 'Warning: PYTHONPATH seems to refer to 2.7 libraries (see above), which may cause problems with Python 3.'
    fi

    if ! python3 -c "$(printf 'import %s;' ${requiredPythonModules})"; then
        die "Failed to import required Python modules.

One way to to fix this is to install the following pip packages in a default
Python 3 virtual environment and have it always activated when using Stdtools:
${pipRequirements}
On a standard Linux system, you may want to create a virtualenv on a shared
work filesystem, add a symlink in your HOME directory, and source
<venv>/bin/activate in your .bashrc in order to have virtualenv set up on all
department computers.  Do not add the venv to your HOME directly, to avoid
quota problems.
"
    fi
}

checkGitLfsTransferToolsStandalone() {
    err=
    if ! haveExpectedLfsStandaloneTransferSsh; then
        echo "Wrong git-lfs-standalonetransfer-ssh version, expected ${expectedLfsStandaloneTransferSshSemver}."
        err=t
    fi

    if ! test ${err}; then
        return 0
    fi

    die 'Wrong Git LFS Transfer tool versions.

To fix this, follow the install instructions in `git-lfs-transfer/README.md`.
'
}

haveExpectedLfsStandaloneTransferSsh() {
    git lfs-standalonetransfer-ssh --version \
    | grep -q "^git-lfs-standalonetransfer-ssh-${expectedLfsStandaloneTransferSshSemver}"
}

lfsVersionMajor=
lfsVersionMinor=
lfsVersionPatch=

initLfsVersion() {
    if [ -n "${lfsVersionMajor}" ]; then
        return
    fi

    local v
    if ! v="$(git lfs version)"; then
        die 'Failed to run `git lfs version`.'
    fi
    if ! [[ "${v}" =~ ^git-lfs/[0-9]+\.[0-9]+\..*$ ]]; then
        die 'Failed to parse Git LFS version.'
    fi
    v=${v#git-lfs/}  # Strip prefix.
    v=${v%% *}  # Strip suffix.
    lfsVersionMajor=${v%%.*}
    v=${v#*.}  # Strip from start to first dot.
    lfsVersionMinor=${v%%.*}
    v=${v#*.}  # Strip from start to first dot.
    lfsVersionPatch=${v}
}

# LFS >= 2.3.1.
lfsHasStandaloneTransfer() {
    initLfsVersion
    local M=${lfsVersionMajor}
    local m=${lfsVersionMinor}
    local p=${lfsVersionPatch}
    if [ $M -ge 3 ]; then
        return 0
    fi
    if [ $M -eq 2 ] && [ $m -ge 4 ]; then
        return 0
    fi
    if [ $M -eq 2 ] && [ $m -eq 3 ] && [ $p -ge 1 ]; then
        return 0
    fi
    return 1
}
