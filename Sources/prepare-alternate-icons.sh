#!/bin/bash

set -euo pipefail

app_bundle="${1:?App bundle path is required}"
icons_dir="${2:?Source icon directory is required}"
info_plist="$app_bundle/Info.plist"
plist_buddy="/usr/libexec/PlistBuddy"

test -f "$info_plist"
test -d "$icons_dir"
test -x "$plist_buddy"
command -v sips >/dev/null

ensure_dictionary() {
    local key_path="$1"
    "$plist_buddy" -c "Print $key_path" "$info_plist" >/dev/null 2>&1 || \
        "$plist_buddy" -c "Add $key_path dict" "$info_plist"
}

ensure_dictionary ":CFBundleIcons"
ensure_dictionary ":CFBundleIcons~ipad"

"$plist_buddy" -c "Delete :CFBundleIcons:CFBundleAlternateIcons" "$info_plist" >/dev/null 2>&1 || true
"$plist_buddy" -c "Delete :CFBundleIcons~ipad:CFBundleAlternateIcons" "$info_plist" >/dev/null 2>&1 || true
"$plist_buddy" -c "Add :CFBundleIcons:CFBundleAlternateIcons dict" "$info_plist"
"$plist_buddy" -c "Add :CFBundleIcons~ipad:CFBundleAlternateIcons dict" "$info_plist"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/uyou-alt-icons.XXXXXX")"
trap 'rm -rf -- "$work_dir"' EXIT

shopt -s nullglob
icon_files=("$icons_dir"/*.png)
if (( ${#icon_files[@]} == 0 )); then
    echo "No alternate icon PNGs found in $icons_dir" >&2
    exit 1
fi

for source_icon in "${icon_files[@]}"; do
    icon_name="$(basename "$source_icon" .png)"
    if [[ ! "$icon_name" =~ ^[A-Za-z0-9_-]+$ ]]; then
        echo "Unsupported alternate icon name: $icon_name" >&2
        exit 1
    fi

    dimensions="$(sips -g pixelWidth -g pixelHeight "$source_icon")"
    width="$(awk '/pixelWidth:/ { print $2 }' <<< "$dimensions")"
    height="$(awk '/pixelHeight:/ { print $2 }' <<< "$dimensions")"
    if [[ -z "$width" || -z "$height" ]]; then
        echo "Unable to read dimensions for $source_icon" >&2
        exit 1
    fi

    if (( width < height )); then
        square_size="$width"
    else
        square_size="$height"
    fi

    square_icon="$work_dir/$icon_name.png"
    sips --cropToHeightWidth "$square_size" "$square_size" "$source_icon" --out "$square_icon" >/dev/null

    phone_base="uYouAlt-$icon_name-60"
    ipad_base="uYouAlt-$icon_name-76"
    ipad_pro_base="uYouAlt-$icon_name-83_5"

    sips --resampleHeightWidth 60 60 "$square_icon" --out "$app_bundle/$phone_base.png" >/dev/null
    sips --resampleHeightWidth 120 120 "$square_icon" --out "$app_bundle/$phone_base@2x.png" >/dev/null
    sips --resampleHeightWidth 180 180 "$square_icon" --out "$app_bundle/$phone_base@3x.png" >/dev/null
    sips --resampleHeightWidth 76 76 "$square_icon" --out "$app_bundle/$ipad_base.png" >/dev/null
    sips --resampleHeightWidth 152 152 "$square_icon" --out "$app_bundle/$ipad_base@2x.png" >/dev/null
    sips --resampleHeightWidth 167 167 "$square_icon" --out "$app_bundle/$ipad_pro_base@2x.png" >/dev/null

    "$plist_buddy" -c "Add :CFBundleIcons:CFBundleAlternateIcons:$icon_name dict" "$info_plist"
    "$plist_buddy" -c "Add :CFBundleIcons:CFBundleAlternateIcons:$icon_name:CFBundleIconFiles array" "$info_plist"
    "$plist_buddy" -c "Add :CFBundleIcons:CFBundleAlternateIcons:$icon_name:CFBundleIconFiles:0 string $phone_base" "$info_plist"

    "$plist_buddy" -c "Add :CFBundleIcons~ipad:CFBundleAlternateIcons:$icon_name dict" "$info_plist"
    "$plist_buddy" -c "Add :CFBundleIcons~ipad:CFBundleAlternateIcons:$icon_name:CFBundleIconFiles array" "$info_plist"
    "$plist_buddy" -c "Add :CFBundleIcons~ipad:CFBundleAlternateIcons:$icon_name:CFBundleIconFiles:0 string $ipad_base" "$info_plist"
    "$plist_buddy" -c "Add :CFBundleIcons~ipad:CFBundleAlternateIcons:$icon_name:CFBundleIconFiles:1 string $ipad_pro_base" "$info_plist"
done

plutil -lint "$info_plist" >/dev/null
echo "Prepared ${#icon_files[@]} alternate app icons in $app_bundle"
