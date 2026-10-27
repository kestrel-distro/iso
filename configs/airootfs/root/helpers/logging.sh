start_install_log() {
  sudo touch "$KESTREL_INSTALL_LOG_FILE"
  sudo chmod 666 "$KESTREL_INSTALL_LOG_FILE"

  export KESTREL_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')

  echo "=== Kestrel Installation Started: $KESTREL_START_TIME ===" >>"$KESTREL_INSTALL_LOG_FILE"
}

stop_install_log() {
  show_cursor

  if [[ -n ${KESTREL_INSTALL_LOG_FILE:-} ]]; then
    KESTREL_END_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    echo "=== Kestrel Installation Completed: $KESTREL_END_TIME ===" >>"$KESTREL_INSTALL_LOG_FILE"
    echo "" >>"$KESTREL_INSTALL_LOG_FILE"
    echo "=== Installation Time Summary ===" >>"$KESTREL_INSTALL_LOG_FILE"

    if [ -n "$KESTREL_START_TIME" ]; then
      KESTREL_START_EPOCH=$(date -d "$KESTREL_START_TIME" +%s)
      KESTREL_END_EPOCH=$(date -d "$KESTREL_END_TIME" +%s)
      KESTREL_DURATION=$((KESTREL_END_EPOCH - KESTREL_START_EPOCH))

      KESTREL_MINS=$((KESTREL_DURATION / 60))
      KESTREL_SECS=$((KESTREL_DURATION % 60))

      echo "Kestrel:     ${KESTREL_MINS}m ${KESTREL_SECS}s" >>"$KESTREL_INSTALL_LOG_FILE"
    fi
    echo "=================================" >>"$KESTREL_INSTALL_LOG_FILE"

    echo "Rebooting system..." >>"$KESTREL_INSTALL_LOG_FILE"
  fi
}

run_logged() {
  local script="$1"

  export CURRENT_SCRIPT="$script"

  echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting: $script" >>"$KESTREL_INSTALL_LOG_FILE"

  # Use bash -c to create a clean subshell
  bash -c "source '$script'" </dev/null >>"$KESTREL_INSTALL_LOG_FILE" 2>&1

  local exit_code=$?

  if [ $exit_code -eq 0 ]; then
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Completed: $script" >>"$KESTREL_INSTALL_LOG_FILE"
    unset CURRENT_SCRIPT
  else
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Failed: $script (exit code: $exit_code)" >>"$KESTREL_INSTALL_LOG_FILE"
  fi

  return $exit_code
}
