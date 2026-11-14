#!/bin/zsh
# Varsayılan: doğrudan kullanım sürümü (Developer ID, SMC sıcaklık/fan istisnası, arm64).
# NABIZ_APPSTORE=1: Mac App Store sürümü (SMC yok, evrensel ikili, Apple Distribution imzası, .pkg).
set -eu
source_dir=${0:A:h}
appstore=${NABIZ_APPSTORE:-0}
version=1.6
build_number=11
if [[ $appstore == 1 ]]; then
  output_dir=${NABIZ_BUILD_DIR:-"$source_dir/build-appstore"}
  bundle_id=${NABIZ_BUNDLE_ID:-com.omeryasir.nabiz}
  architectures=(arm64 x86_64)
  swift_options=(-D NABIZ_APPSTORE)
else
  output_dir=${NABIZ_BUILD_DIR:-"$source_dir/build"}
  bundle_id=local.nabiz.monitor
  architectures=(arm64)
  swift_options=()
fi
app_path="$output_dir/Nabiz.app"
entitlements="$source_dir/Nabiz.entitlements"
if [[ ${NABIZ_MIGRATION_BUILD:-0} == 1 ]]; then
  [[ $appstore != 1 ]] || { print -u2 -- "Geçiş derlemesi App Store sürümüyle birlikte kullanılamaz."; exit 1; }
  entitlements="$source_dir/NabizMigration.entitlements"
  swift_options=(-D NABIZ_MIGRATION_BUILD)
fi
rm -rf "$app_path"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
work=$(mktemp -d "$output_dir/work.XXXXXX")
trap 'rm -rf "$work"' EXIT
# App icon is drawn from code (same geometry as the Figma source) so the build stays reproducible.
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 "$source_dir/Icon.swift" -framework AppKit -o "$work/Icon"
"$work/Icon" "$work/Nabiz.iconset"
iconutil -c icns "$work/Nabiz.iconset" -o "$app_path/Contents/Resources/Nabiz.icns"
sources=(main.swift MenuMeter.swift Panels.swift Settings.swift Ledger.swift History.swift Tests.swift Sandbox.swift Import.swift)
slices=()
for arch in $architectures; do
  xcrun clang -O2 -Wall -Wextra -target $arch-apple-macosx13.0 -c "$source_dir/Metrics.c" -o "$work/Metrics-$arch.o"
  xcrun swiftc -O -swift-version 5 -target $arch-apple-macosx13.0 \
    "${swift_options[@]}" -import-objc-header "$source_dir/Metrics.h" "${sources[@]/#/$source_dir/}" "$work/Metrics-$arch.o" \
    -framework AppKit -framework IOKit -framework CoreFoundation -framework ServiceManagement -lsqlite3 -o "$work/Nabiz-$arch"
  slices+=("$work/Nabiz-$arch")
done
lipo -create "${slices[@]}" -output "$app_path/Contents/MacOS/Nabiz"
# Arayüz Türkçe ve İngilizce: metinler kodda L(tr,en) ile; bu klasörler macOS'a ve App Store'a iki dili bildirir.
for lang in en tr; do
  mkdir -p "$app_path/Contents/Resources/$lang.lproj"
  print -r -- '"CFBundleDisplayName" = "Nabız";' > "$app_path/Contents/Resources/$lang.lproj/InfoPlist.strings"
done
cat > "$app_path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Nabiz</string>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleName</key><string>Nabız</string>
<key>CFBundleDisplayName</key><string>Nabız</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build_number</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>tr</string></array>
<key>LSUIElement</key><true/>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>CFBundleIconFile</key><string>Nabiz</string>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>ITSAppUsesNonExemptEncryption</key><false/>
<key>NSHumanReadableCopyright</key><string>© 2026 Ömer Yasir Önal</string>
</dict></plist>
PLIST

if [[ $appstore == 1 ]]; then
  # Mac App Store: provisioning profile + Apple Distribution imzası + 3rd Party Mac Developer Installer ile .pkg.
  profile=${NABIZ_PROFILE:-}
  [[ -f "$profile" ]] || { print -u2 -- "NABIZ_PROFILE ile Mac App Store provisioning profile yolu verilmeli (.provisionprofile)."; exit 1; }
  security cms -D -i "$profile" > "$work/profile.plist"
  team=$(/usr/libexec/PlistBuddy -c "Print :TeamIdentifier:0" "$work/profile.plist")
  app_id=$(/usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.application-identifier" "$work/profile.plist")
  [[ "$app_id" == "$team.$bundle_id" ]] || { print -u2 -- "Profil $app_id için; beklenen $team.$bundle_id."; exit 1; }
  cp "$profile" "$app_path/Contents/embedded.provisionprofile"
  cat > "$work/appstore.entitlements" <<ENT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.application-identifier</key><string>$app_id</string>
<key>com.apple.developer.team-identifier</key><string>$team</string>
</dict></plist>
ENT
  identity=${NABIZ_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -v t="($team)" '/"Apple Distribution:/ && index($0,t) {print $2; exit}')}
  installer=${NABIZ_INSTALLER_IDENTITY:-$(security find-identity -v | awk -v t="($team)" '/"3rd Party Mac Developer Installer:/ && index($0,t) {print $2; exit}')}
  [[ -n "$identity" && -n "$installer" ]] || { print -u2 -- "Apple Distribution ve 3rd Party Mac Developer Installer kimlikleri bulunamadı."; exit 1; }
  codesign --force --options runtime --timestamp --sign "$identity" --entitlements "$work/appstore.entitlements" "$app_path"
  installer_name=$(security find-identity -v | awk -v h="$installer" '$2==h {sub(/^[^"]*"/,""); sub(/"$/,""); print; exit}')
  productbuild --component "$app_path" /Applications --sign "$installer_name" "$output_dir/Nabiz-$version-$build_number.pkg" >/dev/null
  print -r -- "$app_path"
  print -r -- "$output_dir/Nabiz-$version-$build_number.pkg"
  exit 0
fi

# Stable signing identity preserves the app/container identity across local updates.
identity=${NABIZ_SIGN_IDENTITY:-}
if [[ -z "$identity" ]]; then
  identities=(${(f)$(security find-identity -v -p codesigning | awk '/"Developer ID Application:/ {print $2}')})
  (( ${#identities} == 1 )) || { print -u2 -- "Tek bir Developer ID Application bulunmalı veya NABIZ_SIGN_IDENTITY seçilmeli."; exit 1; }
  identity=$identities[1]
fi
[[ "$identity" != "-" ]] || { print -u2 -- "Sandbox sürümü için sabit bir imza kimliği gerekli; ad-hoc imza kullanılmaz."; exit 1; }
codesign --force --options runtime --timestamp=none --sign "$identity" --entitlements "$entitlements" "$app_path"
print -r -- "$app_path"
