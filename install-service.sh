#!/usr/bin/env bash
# ============================================================================
# install-service.sh - turn any command into a boot-time systemd service.
#
#   System-wide (default):
#     sudo bash install-service.sh -n paseo -d "Paseo Daemon" -- paseo daemon run
#
#   Per-user service (~/.config/systemd/user, starts on login / with linger):
#     bash install-service.sh --user -n paseo -- paseo daemon run
#
#   One-liner install:
#     curl -fsSL https://example.com/install-service.sh | sudo bash -s -- -n paseo -- paseo daemon run
#
# Options:
#   -n, --name NAME      service name (required)
#   -d, --desc TEXT      Description= text
#   --user               install as a per-user unit instead of system unit
#   -u, --run-as USER    account to run as (system units; default: $SUDO_USER)
#   -w, --workdir DIR    WorkingDirectory (default: that user's home)
#   -e, --env-file FILE  EnvironmentFile= (repeatable)
#   --env K=V            Environment= (repeatable)
#   -l, --log FILE       duplicate stdout/stderr into FILE (systemd 240+)
#   -r, --reload-cmd CMD ExecReload= command
#   --restart POLICY     Restart= (default: always)
#   --restart-sec N      RestartSec= (default: 10)
#   --after UNIT         After= list (repeatable; default: network-online.target)
#   --wants UNIT         Wants= list (repeatable)
#   --no-start           write + enable only, do not start now
#   --print              print the generated unit to stdout and exit
#   -- ARG...            everything after -- is the command to run
# ============================================================================
set -euo pipefail

NAME=""; DESC=""; USER_MODE=0; RUN_AS="${SUDO_USER:-}"; WORKDIR=""
LOGFILE=""; RELOAD_CMD=""; RESTART="always"; RESTART_SEC="10"; DO_START=1; PRINT_ONLY=0
AFTER=(); WANTS=(); ENVFILE=(); ENVVARS=()

die(){ echo "ERROR: $*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    -n|--name) NAME="${2:-}"; shift 2;;
    -d|--desc) DESC="${2:-}"; shift 2;;
    --user) USER_MODE=1; shift;;
    -u|--run-as) RUN_AS="${2:-}"; shift 2;;
    -w|--workdir) WORKDIR="${2:-}"; shift 2;;
    -e|--env-file) ENVFILE+=("${2:-}"); shift 2;;
    --env) ENVVARS+=("${2:-}"); shift 2;;
    -l|--log) LOGFILE="${2:-}"; shift 2;;
    -r|--reload-cmd) RELOAD_CMD="${2:-}"; shift 2;;
    --restart) RESTART="${2:-}"; shift 2;;
    --restart-sec) RESTART_SEC="${2:-}"; shift 2;;
    --after) AFTER+=("${2:-}"); shift 2;;
    --wants) WANTS+=("${2:-}"); shift 2;;
    --no-start) DO_START=0; shift;;
    --print) PRINT_ONLY=1; shift;;
    --) shift; break;;
    -h|--help) sed -n '2,40p' "$0"; exit 0;;
    *) die "unknown option: $1 (use -- before the command)";;
  esac
done
CMD=("$@")

[ -n "$NAME" ] || die "missing -n/--name"
[[ "$NAME" =~ ^[A-Za-z0-9_.@-]+$ ]] || die "invalid service name '$NAME'"
[ "${#CMD[@]}" -ge 1 ] || die "missing command (put it after --)"

# --- privilege / mode checks ------------------------------------------------
if [ "$USER_MODE" -eq 0 ]; then
  if [ "$PRINT_ONLY" -eq 0 ]; then
    [ "$(id -u)" -eq 0 ] || die "system install needs sudo/root (or pass --user)"
  fi
  RUN_AS="${RUN_AS:-$(id -un)}"
elif [ "$(id -u)" -eq 0 ]; then
  die "--user must be run as the target user, not root"
fi

# --- resolve target user / home / group ------------------------------------
if [ "$USER_MODE" -eq 1 ]; then
  RUN_AS="$(id -un)"
fi
TARGET_HOME="$(getent passwd "$RUN_AS" | cut -d: -f6)"
TARGET_GROUP="$(id -gn "$RUN_AS")"
WORKDIR="${WORKDIR:-$TARGET_HOME}"

