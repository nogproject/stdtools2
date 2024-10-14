#!/bin/bash

case $(uname) in
MINGW*)
    cat >&2 <<EOF
fatal: stdtools does not support MSYS Git anymore.  Use Ubuntu on Windows.
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

# Parameters that control `foreachAlternateCandidate`.
#
# `timelessYears` contains a few recent year.
# Update in 2025 to '2022 2023 2024 2025'.
timelessYears='2021 2022 2023 2024'
# `activeCiRepos` lists the previous and the current CI repo.  CI is not
# supported by stdtools2.
activeCiRepos=

# `opt_global_skip_*` can be used to globally disable LFS code paths.  The
# mechanism will be incrementally implement over time.
opt_global_skip_lfs_ssh=

# `cfg_stdtoolsYear()` prints the year in which repos may be created.
cfg_stdtoolsYear() {
    local y
    if ! y=$(git config stdtools.currentYear); then
        y=$(date +%Y)
        die "Configure the current year with: git config --global stdtools.currentYear ${y}"
    fi
    case ${y} in
    2019|2020|2021|2022|2023|2024)
        true
        ;;
    *)
        die "Invalid stdtools.currentYear ${y}."
        ;;
    esac
    printf '%s' "${y}"
}

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

cfg_defaultmaintainerid() {
    local id

    # Use environment variable if set.
    id="${STD_DEFAULT_MAINTAINER:-}"
    if [ -n "${id}" ]; then
        printf '%s' "${id}"
        return
    fi

    # Use Git config if set.
    if git config stdtools.defaultMaintainer; then
        return
    fi

    die 'Missing default maintainer id; set it with `git config --global stdtools.defaultMaintainer <user>`.'
}

cfg_toolsconfig() {
    echo '.toolsconfig'
}

cfg_product() {
    echo 'product'
}

cfg_releases() {
    echo 'releases'
}

cfg_latest() {
    echo 'latest'
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

isActiveLfs() {
    isActiveLfsSsh
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

# foreachBuild <toolsconfig> <applyfn> <format-string>
#
# Select files as specified in <toolsconfig> and call <applyfn> with the build
# command.  Report each build section as printf '<format-string>'.
foreachBuild() {
    local toolsconfig=$1
    local apply=$2
    local fmt=$3
    while IFS= read -r build; do
        [ -n "${build}" ] || continue
        printf "${fmt}" "${build}"
        if ! cmd=$(git config --file "${toolsconfig}" build."${build}".cmd); then
            cmd=$build
        fi
        selectFilesFor build "${build}" | processFiles $apply $cmd
    done <<<"$(
        git config --file "${toolsconfig}" --get-regex 'build\.' |
        cut -d . -f 2 |
        uniq
    )"
}

# selectFilesFor <section> <subsection>
#
# Select lines on <stdin> that match <section>.<subsection>.[include|exclude]
# rules in .toolsconfig.
selectFilesFromStdinFor() {
    local section=$1
    local subsection=$2
    local rules
    local cfg
    local nl=$'\n'

    # First check whether file exists; then assume that `git config` error
    # below means that the section is not configured.
    [ -e '.toolsconfig' ] || die 'Missing `.toolsconfig`.'

    # /releases/* is explicitly excluded, because files in the submodule
    # releases are tracked in git.  Files in product need not be explicitly
    # excluded, because they are never tracked in git and will not be listed by
    # lsFilesWithSubmodules.
    rules="exclude /releases/*${nl}"

    # Exclude `*` if <section>.<subsection> is not in `.toolsconfig`.
    if cfg=$(git config --file .toolsconfig --get-regex \
             "${section}"'\.'"${subsection}"'\.(include|exclude)'); then
        rules="${rules}$(
            cut -d '.' -f 3- <<<"${cfg}"
        )${nl}"
    else
        rules=$'exclude *\n'
    fi
    selectWithRules "$rules"
}

selectFilesFor() {
    lsFilesWithSubmodules |
    selectFilesFromStdinFor "$@"
}

