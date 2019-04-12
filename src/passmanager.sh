#!/usr/bin/env bash

# This file is licensed under the GPLv2+. Please see COPYING for more information.
# Based on pass from Jason A. Donenfeld <Jason@zx2c4.com>

# fail if any line fails, also fail if first part of pipe fails
set -euf -o pipefail

fatal() {
    printf "\e[0;31m${1}" >&2
    shift
    local e
    for e in "$@"; do
        printf -- ' %s' "$e" >&2
    done
    printf '\e[0m\n' >&2
    exit 1
}

# check dependencies
for cmd in sed head tr wc getopt base64 md5sum xclip; do
    hash "$cmd" 2> /dev/null || fatal "missing dependency: $cmd"
done


# ============================= global variables ============================= #

# version
VERSION="0.1.0"

# set default values in case they are not defined in environment
umask "${PASSMANAGER_UMASK:-077}" # only user can read and write
PREFIX="${PASSMANAGER_DIR:-${XDG_DATA_HOME:-${HOME}/.local/share}/passmanager}"
INDEX="${PREFIX}/index.gpg"
RECPS="${PREFIX}/recipients.gpg"

# gpg path and options
#export GPG_TTY="${GPG_TTY:-$(tty 2> /dev/null)}"
GPG="${PASSMANAGER_GPG:-$(command -v gpg2)}" || GPG="$(command -v gpg)" || \
    fatal "gpg or gpg2 not found"
GPG_OPTS=(${PASSMANAGER_GPG_OPTS:-} "--quiet" "--yes" "--compress-algo=none" "--no-encrypt-to")
[[ -n "${GPG_AGENT_INFO:-}" || $GPG == "gpg2" ]] && GPG_OPTS+=("--batch" "--use-agent")

# use git?
hash git 2> /dev/null && USE_GIT=1 || USE_GIT=0
USE_GIT="${PASSMANAGER_USE_GIT:-$USE_GIT}"
[[ $USE_GIT -eq 1 ]] && (hash git 2> /dev/null || fatal "git not found")

# editor: default to vi
EDIT=(${PASSMANAGER_EDITOR:-${EDITOR:-vi}})
([[ ${EDIT[0]} == vim ]] || [[ ${EDIT[0]} == nvim ]]) && EDIT+=(-c "set nobackup" -c "set noundofile")

# default password length
PASS_LENGTH="${PASSMANAGER_PASS_LENGTH:-25}"

# clipboard config
X_SELECTION="${PASSMANAGER_X_SELECTION:-clipboard}"
CLIP_TIME="${PASSMANAGER_CLIP_TIME:-15}"

# tool to use to delete files
DELETE=("rm" "-f")
hash shred 2> /dev/null && DELETE=("shred" "-fu")


# ============================== trap functions ============================== #

TMPFILES=()
delete_tmp_files() {
    local f
    for f in "${TMPFILES[@]}"; do
        [[ -e "$f" ]] && "${DELETE[@]}" "$f"
    done
}
trap delete_tmp_files INT TERM EXIT


# ============================= helper functions ============================= #

yesno() {
    [[ -t 0 ]] || return 0
    local response
    read -r -p "$1 [y/N] " response
    [[ $response == [yY] ]] || exit 1
}

printok() {
    printf "\e[0;32m${1}" >&2
    shift
    local e
    for e in "$@"; do
        printf -- ' %s' "$e" >&2
    done
    printf '\e[0m\n' >&2
}

