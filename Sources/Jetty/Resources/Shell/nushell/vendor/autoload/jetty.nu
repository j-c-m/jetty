# Jetty OSC 7 cwd + OSC 133 A/C/D. Nushell vendor autoload.

if "JETTY_SHELL_XDG_DIR" in $env {
  if "XDG_DATA_DIRS" in $env {
    $env.XDG_DATA_DIRS = ($env.XDG_DATA_DIRS | str replace $"($env.JETTY_SHELL_XDG_DIR):" "")
  }
  hide-env JETTY_SHELL_XDG_DIR
}

def jetty-osc7 [] {
  let host = (try { sys host | get hostname } catch { "" })
  print -n $"\e]7;kitty-shell-cwd://($host)($env.PWD)\e\\"
}

# Keep other hook keys (display_output).
$env.config = ($env.config | default {} | upsert hooks (
  ($env.config.hooks? | default {})
  | upsert pre_prompt (
      $env.config.hooks?.pre_prompt? | default [] | append {
        print -n $"\e]133;D;($env.LAST_EXIT_CODE? | default 0)\e\\"
        print -n "\e]133;A\e\\"
        jetty-osc7
      }
    )
  | upsert pre_execution (
      $env.config.hooks?.pre_execution? | default [] | append {
        print -n "\e]133;C\e\\"
      }
    )
))
