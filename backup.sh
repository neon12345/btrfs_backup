#!/bin/bash
# license:
# Copyright 2023 neon12345 - https://github.com/neon12345 (6d315b99647aa9e440981da45a7aa9138ad4bdb256908b6266af57cf0d3478a2)
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this software
# and associated documentation files (the “Software”), to deal in the Software without restriction,
# including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the Software is furnished to
# do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all copies or
# substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED “AS IS”, WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
# PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
# COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN
# AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
#
# usage: ./backup.sh btrfs_root_main btrfs_root_mirror
# This script will create snapshots in btrfs_root_main/$BACKUP_DIR
# and incrementally copy them to btrfs_root_mirror/$BACKUP_DIR.
# A btrfs scrub is done when the current time is $SCRUB_DAYS past the
# last completed scrub, but only if any scrub was ever done on
# the main drive. (The scrub status is available)
# The cleanup algorithm will remove old snapshots but keep snapshots from:
#   a) all $KEEP_LAST days below the current time
#   b) one per day for $KEEP_DAY days below the current time
#   c) one per week for $KEEP_WEEK weeks below the current time
#   d) one per month for $KEEP_MONTH months below the current time
#   e) one for every year
# The cleanup will exit when snapshot dates from the future are discovered.
#
# when: You have two identical drives for backup storage and want to use one
#       as failover mirror. Instead of using any kind of raid, this script can
#       work as an on demand snapshot and mirror solution. Whenever new files
#       are copied to the main backup drive, which can potentially replace old
#       versions, this script can be called to make a snapshot and mirror the
#       data to the failover backup drive.
#       If either disk dies, the recovery strategy is to simply copy the
#       content of the remaining disk to an equal new one. And if the replaced disk
#       was the mirror, remove the root files and only keep the snapshot directory.
#       If the replaced disk was the main disk, copy the top snapshot to the root
#       directory. ("cp -aRx --remove-destination --reflink=always main_top/* main_root/")
#       If both disks die, all data is lost obviously.
#       Therefore this should only be one backup and not a file storage solution.
#       For an only ever two disk backup system, this can make more sense
#       compared to a parity based solution.
#
# requirements: Two equal sized disks with btrfs.
#               $BACKUP_DIR must not exist on either disk when first called.
#
set -o pipefail
trap "exit 1" 10
PROC=$$

BTRFS_TARGET="$1"
BTRFS_MIRROR="$2"

# user options
KEEP_LAST=2
KEEP_DAY=7
KEEP_WEEK=4
KEEP_MONTH=24
SCRUB_DAYS=30
BACKUP_DIR="backup_snapshots" # this will become a subvolume in the btrfs roots

TARGET_DIR="$BTRFS_TARGET/$BACKUP_DIR"
MIRROR_DIR="$BTRFS_MIRROR/$BACKUP_DIR"
TARGET_TOP="$TARGET_DIR/top"
MIRROR_TOP="$MIRROR_DIR/top"
TOP_FILE=$(basename $(readlink "$TARGET_TOP" 2>/dev/null) 2>/dev/null)
TARGET_TOP_REAL="$TARGET_DIR/$TOP_FILE"
MIRROR_TOP_REAL="$MIRROR_DIR/$TOP_FILE"
SCRUB_INFO=$(btrfs scrub status "$BTRFS_TARGET" | grep start | sed 's/[^:]*\://')
if [[ ! $? -eq 0 ]]; then
    exit 1
fi
SCRUB_TIME=$(date -ud "$SCRUB_INFO" +"%s")

CURRENT_DATE=$(date "+%s")

function date_from_ts() {
    local TS="$1"
    local FORMAT="$2"
    local OTHER="$3"
    date -d "$(date -d @$TS "+%Y-%m-%d %H:%M:%S") $OTHER" "$FORMAT"
}

CURRENT_TS=$(date_from_ts "$CURRENT_DATE" "+%s")
CURRENT_DAY=$(date_from_ts "$CURRENT_DATE" "+%d")
CURRENT_WEEK=$(date_from_ts "$CURRENT_DATE" "+%V")
CURRENT_MONTH=$(date_from_ts "$CURRENT_DATE" "+%m")
CURRENT_YEAR=$(date_from_ts "$CURRENT_DATE" "+%Y")

