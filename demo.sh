#!/usr/bin/env bash
# demo.sh - interactive TUI + CLI entry point for the toolhive-demo-sandbox.
#
# No args from a terminal:  walks an interactive menu (requires gum).
# Args present, or no TTY:  runs as a plain CLI (suitable for CI/automation).
#
# Subcommands (CLI mode):
#   bootstrap            ./bootstrap.sh
#   cleanup              ./cleanup.sh
#   validate             ./validate.sh
#   up    <addon...>     deploy each addon (prompts for missing .env when on a TTY)
#   down  <addon...>     tear each addon down
#   list                 print known addon names
#
# Env:
#   DRY_RUN=1            echo external commands instead of running them

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT
readonly CLUSTER_NAME="toolhive-demo-in-a-box"
readonly ADDONS_DIR="$REPO_ROOT/addons"

DRY_RUN="${DRY_RUN:-0}"

# --- theme -------------------------------------------------------------------
# Override gum's default pink/purple accents with Stacklok brand greens
# (green-grass #bddfc2 and green-bright #428d68). 256-color codes; tweak to taste.
readonly THEME_PRIMARY=151   # green-grass: cursors, prompts, brand banners
readonly THEME_ACCENT=72     # green-bright: selected items / checkbox marks
readonly THEME_HEADER=140    # purple-orchid: secondary header text inside menus

export GUM_CHOOSE_CURSOR_FOREGROUND=$THEME_PRIMARY
export GUM_CHOOSE_SELECTED_FOREGROUND=$THEME_ACCENT
export GUM_CHOOSE_SELECTED_PREFIX_FOREGROUND=$THEME_ACCENT
export GUM_CHOOSE_HEADER_FOREGROUND=$THEME_HEADER
export GUM_INPUT_CURSOR_FOREGROUND=$THEME_PRIMARY
export GUM_INPUT_PROMPT_FOREGROUND=$THEME_PRIMARY
export GUM_INPUT_HEADER_FOREGROUND=$THEME_HEADER
export GUM_CONFIRM_SELECTED_BACKGROUND=$THEME_ACCENT
export GUM_SPIN_SPINNER_FOREGROUND=$THEME_PRIMARY

run() {
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[DRY] $*" >&2
  else
    "$@"
  fi
}

is_tty() { [[ -t 0 && -t 1 ]]; }

require_gum() {
  if ! command -v gum >/dev/null 2>&1; then
    cat >&2 <<EOF
demo.sh: gum is required for the interactive menu but was not found.
  brew install gum
  # or: https://github.com/charmbracelet/gum
Or call demo.sh with a subcommand (try: ./demo.sh --help).
EOF
    exit 1
  fi
}

list_addons() {
  find "$ADDONS_DIR" -mindepth 1 -maxdepth 1 -type d ! -name '_*' \
    -exec basename {} \; | sort
}

cluster_running() {
  kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"
}

# ---- .env prompt layer ------------------------------------------------------

# Heuristics: is this var name likely a secret (mask the input)?
is_secret_var() {
  [[ "$1" =~ (SECRET|TOKEN|PASSWORD|PAT|API_KEY|CLIENT_SECRET)$ ]]
}

# Heuristics: does the value in .env.example look like a placeholder rather
# than a real default we'd want to prefill?
is_placeholder() {
  local v="$1"
  [[ -z "$v" \
     || "$v" =~ (your-|replace-me|change-me|XXX|example) \
     || "$v" =~ ^\< \
     || "$v" =~ \>$ ]]
}

