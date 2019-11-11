# `__stdtools2_ps1` is used like `__git_ps1`.  For example include the following
# in your bash PS1 to get a warning if you are inside a retired or sealed repo:
#
#     __stdtools2_ps1 " **%s**"
#
__stdtools2_ps1() {
    local fmt="$1"
    if [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" != "true" ]; then
        return
    fi
    local files=":/README.md :/index.md :/version.inc.md"
    git grep -q '^THIS.*DEPRECATED' origin/master -- ${files} 2>/dev/null \
        && printf "${fmt}" 'DEPRECATED'
    git grep -q '^THIS.*RETIRED' origin/master -- ${files} 2>/dev/null \
        && printf "${fmt}" 'RETIRED'
    git grep -q '^THIS.*FROZEN' origin/master -- ${files} 2>/dev/null \
        && printf "${fmt}" 'FROZEN'
}

_stdtools2() {
    local cur prev
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"

    # Complete first arg to cmd.
    if (( ${COMP_CWORD} == 1 )); then
        local cmds='
            build
            clone
            clone-subrepo
            doctor
            html-to-pdf
            init-hooks
            init-project
            init-toolsconfig
            init-year
            publish-intern
            publish-merge-to-master
            publish-to-master
            pull
            show
        '
        COMPREPLY=( $(compgen -W "${cmds}" -- ${cur}) )
        return 0
    fi

    subcmd="${COMP_WORDS[1]}"
    case "${subcmd}" in
    build)
        case "${cur}" in
        -*)
            local opts='
                -h --help
                -v --verbose
                -P --parallel
                --tasks
                --auto-fetch --no-auto-fetch
                --auto-lfs-ssh --no-auto-lfs-ssh
                --allow-dirty
            '
            COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
            return 0
            ;;
        esac
        ;;
    clone)
        case "${cur}" in
        -*)
            local opts='
                -h --help
                --create
                --npdlink --no-npdlink
                --pndlink --no-pndlink
                --maintainerid
                --year --timeless
                --force
                --lfs --no-lfs
                --toolsconfig --no-toolsconfig
                --subrepos --no-subrepos
                --subrepo
            '
            COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
            return 0
            ;;
        esac
        ;;
    clone-subrepo)
        case "${cur}" in
        -*)
            local opts='
                -h --help
            '
            COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
            return 0
            ;;
        esac
        ;;
    doctor)
        case "${cur}" in
        -*)
            local opts='
                -h --help
                --fix
            '
            COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
            return 0
            ;;
        esac
        ;;
    html-to-pdf)
        case "${cur}" in
        -*)
            local opts='
                -h --help
                --portrait --landscape
            '
            COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
            return 0
            ;;
        esac
        ;;
    init-project)
        case "${cur}" in
        -*)
            local opts='
                -h --help
                --maintainerid
            '
            COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
            return 0
            ;;
        esac
        ;;
    init-toolsconfig)
        case "${cur}" in
        -*)
            local opts='
                -h --help
                -f --force
            '
            COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
            return 0
            ;;
        esac
        ;;
    init-year)
        case "${cur}" in
        -*)
            local opts='
                -h --help
                -y --yes
                --maintainerid
            '
            COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
            return 0
            ;;
        esac
        ;;
    publish-intern)
        case "${cur}" in
        -*)
            local opts='
                -h --help
                -y --yes
                --no-master-check
                --no-recurse-submodules-check
            '
            COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
            return 0
            ;;
        esac
        ;;
    publish-merge-to-master)
        case "${cur}" in
        -*)
            local opts='
                -h --help
                -y --yes
                --skip-additional
            '
            COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
            return 0
            ;;
        esac
        ;;
    publish-to-master)
        case "${cur}" in
        -*)
            local opts='
                -h --help
                -f --force
                -y --yes
                --no-master-check
                --no-recurse-submodules-check
                --skip-additional
            '
            COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
            return 0
            ;;
        esac
        ;;
    show)
        case "${cur}" in
        -*)
            local opts='
                -h
                --help
                --files --no-files
                -n
                --ls --no-ls
            '
            COMPREPLY=( $(compgen -W "${opts}" -- ${cur}) )
            return 0
            ;;
        esac
        ;;
    esac

    # Default to file completion.
    COMPREPLY=( $(compgen -f -- ${cur}) )
    return 0
}

complete -F _stdtools2 stdtools2