selectWithRules() {
    local rules="$1"
    local path ruletype pattern
    while IFS= read -r path; do
        [ -n "${path}" ] || continue
        while IFS=' ' read -r ruletype pattern; do
            [ -n "${ruletype}" ] || continue
            if [ "${pattern:0:1}" != '/' ] && [ "${pattern:0:1}" != '*' ]; then
                pattern="*/${pattern}"
            fi
            case "/${path}" in
                $pattern)
                    # match, evaluate ruletype below.
                    ;;
                *)
                    # no match, continue with next rule.
                    continue
                    ;;
            esac
            case "${ruletype}" in
                include)
                    printf '%s\n' "${path}"
                    ;;
                exclude)
                    ;;
                *)
                    die "Invalid ruletype ${ruletype}."
                    ;;
            esac
            break
        done <<<"$rules"
    done
}

# usage: lsFilesWithSubmodules
#
# Print all files in repo and submodules (recursively) to stdout.
lsFilesWithSubmodules() {
    # Select files from git ls-files's output, because ls-files prints
    # submodules, although they are directories.
    ( git ls-files && lsFilesInSubmodulesRecursive ) \
    | selectRegularFiles
}

lsFilesInSubmodulesRecursive() {
    case $(uname) in
    MINGW*)
        local wd="$(pwd -W)"
        ;;
    *)
        local wd="$(pwd -P)"
        ;;
    esac

    git submodule --quiet foreach --recursive \
        'git ls-files | sed -e "s@^@$toplevel/$path/@"' \
    | sed -e 's@^\([a-z]\):@/\1@' \
    | sed -e "s@^${wd}/@@"
}

lsActiveSubmodulesRecursive() {
    git submodule foreach --recursive 'true' | cut -d "'" -f 2
}

lsLfsSubmodulesRecursiveIncludingSuper() {
    if hasLfsObjects; then
        echo .
    fi

    lsActiveSubmodulesRecursive \
    | while IFS= read -r path; do
        if ( cd "${path}" && hasLfsObjects ); then
            printf '%s\n' "${path}"
        fi
    done
}

selectRegularFiles() {
    while IFS= read -r path; do
        [ -z "${path}" ] && continue
        [ -f "${path}" ] || continue
        printf '%s\n' "${path}"
    done
}

# usage: processFiles <cmd>...
#
# Call <cmd> for each line on stdin.
processFiles() {
    local src
    while IFS= read -r src; do
        [ -n "${src}" ] || continue
        "$@" "$src"
    done
}

# usage: getVersion
#
# Create version key from closest tagged or non-release commit.  Release
# commits are commits that touch only 'releases'.  They are ignored to avoid
# spurious version changes after creating a release.
#
# version format: `<tag>` or `<committer-ISO-date>-g<sha1-6digits>`; with
# suffix `-dirty-<unix-seconds>` if the working copy is dirty.
#
# The committer date indicates when the commit was touched the last time.  The
# author date might be older, because it is kept when cherry-picking.
getVersion() {
    local c
    c=$(findVersioningCommit)
    if gitStatusIsClean; then
        git describe --exact-match ${c} 2> /dev/null ||
        git show --abbrev=6 -s --pretty='%cd-g%h' --date=short ${c}
    else
        git show --abbrev=6 -s --pretty="%cd-g%h-dirty-$(date +%s)" --date=short ${c}
    fi
}

# Like getVersion, but appends the detailed version info for tagged versions.
getVersionHuman() {
    local c tag
    c=$(findVersioningCommit)
    if gitStatusIsClean; then
        if tag=$(git describe --exact-match ${c} 2>/dev/null); then
            git show --abbrev=6 -s --pretty="${tag} (%cd-g%h)" --date=short ${c}
        else
            git show --abbrev=6 -s --pretty="%cd-g%h" --date=short ${c}
        fi
    else
        git show --abbrev=6 -s --pretty="%cd-g%h-dirty-$(date +%s)" --date=short ${c}
    fi
}

getVersionTarDate() {
    local c
    c=$(findVersioningCommit)
    git show -s --pretty=format:%cd --date=iso ${c} | cut -d ' ' -f 1,2
}

