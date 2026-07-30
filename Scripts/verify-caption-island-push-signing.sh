#!/bin/sh

set -eu

usage() {
    echo "Usage: $0 <finally-signed .ipa or .app>" >&2
    exit 64
}

fail() {
    echo "Caption Island push signing check failed: $1" >&2
    exit 1
}

[ "$#" -eq 1 ] || usage
input_path=$1
[ -e "$input_path" ] || fail "input does not exist: $input_path"

temporary_directory=
cleanup() {
    if [ -n "$temporary_directory" ] &&
       [ -d "$temporary_directory" ]; then
        rm -rf "$temporary_directory"
    fi
}
trap cleanup EXIT HUP INT TERM

case "$input_path" in
    *.ipa)
        temporary_directory=$(mktemp -d)
        /usr/bin/unzip -q "$input_path" -d "$temporary_directory"
        app_path=$(
            /usr/bin/find "$temporary_directory/Payload" \
                -maxdepth 1 -type d -name '*.app' -print -quit
        )
        [ -n "$app_path" ] || fail "the IPA has no app under Payload"
        ;;
    *.app)
        app_path=$input_path
        ;;
    *)
        usage
        ;;
esac

[ -f "$app_path/Info.plist" ] ||
    fail "host Info.plist is missing"
host_bundle_id=$(
    /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
        "$app_path/Info.plist"
)
[ "$host_bundle_id" != "com.google.ios.youtube" ] ||
    fail "com.google.ios.youtube belongs to Google; use an explicit App ID owned by your Apple Developer Team"

widget_path="$app_path/PlugIns/CaptionIslandWidget.appex"
[ -f "$widget_path/Info.plist" ] ||
    fail "CaptionIslandWidget.appex is missing"
widget_bundle_id=$(
    /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" \
        "$widget_path/Info.plist"
)
[ "$widget_bundle_id" = "$host_bundle_id.CaptionIslandWidget" ] ||
    fail "widget bundle ID must be $host_bundle_id.CaptionIslandWidget"
host_live_activity_support=$(
    /usr/bin/plutil -extract NSSupportsLiveActivities raw -o - \
        "$app_path/Info.plist" 2>/dev/null || true
)
host_frequent_update_support=$(
    /usr/bin/plutil -extract NSSupportsLiveActivitiesFrequentUpdates raw -o - \
        "$app_path/Info.plist" 2>/dev/null || true
)
widget_live_activity_support=$(
    /usr/bin/plutil -extract NSSupportsLiveActivities raw -o - \
        "$widget_path/Info.plist" 2>/dev/null || true
)
widget_extension_point=$(
    /usr/bin/plutil -extract NSExtension.NSExtensionPointIdentifier raw -o - \
        "$widget_path/Info.plist" 2>/dev/null || true
)
[ "$host_live_activity_support" = "true" ] ||
    fail "host Info.plist must contain NSSupportsLiveActivities=true"
[ "$host_frequent_update_support" = "true" ] ||
    fail "host Info.plist must contain NSSupportsLiveActivitiesFrequentUpdates=true"
[ "$widget_live_activity_support" = "true" ] ||
    fail "widget Info.plist must contain NSSupportsLiveActivities=true"
[ "$widget_extension_point" = "com.apple.widgetkit-extension" ] ||
    fail "CaptionIslandWidget has the wrong extension point"

/usr/bin/codesign --verify --strict "$app_path" 2>/dev/null ||
    fail "host code signature is invalid"
/usr/bin/codesign --verify --strict "$widget_path" 2>/dev/null ||
    fail "widget code signature is invalid"

temporary_directory=${temporary_directory:-$(mktemp -d)}
host_entitlements="$temporary_directory/host-entitlements.plist"
widget_entitlements="$temporary_directory/widget-entitlements.plist"
host_profile="$temporary_directory/host-profile.plist"
widget_profile="$temporary_directory/widget-profile.plist"

/usr/bin/codesign -d --entitlements :- "$app_path" \
    >"$host_entitlements" 2>/dev/null ||
    fail "host signature entitlements cannot be read"
/usr/bin/codesign -d --entitlements :- "$widget_path" \
    >"$widget_entitlements" 2>/dev/null ||
    fail "widget signature entitlements cannot be read"
/usr/bin/plutil -lint "$host_entitlements" >/dev/null ||
    fail "host signature has no readable entitlement plist"
/usr/bin/plutil -lint "$widget_entitlements" >/dev/null ||
    fail "widget signature has no readable entitlement plist"

push_environment=$(
    /usr/bin/plutil -extract aps-environment raw -o - \
        "$host_entitlements" 2>/dev/null || true
)
case "$push_environment" in
    development)
        relay_environment=sandbox
        ;;
    production)
        relay_environment=production
        ;;
    *)
        fail "host signature is missing a provisioning-authorized aps-environment entitlement"
        ;;