copy() {
    [[ $# -eq 2 ]] || fatal "copy needs exactly two arguments"
    # "securly" delete destination file if it exists
    [[ -e "$2" ]] && ("${DELETE[@]}" "$2" || fatal "failed to delete $2")
    cp "$1" "$2" || fatal "failed to copy $1 to $2"
}

git_commit() {
    # $1 = commit message
    [[ $USE_GIT -eq 1 ]] || return 0
    cd "$PREFIX" 2> /dev/null || fatal "${PREFIX} does not exist"
    git add .
    git commit -q -m "$1"
}

rand_id() {
    # $1 = length ; ($2 == 2 : symbols and capitals ; $2 == 1 : capitals)
    local charset='a-z0-9'
    [[ "$2" -ge 1 ]] && charset="${charset}A-Z"
    [[ "$2" -ge 2 ]] && charset="$charset"'`^~<=>|_\-,;:!?/."()[]{}@$*\\&#%+'"'"
    printf -- "%s\n" "$(cat /dev/urandom | tr -dc "$charset" | head -c "$1")"
}

path_to_id() {
    [[ -f "$INDEX" ]] || return 0
    local pathre="$(sed -r 's/([./])/\\\1/g' <<< "$1")"
    local strid="$(cat "$INDEX" | $GPG -d "${GPG_OPTS[@]}" | sed -rn 's/^'"$pathre"'\t(.*)$/\1/p')"
    [[ $(wc -l <<< "$strid") -le 1 ]] || fatal "corrupt index: path $1 present more than once"
    cat <<< "$strid"
}

id_to_path() {
    [[ -f "$INDEX" ]] || return 0
    local path="$(cat "$INDEX" | $GPG -d "${GPG_OPTS[@]}" | sed -rn 's/^(.*)\t'"$1"'$/\1/p')"
    [[ $(wc -l <<< "$path") -le 1 ]] || fatal "corrupt index: ID $1 present more than once"
    cat <<< "$path"
}

# NOTE: do NOT call this function in a subshell $(tmp_file) or TMPFILES won't be updated
#       instead do: tmp_file; local tmp="${TMPFILES[-1]}"
tmp_file() {
    local tmpdir="/tmp"
    # prefer /dev/shm if it exists
    [[ -d /dev/shm && -w /dev/shm ]] && tmpdir="/dev/shm"
    local path="$tmpdir/$(rand_id 16 0)"
    # generate non-existant random path
    while [[ -e "$path" ]]; do
        path="$tmpdir/$(rand_id 16 0)"
    done
    TMPFILES+=("$path")
}

load_recipients() {
    [[ -f "$RECPS" ]] || fatal "no recipient file present: please run '$PROGRAM init'"
    # GPG_RECIPIENTS is a global variable
    GPG_RECIPIENTS=()
    GPG_RECIPIENTS_ARGS=()
    local recp
    while read -r recp; do
        GPG_RECIPIENTS+=("$recp")
        GPG_RECIPIENTS_ARGS+=('-R' "$recp")
    done <<< "$(cat "$RECPS" | $GPG -d "${GPG_OPTS[@]}")"
    [[ ${#GPG_RECIPIENTS[@]} -gt 0 ]] || fatal "no recipient defined"
}

add_to_index() {
    # $1 = path ; $2 = id
    tmp_file; local tmp="${TMPFILES[-1]}"
    if ! [[ -f "$INDEX" ]]; then
        # create new index
        printf -- "%s\t%s\n" "$1" "$2" | \
            $GPG -e "${GPG_OPTS[@]}" "${GPG_RECIPIENTS_ARGS[@]}" -o "$tmp" || \
            fatal "failed to encrypt index"
    else
        # check existing index
        [[ -z "$(path_to_id "$1")" && -z "$(id_to_path "$2")" ]] || \
            fatal "password with this path or id already exists"
        (cat "$INDEX" | $GPG -d "${GPG_OPTS[@]}" ; printf -- "%s\t%s\n" "$1" "$2") | \
            $GPG -e "${GPG_OPTS[@]}" "${GPG_RECIPIENTS_ARGS[@]}" -o "$tmp" || \
            fatal "failed to encrypt index"
    fi
    copy "$tmp" "$INDEX" || fatal "failed to update index"
}

remove_from_index() {
    # $1 = id
    [[ -f "$INDEX" ]] || fatal "cannot remove from nonexistent index"
    tmp_file; local tmp="${TMPFILES[-1]}"
    cat "$INDEX" | $GPG -d "${GPG_OPTS[@]}" | sed -r '/.*\t'"$1"'$/d' | \
        $GPG -e "${GPG_OPTS[@]}" "${GPG_RECIPIENTS_ARGS[@]}" -o "$tmp" || \
        fatal "failed to encrypt index"
    copy "$tmp" "$INDEX" || fatal "failed to update index"
}

# not a correct tree but good enough to work with PassFF
print_tree() {
    local IFS='/'
    local prev=() current path
    for path in "$@"; do
        # split path
        read -r -a current <<< "$path"
        local i j
        for i in "${!current[@]}"; do
            if [[ $i -eq $((${#current[@]} - 1)) ]]; then
                printf '|-- %s\n' "${current[$i]}"
                break
            fi
            if [[ $i -ge ${#prev[@]} || "${current[$i]}" != "${prev[$i]}" ]]; then
                printf '|-- %s\n' "${current[$i]}"
                for ((j = 0; j <= $i; ++j)); do
                    printf '|   '
                done
            else
                printf '|   '
            fi
        done
        prev=("${current[@]}")
    done
}

reencrypt_file() {
    [[ -f "$1" ]] || fatal "missing file: $1"
    tmp_file; local tmp="${TMPFILES[-1]}"
    cat "$1" | $GPG -d "${GPG_OPTS[@]}" | \
        $GPG -e "${GPG_OPTS[@]}" "${GPG_RECIPIENTS_ARGS[@]}" -o "$tmp" || \
        fatal "failed to re-encrypt $1"
    copy "$tmp" "$1" || fatal "failed to re-encrypt $1"
}

reencrypt_all() {
    [[ -f "$INDEX" ]] || return 0
    local id
    while read -r id; do
        reencrypt_file "${PREFIX}/${id}.gpg"
    done <<< "$(cat "$INDEX" | $GPG -d "${GPG_OPTS[@]}" | sed -rn 's/^.*\t(.*)$/\1/p' | sort)"
}

clip() {
    # This base64 business is because bash cannot store binary data in a shell
    # variable. Specifically, it cannot store nulls nor (non-trivally) store
    # trailing new lines.
    local sleep_argv0="password store sleep on display $DISPLAY"
    pkill -f "^$sleep_argv0" 2> /dev/null && sleep 0.5
    local before="$(xclip -o -selection "$X_SELECTION" 2> /dev/null | base64)"
    echo -n "$1" | xclip -selection "$X_SELECTION" || \
        fatal "failed to copy data to the clipboard"
    (
        ( exec -a "$sleep_argv0" bash <<<"trap 'kill %1' TERM; sleep '$CLIP_TIME' & wait" )
        local now="$(xclip -o -selection "$X_SELECTION" | base64)"
        [[ $now != $(echo -n "$1" | base64) ]] && before="$now"

        # It might be nice to programatically check to see if klipper exists,
        # as well as checking for other common clipboard managers. But for now,
        # this works fine -- if qdbus isn't there or if klipper isn't running,
        # this essentially becomes a no-op.
        #
        # Clipboard managers frequently write their history out in plaintext,
        # so we axe it here:
        qdbus org.kde.klipper /klipper org.kde.klipper.klipper.clearClipboardHistory &> /dev/null ||
            true

        echo "$before" | base64 -d | xclip -selection "$X_SELECTION"
    ) 2> /dev/null & disown
    printok "Copied $2 to clipboard. Will clear in $CLIP_TIME seconds."
}

digest() {
    if [[ $? -gt 0 ]]; then
        echo "$@" | md5sum | sed -rn 's/^([0-9a-fA-F]+)\s.*/\1/p'
    else
        md5sum | sed -rn 's/^([0-9a-fA-F]+)\s.*/\1/p'
    fi
}


# ============================= command functions ============================ #

cmd_help() {
    cat <<-_EOF
	Usage:
	    $PROGRAM init [-f] gpg-id...
	        Initialize new password storage and use gpg-id for encryption.
	        Re-encrypt all existing passwords using new gpg-id [-f].
	    $PROGRAM [ls]
	        List passwords.
	    $PROGRAM [show] [--clip[=line-number],-c[line-number]] pass-name
	        Show existing password and optionally put it on the clipboard.
	        If put on the clipboard, it will be cleared in $CLIP_TIME seconds.
	    $PROGRAM find pass-names...
	        List passwords that match pass-names.
	    $PROGRAM edit pass-name
	        Insert a new password or edit an existing password using ${EDIT[0]}
	    $PROGRAM generate [--no-symbols,-n] [--in-place,-i | --force,-f] pass-name [pass-length]
	        Generate a new password of pass-length (or $PASS_LENGTH if unspecified).
	        Optionally generate a password without symbols [-n].
	        Optionally replace only the first line of an existing file with a new password [-i].
	        Or overwrite the whole file with a new password [-f].
	    $PROGRAM rm [--force,-f] pass-name
	        Remove existing password, optionally forcefully.
	    $PROGRAM mv [--force,-f] old-path new-path
	        Renames or moves old-path to new-path, optionally forcefully, selectively reencrypting.
	    $PROGRAM cp [--force,-f] old-path new-path
	        Copies old-path to new-path, optionally forcefully, selectively reencrypting.
	    $PROGRAM git git-command-args...
	        If the password store is a git repository, execute a git command
	        specified by git-command-args.
	    $PROGRAM path id
	        Show the path corresponding to the provided id. Useful to decode git log messages.
	    $PROGRAM help
	        Show this text.
	    $PROGRAM version
	        Show version information.
	_EOF
}

cmd_version() {
    printf 'passmanager version %s\n' "$VERSION"
}

cmd_init() {
    # parse arguments
    local opts err=0 force=0
    opts="$(getopt -o f -l force: -n "$PROGRAM" -- "$@")" || err=1
    eval set -- "$opts"
    while true; do case $1 in
        -f|--force) force=1; shift ;;
        --) shift; break ;;
    esac done
    [[ $err -eq 0 && $# -gt 0 ]] || fatal "Usage: $PROGRAM $COMMAND [-f,--force] gpg-id..."

    # check if new password store
    local new_store=0
    [[ -f "$RECPS" ]] || new_store=1
    [[ $new_store -eq 1 || $force -eq 1 ]] || \
        fatal "password store already exists: use -f to re-encrypt with new keys"

    local prev_recps=""
    if [[ $new_store -eq 1 ]]; then
        mkdir -p "$PREFIX" || fatal "failed to create password store directory"
    else
        load_recipients
        prev_recps="$(printf '%s\n' "${GPG_RECIPIENTS[@]}" | sort -u | digest)"
    fi

    # parse new recipients.
    GPG_RECIPIENTS=()
    GPG_RECIPIENTS_ARGS=()
    local recp
    for recp in "$@"; do
        GPG_RECIPIENTS+=("$recp")
        GPG_RECIPIENTS_ARGS+=('-R' "$recp")
    done

    # check if recipients have changed
    local new_recps="$(printf '%s\n' "${GPG_RECIPIENTS[@]}" | sort -u | digest)"
    [[ "$new_recps" != "$prev_recps" ]] || \
        fatal "password store is already encrypted for these recipients"

    # write recipients in encrypted file
    tmp_file; local tmp="${TMPFILES[-1]}"
    printf '%s\n' "${GPG_RECIPIENTS[@]}" | sort -u | \
        $GPG -e "${GPG_OPTS[@]}" "${GPG_RECIPIENTS_ARGS[@]}" -o "$tmp" || \
        fatal "failed to encrypt recipient file"
    copy "$tmp" "$RECPS" || fatal "failed to add new recipient"

    if [[ $new_store -eq 1 ]]; then
        printok "password store successfully created"
        # initialize git repo
        [[ $USE_GIT -eq 1 ]] || return 0
        cd "$PREFIX"
        git init -q || fatal "failed to initialize git repository"
        echo '*.gpg diff=gpg' > "$PREFIX/.gitattributes"
        git config --local user.name "user"
        git config --local user.email "user@pc"
        git config --local diff.gpg.binary true
        git config --local diff.gpg.textconv "$GPG -d ${GPG_OPTS[*]}"
        git_commit "initialized new password store"
    else
        reencrypt_all
        git_commit "password store re-encrypted with different keys"
        printok "passwords re-encrypted with keys: ${GPG_RECIPIENTS[@]}"
    fi
}

cmd_git() {
    [[ $USE_GIT -eq 1 ]] || fatal "git not enabled"
    cd "$PREFIX" 2> /dev/null || fatal "${PREFIX} does not exist"
    git "$@"
}

cmd_show() {
    [[ -d "$PREFIX" ]] || fatal "password store is empty: please run '$PROGRAM init'"
    # parse options
    local opts clip_location=1 clip=0
    opts="$(getopt -o c:: -l clip:: -n "$PROGRAM" -- "$@")" ||
        fatal "Usage: $PROGRAM $COMMAND [--clip[=line-number],-c[line-number]] [pass-name]"
    eval set -- "$opts"
    while true; do case $1 in
        -c|--clip) clip=1; clip_location="${2:-1}"; shift 2 ;;
        --) shift; break ;;
    esac done

    # show password tree
    if [[ -z "$@" ]]; then
        echo "Password Store"
        [[ -f "$INDEX" ]] || return 0
        # extract all paths from encrypted index
        local paths=() path
        while read -r path; do
            paths+=("$path")
        done <<< "$(cat "$INDEX" | $GPG -d "${GPG_OPTS[@]}" | sed -rn 's/^(.*)\t.*$/\1/p' | sort)"
        # print tree
        print_tree "${paths[@]}"
        return 0
    fi

    # look in index which gpg file corresponds to provided path
    local path="$1"
    local id="$(path_to_id "$1")"
    [[ -n "$id" ]] || fatal "$1 is not in the password store"
    local passfile="${PREFIX}/${id}.gpg"
    [[ -f "$passfile" ]] || fatal "corrupted index: ${id} in index but GPG file not present"

    # decrypt password file
    if [[ $clip -eq 0 ]]; then
        $GPG -d "${GPG_OPTS[@]}" "$passfile" || fatal "failed to decrypt ${passfile}"
    else
        [[ $clip_location =~ ^[0-9]+$ ]] || fatal "Clip location '$clip_location' is not a number."
        local pass="$($GPG -d "${GPG_OPTS[@]}" "$passfile" | tail -n +${clip_location} | head -n 1)"
        [[ -n $pass ]] || fatal "nothing at line ${clip_location} of ${path}."
        clip "$pass" "$path"
    fi
}

cmd_find() {
    [[ -z "$@" ]] && fatal "Usage: $PROGRAM $COMMAND pass-names..."
    [[ -f "$INDEX" ]] || return 0
    local args=() arg
    for arg in "$@"; do
        args+=('-e' "$arg")
    done
    # extract all paths from encrypted index
    local paths=() path
    while read -r path; do
        paths+=("$path")
    done <<< "$(cat "$INDEX" | $GPG -d "${GPG_OPTS[@]}" | sed -rn 's/^(.*)\t.*$/\1/p' | \
        grep -F "${args[@]}" | sort)"
    print_tree "${paths[@]}"
}

cmd_generate() {
    # parse arguments
    local opts force=0 level=2 inplace=0 err=0
    opts="$(getopt -o nif -l no-symbols,in-place,force -n "$PROGRAM" -- "$@")" || err=1
    eval set -- "$opts"
    while true; do case $1 in
        -n|--no-symbols) level=1; shift ;;
        -f|--force) force=1; shift ;;
        -i|--in-place) inplace=1; shift ;;
        --) shift; break ;;
    esac done
    [[ $err -eq 0 && ($# -eq 1 || $# -eq 2) && ($inplace -eq 0 || $force -eq 0) ]] || \
        fatal "Usage: $PROGRAM $COMMAND [--no-symbols,-n] [--in-place,-i | --force,-f] pass-name [pass-length]"

    # generate a new id for path
    load_recipients
    local path="$1"
    local len="${2:-$PASS_LENGTH}"
    local id="$(path_to_id "$path")"
    local pass="$(rand_id $len $level)"
    local passfile
    if [[ -n "$id" ]]; then
        passfile="${PREFIX}/${id}.gpg"
        [[ -f "$passfile" ]] || fatal "corrupted index: ${id} in index but GPG file not present"
        # modify an existing file
        tmp_file; local tmp="${TMPFILES[-1]}"
        if [[ $inplace -eq 1 ]]; then
            # replace first line of file with new password
            (printf "%s\n" "$pass"; cat "$passfile" | $GPG -d "${GPG_OPTS[@]}" | tail -n +2) | \
                $GPG -e "${GPG_OPTS[@]}" "${GPG_RECIPIENTS_ARGS[@]}" -o "$tmp" || \
                fatal "failed to encrypt password"
        elif [[ $force -eq 1 ]]; then
            # overwrite file with only the password
            $GPG -e "${GPG_OPTS[@]}" "${GPG_RECIPIENTS_ARGS[@]}" -o "$tmp" <<< "$pass" || \
                fatal "failed to encrypt password"
        else
            fatal "$path already exists: use -f or -i option to overwrite"
        fi
        copy "$tmp" "$passfile" || fatal "failed to replace password"
        git_commit "replaced password for ${id}"
    else
        # generate a new file
        id="$(rand_id 16 0)"
        passfile="${PREFIX}/${id}.gpg"
        while [[ -e "$passfile" ]]; do
            id="$(rand_id 16 0)"
            passfile="${PREFIX}/${id}.gpg"
        done
        $GPG -e "${GPG_OPTS[@]}" "${GPG_RECIPIENTS_ARGS[@]}" -o "$passfile" <<< "$pass" || \
            fatal "failed to encrypt password"
        add_to_index "$path" "$id"
        git_commit "generated new password for ${id}"
    fi
}

cmd_edit() {
    [[ $# -ne 1 ]] && die "Usage: $PROGRAM $COMMAND pass-name"
    load_recipients

    local path="$1"
    local id="$(path_to_id "$path")"
    local passfile new_pass=0
    tmp_file; local tmp="${TMPFILES[-1]}"
    if [[ -n "$id" ]]; then
        # edit existing file
        passfile="${PREFIX}/${id}.gpg"
        [[ -f "$passfile" ]] || fatal "corrupted index: ${id} in index but GPG file not present"
        cat "$passfile" | $GPG -d "${GPG_OPTS[@]}" -o "$tmp"
    else
        # generate new file (pre-fill it with a random password)
        new_pass=1
        id="$(rand_id 16 0)"
        passfile="${PREFIX}/${id}.gpg"
        while [[ -e "$passfile" ]]; do
            id="$(rand_id 16 0)"
            passfile="${PREFIX}/${id}.gpg"
        done
        local pass="$(rand_id $PASS_LENGTH 2)"
        cat > "$tmp" <<< "$pass"
    fi

    # check if the password file was edited and that it is not empty
    local before_edit="$(cat "$tmp" | digest)"
    "${EDIT[@]}" "$tmp" || fatal "${EDIT[@]} returned an error: $?"
    [[ $new_pass -eq 1 || "$(cat "$tmp" | digest)" != "$before_edit" ]] || \
        fatal "password file was not modified"
    [[ $(cat "$tmp" | grep -v '^$' | wc -l) -gt 0 ]] || fatal "edited password file was empty"

    # re-encrypt modified file
    tmp_file; local tmp2="${TMPFILES[-1]}"
    cat "$tmp" | $GPG -e "${GPG_OPTS[@]}" "${GPG_RECIPIENTS_ARGS[@]}" -o "$tmp2" || \
        fatal "failed to encrypt password"
    [[ $new_pass -eq 0 ]] || add_to_index "$path" "$id"
    copy "$tmp2" "$passfile" || fatal "failed to copy encrypted password file"
    [[ $new_pass -eq 0 ]] && git_commit "edited password for ${id}" || \
        git_commit "generated new password for ${id}"
}

cmd_delete() {
    # parse arguments
    local opts force=0 err=0
    opts="$(getopt -o f -l force -n "$PROGRAM" -- "$@")" || err=1
    eval set -- "$opts"
    while true; do case $1 in
        -f|--force) force=1; shift ;;
        --) shift; break ;;
    esac done
    [[ $err -eq 0 && $# -eq 1 ]] || fatal "Usage: $PROGRAM $COMMAND [--force,-f] pass-name"

    # get id corresponding to provided path
    local path="$1"
    local id="$(path_to_id "$path")"
    [[ -n "$id" ]] || fatal "$1 is not in the password store"
    local passfile="${PREFIX}/${id}.gpg"

    # remove from index and delete password file
    load_recipients
    [[ $force -eq 1 ]] || yesno "Do you really want to delete $path"
    remove_from_index "$id"
    "${DELETE[@]}" "$passfile"
    git_commit "delete $id from password store"
    printok "deleted $path from password store"
}

cmd_copy_move() {
    # parse arguments
    local opts move=1 force=0 err=0 action="$1"
    if [[ $1 == "copy" ]]; then
        move=0
        action="copied"
    fi
    shift
    opts="$(getopt -o f -l force -n "$PROGRAM" -- "$@")" || err=1
    eval set -- "$opts"
    while true; do case $1 in
        -f|--force) force=1; shift ;;
        --) shift; break ;;
    esac done
    [[ $err -eq 0 && $# -eq 2 ]] || fatal "Usage: $PROGRAM $COMMAND [--force,-f] old-path new-path"
    [[ "$1" != "$2" ]] || fatal "old-path and new-path cannot be the same"

    # check paths
    local path1="$1"
    local id1="$(path_to_id "$path1")"
    [[ -n "$id1" ]] || fatal "$1 is not in the password store"
    local srcfile="${PREFIX}/${id1}.gpg"
    [[ -f "$srcfile" ]] || fatal "corrupted index: ${id1} in index but GPG file not present"
    local path2="$2"
    local id2="$(path_to_id "$path2")"
    # check if destination already exists
    [[ -z "$id2" || $force -eq 1 ]] || fatal "$path2 already exists: use -f option to replace"

    load_recipients
    local dstfile="${PREFIX}/${id2}.gpg"
    if [[ -n "$id2" ]]; then
        remove_from_index "$id2"
        "${DELETE[@]}" "$dstfile"
    else
        id2="$(rand_id 16 0)"
        dstfile="${PREFIX}/${id2}.gpg"
        while [[ -e "$dstfile" ]]; do
            id2="$(rand_id 16 0)"
            dstfile="${PREFIX}/${id2}.gpg"
        done
    fi
    local dstfile="${PREFIX}/${id2}.gpg"
    copy "$srcfile" "$dstfile" || fatal "failed to $action encrypted password file"
    add_to_index "$path2" "$id2"

    if [[ $move -eq 1 ]]; then
        "${DELETE[@]}" "$srcfile"
        remove_from_index "$id1"
        git_commit "moved password $id1 to $id2"
        printok "moved password $path1 to $path2"
    else
        git_commit "copied password $id1 to $id2"
        printok "copied password $path1 to $path2"
    fi
}

cmd_path() {
    [[ $# -ne 1 ]] && fatal "Usage: $PROGRAM $COMMAND id"
    [[ -f "$INDEX" ]] || return 0
    local path="$(id_to_path "$1")"
    [[ -n "$path" ]] && printf -- '%s\n' "$path" || fatal "no password with id $1 in password store"
}


# =================================== main =================================== #

PROGRAM="${0##*/}"
COMMAND="${1:-}"

case "$COMMAND" in
    init) shift;                cmd_init "$@" ;;
    help|--help|-h) shift;      cmd_help "$@" ;;
    version|--version) shift;   cmd_version "$@" ;;
    show|ls|list) shift;        cmd_show "$@" ;;
    find|search) shift;         cmd_find "$@" ;;
    edit) shift;                cmd_edit "$@" ;;
    generate) shift;            cmd_generate "$@" ;;
    delete|rm|remove) shift;    cmd_delete "$@" ;;
    rename|mv) shift;           cmd_copy_move "move" "$@" ;;
    copy|cp) shift;             cmd_copy_move "copy" "$@" ;;
    git) shift;                 cmd_git "$@" ;;
    path) shift;                cmd_path "$@" ;;
    *) COMMAND="show";          cmd_show "$@" ;;
esac
