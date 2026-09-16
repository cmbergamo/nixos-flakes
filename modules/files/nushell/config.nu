# Nushell gerenciado pelo flake (modules/files/nushell/config.nu)
# Padrão universal para cmb-nix e dstk-server.

# Proteção de TERM para sessões SSH e terminais com terminfo ausente
if not ("TERM" in $env) or ($env.TERM == "") or ($env.TERM == "dumb") {
    $env.TERM = "xterm-256color"
}

def shorten_path [] {
    let home = if "HOME" in $env {
        ($env.HOME | into string)
    } else {
        (
            $nu.default-config-dir
            | path dirname
            | path dirname
            | into string
        )
    }

    let pwd = ($env.PWD | into string)

    let rel = if ($pwd | str starts-with $home) {
        $"~($pwd | str substring ($home | str length)..)"
    } else {
        $pwd
    }

    let parts = ($rel | split row "/" | where $it != "")

    if ($rel == "~" or ($parts | length) <= 3) {
        $rel
    } else {
        let tail = ($parts | last 3)
        if ($rel | str starts-with "~") {
            $"~/($tail | str join "/")"
        } else {
            $"…/($tail | str join "/")"
        }
    }
}

def git_prompt_segment [] {
    let inside = (do -i { git rev-parse --is-inside-work-tree } | complete)

    if $inside.exit_code != 0 {
        return ""
    }

    let branch_result = (do -i { git branch --show-current } | complete)
    let branch_name = if $branch_result.exit_code == 0 {
        ($branch_result.stdout | str trim)
    } else {
        ""
    }

    let raw_status = (do -i { git status --porcelain } | complete)
    let lines = if $raw_status.exit_code == 0 {
        ($raw_status.stdout | lines)
    } else {
        []
    }

    let staged = ($lines | where (($it | str substring 0..1) != " " and ($it | str substring 0..1) != "?") | length)
    let unstaged = ($lines | where (($it | str substring 1..2) != " " and not ($it | str starts-with "??")) | length)
    let untracked = ($lines | where ($it | str starts-with "??") | length)

    let reset = (ansi reset)
    let branch_color = (ansi magenta_bold)
    let ok_color = (ansi green_bold)
    let warn_color = (ansi yellow_bold)
    let err_color = (ansi red_bold)
    let sep_color = (ansi dark_gray)

    mut parts = []

    if ($branch_name | is-empty) {
        $parts = ($parts | append $"($branch_color) git($reset)")
    } else {
        $parts = ($parts | append $"($branch_color) ($branch_name)($reset)")
    }

    if $staged > 0 {
        $parts = ($parts | append $"($ok_color)+($staged)($reset)")
    }

    if $unstaged > 0 {
        $parts = ($parts | append $"($warn_color)!($unstaged)($reset)")
    }

    if $untracked > 0 {
        $parts = ($parts | append $"($err_color)?($untracked)($reset)")
    }

    if ($staged == 0 and $unstaged == 0 and $untracked == 0) {
        $parts = ($parts | append $"($ok_color)clean($reset)")
    }

    $" ($sep_color)|($reset) [($parts | str join ' ')]"
}

def create_left_prompt [] {
    let reset = (ansi reset)

    let frame_color = (ansi dark_gray)
    let user_host_color = (ansi white_reverse)
    let arrow_color = (ansi white)
    let path_color = (ansi blue_bold)
    let symbol_color = (ansi purple_bold)

    let user = if "USER" in $env {
        ($env.USER | into string)
    } else {
        "user"
    }

    let host = if "HOSTNAME" in $env {
        ($env.HOSTNAME | into string)
    } else {
        (sys host | get hostname | into string)
    }

    let path_segment = (shorten_path)
    let git_segment = (git_prompt_segment)

    let line1 = $"($frame_color)╭─╴($reset)($user_host_color) ($user)@($host) ($reset)($arrow_color)($reset) ($path_color)($path_segment)($reset)"

    let line2 = if ($git_segment | is-empty) {
        ""
    } else {
        $"($frame_color)╰─╴($reset)($git_segment)"
    }

    let line3 = $"($symbol_color)❯ ($reset)"

    if ($line2 | is-empty) {
        $"($line1)\n($line3)"
    } else {
        $"($line1)\n($line2)\n($line3)"
    }
}

def create_right_prompt [] {
    let reset = (ansi reset)
    let time_color = (ansi yellow)
    let subtle_color = (ansi dark_gray)
    let now = (date now | format date '%H:%M')

    $"($subtle_color)[($reset)($time_color)($now)($reset)($subtle_color)]($reset)"
}

$env.PROMPT_COMMAND = { create_left_prompt }
$env.PROMPT_COMMAND_RIGHT = { create_right_prompt }
$env.PROMPT_INDICATOR = ""
$env.PROMPT_INDICATOR_VI_INSERT = ""
$env.PROMPT_INDICATOR_VI_NORMAL = ""
$env.PROMPT_MULTILINE_INDICATOR = "::: "

# Desativa marcadores semânticos OSC 133 (evita quebras de linha espúrias em conexões remotas WezTerm/SSH)
$env.config.shell_integration.osc133 = false
