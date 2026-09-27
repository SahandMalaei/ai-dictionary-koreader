#!/system/bin/sh
# Apply a fully uploaded snapshot. Called by deploy-android.ps1, not by KOReader.
set -eu

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

is_preserved() {
    # Keep these rules aligned with updater.lua.
    case "$1" in
        configuration.lua|*/configuration.lua|Lookups|Lookups/*|.update-*) return 0 ;;
        *) return 1 ;;
    esac
}

# Use subshells so recursive calls cannot change their caller's variables.
walk_tree() (
    for entry in "$1"/* "$1"/.[!.]* "$1"/..?*; do
        [ -e "$entry" ] || [ -L "$entry" ] || continue
        relative=$2${entry##*/}
        if is_preserved "$relative"; then
            [ "$3" != source ] || fail "Payload contains protected data: $relative"
            continue
        fi
        [ ! -L "$entry" ] || fail "Refusing to follow a symbolic link: $entry"
        if [ -d "$entry" ]; then
            walk_tree "$entry" "$relative/" "$3" || exit 1
            if [ "$3" = prune ]; then
                # A directory containing preserved data can never be removed here.
                rmdir "$entry" 2>/dev/null || :
            fi
        elif [ -f "$entry" ]; then
            if [ "$3" = prune ] && [ ! -f "$payload/$relative" ]; then
                rm -f "$entry" || exit 1
                printf 'Removed obsolete file: %s\n' "$relative"
            fi
        else
            fail "Unsupported file type: $entry"
        fi
    done
)

[ "$#" -eq 2 ] || fail 'Expected payload directory and plugins directory.'
for path in "$1" "$2"; do
    case "$path" in
        /*) ;;
        *) fail "Expected an absolute path: $path" ;;
    esac
    case "$path/" in
        */../*|*/./*) fail "Refusing a path with dot segments: $path" ;;
    esac
done
payload=$(cd "$1" && pwd -P) || exit 1
plugins=$(cd "$2" && pwd -P) || exit 1
[ "${plugins##*/}" = plugins ] || fail 'Destination must resolve to a plugins directory.'
target=$plugins/AI_Dictionary.koplugin
[ ! -L "$target" ] || fail 'The installed plugin must not be a symbolic link.'
case "$payload/" in "$target/"*) fail 'Payload must be outside the installed plugin.' ;; esac
case "$target/" in "$payload/"*) fail 'Installed plugin must be outside the payload.' ;; esac
[ -f "$payload/main.lua" ] && [ -f "$payload/_meta.lua" ] || fail 'Incomplete plugin payload.'

# Validate both trees before copying or deleting anything. Never traverse links
# that could redirect a write or deletion into preserved data or another plugin.
walk_tree "$payload" '' source || exit 1
if [ -e "$target" ]; then
    [ -d "$target" ] || fail 'The installed plugin path is not a directory.'
    walk_tree "$target" '' target || exit 1
fi

mkdir -p "$target"
cp -R "$payload/." "$target/" || fail 'Copy failed; obsolete files have not been pruned.'
walk_tree "$target" '' prune || exit 1
printf '%s\n' 'Plugin synchronized; configuration and lookup history preserved.'
