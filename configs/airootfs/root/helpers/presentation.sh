# Get terminal size from /dev/tty (works in all scenarios: direct, sourced, or piped)
if [ -e /dev/tty ]; then
  TERM_SIZE=$(stty size 2>/dev/null </dev/tty)

  if [ -n "$TERM_SIZE" ]; then
    export TERM_HEIGHT=$(echo "$TERM_SIZE" | cut -d' ' -f1)
    export TERM_WIDTH=$(echo "$TERM_SIZE" | cut -d' ' -f2)
  else
    # Fallback to reasonable defaults if stty fails
    export TERM_WIDTH=80
    export TERM_HEIGHT=24
  fi
else
  # No terminal available (e.g., non-interactive environment)
  export TERM_WIDTH=80
  export TERM_HEIGHT=24
fi

export LOGO_PATH="$KESTREL_PATH/logo.txt"
export LOGO_WIDTH=$(awk '{ if (length > max) max = length } END { print max+0 }' "$LOGO_PATH" 2>/dev/null || echo 0)
export LOGO_HEIGHT=$(wc -l <"$LOGO_PATH" 2>/dev/null || echo 0)

export PADDING_LEFT=$((($TERM_WIDTH - $LOGO_WIDTH) / 2))
export PADDING_LEFT_SPACES=$(printf "%*s" $PADDING_LEFT "")

clear_logo() {
  printf "\033[H\033[2J" # Clear screen and move cursor to top-left
  printf '\n%s\n\n' "$(<"$LOGO_PATH")"
}

# Stop with a readable message on an unrecoverable installer error.
abort() {
  # Write the reason straight into the log: the tee that mirrors the configurator
  # and phase output is asynchronous, and a direct append survives the exit.
  if [[ -n ${KESTREL_INSTALL_LOG_FILE:-} ]]; then
    printf "[%s] ABORT: %s\n" "$(date +%T)" "${1:-unknown error}" >>"$KESTREL_INSTALL_LOG_FILE" 2>/dev/null || true
  fi
  clear_logo
  echo
  printf 'Kestrel installation stopped: %s\n' "${1:-unknown error}"
  echo
  exit 1
}
