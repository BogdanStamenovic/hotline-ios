#!/usr/bin/env bash
# The lifecycle of hotline-ios's server, hotline-iosd, for ownbox.
#
#   ./ownbox.sh setup    venv, .env, the hotline-ios user unit, the map hook
#   ./ownbox.sh update   rebuild the venv, re-render the unit, restart it
#   ./ownbox.sh remove   stop and remove the unit; asks about hooks and the store
#   ./ownbox.sh status   what is installed, and whether the daemon answers
#
# Phone calls are not here: they are hotline-call's (`ownbox install
# hotline-call`), and this daemon forwards to it. The iOS app itself is built
# by CI (.github/workflows) and sideloaded; nothing here builds it.
#
# Knobs: HOTLINE_IOS_UNIT (hotline-ios), HOTLINE_IOS_HOST (100.72.2.62),
# HOTLINE_IOS_PORT (8789), HOTLINE_SRC
# (~/data/hotline/src). Optional steps prompt on a TTY and take the safe default
# without one, printing what was skipped.
set -euo pipefail

DIR="${OWNBOX_TOOL_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}"
UNIT="${HOTLINE_IOS_UNIT:-hotline-ios}"
UNIT_FILE="$HOME/.config/systemd/user/$UNIT.service"
MARKER="# Rendered by hotline-ios ownbox.sh"
HOST="${HOTLINE_IOS_HOST:-100.72.2.62}"
PORT="${HOTLINE_IOS_PORT:-8789}"
HOTLINE_SRC_DIR="${HOTLINE_SRC:-$HOME/data/hotline/src}"

say() { printf 'hotline-ios: %s\n' "$*"; }
ask() {
    local q=$1 def=$2 reply
    if [ -t 0 ]; then
        read -r -p "hotline-ios: $q [$( [ "$def" = y ] && echo Y/n || echo y/N )] " reply || reply=""
        reply=${reply:-$def}
    else
        reply=$def
        say "$q -> ${def} (no terminal; taking the default)"
    fi
    [[ $reply =~ ^[Yy] ]]
}

# A unit somebody wrote by hand is left alone: on archserver the live
# hotline-ios.service predates this script and is the one that has been
# restarted, rung and debugged. Only a unit this script rendered is rewritten.
unit_is_ours() { [ ! -e "$UNIT_FILE" ] || head -1 "$UNIT_FILE" | grep -qF "$MARKER"; }

build_venv() {
    command -v uv >/dev/null || { say "uv is required"; exit 1; }
    [ -x "$DIR/server/.venv/bin/python" ] || uv venv -q --python 3.12 "$DIR/server/.venv"
    uv pip install -q --python "$DIR/server/.venv/bin/python" -e "$DIR/server[hotline,dev]"
    say "venv ready: $("$DIR/server/.venv/bin/python" -V)"
    [ -f "$HOTLINE_SRC_DIR/hotline/httpd.py" ] || \
        say "WARNING: hotline's source is not at $HOTLINE_SRC_DIR; the daemon will not start"
}

write_env() {
    if [ -f "$DIR/.env" ]; then
        say ".env: keeping $DIR/.env"
        return
    fi
    (umask 077; cp "$DIR/.env.example" "$DIR/.env")
    say ".env: wrote a template; set HOTLINE_ALLOW_IPS and HOTLINE_API_KEY there"
}

render_unit() {
    if ! unit_is_ours; then
        say "unit: $UNIT_FILE was not written by this script; leaving it alone."
        say "  To hand it over: compare it with systemd/hotline-ios.service.in, then"
        say "  delete it and run setup again."
        return 1
    fi
    mkdir -p "$(dirname "$UNIT_FILE")"
    local tmp
    tmp=$(mktemp)
    # HOTLINE_IOS_DB and HOTLINE_IOS_CALLD_URL go into the unit when given, so
    # a second instance can be pointed at its own store and its own call daemon
    # -- without them it would share the live store at ~/.local/state/hotline.
    local extra="" name
    for name in HOTLINE_IOS_DB HOTLINE_IOS_CALLD_URL; do
        [ -n "${!name:-}" ] && extra+="Environment=$name=${!name}\\n"
    done
    sed -e "s|@DIR@|$DIR|g" -e "s|@HOTLINE_SRC@|$HOTLINE_SRC_DIR|g" \
        -e "s|@HOST@|$HOST|g" -e "s|@PORT@|$PORT|g" \
        -e "s|^@ENVIRONMENT@\$|$extra|" "$DIR/systemd/hotline-ios.service.in" | sed '/^$/{N;/^\n$/D}' > "$tmp"
    if [ -f "$UNIT_FILE" ] && cmp -s "$tmp" "$UNIT_FILE"; then
        rm -f "$tmp"
        return 0
    fi
    mv "$tmp" "$UNIT_FILE"
    systemctl --user daemon-reload
    say "unit: wrote $UNIT_FILE"
}