# Parse a .env.example. For each KEY=VALUE line, emit "KEY|comment|VALUE".
# Comments are the most-recent contiguous block of `# ...` lines above the var.
parse_env_example() {
  local file="$1" comment=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*# ]]; then
      local s="${line#"${line%%[![:space:]]*}"}"
      s="${s#\#}"; s="${s# }"
      comment+="${comment:+ }$s"
    elif [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      printf '%s|%s|%s\n' "${line%%=*}" "$comment" "${line#*=}"
      comment=""
    elif [[ -z "$line" ]]; then
      comment=""
    fi
  done < "$file"
}

# Ensure addons/<addon>/.env exists. Walk .env.example via gum prompts on a TTY;
# fail with a clear message in non-interactive contexts.
ensure_env() {
  local addon="$1"
  local addon_dir="$ADDONS_DIR/$addon"
  local env_file="$addon_dir/.env"
  local example="$addon_dir/.env.example"

  [[ -f "$env_file" ]] && return 0
  [[ -f "$example" ]] || return 0

  if ! is_tty || ! command -v gum >/dev/null 2>&1; then
    cat >&2 <<EOF
demo.sh: $addon requires $env_file but it does not exist.
  cp "$example" "$env_file"  # then edit
EOF
    return 1
  fi

  gum style --foreground "$THEME_PRIMARY" --bold "Configure $addon"
  echo "(values from $(basename "$example") - enter to accept, ctrl-c to abort)"
  echo

  local tmp
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' RETURN

  while IFS='|' read -r name comment default; do
    [[ -z "$name" ]] && continue

    local args=(--header "$name")
    [[ -n "$comment" ]] && args+=(--placeholder "$comment")
    if ! is_placeholder "$default"; then
      args+=(--value "$default")
    fi
    is_secret_var "$name" && args+=(--password)

    local val
    if ! val="$(gum input "${args[@]}")"; then
      return 1
    fi
    printf '%s=%s\n' "$name" "$val" >> "$tmp"
  done < <(parse_env_example "$example")

  mv "$tmp" "$env_file"
  trap - RETURN
  echo "Wrote $env_file"
}

# ---- subcommands ------------------------------------------------------------

cmd_bootstrap() { run "$REPO_ROOT/bootstrap.sh"; }
cmd_cleanup()   { run "$REPO_ROOT/cleanup.sh"; }
cmd_validate()  { run "$REPO_ROOT/validate.sh"; }

cmd_up() {
  [[ $# -eq 0 ]] && { echo "up: no addons given" >&2; return 2; }
  local addon
  for addon in "$@"; do
    if [[ ! -d "$ADDONS_DIR/$addon" ]]; then
      echo "Unknown addon: $addon (try ./demo.sh list)" >&2
      return 1
    fi
    ensure_env "$addon"
    run "$ADDONS_DIR/$addon/deploy.sh"
  done
}

cmd_down() {
  [[ $# -eq 0 ]] && { echo "down: no addons given" >&2; return 2; }
  local addon
  for addon in "$@"; do
    if [[ ! -d "$ADDONS_DIR/$addon" ]]; then
      echo "Unknown addon: $addon (try ./demo.sh list)" >&2
      return 1
    fi
    run "$ADDONS_DIR/$addon/teardown.sh"
  done
}

usage() {
  cat <<EOF
Usage: ./demo.sh                       interactive menu (requires gum + TTY)
       ./demo.sh bootstrap             create the kind cluster + base resources
       ./demo.sh cleanup               tear down the kind cluster
       ./demo.sh validate              run endpoint checks
       ./demo.sh up    <addon...>      deploy addons (idempotent)
       ./demo.sh down  <addon...>      tear down addons (idempotent)
       ./demo.sh list                  list known addons

Env:
  DRY_RUN=1   echo external commands instead of running them
EOF
}

# ---- interactive menus ------------------------------------------------------

# pick_addons TITLE  -> writes selected addons (newline-separated) to stdout.
# Note: gum choose uses the alt-screen, so context must live in --header
# (anything we print before is hidden once gum takes over the terminal).
pick_addons() {
  local title="$1"
  list_addons | gum choose --no-limit \
    --header "$title"$'\n'"[space] toggle  [enter] confirm  [esc] back"$'\n' \
    --cursor "> " \
    --cursor-prefix "[ ] " \
    --selected-prefix "[x] " \
    --unselected-prefix "[ ] "
}

interactive_no_cluster() {
  gum style --foreground "$THEME_PRIMARY" --bold "ToolHive demo sandbox"
  if ! gum confirm "No demo cluster found. Bootstrap one now?"; then
    exit 0
  fi
  cmd_bootstrap

  local picks
  picks="$(pick_addons "Optional: pick addons to deploy (space toggles, enter confirms)" || true)"
  if [[ -n "$picks" ]]; then
    # shellcheck disable=SC2086
    cmd_up $picks
  fi
}

# Main menu loop. Returns when the user picks Quit, escapes the top menu, or
# destroys the cluster. Sub-pickers (addon deploy/teardown) treat escape as
# "go back" — gum returns non-zero, we swallow it and re-enter the loop.
interactive_running() {
  while true; do
    gum style --foreground "$THEME_PRIMARY" --bold \
      "ToolHive demo sandbox" "Cluster: $CLUSTER_NAME (running)"
    local action
    if ! action="$(gum choose --header "" \
        "Deploy / redeploy addons" \
        "Tear down addons" \
        "Re-bootstrap (refresh)" \
        "Validate endpoints" \
        "Cleanup entirely (destroy cluster)" \
        "Quit")"; then
      return 0   # esc on the top-level menu exits the loop
    fi

    case "$action" in
      "Deploy / redeploy addons")
        local picks; picks="$(pick_addons "Pick addons to deploy" || true)"
        # shellcheck disable=SC2086
        [[ -n "$picks" ]] && cmd_up $picks
        ;;
      "Tear down addons")
        local picks; picks="$(pick_addons "Pick addons to tear down" || true)"
        # shellcheck disable=SC2086
        [[ -n "$picks" ]] && cmd_down $picks
        ;;
      "Re-bootstrap (refresh)")
        cmd_bootstrap
        ;;
      "Validate endpoints")
        cmd_validate
        ;;
      "Cleanup entirely (destroy cluster)")
        if gum confirm --default=false "Destroy the kind cluster '$CLUSTER_NAME'?"; then
          cmd_cleanup
          return 0   # cluster gone, no point looping
        fi
        ;;
      "Quit"|"") return 0 ;;
    esac
  done
}

interactive_menu() {
  require_gum
  if cluster_running; then
    interactive_running
  else
    interactive_no_cluster
    # After bootstrap completes the cluster is running; drop into the main loop.
    cluster_running && interactive_running
  fi
}

# ---- entry point ------------------------------------------------------------

main() {
  if [[ $# -gt 0 ]]; then
    local cmd="$1"; shift
    case "$cmd" in
      bootstrap)        cmd_bootstrap ;;
      cleanup)          cmd_cleanup ;;
      validate)         cmd_validate ;;
      up)               cmd_up "$@" ;;
      down)             cmd_down "$@" ;;
      list)             list_addons ;;
      -h|--help|help)   usage ;;
      *)                echo "Unknown command: $cmd" >&2; usage; exit 2 ;;
    esac
    return
  fi

  if ! is_tty; then
    usage
    exit 0
  fi

  interactive_menu
}

main "$@"