FILE="$CURRENT_TS-$CURRENT_DAY-$CURRENT_MONTH-$CURRENT_YEAR-$CURRENT_WEEK.inc.backup"
TARGET_FILE="$TARGET_DIR/$FILE"
MIRROR_FILE="$MIRROR_DIR/$FILE"

if [[ ! -d "$TARGET_DIR" ]]; then
    btrfs -q subvolume create "$TARGET_DIR" || exit 1
fi
if [[ ! -d "$MIRROR_DIR" ]]; then
    btrfs -q subvolume create "$MIRROR_DIR" || exit 1
fi

function err() {
    echo "$@" 1>&2;
}

function fatal() {
    err "$@"
    kill -10 $PROC
}

function sscanf() {
    local str="$1"
    if [[ "$str" =~ ^([0-9]+)-([0-9]+)-([0-9]+)-([0-9]+)-([0-9]+).inc.backup$ ]]; then
        TS=${BASH_REMATCH[1]}
        DAY=${BASH_REMATCH[2]}
        MONTH=${BASH_REMATCH[3]}
        YEAR=${BASH_REMATCH[4]}
        WEEK=${BASH_REMATCH[5]}
        return
    fi
    TS="-1"
    false
}

function date_ts_from_ymd() {
    local YEAR="$1"
    local MONTH="$2"
    local DAY="$3"
    date -d "$YEAR-$MONTH-$DAY 00:00:00" "+%s"
}

function date_in_range() {
    local TS="$1"
    local MIN="$2"
    local MAX="$3"
    if (( CURRENT_TS < TS )); then
        fatal "time is in the future"
        exit 1
    fi
    (( MIN <= TS && TS < MAX ))
}

function date_current_ts() {
    local OTHER="$1"
    local FROM="$2"
    if [[ -z "$FROM" ]]; then
        FROM="$CURRENT_TS"
    fi
    date_from_ts "$FROM" "+%s" "$OTHER"
}

function find_snapshots() {
    local MIN_YEAR=9999
    while IFS= read -r -d $'\0' file; do
        THE_FILE=$(basename $file)
        if sscanf "$THE_FILE"; then
            if (( MIN_YEAR > YEAR )); then
                MIN_YEAR=$YEAR
            fi
            echo "$THE_FILE"
        fi
    done < <(find "$TARGET_DIR" -maxdepth 1 -type d -print0 | sort -Vz)
    echo $MIN_YEAR
}