esac

[ -f "$app_path/embedded.mobileprovision" ] ||
    fail "host embedded.mobileprovision is missing"
[ -f "$widget_path/embedded.mobileprovision" ] ||
    fail "widget embedded.mobileprovision is missing"
/usr/bin/security cms -D -i "$app_path/embedded.mobileprovision" \
    -o "$host_profile" ||
    fail "host provisioning profile cannot be decoded"
/usr/bin/security cms -D -i "$widget_path/embedded.mobileprovision" \
    -o "$widget_profile" ||
    fail "widget provisioning profile cannot be decoded"

host_profile_expiration=$(
    /usr/bin/plutil -extract ExpirationDate raw -o - \
        "$host_profile" 2>/dev/null || true
)
widget_profile_expiration=$(
    /usr/bin/plutil -extract ExpirationDate raw -o - \
        "$widget_profile" 2>/dev/null || true
)
[ -n "$host_profile_expiration" ] ||
    fail "host provisioning profile has no ExpirationDate"
[ -n "$widget_profile_expiration" ] ||
    fail "widget provisioning profile has no ExpirationDate"
host_profile_expiration_epoch=$(
    /bin/date -j -u -f "%Y-%m-%dT%H:%M:%SZ" \
        "$host_profile_expiration" "+%s" 2>/dev/null
) || fail "host provisioning profile ExpirationDate cannot be parsed"
widget_profile_expiration_epoch=$(
    /bin/date -j -u -f "%Y-%m-%dT%H:%M:%SZ" \
        "$widget_profile_expiration" "+%s" 2>/dev/null
) || fail "widget provisioning profile ExpirationDate cannot be parsed"
current_epoch=$(/bin/date -u "+%s")
[ "$host_profile_expiration_epoch" -gt "$current_epoch" ] ||
    fail "host provisioning profile expired at $host_profile_expiration"
[ "$widget_profile_expiration_epoch" -gt "$current_epoch" ] ||
    fail "widget provisioning profile expired at $widget_profile_expiration"

team_id=$(
    /usr/bin/plutil -extract TeamIdentifier.0 raw -o - \
        "$host_profile"
)
profile_app_id=$(
    /usr/bin/plutil -extract Entitlements.application-identifier raw -o - \
        "$host_profile"
)
profile_push_environment=$(
    /usr/bin/plutil -extract Entitlements.aps-environment raw -o - \
        "$host_profile" 2>/dev/null || true
)
signed_app_id=$(
    /usr/bin/plutil -extract application-identifier raw -o - \
        "$host_entitlements" 2>/dev/null || true
)
signed_team_id=$(
    /usr/bin/plutil -extract com.apple.developer.team-identifier raw -o - \
        "$host_entitlements" 2>/dev/null || true
)
widget_profile_app_id=$(
    /usr/bin/plutil -extract Entitlements.application-identifier raw -o - \
        "$widget_profile"
)
widget_signed_app_id=$(
    /usr/bin/plutil -extract application-identifier raw -o - \
        "$widget_entitlements" 2>/dev/null || true
)
widget_signed_team_id=$(
    /usr/bin/plutil -extract com.apple.developer.team-identifier raw -o - \
        "$widget_entitlements" 2>/dev/null || true
)

[ "$profile_app_id" = "$team_id.$host_bundle_id" ] ||
    fail "host provisioning profile is not an explicit App ID for $host_bundle_id"
[ "$signed_app_id" = "$profile_app_id" ] ||
    fail "host code-signature application-identifier does not match its profile"
[ "$signed_team_id" = "$team_id" ] ||
    fail "host code-signature team identifier does not match its profile"
[ "$profile_push_environment" = "$push_environment" ] ||
    fail "aps-environment was injected without matching provisioning authorization"
[ "$widget_profile_app_id" = "$team_id.$widget_bundle_id" ] ||
    fail "widget provisioning profile does not match $widget_bundle_id"
[ "$widget_signed_app_id" = "$widget_profile_app_id" ] ||
    fail "widget code-signature application-identifier does not match its profile"
[ "$widget_signed_team_id" = "$team_id" ] ||
    fail "widget code-signature team identifier does not match the host team"

echo "Caption Island APNs signing is valid."
echo "APNS_TEAM_ID=$team_id"
echo "APNS_BUNDLE_ID=$host_bundle_id"
echo "APNS_ENVIRONMENT=$relay_environment"
echo "APNs topic=$host_bundle_id.push-type.liveactivity"
echo "Host profile expires=$host_profile_expiration"
echo "Widget profile expires=$widget_profile_expiration"
