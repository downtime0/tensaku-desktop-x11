#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
config_file="$script_dir/config.toml"
font_root="${XDG_DATA_HOME:-$HOME/.local/share}/fonts/tensaku"
dry_run=false

required_cmds=(
    curl
    fc-cache
    fc-list
    grep
    head
    mktemp
    python3
    sed
    tr
)

usage() {
    cat <<'EOF'
Usage: install-fonts [--dry-run] [FONT ...]

Checks whether each font family is already installed through fontconfig.
Missing families are downloaded from known GitHub sources first, then from Google Fonts only as a last-resort fallback, and installed under:
  ~/.local/share/fonts/tensaku

Arguments:
  FONT         One or more font family names.
               A single argument may also contain a comma-separated list.

Options:
  --dry-run    Report what would be installed without downloading.
  --help       Show this help text.

If no FONT arguments are given, the script reads [font].family from src/config.toml.

Known built-in GitHub aliases:
  Excalifont   Excalidraw's current bundled hand-drawn font
  Virgil       Excalidraw's older bundled font
  Excalidraw   Alias for Excalifont
EOF
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

require_commands() {
    local cmd
    for cmd in "${required_cmds[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
    done
}

trim() {
    sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

read_config_font() {
    [[ -f "$config_file" ]] || return 1

    sed -n '/^\[font\]/,/^\[/p' "$config_file" |
        sed -n 's/^family[[:space:]]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' |
        head -n1
}

normalize_family() {
    tr '[:upper:]' '[:lower:]' |
        trim
}

font_installed() {
    local requested="$1"
    local normalized_requested

    normalized_requested="$(printf '%s\n' "$requested" | normalize_family)"

    fc-list : family |
        tr ',' '\n' |
        normalize_family |
        grep -Fxq "$normalized_requested"
}

family_slug() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/-\{2,\}/-/g; s/^-//; s/-$//'
}

google_css_url() {
    python3 - "$1" <<'PY'
import sys
from urllib.parse import quote_plus

family = sys.argv[1].strip()
print(f"https://fonts.googleapis.com/css2?family={quote_plus(family)}")
PY
}

known_font_urls() {
    local family_normalized="$1"

    case "$family_normalized" in
        excalifont|excalidraw)
            cat <<'EOF'
https://excalidraw.nyc3.cdn.digitaloceanspaces.com/fonts/Excalifont-Regular.woff2
EOF
            ;;
        virgil)
            cat <<'EOF'
https://raw.githubusercontent.com/excalidraw/excalidraw/master/packages/excalidraw/fonts/Virgil/Virgil-Regular.woff2
EOF
            ;;
        *)
            return 1
            ;;
    esac
}

describe_source() {
    local family_normalized="$1"

    case "$family_normalized" in
        excalifont|excalidraw)
            printf '%s\n' "Excalidraw CDN"
            ;;
        virgil)
            printf '%s\n' "GitHub"
            ;;
        *)
            printf '%s\n' "Google Fonts fallback"
            ;;
    esac
}

build_manifest_from_urls() {
    local family_dir="$1"
    local url name

    while IFS= read -r url; do
        [[ -z "$url" ]] && continue
        name="${url##*/}"
        printf '%s\t%s\n' "$url" "$family_dir/$name"
    done
}

build_manifest_from_google_css() {
    local css_file="$1"
    local family_dir="$2"

    python3 - "$css_file" "$family_dir" <<'PY'
import pathlib
import re
import sys
from urllib.parse import urlsplit

css_path = pathlib.Path(sys.argv[1])
target_dir = pathlib.Path(sys.argv[2])
urls = re.findall(r'url\((https://[^)]+)\)', css_path.read_text())
seen = set()

for index, url in enumerate(urls, start=1):
    if url in seen:
        continue
    seen.add(url)
    name = pathlib.Path(urlsplit(url).path).name or f'font-{index}.ttf'
    print(f"{url}\t{target_dir / name}")
PY
}

