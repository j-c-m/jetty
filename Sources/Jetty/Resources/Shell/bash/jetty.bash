# Jetty shell inject: OSC 7 cwd + OSC 133 A/C/D. Loaded via ENV + bash --posix.

if [[ $- != *i* ]]; then
  builtin return
fi

if [[ -n ${JETTY_BASH_INJECT-} ]]; then
  builtin unset ENV JETTY_BASH_INJECT
  if [[ -n ${JETTY_BASH_ENV-} ]]; then
    builtin export ENV="$JETTY_BASH_ENV"
    builtin unset JETTY_BASH_ENV
  fi
  builtin set +o posix
  builtin shopt -u inherit_errexit 2>/dev/null
  if builtin shopt -q login_shell; then
    [[ -r /etc/profile ]] && builtin source /etc/profile
    for _jetty_rc in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile"; do
      if [[ -r $_jetty_rc ]]; then
        builtin source "$_jetty_rc"
        break
      fi
    done
    builtin unset _jetty_rc
  else
    [[ -r $HOME/.bashrc ]] && builtin source "$HOME/.bashrc"
  fi
fi

_jetty_executing=
_jetty_cwd=

_jetty_precmd() {
  builtin local ret=$?
  if [[ -n $_jetty_executing ]]; then
    builtin printf '\e]133;D;%s\a' "$ret"
  fi
  builtin printf '\e]133;A\a'
  if [[ $_jetty_cwd != "$PWD" ]]; then
    _jetty_cwd=$PWD
    builtin printf '\e]7;kitty-shell-cwd://%s%s\a' "${HOSTNAME-}" "$PWD"
  fi
  _jetty_executing=0
}

_jetty_preexec() {
  builtin printf '\e]133;C\a'
  _jetty_executing=1
}

if ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 4))); then
  _jetty_hook() {
    _jetty_precmd
    if [[ $PS0 != *_jetty_preexec* ]]; then
      PS0='$( _jetty_preexec >/dev/tty )'"$PS0"
    fi
  }

  # Keep PROMPT_COMMAND's type. Bash 5.1+ uses an array (starship).
  if [[ ";${PROMPT_COMMAND[*]:-};" != *";_jetty_hook 2>/dev/null;"* ]]; then
    if [[ -z "${PROMPT_COMMAND[*]}" ]]; then
      if ((BASH_VERSINFO[0] > 5 || (BASH_VERSINFO[0] == 5 && BASH_VERSINFO[1] >= 1))); then
        PROMPT_COMMAND=("_jetty_hook 2>/dev/null")
      else
        PROMPT_COMMAND="_jetty_hook 2>/dev/null"
      fi
    elif [[ $(builtin declare -p PROMPT_COMMAND 2>/dev/null) == "declare -a "* ]]; then
      PROMPT_COMMAND+=("_jetty_hook 2>/dev/null")
    else
      [[ "${PROMPT_COMMAND}" =~ (\;[[:space:]]*|$'\n')$ ]] || PROMPT_COMMAND+=";"
      PROMPT_COMMAND+="_jetty_hook 2>/dev/null"
    fi
  fi
fi
