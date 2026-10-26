# Live ISO: start the Kestrel desktop on the first virtual terminal.
# Only when nothing graphical is already running, so subshells and scp/ssh
# logins never try to start a second session.
if [[ $(tty 2>/dev/null) == /dev/tty1 && -z ${WAYLAND_DISPLAY:-} && -z ${KESTREL_LIVE_SESSION:-} ]]; then
  export KESTREL_LIVE_SESSION=1
  command -v logger >/dev/null && logger -t kestrel-live "starting the Hyprland session on $(tty)"
  exec uwsm start -g -1 -e -D Hyprland hyprland.desktop
fi

# Non-session login shells (tty2+) carry the shell transcript hook.
[[ -f ~/.bashrc ]] && source ~/.bashrc