download_family() {
    local family="$1"
    local family_dir css_url css_file="" manifest_file normalized_family source_label
    local temp_dir temp_path converted_path display_path

    family_dir="$font_root/$(family_slug "$family")"
    if [[ "$dry_run" != true ]]; then
        mkdir -p "$family_dir"
    fi

    manifest_file="$(mktemp)"
    normalized_family="$(printf '%s\n' "$family" | normalize_family)"
    source_label="$(describe_source "$normalized_family")"

    if known_font_urls "$normalized_family" | build_manifest_from_urls "$family_dir" >"$manifest_file"; then
        :
    else
        css_url="$(google_css_url "$family")"
        css_file="$(mktemp)"
        source_label="Google Fonts fallback"

        if ! curl -fsSL "$css_url" -o "$css_file"; then
            rm -f "$css_file" "$manifest_file"
            fail "Could not fetch Google Fonts fallback metadata for: $family"
        fi

        if ! grep -q 'font-family:' "$css_file"; then
            rm -f "$css_file" "$manifest_file"
            fail "No built-in GitHub source is defined for '$family', and the Google Fonts fallback did not provide downloadable files"
        fi

        build_manifest_from_google_css "$css_file" "$family_dir" >"$manifest_file"
        if [[ ! -s "$manifest_file" ]]; then
            rm -f "$css_file" "$manifest_file"
            fail "Google Fonts fallback did not provide downloadable files for: $family"
        fi
    fi

    if [[ "$dry_run" != true ]]; then
        temp_dir="$(mktemp -d)"
        trap "rm -rf -- '$temp_dir'" EXIT
    fi

    while IFS=$'\t' read -r url target_path; do
        [[ -z "$url" ]] && continue

        if [[ "$dry_run" == true ]]; then
            display_path="$target_path"
            [[ "$display_path" == *.woff2 ]] && display_path="${display_path%.woff2}.ttf"
            echo "Would download $family from $source_label -> $display_path"
            continue
        fi

        temp_path="$temp_dir/${target_path##*/}"
        curl -fsSL "$url" -o "$temp_path"
        if [[ "$temp_path" == *.woff2 ]]; then
            command -v woff2_decompress >/dev/null 2>&1 || fail "woff2_decompress is required to convert $temp_path — install it with: sudo apt install woff2"
            woff2_decompress "$temp_path" >/dev/null 2>&1
            converted_path="${temp_path%.woff2}.ttf"
            target_path="${target_path%.woff2}.ttf"
            mv -f -- "$converted_path" "$target_path"
        else
            mv -f -- "$temp_path" "$target_path"
        fi
        echo "Installed $family from $source_label -> $target_path"
    done <"$manifest_file"

    [[ -n "$css_file" ]] && rm -f "$css_file"
    rm -f "$manifest_file"
    if [[ "$dry_run" != true ]]; then
        trap - EXIT
        rm -rf -- "$temp_dir"
    fi
}

parse_fonts() {
    local raw args=() item

    for raw in "$@"; do
        while IFS= read -r item; do
            item="$(printf '%s\n' "$item" | trim)"
            [[ -n "$item" ]] && args+=("$item")
        done < <(printf '%s\n' "$raw" | tr ',' '\n')
    done

    printf '%s\n' "${args[@]}"
}

main() {
    local fonts=() configured_font font missing=false installed_any=false

    require_commands

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                dry_run=true
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            --*)
                fail "Unknown option: $1"
                ;;
            *)
                fonts+=("$1")
                ;;
        esac
        shift
    done

    if [[ ${#fonts[@]} -eq 0 ]]; then
        configured_font="$(read_config_font || true)"
        [[ -n "$configured_font" ]] || fail "No font arguments were provided and no [font].family value was found in $config_file"
        fonts+=("$configured_font")
    fi

    mapfile -t fonts < <(parse_fonts "${fonts[@]}")
    [[ ${#fonts[@]} -gt 0 ]] || fail "No font families were provided"

    if [[ "$dry_run" != true ]]; then
        mkdir -p "$font_root"
    fi

    for font in "${fonts[@]}"; do
        if font_installed "$font"; then
            echo "Already installed: $font"
            installed_any=true
            continue
        fi

        missing=true
        download_family "$font"
    done

    if [[ "$dry_run" == true ]]; then
        if [[ "$missing" == false ]]; then
            echo "Dry run complete: nothing to install."
        fi
        exit 0
    fi

    if [[ "$missing" == true ]]; then
        fc-cache -f "$font_root" >/dev/null
        echo "Refreshed font cache: $font_root"
    elif [[ "$installed_any" == true ]]; then
        echo "Nothing changed."
    fi
}

main "$@"
