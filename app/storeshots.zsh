#!/bin/zsh
# App Store ekran görüntülerini (2880x1800, App Store sürümü görünümü) üretir. Çıktı: appstore/screenshots (Git dışı).
set -eu
source_dir=${0:A:h}
out=${1:-"$source_dir/appstore/screenshots"}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"
for f in main MenuMeter Panels Settings Ledger History Tests Sandbox Import; do cp "$source_dir/$f.swift" "$work/"; done
# Uygulamanın üst düzey başlatma kodu çıkarılır; giriş noktası StoreShots olur.
python3 - "$work/main.swift" <<'PY'
import sys;from pathlib import Path
p=Path(sys.argv[1]);s=p.read_text();p.with_name('app.swift').write_text(s[:s.index('if CommandLine.arguments.contains("--self-test")')]);p.unlink()
PY
cp "$source_dir/StoreShots.swift" "$work/main.swift"
xcrun clang -O2 -target arm64-apple-macosx13.0 -c "$source_dir/Metrics.c" -o "$work/Metrics.o"
xcrun swiftc -D NABIZ_APPSTORE -swift-version 5 -target arm64-apple-macosx13.0 -import-objc-header "$source_dir/Metrics.h" "$work"/*.swift "$work/Metrics.o" -framework AppKit -framework IOKit -framework ServiceManagement -lsqlite3 -o "$work/shots"
for lang in tr en; do
  mkdir -p "$out/$lang"
  NABIZ_LANG=$lang "$work/shots" "$out/$lang" >/dev/null
done
print -r -- "$out"
