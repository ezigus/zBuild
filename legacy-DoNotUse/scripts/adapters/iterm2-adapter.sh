#!/usr/bin/env bash
# ╔═══════════════════════════════════════════════════════════════════════════╗
# ║  iterm2-adapter.sh — Terminal adapter for iTerm2 tab management         ║
# ║                                                                          ║
# ║  Uses AppleScript (osascript) to create iTerm2 tabs with named titles   ║
# ║  and working directories. macOS only.                                    ║
# ║  Sourced by sw-session.sh — exports: spawn_agent, list_agents,         ║
# ║  kill_agent, focus_agent.                                                ║
# ╚═══════════════════════════════════════════════════════════════════════════╝

# Verify we're on macOS and iTerm2 is available
if [[ "$(uname)" != "Darwin" ]]; then
    echo -e "\033[38;2;248;113;113m\033[1m✗\033[0m iTerm2 adapter requires macOS." >&2
    exit 1
fi

# Track created tab IDs for agent management
declare -a _ITERM2_TAB_NAMES=()

spawn_agent() {
    local name="$1"
    local working_dir="${2:-$PWD}"
    local command="${3:-}"

    # Resolve working_dir — tmux format #{pane_current_path} won't work here
    if [[ "$working_dir" == *"pane_current_path"* || "$working_dir" == "." ]]; then
        working_dir="$PWD"
    fi

    osascript <<APPLESCRIPT
tell application "iTerm2"
    tell current window
        -- Create a new tab
        set newTab to (create tab with default profile)
        tell current session of newTab
            -- Set the name/title
            set name to "${name}"
            -- Change to the working directory
            write text "cd '${working_dir}' && clear"
        end tell
    end tell
end tell
APPLESCRIPT

    # Run the command if provided
    if [[ -n "$command" ]]; then
        sleep 0.3
        osascript <<APPLESCRIPT
tell application "iTerm2"
    tell current window
        tell current session of current tab
            write text "${command}"
        end tell
    end tell
end tell
APPLESCRIPT
    fi

    _ITERM2_TAB_NAMES+=("$name")
}

list_agents() {
    # List all tabs in the current iTerm2 window
    osascript <<'APPLESCRIPT'
tell application "iTerm2"
    tell current window
        set output to ""
        set tabIndex to 0
        repeat with aTab in tabs
            set tabIndex to tabIndex + 1
            tell current session of aTab
                set sessionName to name
                set output to output & tabIndex & ": " & sessionName & linefeed
            end tell
        end repeat
        return output
    end tell
end tell
APPLESCRIPT
}

kill_agent() {
    local name="$1"

    osascript <<APPLESCRIPT
tell application "iTerm2"
    tell current window
        repeat with aTab in tabs
            tell current session of aTab
                if name is "${name}" then
                    close
                    return "closed"
                end if
            end tell
        end repeat
    end tell
end tell
return "not found"
APPLESCRIPT
}

focus_agent() {
    local name="$1"

    osascript <<APPLESCRIPT
tell application "iTerm2"
    tell current window
        set tabIndex to 1
        repeat with aTab in tabs
            tell current session of aTab
                if name is "${name}" then
                    select aTab
                    return "focused"
                end if
            end tell
            set tabIndex to tabIndex + 1
        end repeat
    end tell
end tell
return "not found"
APPLESCRIPT
}
