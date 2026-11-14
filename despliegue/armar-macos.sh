#!/bin/bash
# En un Mac (la CI, macos-latest): compila el agente y la bandeja para Apple Silicon e Intel, los une en binarios
# universales y arma Helpert.app (la bandeja, solo en la barra de menús). Deja todo en $1 (por defecto dist-macos).
# Firma «ad hoc» (sin cuenta de desarrollador de Apple): basta para que corran; Gatekeeper avisa al abrir lo bajado,
# por eso el instalador quita la marca de cuarentena.
set -eu
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
SALIDA=$(mkdir -p "${1:-dist-macos}" && cd "${1:-dist-macos}" && pwd)
OBJETIVOS="aarch64-apple-darwin x86_64-apple-darwin"
rustup target add $OBJETIVOS >/dev/null
for o in $OBJETIVOS; do
  (cd "$RAIZ/agente" && cargo build --release -q --target "$o")
  (cd "$RAIZ/bandeja" && cargo build --release -q --target "$o")
done
universal() {  # $1 carpeta (agente o bandeja), $2 binario, $3 destino
  lipo -create -output "$3" "$RAIZ/$1/target/aarch64-apple-darwin/release/$2" "$RAIZ/$1/target/x86_64-apple-darwin/release/$2"
  codesign --force -s - "$3"
}
mkdir -p "$SALIDA/bin"
universal agente helpert-agente "$SALIDA/bin/helpert-agente"
universal agente helpert "$SALIDA/bin/helpert"

APP=$SALIDA/Helpert.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
universal bandeja helpert-bandeja "$APP/Contents/MacOS/helpert-bandeja"
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' "$RAIZ/bandeja/Cargo.toml" | head -1)
ICONOS=$(mktemp -d)/Helpert.iconset
mkdir -p "$ICONOS"
for n in 16 32 128 256 512; do
  sips -z $n $n "$RAIZ/bandeja/iconos/icono.png" --out "$ICONOS/icon_${n}x${n}.png" >/dev/null
  sips -z $((n * 2)) $((n * 2)) "$RAIZ/bandeja/iconos/icono.png" --out "$ICONOS/icon_${n}x${n}@2x.png" >/dev/null
done
iconutil -c icns -o "$APP/Contents/Resources/Helpert.icns" "$ICONOS"
cat > "$APP/Contents/Info.plist" <<EOT
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Helpert</string>
  <key>CFBundleDisplayName</key><string>Helpert</string>
  <key>CFBundleIdentifier</key><string>pe.helpert.bandeja</string>
  <key>CFBundleExecutable</key><string>helpert-bandeja</string>
  <key>CFBundleIconFile</key><string>Helpert</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOT
codesign --force -s - "$APP"
lipo -archs "$SALIDA/bin/helpert-agente"
echo "Listo: $SALIDA"
