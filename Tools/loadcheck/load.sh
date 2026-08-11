#!/bin/sh
#
# The load the dropouts were measured under: one CPU spinner per core plus
# continuous disk writes. Nothing here touches audio — the point is to
# starve the audio threads of scheduling, not to compete for the device.
#
#   load.sh start   # begin, record pids
#   load.sh stop    # kill everything and clean up

dir=$(cd "$(dirname "$0")" && pwd)
pidfile="$dir/load.pids"
scratch="$dir/loadfiles"

case "$1" in
start)
    : > "$pidfile"
    mkdir -p "$scratch"
    cores=$(sysctl -n hw.ncpu)
    i=0
    while [ "$i" -lt "$cores" ]; do
        sh -c 'while :; do :; done' &
        echo $! >> "$pidfile"
        i=$((i + 1))
    done
    j=0
    while [ "$j" -lt 4 ]; do
        sh -c "while :; do dd if=/dev/zero of=$scratch/f$j bs=1m count=256 2>/dev/null; done" &
        echo $! >> "$pidfile"
        j=$((j + 1))
    done
    echo "load: $cores cpu spinners + 4 disk writers"
    ;;
stop)
    if [ -f "$pidfile" ]; then
        while read -r pid; do
            pkill -P "$pid" 2>/dev/null
            kill "$pid" 2>/dev/null
        done < "$pidfile"
        rm -f "$pidfile"
    fi
    pkill -f 'while :; do :; done' 2>/dev/null
    pkill -f 'dd if=/dev/zero' 2>/dev/null
    rm -rf "$scratch"
    echo "load: stopped"
    ;;
*)
    echo "usage: load.sh start|stop" >&2
    exit 2
    ;;
esac
