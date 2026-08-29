# Jetty OSC 7 cwd + OSC 133 A/C/D for interactive zsh.
# First A waits for the first precmd (after .zshrc).

[[ -o interactive ]] || return 0
(( $+_jetty_loaded )) && return 0
typeset -gi _jetty_loaded=1
typeset -gi _jetty_cmd=0

_jetty_precmd() {
  local ret=$?
  builtin typeset -ag precmd_functions
  if [[ ${precmd_functions[-1]} != _jetty_precmd ]]; then
    precmd_functions=(${precmd_functions:#_jetty_precmd} _jetty_precmd)
  fi
  if (( _jetty_cmd )); then
    print -n "\e]133;D;$ret\a"
    _jetty_cmd=0
  fi
  print -n "\e]133;A\a"
  print -n "\e]7;kitty-shell-cwd://${HOST}${PWD}\a"
}

_jetty_preexec() {
  print -n "\e]133;C\a"
  _jetty_cmd=1
}

_jetty_deferred_init() {
  builtin typeset -ag precmd_functions preexec_functions
  precmd_functions=(${precmd_functions:#_jetty_deferred_init} _jetty_precmd)
  preexec_functions+=(_jetty_preexec)
  _jetty_precmd
}

builtin typeset -ag precmd_functions
precmd_functions+=(_jetty_deferred_init)
