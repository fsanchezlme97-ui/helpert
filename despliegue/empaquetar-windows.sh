#!/bin/bash
# Arma helpert-windows.zip: el instalador de Helpert para equipos Windows 10/11 (servicio + bandeja).
# En el equipo: extraer el .zip y doble clic en «Instalar Helpert.cmd» (pide permiso de administrador).
#   despliegue/empaquetar-windows.sh --servidor https://helpert.empresa.pe --clave-publica playbooks.pub \
#        --inscripcion-archivo inscripcion.txt [--binarios DIR] [--salida helpert-windows.zip]
# Los .exe los compila la CI en Windows (artefacto «helpert-windows»); sin --binarios se descarga, con gh, el de la
# ejecución correcta de la CI para este mismo commit (git rev-parse HEAD), no el de otro. Aquí solo se juntan con los playbooks firmados (fuera de la VPS y de
# la CI: la clave privada nunca sale de donde se firma). shortcut: el paquete lleva la clave de inscripción de la
# organización, como el de Linux.
set -eu
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
SALIDA=$PWD/helpert-windows.zip
while [ $# -gt 0 ]; do
  case $1 in
    --servidor) SERVIDOR=$2; shift 2 ;;
    --clave-publica) PUB=$2; shift 2 ;;
    --inscripcion-archivo) INSCRIPCION_F=$2; shift 2 ;;
    --binarios) BINARIOS=$2; shift 2 ;;
    --salida) SALIDA=$(realpath -m "$2"); shift 2 ;;
    *) sed -n '4,5p' "$0"; exit 2 ;;
  esac
done
[ -n "${SERVIDOR:-}" ] && [ -n "${PUB:-}" ] && [ -n "${INSCRIPCION_F:-}" ] || { sed -n '4,5p' "$0"; exit 2; }
case $SERVIDOR in https://*) ;; *) echo "El servidor debe ser https:// (el agente no habla con otro)."; exit 1 ;; esac
for pb in "$RAIZ"/playbooks/*/; do
  [ -f "$pb/firma.ed25519" ] || { echo "Firma los playbooks primero: falta $pb/firma.ed25519"; exit 1; }
done

D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
if [ -z "${BINARIOS:-}" ]; then
  COMMIT=$(git -C "$RAIZ" rev-parse HEAD)
  RUN=$(gh run list -R "$(git -C "$RAIZ" remote get-url origin)" --workflow ci --commit "$COMMIT" --event push --status success \
        --limit 1 --json databaseId -q '.[0].databaseId')
  [ -n "$RUN" ] || { echo "No hay una ejecución correcta de la CI para $COMMIT (¿subiste el commit?); o usa --binarios DIR."; exit 1; }
  gh run download "$RUN" -R "$(git -C "$RAIZ" remote get-url origin)" -n helpert-windows -D "$D/descarga"
  BINARIOS=$D/descarga
fi
mkdir -p "$D/p/bin"
for exe in helpert-agente.exe helpert.exe helpert-bandeja.exe; do
  f=$(find "$BINARIOS" -name "$exe" -type f | head -1)
  [ -n "$f" ] || { echo "Falta $exe en $BINARIOS"; exit 1; }
  cp "$f" "$D/p/bin/"
done
cp -r "$RAIZ/playbooks" "$D/p/playbooks"
# solo se quitan las pruebas de la raíz: la firma cubre cada archivo de la carpeta del playbook (también linux.sh y
# macos.sh), así que quitarlos haría que el agente rechace el paquete. El agente solo corre el script de su sistema.
rm -f "$D"/p/playbooks/*.ps1 "$D"/p/playbooks/*.sh "$D"/p/playbooks/*.py
cp "$PUB" "$D/p/playbooks.pub"
printf '%s\r\n' "$SERVIDOR" > "$D/p/servidor.txt"
(umask 077; cp "$INSCRIPCION_F" "$D/p/inscripcion")
# PowerShell 5.1 lee como ANSI un .ps1 sin BOM: con tildes y «», el BOM es obligatorio
printf '\xef\xbb\xbf' > "$D/p/instalar.ps1"
sed 's/$/\r/' "$RAIZ/despliegue/instalar-agente-windows.ps1" >> "$D/p/instalar.ps1"
printf '@echo off\r\npowershell.exe -NoProfile -ExecutionPolicy Bypass -File "%%~dp0instalar.ps1" %%*\r\n' > "$D/p/Instalar Helpert.cmd"
printf '@echo off\r\npowershell.exe -NoProfile -ExecutionPolicy Bypass -File "%%~dp0instalar.ps1" -Desinstalar\r\n' > "$D/p/Desinstalar Helpert.cmd"
rm -f "$SALIDA"
(cd "$D/p" && python3 -c 'import sys, zipfile, os
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    for raiz, _, archivos in os.walk("."):
        for a in sorted(archivos):
            z.write(os.path.join(raiz, a), os.path.join("Helpert", raiz, a))' "$SALIDA")
echo "Listo: $SALIDA ($(du -h "$SALIDA" | cut -f1)). En el equipo: extraer y doble clic en «Instalar Helpert.cmd»."
