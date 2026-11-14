#!/bin/bash
# Compila el CSS y copia las librerías (versiones fijas en package.json) a donde las sirve cada pieza.
# El resultado se versiona: la VPS y los equipos no necesitan Node.
set -eu
cd "$(dirname "$0")"
[ -d node_modules ] || npm ci --no-audit --no-fund
E=../server/helpert_server/estatico
U=../bandeja/ui
mkdir -p "$E/fuentes" "$U/fuentes"
npx @tailwindcss/cli -i consola.css -o "$E/consola.css" --minify
npx @tailwindcss/cli -i bandeja.css -o "$U/estilo.css" --minify
for d in "$E" "$U"; do
  cp node_modules/@fontsource-variable/inter/files/inter-latin-wght-normal.woff2 "$d/fuentes/inter.woff2"
  cp node_modules/@fontsource-variable/geist-mono/files/geist-mono-latin-wght-normal.woff2 "$d/fuentes/geist-mono.woff2"
done
cp node_modules/datatables.net/js/dataTables.min.js "$E/datatables.js"
cp node_modules/choices.js/public/assets/scripts/choices.min.js "$E/choices.js"
cp node_modules/echarts/dist/echarts.min.js "$E/echarts.js"
cp consola.js "$E/consola.js"
for d in "$E" "$U"; do cp ../bandeja/iconos/logo-claro.svg ../bandeja/iconos/logo-oscuro.svg "$d/"; done
rm -f "$E/logo.svg" "$U/logo.svg" "$E/fuentes/geist.woff2" "$U/fuentes/geist.woff2"
du -sh "$E" "$U/estilo.css" | sed 's/^/  /'
