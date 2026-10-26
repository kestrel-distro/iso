# Directs user to Kestrel Discord
QR_CODE='
█▀▀▀▀▀█ ▄ ▄ ▀▄▄▄█ █▀▀▀▀▀█
█ ███ █ ▄▄▄▄▀▄▀▄▀ █ ███ █
█ ▀▀▀ █ ▄█  ▄█▄▄▀ █ ▀▀▀ █
▀▀▀▀▀▀▀ ▀▄█ █ █ █ ▀▀▀▀▀▀▀
▀▀█▀▀▄▀▀▀▀▄█▀▀█  ▀ █ ▀ █ 
█▄█ ▄▄▀▄▄ ▀ ▄ ▀█▄▄▄▄ ▀ ▀█
▄ ▄▀█ ▀▄▀▀▀▄ ▄█▀▄█▀▄▀▄▀█▀
█ ▄▄█▄▀▄█ ▄▄▄  ▀ ▄▀██▀ ▀█
▀ ▀   ▀ █ ▀▄  ▀▀█▀▀▀█▄▀  
█▀▀▀▀▀█ ▀█  ▄▀▀ █ ▀ █▄▀██
█ ███ █ █▀▄▄▀ █▀███▀█▄██▄
█ ▀▀▀ █ ██  ▀ █▄█ ▄▄▄█▀ █
▀▀▀▀▀▀▀ ▀ ▀ ▀▀▀  ▀ ▀▀▀▀▀▀'

# Track if we're already handling an error to prevent double-trapping
ERROR_HANDLING=false

# Cursor is usually hidden while we install
show_cursor() {
  printf "\033[?25h"
}

# Display truncated log lines from the install log
show_log_tail() {
  if [[ -f $KESTREL_INSTALL_LOG_FILE ]]; then
    local log_lines=$(($TERM_HEIGHT - $LOGO_HEIGHT - 35))
    local max_line_width=$((LOGO_WIDTH - 4))

    tail -n $log_lines "$KESTREL_INSTALL_LOG_FILE" | while IFS= read -r line; do
      if ((${#line} > max_line_width)); then
        local truncated_line="${line:0:$max_line_width}..."
      else
        local truncated_line="$line"
      fi

      printf '%s\n' "$truncated_line"
    done

    echo
  fi
}

# Display the failed command or script name
show_failed_script_or_command() {
  if [[ -n ${CURRENT_SCRIPT:-} ]]; then
    printf 'Failed script: %s\n' "$CURRENT_SCRIPT"
  else
    # Truncate long command lines to fit the display
    local cmd="$BASH_COMMAND"
    local max_cmd_width=$((LOGO_WIDTH - 4))

    if ((${#cmd} > max_cmd_width)); then
      cmd="${cmd:0:$max_cmd_width}..."
    fi

    printf '%s\n' "$cmd"
  fi
}

# Save original stdout and stderr for trap to use
save_original_outputs() {
  exec 3>&1 4>&2
}

# Restore stdout and stderr to original (saved in FD 3 and 4)
# This ensures output goes to screen, not log file
restore_outputs() {
  if [ -e /proc/self/fd/3 ] && [ -e /proc/self/fd/4 ]; then
    exec 1>&3 2>&4
  fi
}

# Error handler
catch_errors() {
  # Prevent recursive error handling
  if [[ $ERROR_HANDLING == true ]]; then
    return
  else
    ERROR_HANDLING=true
  fi

  # Store exit code immediately before it gets overwritten
  local exit_code=$?

  stop_log_output
  restore_outputs

  clear_logo
  show_cursor

  printf 'Kestrel installation stopped!\n'
  show_log_tail

  printf 'This command halted with exit code %s:\n' "$exit_code"
  show_failed_script_or_command

  printf '%s\n' "$QR_CODE"
  echo
  printf 'Get help from the community via QR code or at https://discord.gg/tXFUdasqhY\n'

  # Offer options menu
  while true; do
    options=()

    # If online install, show retry first
    if [[ -n ${KESTREL_ONLINE_INSTALL:-} ]]; then
      options+=("Retry installation")
    fi

    # Add remaining options
    options+=("View full log")
    options+=("Exit")

    local i reply
    for i in "${!options[@]}"; do
      printf '%2d) %s\n' "$((i + 1))" "${options[i]}"
    done
    printf 'What would you like to do? ' >&2
    IFS= read -r reply || exit 1
    choice=""
    if [[ $reply =~ ^[0-9]+$ ]] && ((reply >= 1 && reply <= ${#options[@]})); then
      choice=${options[reply - 1]}
    fi

    case "$choice" in
    "Retry installation")
      exec kestrel-install
      ;;
    "View full log")
      if command -v less &>/dev/null; then
        less "$KESTREL_INSTALL_LOG_FILE"
      else
        tail "$KESTREL_INSTALL_LOG_FILE"
      fi
      ;;
    "Exit" | "")
      exit 1
      ;;
    esac
  done
}

# Exit handler - ensures cleanup happens on any exit
exit_handler() {
  local exit_code=$?

  # Only run if we're exiting with an error and haven't already handled it
  if [[ $exit_code -ne 0 && $ERROR_HANDLING != true ]]; then
    catch_errors
  else
    stop_log_output
    show_cursor
  fi
}

# Set up traps
trap catch_errors ERR INT TERM
trap exit_handler EXIT

# Save original outputs in case we trap
save_original_outputs