# Walk along the first parent to a commit that is either tagged or does touch
# more than 'releases'.
findVersioningCommit() {
    local c parent
    c=$(git rev-parse HEAD)
    while parent=$(git rev-parse ${c}^) && isReleaseCommit ${c} &&
        ! isTaggedCommit ${c}; do
        c=${parent}
    done
    printf '%s' ${c}
}

isReleaseCommit() {
    local c=$1
    isNonMergeCommit $c &&
    [ "$(git diff-tree ${c}^..${c} --name-only)" = "releases" ]
}

isNonMergeCommit() {
    [ $(nParents $1) = 1 ]
}

# Mac OS X's wc pads with whitespace.  Use sed to strip it to avoid potential
# confusion of the callers.
nParents() {
    git show -s --format=%P $1 | wc -w | sed -e 's/ *//g'
}

isTaggedCommit() {
    git describe --exact-match >/dev/null 2>/dev/null $1
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
        [a-zA-Z0-9-]+ _ [a-zA-Z0-9-]+ _ (201[6-9]|202[0-4]) (-(0[1-9]|1[0-2]))?
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

isValidDate() {
    local ergx='^(201[3-9]|202[0-4])(-(0[1-9]|1[0-2]))?$'
    egrep -q "${ergx}" <<<"$1"
}

validateProjectName() {
    isWellformedProjectName "$1" ||
        die "Project name '$1' is malformed."
}

isWellformedProjectName() {
    local ergx='^[a-zA-Z0-9-]+$'
    egrep -q "${ergx}" <<<"$1"
}

# fooproject-barrepo
ergxStd2FullnameTimeless='
    ^
    [a-zA-Z][a-zA-Z0-9]+
    -
    [a-zA-Z][a-zA-Z0-9]+
    $
'
ergxStd2FullnameTimeless="$(tr -d ' \n' <<<"${ergxStd2FullnameTimeless}")"

# fooproject-barrepo-2021
ergxStd2FullnameYear='
    ^
    [a-zA-Z][a-zA-Z0-9]+
    -
    [a-zA-Z][a-zA-Z0-9]+
    -
    202[1-4]
    $
'
ergxStd2FullnameYear="$(tr -d ' \n' <<<"${ergxStd2FullnameYear}")"

# fooproject-barrepo-xxxx
ergxStd2FullnameAnyYear='
    ^
    [a-zA-Z][a-zA-Z0-9]+
    -
    [a-zA-Z][a-zA-Z0-9]+
    -
    [0-9][0-9][0-9][0-9]
    $
'
ergxStd2FullnameAnyYear="$(tr -d ' \n' <<<"${ergxStd2FullnameAnyYear}")"

# fooproject-barrepo-2021-01
ergxStd2FullnameMonth='
    ^
    [a-zA-Z][a-zA-Z0-9]+
    -
    [a-zA-Z][a-zA-Z0-9]+
    -
    202[1-4]-(0[1-9]|1[0-2])
    $
'
ergxStd2FullnameMonth="$(tr -d ' \n' <<<"${ergxStd2FullnameMonth}")"

# fooproject-barrepo-xxxx-xx
ergxStd2FullnameAnyMonth='
    ^
    [a-zA-Z][a-zA-Z0-9]+
    -
    [a-zA-Z][a-zA-Z0-9]+
    -
    [0-9][0-9][0-9][1-1]-[0-9][0-9]
    $
'
ergxStd2FullnameAnyMonth="$(tr -d ' \n' <<<"${ergxStd2FullnameAnyMonth}")"

isStd2FullnameTimeless() {
    egrep -q "${ergxStd2FullnameTimeless}" <<<"$1" \
    && ! egrep -q "${ergxStd2FullnameAnyYear}" <<<"$1" \
    && ! egrep -q "${ergxStd2FullnameAnyMonth}" <<<"$1"
}

isStd2FullnameYear() {
    egrep -q "${ergxStd2FullnameYear}" <<<"$1"
}

isStd2FullnameMonth() {
    egrep -q "${ergxStd2FullnameMonth}" <<<"$1"
}

isStd2Fullname() {
    isStd2FullnameTimeless "$1" ||
    isStd2FullnameYear "$1" ||
    isStd2FullnameMonth "$1"
}

shortnameFromStd2Fullname() {
    local fullname="$1"
    local project year name
    if isStd2FullnameTimeless "${fullname}"; then
        sed -e 's/^[^-]*//' <<<"${fullname}"
    elif isStd2FullnameYear "${fullname}"; then
        sed -e 's/^[^-]*//' -e 's/-[0-9][0-9][0-9][0-9]$//' <<<"${fullname}"
    elif isStd2FullnameMonth "${fullname}"; then
        sed -e 's/^[^-]*//' -e 's/-[0-9][0-9][0-9][0-9]-[0-9][0-9]$//' <<<"${fullname}"
    fi
}

split() {
    sed -e "s@$1@ @g" <<<"$2"
}

countSlashes() {
    # Delete all non-slashes; then return length of string.
    local str="$1"
    str=$(sed -e 's/[^/]*//g' <<<"${str}")
    printf '%d' "${#str}"
}

# `configLfsAlternates` sets silo.alternate in releases to point to all
# submodules with silo except releases itself.
configLfsAlternates() {
    local releases subdir
    releases=$(cfg_releases)
    if ! isGitWorktreeRoot "${releases}"; then
        return 0
    fi
    lsLfsSubmodulesRecursiveIncludingSuper \
    | ( grep -v "^${releases}$" || true ) | (
        cd "${releases}" &&
        while IFS= read -r subdir; do
            [ -z "${subdir}" ] && continue
            p="../${subdir}"
            git config lfs.weakalternate "${p}" "^$(egrepEscapePath "${p}")$"
        done
    )
}

# `isGitWorktreeRoot <dir>` tests whether `<dir>` is the root dir of a git
# work tree.
isGitWorktreeRoot() {
    local prefix
    [ -d "$1" ] &&
    prefix="$(cd "$1" && git rev-parse --show-prefix 2>/dev/null)" &&
    [ -z "${prefix}" ]
}

# `egrepEscapePath <string>` quotes special regex chars that are common in
# paths such that egrep matches them without special meaning.
egrepEscapePath() {
    sed -e 's/\./[.]/g' <<< "$1"
}

# parseModelines <cmd> <cb>
#
# A modeline has format:
#
#     <space or beginning of line><cmd>:<option>...:<ignored>
#
# Several <option> can be separated by <space> or ':'.
# <cb> <option>... is called for each modeline in stdin.
parseModelines() {
    local cmd="$1"
    local cb="$2"
    while IFS= read -r args; do
        [ -n "${args}" ] || continue
        ${cb} $args
    done <<<"$(grepModelines ${cmd})"
}

grepModelines() {
    local name="$1"
    egrep "(^| )${name}:.*:" \
    | sed -e "s/^.*${name}://" \
    | sed -e 's/:[^:]*$//' \
    | sed -e 's/:/ /g'
}

cfg_maintainerid() {
    git config tools.maintainerid \
    || ( detectMaintainerId ) \
    || die "Failed to determine 'tools.maintainerid'.  You may use git config to explicitly set it."
}

# `detectMaintainerId` determines the account that owns the remote workspace.
detectMaintainerId() {
    local url
    local masterhost masterpath
    url="$(parseRemoteURL)" || die 'Failed to parse remote URL.'
    IFS=: read -r masterhost masterpath <<<"${url}"

    rpcGetId() {
        exec_ssh ${masterhost} bash -s <<EOF
set -o errexit -o nounset -o pipefail -o noglob
stat --format=%U $(printf '%q' "${masterpath}")
exit ${cfg_exit_ok}
EOF
    }
    if ! rpcGetId; then
        die "Failed to determine owner of remote path."
    fi
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

hasLfsObjects() {
    [ -d "$(git rev-parse --git-path 'lfs/objects')" ]
}

linkCount() {
    ls -l -- "$1" | sed -e 's/  */ /' | cut -d ' ' -f 2
}

isHardLink() {
    [ "$(linkCount "$1")" -gt 1 ]
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

# `callStdhostAsUser <user> <cmd> <args>...` is like `callStdhost <cmd>` but
# SSH connects as `<user>`.
callStdhostAsUser() {
    local user=$1
    local cmd=$2
    shift 2

    local stdhost
    if ! stdhost="$(cfg_stdhost)"; then
        return 1
    fi

    local conn="${user}@${stdhost}"
    manageKeys "${conn}"
    (
        tr -d '\r' <"${toolsdir}/lib/lib.sh" &&
        genprgDecodeArgs &&
        genprgOpts &&
        genprgStdhostEnv &&
        genprgSameGitAuthorAtRemote &&
        genprgSameGitCommitterAsUser "${user}" &&
        tr -d '\r' <"${toolsdir}/lib/call/${cmd}"
    ) | exec_ssh "${conn}" bash -s $(encodeArgs "$@")
}

# Try to add an ssh key when needed: if a user is explicitly given for the
# connection and an ssh-agent is running and there is a key
# `<initials>-as-<login>`, check whether the agent has the key.
manageKeys() {
    IFS='@' read -r user host <<<"$1"
    [ -n "${host}" ] || return 0  # no user.
    [ -n "${SSH_AUTH_SOCK:-}" ] || return 0  # no ssh-agent.
    if [ "${user}" = "${USER}" ]; then
        return 0  # Don't manage keys for the user itself.
    fi
    local initials="$(git config user.initials)"
    local keyname="${initials}-as-${user}"
    local retries=3
    while let retries-- ; do
        if ssh-add -l | grep -q -F "${keyname}"; then
            return 0  # ssh-agent has key.
        fi
        local keyfile="${HOME}/.ssh/${keyname}"
        if [ -e "${keyfile}" ]; then
            local lifetime=3600
            echo "Adding ssh key ${keyname}..." >&2
            ssh-add -t ${lifetime} "${keyfile}"
        else
            echo
            echo "Expecting ssh key ${keyname}.  Press any key to continue."
            echo 'See "how to manage ssh keys?" in stdtools userdoc.'
            read _
        fi
    done
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

# `stdlock <fd>` flocks the file descriptor <fd>, which must have been opened
# on the directory that represents the lock.  We determined the lock dir with
# `$(stdlockdir)` by convention, which prints the path to the toplevel of a git
# work tree or the current directory if it is outside a git work tree.  See
# 'man flock(1) EXAMPLES' how to lock a block of shell code.
stdlock() {
    local fd="$1"
    if ! flock -n ${fd}; then
        local lockdir
        lockdir="$(cd "$(git rev-parse --git-dir)" && pwd)"
        echo "Waiting for stdtools lock '${lockdir}' ..."
        flock ${fd}
    fi
}

stdlockdir() {
    if isInsideWorkTree; then
        git rev-parse --show-toplevel
    else
        echo '.'
    fi
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

# `gitNoLfsSmudge` can be used in place of `git` to ensure that Git LFS smudge
# is disabled.
gitNoLfsSmudge() {
    git -c 'filter.lfs.clean=git-lfs clean -- %f' \
        -c 'filter.lfs.smudge=' \
        -c 'filter.lfs.process=' \
        -c 'filter.lfs.required=false' \
        "$@"
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

# Try to determine previous repo generations by parsing version.inc.md.  Take
# the paragraph starting from 'Previous generations'.  Convert backticks to
# newlines, so that full repo names are on separate lines.  Then grep for them.
previousRepoGenerations() {
    local versioninc='version.inc.md'
    [ -f "${versioninc}" ] || return 0
    sed -n '/^Previous generations/,/^ *$/p' "${versioninc}" |
    tr '`' '\n' |
    ( grepRepoFullname || true )
}

# Heuristic to find potential alternates: Walk from the current directory
# towards the root and check at each level whether a subdir `<year>/<repo>`
# exits.  Don't walk too far in order to stay on the same file system so that
# hardlinks work.  Avoid alternates to self.
#
# Based on the assumption that copying is expensive, we add many alternates in
# order to increase the chance that a hardlink can be used.  Specifically,
# alternates tries:
#
#  - the current ci repo.
#  - previous repo generations.
#  - releases of the super repo.
#
foreachAlternateCandidate() {
    local callback="$1"
    local subPath="$2"
    shift 2
    local year superRepoYear repo dir device
    if [ "${subPath}" == '.' ]; then
        shift  # Skip self
    fi
    repo=$(getRepoCommonName2)
    case "${repo}" in
    unknown)
        return
        ;;
    */*)
        return
        ;;
    esac
    read _ _ _ year _ <<<"$(parseRepoName ${repo})"
    dir="$(pwd -P)"
    device=$(statDevice "${dir}")
    while [ "${dir}" != '/' ] \
        && dir="$(dirname "${dir}")" \
        && [ "$(statDevice "${dir}")" = "${device}" ];
    do
        echo "Considering repos relative to '${dir}'."
        if [ -n "${year}" ]; then
            ${callback} "${dir}/${year}/${repo}"
            for ci in ${activeCiRepos}; do
                ${callback} "${dir}/${ci}/${year}/${repo}"
            done
        else
            for y in ${timelessYears}; do
                ${callback} "${dir}/${y}/${repo}"
                for ci in ${activeCiRepos}; do
                    ${callback} "${dir}/${ci}/${y}/${repo}"
                done
            done
        fi
        if [ "${subPath}" == '.' ]; then
            for superRepo in "$@"; do
                read _ _ _ superRepoYear _ <<<"$(parseRepoName ${superRepo})"
                if [ -n "${superRepoYear}" ]; then
                    ${callback} "${dir}/${superRepoYear}/${superRepo}"
                    ${callback} "${dir}/${superRepoYear}/${superRepo}/releases"
                    for ci in ${activeCiRepos}; do
                        ${callback} "${dir}/${ci}/${superRepoYear}/${superRepo}"
                        ${callback} "${dir}/${ci}/${superRepoYear}/${superRepo}/releases"
                    done
                else
                    for y in ${timelessYears}; do
                        ${callback} "${dir}/${y}/${superRepo}"
                        ${callback} "${dir}/${y}/${superRepo}/releases"
                        for ci in ${activeCiRepos}; do
                            ${callback} "${dir}/${ci}/${y}/${superRepo}"
                            ${callback} "${dir}/${ci}/${y}/${superRepo}/releases"
                        done
                    done
                fi
            done
        else
            for superRepo in "$@"; do
                read _ _ _ superRepoYear _ <<<"$(parseRepoName ${superRepo})"
                if [ -n "${superRepoYear}" ]; then
                    ${callback} "${dir}/${superRepoYear}/${superRepo}/${subPath}"
                    ${callback} "${dir}/${superRepoYear}/${superRepo}/releases"
                    for ci in ${activeCiRepos}; do
                        ${callback} "${dir}/${ci}/${superRepoYear}/${superRepo}/${subPath}"
                        ${callback} "${dir}/${ci}/${superRepoYear}/${superRepo}/releases"
                    done
                else
                    for y in ${timelessYears}; do
                        ${callback} "${dir}/${y}/${superRepo}/${subPath}"
                        ${callback} "${dir}/${y}/${superRepo}/releases"
                        for ci in ${activeCiRepos}; do
                            ${callback} "${dir}/${ci}/${y}/${superRepo}/${subPath}"
                            ${callback} "${dir}/${ci}/${y}/${superRepo}/releases"
                        done
                    done
                fi
            done
        fi
    done
}

# `statDevice <dir>` prints a device id that can be used to determine whether
# hard links can be used between two directories.
#
# A path prefix is used as a fallback, since I(spr) am unsure how stat works on
# Windows.  The prefix should correctly detect the same device under the
# assumption that paths on the same Windows drive can use hard links and the
# Windows drive is represented in the first part of the path.
#
# - path c:/foo/bar -> id c:/
# - path /c/foo/bar -> id /c/
#
case $(uname -s) in
Linux)
    statDevice() {
        stat -c '%d' "$1"
    }
    ;;
Darwin)
    statDevice() {
        stat -f '%d' "$1"
    }
    ;;
*)
    statDevice() {
        ( cd "${1}" && pwd -P | sed -e 's@^\(/*[^/]*/\).*@\1@' )
    }
    ;;
esac

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
