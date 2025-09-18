# bash completion for gittrail
_gittrail() {
  local cur prev
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD-1]}"

  case "$prev" in
    --username|--out|--since|--until) return ;;
  esac

  COMPREPLY=( $(compgen -W "--reposcan --username --out --default-branch-only --since --until --version --about -h --help" -- "$cur") )
}
complete -F _gittrail gittrail