function find_remove() {
    local MIN=0
    local MAX=0
    local CURRENT=0
    local CURRENT2=0
    local SNAPSHOTS=$(find_snapshots)
    local MIN_YEAR=0
    local KEEP=""
    local MAP=""
    declare -A MAP

    function find_keep() {
        if (( KEEP_LAST > 0 )); then
            MIN=$(date_current_ts "$(( KEEP_LAST )) days ago")
            MAX=$(date_current_ts "1 days")
            for file in $SNAPSHOTS; do
                sscanf "$file"
                if date_in_range $TS $MIN $MAX; then
                    echo "$file"
                fi
                MIN_YEAR="$file"
            done
        fi

        if (( KEEP_DAY > 0 )); then
            for (( j=0; j < $KEEP_DAY; j++ )); do
                MIN=$(date_current_ts "$j days ago")
                MAX=$(date_current_ts "1 days" $MIN)
                for file in $SNAPSHOTS; do
                    sscanf "$file"
                    if date_in_range $TS $MIN $MAX; then
                        echo "$file"
                        break
                    fi
                done
            done
        fi

        if (( KEEP_WEEK > 0 )); then
            local WEEK_DAY=$(date_from_ts $(date_current_ts "") "+%u")
            CURRENT=$(date_current_ts "$WEEK_DAY days ago")
            for (( j=0; j < KEEP_WEEK; j++ )); do
                MIN=$CURRENT
                MAX=$(date_current_ts "8 days" $MIN)
                for file in $SNAPSHOTS; do
                    sscanf "$file"
                    if date_in_range $TS $MIN $MAX; then
                        echo "$file"
                        break
                    fi
                done
                CURRENT=$(date_current_ts "7 days ago" $CURRENT)
            done
        fi

        if (( KEEP_MONTH > 0 )); then
            CURRENT=$(date_ts_from_ymd "$CURRENT_YEAR" "$CURRENT_MONTH" "1")
            CURRENT2=$(date_current_ts "1 months" $CURRENT)
            for (( j=0; j < KEEP_MONTH; j++ )); do
                MIN=$CURRENT
                MAX=$CURRENT2
                for file in $SNAPSHOTS; do
                    sscanf "$file"
                    if date_in_range $TS $MIN $MAX; then
                        echo "$file"
                        break
                    fi
                done
                CURRENT2=$CURRENT
                CURRENT=$(date_current_ts "1 months ago" $CURRENT)
            done
        fi

        for (( j=MIN_YEAR; j <= CURRENT_YEAR; j++ )); do
            MIN=$(date_ts_from_ymd "$j" "1" "1")
            MAX=$(date_ts_from_ymd "$(( j + 1))" "1" "1")
            for file in $SNAPSHOTS; do
                sscanf "$file"
                if date_in_range $TS $MIN $MAX; then
                    echo "$file"
                    break
                fi
            done
        done
    }

    KEEP=$(find_keep | sort -u)

    for file in $KEEP; do
        MAP["$file"]=1
    done

    for file in $SNAPSHOTS; do
        if [[  ${MAP["$file"]} != 1  ]]; then
            if (( ${#file} > 10 )); then
                echo "$file"
            fi
        fi
    done
}

do_scrub() {
    TARGET="$1"
    SCRUB_STATE=$(btrfs scrub status "$TARGET" | grep Status: | sed 's/[^:]*\://' | tr -d '[:space:]')
    SCRUB_ERR=$(test -z "$(btrfs scrub status $TARGET | grep 'no errors found')" && echo "true" || echo "false")
    if [[ "$SCRUB_ERR" == "true" ]]; then
        echo "scrub error: $TARGET"
        exit 1
    fi
    case $SCRUB_STATE in
        running)
        btrfs scrub cancel "$TARGET" && btrfs scrub resume -B "$TARGET"
        ;;

        interrupted|aborted)
        btrfs scrub resume -B "$TARGET"
        ;;

        finished)
        btrfs scrub start -B "$TARGET"
        ;;

       *)
       exit 1
       ;;
    esac
    exit $?
}

if [[ "$TOP_FILE" == "$FILE" ]]; then
    err "$FILE exists, try later."
    exit 1
fi

# do a scrub of main and backup disk
SCRUB_TIME=$(date_current_ts "$SCRUB_DAYS days" $SCRUB_TIME)
if (( CURRENT_TS >= SCRUB_TIME )); then
    scrub_pids=()
    do_scrub "$BTRFS_TARGET" &
    scrub_pids+=($!)
    do_scrub "$BTRFS_MIRROR" &
    scrub_pids+=($!)

    for pid in "${scrub_pids[@]}"; do
        wait "$pid"
        if [[ ! $? -eq 0 ]]; then
            exit 1
        fi
    done
fi

# add a new snapshot
btrfs -q subvolume snapshot -r "$BTRFS_TARGET" "$TARGET_FILE" || exit 1

# send/receive the newly created snapshot to backup disk(s)
if [[ -n "$TOP_FILE" ]]; then
    btrfs -q send -p "$TARGET_TOP_REAL" "$TARGET_FILE" | btrfs -q receive "$MIRROR_DIR"
else
    btrfs -q send "$TARGET_FILE" | btrfs -q receive "$MIRROR_DIR"
fi
if [[ ! $? -eq 0 ]]; then
    btrfs -q subvolume delete "$TARGET_FILE"
    err "btrfs send/receive failed"
    exit 1
fi

#update top link
rm -f "$TARGET_TOP"
ln -s "$TARGET_FILE" "$TARGET_TOP"
rm -f "$MIRROR_TOP"
ln -s "$MIRROR_FILE" "$MIRROR_TOP"

# do smart remove and delete snapshots from source and dest disk(s)
for line in $(find_remove); do
    #echo "remove: $line"
    btrfs -q subvolume delete "$TARGET_DIR/$line" || exit 1
    btrfs -q subvolume delete "$MIRROR_DIR/$line" || exit 1
done