hooks_installed() { grep -q 'hotline-ios-map.py' "$HOME/.claude/settings.json" 2>/dev/null; }

install_hooks() {
    if hooks_installed; then
        # Not re-run on purpose: hooks.install() rewrites the statusline wrapper,
        # and on a second run it no longer knows what it wrapped.
        say "hooks: already registered in ~/.claude/settings.json"
        return
    fi
    # Without a terminal this is skipped: it edits the settings every Claude
    # session on the box runs through, additively but globally.
    if ask "register the map hook and statusline wrapper in ~/.claude/settings.json?" n; then
        PYTHONPATH="$DIR/server/src:$HOTLINE_SRC_DIR" "$DIR/server/.venv/bin/python" -m hotline_ios.hooks
    else
        say "hooks: skipped. The map stays empty until: PYTHONPATH=$DIR/server/src:$HOTLINE_SRC_DIR $DIR/server/.venv/bin/hotline-ios-hooks"
    fi
}

cmd_setup() {
    build_venv
    write_env
    if render_unit; then
        systemctl --user enable "$UNIT" >/dev/null 2>&1 && say "unit: enabled $UNIT"
        systemctl --user restart "$UNIT"
        say "started $UNIT"
    fi
    install_hooks
}

cmd_update() {
    build_venv
    [ -f "$DIR/.env" ] || write_env
    # The store migrates itself when the daemon opens it (store.py adds missing
    # columns in place and never drops one), so a rollback to an older revision
    # still opens a newer database.
    if render_unit && systemctl --user is-active -q "$UNIT"; then
        systemctl --user restart "$UNIT"
        say "restarted $UNIT"
    elif ! unit_is_ours; then
        say "not restarting a unit this script does not own; restart it yourself"
    fi
}

cmd_remove() {
    if [ -f "$UNIT_FILE" ] && unit_is_ours; then
        systemctl --user disable --now "$UNIT" >/dev/null 2>&1 || true
        rm -f "$UNIT_FILE"
        systemctl --user daemon-reload
        say "removed $UNIT"
    elif [ -f "$UNIT_FILE" ]; then
        say "left $UNIT_FILE alone: this script did not write it"
    fi
    if hooks_installed; then
        say "hooks: still registered. They fail silently (300 ms, then a 30 s backoff)"
        say "  with the daemon gone; remove the hotline-ios-* entries from"
        say "  ~/.claude/settings.json by hand if you want them gone."
    fi
    local db="${XDG_STATE_HOME:-$HOME/.local/state}/hotline/hotline-ios.db"
    if [ -f "$db" ] && ask "delete the store $db (every conversation and agent history)?" n; then
        rm -f "$db" "$db-wal" "$db-shm"
        say "deleted $db"
    elif [ -f "$db" ]; then
        say "kept $db"
    fi
}

cmd_status() {
    say "checkout: $DIR"
    say "unit:     $UNIT ($(systemctl --user is-active "$UNIT" 2>/dev/null || true); $(unit_is_ours && echo 'rendered here' || echo 'hand-written'))"
    say "hooks:    $(hooks_installed && echo registered || echo 'not registered')"
    curl -s --max-time 5 "http://127.0.0.1:$PORT/health" && echo || say "daemon not answering on $PORT"
    say "tests:    cd $DIR/server && PYTHONPATH=src:$HOTLINE_SRC_DIR .venv/bin/python -m pytest -q tests"
}

case "${1:-}" in
    setup) cmd_setup ;;
    update) cmd_update ;;
    remove) cmd_remove ;;
    status) cmd_status ;;
    *) echo "usage: $0 setup|update|remove|status" >&2; exit 2 ;;
esac
