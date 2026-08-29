# Jetty OSC 7 cwd + OSC 133 A/C/D. Pop our XDG data dir first.

if set -q JETTY_SHELL_XDG_DIR; and set -q XDG_DATA_DIRS
    set _jetty_dirs (string split : -- $XDG_DATA_DIRS)
    set _jetty_keep
    for _jetty_d in $_jetty_dirs
        if test "$_jetty_d" != "$JETTY_SHELL_XDG_DIR"
            set -a _jetty_keep $_jetty_d
        end
    end
    if set -q _jetty_keep[1]
        set -gx XDG_DATA_DIRS (string join : -- $_jetty_keep)
    else
        set -e XDG_DATA_DIRS
    end
    set -e JETTY_SHELL_XDG_DIR
    set -e _jetty_dirs _jetty_keep _jetty_d
end

status is-interactive; or return

# Other vendor_conf.d / prompt scripts run first. Install OSC 133 last.
function __jetty_setup --on-event fish_prompt
    functions -e __jetty_setup

    function __jetty_prompt --on-event fish_prompt --on-event fish_posterror
        if test "$__jetty_state" != prompt
            echo -en "\e]133;D\a"
        end
        set -g __jetty_state prompt
        echo -en "\e]133;A\a"
    end

    function __jetty_preexec --on-event fish_preexec
        set -g __jetty_state exec
        echo -en "\e]133;C\a"
    end

    function __jetty_postexec --on-event fish_postexec
        set -g __jetty_state done
        echo -en "\e]133;D;$status\a"
    end

    function __jetty_cwd --on-variable PWD
        printf '\e]7;file://%s%s\a' $hostname (string escape --style=url -- $PWD)
    end

    __jetty_prompt
    __jetty_cwd
end
