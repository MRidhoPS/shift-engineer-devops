#!/bin/sh

APP=/app/server
PID=""
LAST=""

hash_app() {
    md5sum "$APP" 2>/dev/null | cut -d' ' -f1
}

start_app() {
    "$APP" &
    PID=$!
    LAST="$(hash_app)"
    echo "supervisor: started ${APP} pid=${PID} hash=${LAST}"
}

stop_app() {
    if [ -n "$PID" ]; then
        kill "$PID" 2>/dev/null
        wait "$PID" 2>/dev/null
    fi
}

trap 'stop_app; exit 0' TERM INT

start_app

while true; do
    sleep 1
    CUR="$(hash_app)"
    if [ -n "$CUR" ] && [ "$CUR" != "$LAST" ]; then
        echo "supervisor: binary changed, reloading process"
        stop_app
        start_app
    elif ! kill -0 "$PID" 2>/dev/null; then
        echo "supervisor: app exited, restarting process"
        start_app
    fi
done