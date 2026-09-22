#!/usr/bin/env bash
set -euo pipefail

# Incrementally seed or relay a large kernel repository without requiring one
# monolithic push.  Designed for the NextGen linux-at91 tree, but generic.
#
# seed  : snapshot the CURRENT working tree into a fresh batched history and
#         push each batch immediately.
# relay : replay that already-batched history to another remote one commit at
#         a time, again pushing after every commit.

SCRIPT_NAME=${0##*/}
DEFAULT_BATCH_MIB=${BATCH_MIB:-64}
MAX_FILE_MIB=${MAX_FILE_MIB:-95}

log()
{
    printf '[%(%Y-%m-%d %H:%M:%S)T] %s\n' -1 "$*"
}

die()
{
    printf 'error: %s\n' "$*" >&2
    exit 1
}

usage()
{
    cat <<USAGE
Usage:
  $SCRIPT_NAME seed  <target-remote-or-url> <target-branch> [batch-MiB]
  $SCRIPT_NAME relay <source-remote-or-url> <source-branch> \\
                     <target-remote-or-url> <target-branch>

Examples from /data/git/NextGen-Linux/linux-at91:

  # Seed the ChatGPT-accessible working mirror in ~64 MiB pushes.
  ./$SCRIPT_NAME seed chatgpt chatgpt/current-nextgen 64

  # Then replay that same batched history into the Castle repository.
  ./$SCRIPT_NAME relay chatgpt chatgpt/current-nextgen \\
      origin chatgpt/current-nextgen

Environment overrides:
  BATCH_MIB=64             Default raw source bytes per seed commit/push.
  MAX_FILE_MIB=95          Refuse any individual file larger than this.
  BATCH_PUSH_WORKDIR=...   Persistent state directory. Defaults under .git.

Notes:
  * Run 'seed' from the source linux-at91 working tree you want to snapshot.
  * Tracked files plus non-ignored untracked files are included.
  * The following local-only files are excluded by default:
        mods/
        targets.log
        workingconfig
        workingconfig-rgb-drm
  * Ignored kernel build products (.config, *.o, generated output, etc.) are
    naturally excluded by 'git ls-files --exclude-standard'.
  * Do not edit the source tree while a seed import is running.
USAGE
}

require()
{
    command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

for cmd in git rsync stat awk sort; do
    require "$cmd"
done

SOURCE_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || \
    die "run this script from inside the source git working tree"
SOURCE_ROOT=$(cd "$SOURCE_ROOT" && pwd)
SOURCE_GIT_DIR=$(git -C "$SOURCE_ROOT" rev-parse --git-dir)
case "$SOURCE_GIT_DIR" in
    /*) ;;
    *) SOURCE_GIT_DIR="$SOURCE_ROOT/$SOURCE_GIT_DIR" ;;
esac
SOURCE_GIT_DIR=$(cd "$SOURCE_GIT_DIR" && pwd)

resolve_remote()
{
    local value=$1
    local url

    if url=$(git -C "$SOURCE_ROOT" remote get-url "$value" 2>/dev/null); then
        printf '%s\n' "$url"
    else
        printf '%s\n' "$value"
    fi
}

safe_name()
{
    printf '%s' "$1" | tr '/:@ ' '____' | tr -cd 'A-Za-z0-9._-'
}

remote_head()
{
    local remote=$1 branch=$2
    git ls-remote --heads "$remote" "refs/heads/$branch" | awk 'NR==1 {print $1}'
}

source_file_list()
{
    # Snapshot tracked files plus non-ignored untracked source.  Kernel build
    # output is normally ignored by the kernel .gitignore and is not included.
    git -C "$SOURCE_ROOT" ls-files -co --exclude-standard | sort -u | \
    awk '
        $0 == "targets.log" { next }
        $0 == "workingconfig" { next }
        $0 == "workingconfig-rgb-drm" { next }
        $0 == "kernel-batch-push.sh" { print; next }
        index($0, "mods/") == 1 { next }
        { print }
    '
}

write_seed_manifest()
{
    local manifest=$1
    local max_bytes=$((MAX_FILE_MIB * 1024 * 1024))
    local path size

    : > "$manifest"
    while IFS= read -r path; do
        [ -n "$path" ] || continue
        [ -e "$SOURCE_ROOT/$path" ] || [ -L "$SOURCE_ROOT/$path" ] || continue
        size=$(stat -c '%s' "$SOURCE_ROOT/$path")
        if (( size > max_bytes )); then
            die "file exceeds ${MAX_FILE_MIB} MiB safety limit: $path ($size bytes)"
        fi
        printf '%s\t%s\n' "$size" "$path" >> "$manifest"
    done < <(source_file_list)
}

seed_mode()
{
    [ $# -ge 2 ] && [ $# -le 3 ] || { usage; exit 2; }

    local target_arg=$1
    local target_branch=$2
    local batch_mib=${3:-$DEFAULT_BATCH_MIB}
    [[ "$batch_mib" =~ ^[0-9]+$ ]] && (( batch_mib > 0 )) || \
        die "batch-MiB must be a positive integer"

    local target_remote
    target_remote=$(resolve_remote "$target_arg")

    local tag stage_dir manifest batch_file marker complete
    tag=$(safe_name "${target_remote}_${target_branch}")
    local base_workdir=${BATCH_PUSH_WORKDIR:-$(CDPATH= cd -- "$SOURCE_ROOT/.." && pwd)/.nextgen-kernel-transfer}
    stage_dir="$base_workdir/seed-$tag"
    manifest="$stage_dir/.nextgen-batch-files"
    batch_file="$stage_dir/.nextgen-current-batch"
    marker="$stage_dir/.nextgen-batch-import"
    complete="$stage_dir/.nextgen-batch-complete"

    mkdir -p "$base_workdir"

    local rhead
    rhead=$(remote_head "$target_remote" "$target_branch" || true)

    if [ ! -d "$stage_dir/.git" ]; then
        if [ -n "$rhead" ]; then
            log "Resuming by cloning existing target branch $target_branch"
            git clone --single-branch --branch "$target_branch" \
                "$target_remote" "$stage_dir"
            [ -f "$marker" ] || \
                die "target branch exists but is not a batch-import branch: $target_branch"
        else
            log "Creating persistent staging repository: $stage_dir"
            rm -rf "$stage_dir"
            git init -q "$stage_dir"
            git -C "$stage_dir" config user.name \
                "$(git -C "$SOURCE_ROOT" config user.name || echo 'NextGen Kernel Import')"
            git -C "$stage_dir" config user.email \
                "$(git -C "$SOURCE_ROOT" config user.email || echo 'kernel-import@localhost')"
            git -C "$stage_dir" remote add target "$target_remote"

            local source_head source_branch upstream_url origin_url chatgpt_url
            source_head=$(git -C "$SOURCE_ROOT" rev-parse HEAD)
            source_branch=$(git -C "$SOURCE_ROOT" branch --show-current)
            upstream_url=$(git -C "$SOURCE_ROOT" remote get-url upstream 2>/dev/null || true)
            origin_url=$(git -C "$SOURCE_ROOT" remote get-url origin 2>/dev/null || true)
            chatgpt_url=$(git -C "$SOURCE_ROOT" remote get-url chatgpt 2>/dev/null || true)

            cat > "$marker" <<META
NextGen kernel batch snapshot import
source-commit=$source_head
source-branch=$source_branch
upstream=$upstream_url
origin=$origin_url
working-mirror=$chatgpt_url
target-branch=$target_branch
batch-mib=$batch_mib
META

            log "Building source manifest"
            write_seed_manifest "$manifest"

            git -C "$stage_dir" add .nextgen-batch-import .nextgen-batch-files
            git -C "$stage_dir" commit -q -m \
                "Start NextGen kernel snapshot import"
            log "Creating target branch with small metadata-only push"
            git -C "$stage_dir" push -u target \
                "HEAD:refs/heads/$target_branch"
        fi
    else
        if ! git -C "$stage_dir" remote get-url target >/dev/null 2>&1; then
            git -C "$stage_dir" remote add target "$target_remote"
        else
            git -C "$stage_dir" remote set-url target "$target_remote"
        fi
    fi

    [ -f "$marker" ] || die "staging repository is missing import marker"

    if [ -f "$complete" ]; then
        log "Seed already complete: $target_branch"
        exit 0
    fi

    # If the previous run committed a batch but the push failed, retry that
    # commit before adding anything else.
    rhead=$(remote_head "$target_remote" "$target_branch" || true)
    local lhead
    lhead=$(git -C "$stage_dir" rev-parse HEAD)
    if [ "$rhead" != "$lhead" ]; then
        [ -n "$rhead" ] || die "target branch disappeared during import"
        if git -C "$stage_dir" merge-base --is-ancestor "$rhead" "$lhead"; then
            log "Retrying previously unpushed batch"
            git -C "$stage_dir" push target "HEAD:refs/heads/$target_branch"
        else
            die "target branch moved independently; refusing to overwrite it"
        fi
    fi

    # On a resumed clone, the manifest is still tracked until the completion
    # commit. If it has already been removed, completion should also exist.
    [ -f "$manifest" ] || die "seed manifest is missing before completion"

    local batch_limit=$((batch_mib * 1024 * 1024))
    local batch_bytes=0 batch_count=0 total_files=0 total_bytes=0
    local size path
    local -a batch_paths=()

    flush_batch()
    {
        local count=${#batch_paths[@]}
        (( count > 0 )) || return 0

        : > "$batch_file"
        local p
        for p in "${batch_paths[@]}"; do
            printf '%s\0' "$p" >> "$batch_file"
        done

        rsync -aR --from0 --files-from="$batch_file" \
            "$SOURCE_ROOT/" "$stage_dir/"
        rm -f "$batch_file"

        git -C "$stage_dir" add -A
        batch_count=$((batch_count + 1))
        git -C "$stage_dir" commit -q -m \
            "Import kernel source batch $batch_count (${count} files, ${batch_bytes} bytes)"

        log "Pushing batch $batch_count: $count files, $batch_bytes raw bytes"
        git -C "$stage_dir" push target "HEAD:refs/heads/$target_branch"

        total_files=$((total_files + count))
        total_bytes=$((total_bytes + batch_bytes))
        batch_paths=()
        batch_bytes=0
    }

    while IFS=$'\t' read -r size path; do
        [ -n "$path" ] || continue

        # Skip source paths that are already present in a previously-pushed
        # batch. Marker/manifest files are not listed in the source manifest.
        if git -C "$stage_dir" ls-files --error-unmatch -- "$path" \
                >/dev/null 2>&1; then
            continue
        fi

        # Flush before adding a file that would cross the desired raw-size
        # limit, unless this is the first file in the batch.
        if (( batch_bytes > 0 && batch_bytes + size > batch_limit )); then
            flush_batch
        fi

        batch_paths+=("$path")
        batch_bytes=$((batch_bytes + size))

        if (( batch_bytes >= batch_limit )); then
            flush_batch
        fi
    done < "$manifest"

    flush_batch

    rm -f "$manifest"
    cat > "$complete" <<DONE
completed=$(date -u +%Y-%m-%dT%H:%M:%SZ)
source-commit=$(git -C "$SOURCE_ROOT" rev-parse HEAD)
target=$target_remote
target-branch=$target_branch
DONE
    git -C "$stage_dir" add -A
    git -C "$stage_dir" commit -q -m "Complete NextGen kernel snapshot import"
    log "Pushing completion marker"
    git -C "$stage_dir" push target "HEAD:refs/heads/$target_branch"

    log "Seed complete: $target_remote $target_branch"
    log "This run imported $total_files files / $total_bytes raw bytes"
    log "Persistent staging repo retained at: $stage_dir"
}

relay_mode()
{
    [ $# -eq 4 ] || { usage; exit 2; }

    local source_arg=$1
    local source_branch=$2
    local target_arg=$3
    local target_branch=$4
    local source_remote target_remote
    source_remote=$(resolve_remote "$source_arg")
    target_remote=$(resolve_remote "$target_arg")

    local tag relay_dir
    tag=$(safe_name "${source_remote}_${source_branch}")
    local base_workdir=${BATCH_PUSH_WORKDIR:-$(CDPATH= cd -- "$SOURCE_ROOT/.." && pwd)/.nextgen-kernel-transfer}
    relay_dir="$base_workdir/relay-$tag"
    mkdir -p "$base_workdir"

    if [ ! -d "$relay_dir/.git" ]; then
        log "Cloning batched source history for relay"
        rm -rf "$relay_dir"
        git clone --single-branch --branch "$source_branch" \
            "$source_remote" "$relay_dir"
    else
        git -C "$relay_dir" remote set-url origin "$source_remote"
        git -C "$relay_dir" fetch origin "$source_branch"
        git -C "$relay_dir" reset --hard "origin/$source_branch" >/dev/null
    fi

    if git -C "$relay_dir" remote get-url destination >/dev/null 2>&1; then
        git -C "$relay_dir" remote set-url destination "$target_remote"
    else
        git -C "$relay_dir" remote add destination "$target_remote"
    fi

    local source_head target_head
    source_head=$(git -C "$relay_dir" rev-parse HEAD)
    target_head=$(remote_head "$target_remote" "$target_branch" || true)

    if [ "$target_head" = "$source_head" ]; then
        log "Relay already complete: $target_branch"
        exit 0
    fi

    local -a commits=()
    mapfile -t commits < <(git -C "$relay_dir" rev-list --reverse HEAD)
    (( ${#commits[@]} > 0 )) || die "source branch contains no commits"

    local start=0 i found=0
    if [ -n "$target_head" ]; then
        for i in "${!commits[@]}"; do
            if [ "${commits[$i]}" = "$target_head" ]; then
                start=$((i + 1))
                found=1
                break
            fi
        done
        (( found == 1 )) || \
            die "target branch exists but is not part of the batched source history"
    fi

    local total=${#commits[@]}
    if (( start >= total )); then
        log "Relay already complete"
        exit 0
    fi

    log "Relaying $((total - start)) commits one push at a time"
    for ((i=start; i<total; i++)); do
        local commit=${commits[$i]}
        local subject
        subject=$(git -C "$relay_dir" log -1 --format=%s "$commit")
        log "Push $((i + 1))/$total: ${commit:0:12} $subject"
        git -C "$relay_dir" push destination \
            "$commit:refs/heads/$target_branch"
    done

    log "Relay complete: $target_remote $target_branch"
}

case ${1:-} in
    seed)
        shift
        seed_mode "$@"
        ;;
    relay)
        shift
        relay_mode "$@"
        ;;
    -h|--help|help|'')
        usage
        ;;
    *)
        usage >&2
        exit 2
        ;;
esac
