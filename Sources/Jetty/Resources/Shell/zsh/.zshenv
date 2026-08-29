# Jetty ZDOTDIR wrapper. Restores user ZDOTDIR, then loads OSC 7/133.
# Aliases may be on. Quote and use builtin.

if [[ -n "${JETTY_ZSH_ZDOTDIR+X}" ]]; then
  'builtin' 'export' ZDOTDIR="$JETTY_ZSH_ZDOTDIR"
  'builtin' 'unset' 'JETTY_ZSH_ZDOTDIR'
else
  'builtin' 'unset' 'ZDOTDIR'
fi

# User `return` in ~/.zshenv must not skip inject.
{
  'builtin' 'typeset' _jetty_file=${ZDOTDIR-$HOME}"/.zshenv"
  [[ ! -r "$_jetty_file" ]] || 'builtin' 'source' '--' "$_jetty_file"
} always {
  if [[ -o 'interactive' ]]; then
    'builtin' 'typeset' _jetty_file="${${(%):-%x}:A:h}"/jetty.zsh
    if [[ -r "$_jetty_file" ]]; then
      'builtin' 'source' '--' "$_jetty_file"
    fi
  fi
  'builtin' 'unset' '_jetty_file'
}