# --- resolve command to absolute path --------------------------------------
BIN="${CMD[0]}"
if [[ "$BIN" != /* ]]; then
  RESOLVED="$(command -v "$BIN" 2>/dev/null || true)"
  # fall back to the target user's login-shell PATH (e.g. node/version-manager bins
  # that root's PATH doesn't include)
  if [ -z "$RESOLVED" ] && [ -n "$RUN_AS" ]; then
    if [ "$(id -u)" -eq 0 ] && [ "$RUN_AS" != "root" ]; then
      RESOLVED="$(sudo -u "$RUN_AS" bash -lc "command -v $(printf '%q' "$BIN")" 2>/dev/null || true)"
    else
      RESOLVED="$(bash -lc "command -v $(printf '%q' "$BIN")" 2>/dev/null || true)"
    fi
  fi
  [ -n "$RESOLVED" ] || die "command '$BIN' not found on PATH (tried current and $RUN_AS's login shell); use an absolute path"
  CMD[0]="$RESOLVED"; BIN="$RESOLVED"
fi
BIN_DIR="$(dirname "$BIN")"

# --- build PATH (binary dir + target user's login-shell PATH) ---------------
if [ "$(id -u)" -eq 0 ] && [ "$RUN_AS" != "root" ]; then
  LOGIN_PATH="$(sudo -u "$RUN_AS" bash -lc 'echo "$PATH"' 2>/dev/null || true)"
else
  LOGIN_PATH="$(bash -lc 'echo "$PATH"' 2>/dev/null || true)"
fi
SERVICE_PATH="$(printf '%s' "$BIN_DIR:${LOGIN_PATH:-/usr/local/bin:/usr/bin:/bin}" \
  | tr ':' '\n' | awk 'NF && !seen[$0]++' | paste -sd: -)"

# --- defaults for After/Wants ----------------------------------------------
[ "${#AFTER[@]}" -eq 0 ] && AFTER=("network-online.target")
[ "${#WANTS[@]}" -eq 0 ] && WANTS=("network-online.target")

# --- generate unit ----------------------------------------------------------
render_unit() {
  [ -n "$DESC" ] || DESC="$NAME (installed by install-service.sh)"
  echo "[Unit]"
  echo "Description=$DESC"
  printf 'After=%s\n' "${AFTER[*]}"
  printf 'Wants=%s\n' "${WANTS[*]}"
  echo
  echo "[Service]"
  echo "Type=simple"
  if [ "$USER_MODE" -eq 0 ]; then
    echo "User=$RUN_AS"
    echo "Group=$TARGET_GROUP"
  fi
  echo "WorkingDirectory=$WORKDIR"
  echo "Environment=HOME=$TARGET_HOME"
  echo "Environment=PATH=$SERVICE_PATH"
  for kv in "${ENVVARS[@]:-}"; do [ -n "$kv" ] && echo "Environment=$kv"; done
  for f in "${ENVFILE[@]:-}"; do [ -n "$f" ] && echo "EnvironmentFile=$f"; done
  printf 'ExecStart='
  for a in "${CMD[@]}"; do printf '%q ' "$a"; done; echo
  [ -n "$RELOAD_CMD" ] && echo "ExecReload=$RELOAD_CMD"
  if [ -n "$LOGFILE" ]; then
    echo "StandardOutput=append:$LOGFILE"
    echo "StandardError=append:$LOGFILE"
  fi
  echo "Restart=$RESTART"
  echo "RestartSec=$RESTART_SEC"
  echo
  echo "[Install]"
  if [ "$USER_MODE" -eq 1 ]; then echo "WantedBy=default.target"; else echo "WantedBy=multi-user.target"; fi
}

if [ "$PRINT_ONLY" -eq 1 ]; then render_unit; exit 0; fi

# --- write unit -------------------------------------------------------------
if [ "$USER_MODE" -eq 1 ]; then
  UNIT_DIR="$TARGET_HOME/.config/systemd/user"
  mkdir -p "$UNIT_DIR"
  UNIT="$UNIT_DIR/$NAME.service"
  SCTL=(systemctl --user)
else
  UNIT_DIR="/etc/systemd/system"
  UNIT="$UNIT_DIR/$NAME.service"
  SCTL=(systemctl)
fi

echo "==> Installing $NAME.service ($([ "$USER_MODE" -eq 1 ] && echo user || echo system))"
echo "    user:    $RUN_AS"
echo "    workdir: $WORKDIR"
echo "    exec:    ${CMD[*]}"
echo "    path:    $SERVICE_PATH"
[ -n "$LOGFILE" ] && echo "    log:     $LOGFILE"

TMP="$(mktemp)"; render_unit >"$TMP"; install -m 0644 "$TMP" "$UNIT"; rm -f "$TMP"

# clean up conflicting unit in the *other* scope
if [ "$USER_MODE" -eq 0 ] && [[ -n "$RUN_AS" ]] && [ -f "$TARGET_HOME/.config/systemd/user/$NAME.service" ]; then
  echo "==> Disabling conflicting user unit"
  sudo -u "$RUN_AS" XDG_RUNTIME_DIR="/run/user/$(id -u "$RUN_AS")" \
    systemctl --user disable --now "$NAME.service" 2>/dev/null || true
fi

if [ "$USER_MODE" -eq 1 ]; then
  "${SCTL[@]}" daemon-reload
  "${SCTL[@]}" enable "$NAME.service"
  if [ "$DO_START" -eq 1 ]; then "${SCTL[@]}" restart "$NAME.service"; fi
  echo "==> Done. Starts on login. For boot-without-login run once:"
  echo "      sudo loginctl enable-linger $RUN_AS"
else
  "${SCTL[@]}" daemon-reload
  if [ "$DO_START" -eq 1 ]; then
    "${SCTL[@]}" enable --now "$NAME.service"
  else
    "${SCTL[@]}" enable "$NAME.service"
  fi
  sleep 2
  "${SCTL[@]}" --no-pager --full status "$NAME.service" || true
  echo "==> Done: $NAME will auto-start at boot."
fi
