#!/bin/bash
# Arma helpert-macos.zip: el instalador de Helpert para Mac (macOS 13+, Apple Silicon e Intel): servicio + bandeja.
# En el Mac: abrir el .zip y doble clic en «Instalar Helpert.command» (pide la contraseña de administrador). La primera
# vez macOS puede bloquearlo por no ser de un desarrollador identificado: clic derecho > Abrir.
#   despliegue/empaquetar-macos.sh --servidor https://helpert.empresa.pe --clave-publica playbooks.pub \
#        --inscripcion-archivo inscripcion.txt [--binarios DIR] [--salida helpert-macos.zip]
# Los binarios y Helpert.app los arma la CI en macOS (despliegue/armar-macos.sh, artefacto «helpert-macos»); sin
# --binarios se descarga, con gh, el de la ejecución correcta de la CI para este mismo commit. Aquí solo se juntan con
# los playbooks firmados (la clave privada nunca sale de donde se firma). shortcut: el paquete lleva la clave de
# inscripción de la organización, como el de Linux y el de Windows.
set -eu
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
SALIDA=$PWD/helpert-macos.zip
while [ $# -gt 0 ]; do
  case $1 in
    --servidor) SERVIDOR=$2; shift 2 ;;
    --clave-publica) PUB=$2; shift 2 ;;
    --inscripcion-archivo) INSCRIPCION_F=$2; shift 2 ;;
    --binarios) BINARIOS=$2; shift 2 ;;
    --salida) SALIDA=$(realpath -m "$2"); shift 2 ;;
    *) sed -n '5,6p' "$0"; exit 2 ;;
  esac
done
[ -n "${SERVIDOR:-}" ] && [ -n "${PUB:-}" ] && [ -n "${INSCRIPCION_F:-}" ] || { sed -n '5,6p' "$0"; exit 2; }
case $SERVIDOR in https://*) ;; *) echo "El servidor debe ser https://."; exit 1 ;; esac
for pb in "$RAIZ"/playbooks/*/; do
  [ -f "$pb/firma.ed25519" ] || { echo "Firma los playbooks primero: falta $pb/firma.ed25519"; exit 1; }
done

D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
if [ -z "${BINARIOS:-}" ]; then
  COMMIT=$(git -C "$RAIZ" rev-parse HEAD)
  RUN=$(gh run list -R "$(git -C "$RAIZ" remote get-url origin)" --workflow ci --commit "$COMMIT" --event push --status success \
        --limit 1 --json databaseId -q '.[0].databaseId')
  [ -n "$RUN" ] || { echo "No hay una ejecución correcta de la CI para $COMMIT (¿subiste el commit?); o usa --binarios DIR."; exit 1; }
  gh run download "$RUN" -R "$(git -C "$RAIZ" remote get-url origin)" -n helpert-macos -D "$D/descarga"
  BINARIOS=$D/descarga
fi
for f in bin/helpert-agente bin/helpert Helpert.app/Contents/MacOS/helpert-bandeja; do
  [ -f "$BINARIOS/$f" ] || { echo "Falta $f en $BINARIOS"; exit 1; }
done
mkdir -p "$D/p"
cp -R "$BINARIOS/bin" "$BINARIOS/Helpert.app" "$D/p/"
chmod 755 "$D"/p/bin/* "$D/p/Helpert.app/Contents/MacOS/helpert-bandeja"  # el artefacto de la CI pierde los permisos
cp -r "$RAIZ/playbooks" "$D/p/playbooks"
# solo se quitan las pruebas de la raíz: la firma cubre cada archivo de la carpeta de cada playbook
rm -f "$D"/p/playbooks/*.ps1 "$D"/p/playbooks/*.sh "$D"/p/playbooks/*.py
cp "$PUB" "$D/p/playbooks.pub"
cp "$RAIZ/despliegue/pe.helpert.agente.plist" "$RAIZ/despliegue/instalar-agente-macos.sh" "$D/p/"
printf '%s\n' "$SERVIDOR" > "$D/p/servidor.txt"
(umask 077; cp "$INSCRIPCION_F" "$D/p/inscripcion")
cat > "$D/p/Instalar Helpert.command" <<'EOT'
#!/bin/bash
# Doble clic: instala Helpert en este Mac (pide la contraseña de administrador).
cd "$(dirname "$0")" && sudo /bin/bash ./instalar-agente-macos.sh --paquete "$PWD"
echo; read -r -p "Pulsa Intro para cerrar. " _
EOT
cat > "$D/p/Desinstalar Helpert.command" <<'EOT'
#!/bin/bash
cd "$(dirname "$0")" && sudo /bin/bash ./instalar-agente-macos.sh --desinstalar
echo; read -r -p "Pulsa Intro para cerrar. " _
EOT
chmod 755 "$D/p/"*.command
rm -f "$SALIDA"
# zip con permisos de Unix (los binarios deben quedar ejecutables al abrirlo en el Mac)
(cd "$D/p" && python3 -c 'import os, stat, sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_DEFLATED) as z:
    for raiz, _, archivos in os.walk("."):
        for a in sorted(archivos):
            ruta = os.path.join(raiz, a)
            info = zipfile.ZipInfo.from_file(ruta, os.path.join("Helpert", ruta))
            info.external_attr = (os.stat(ruta).st_mode & 0xFFFF) << 16
            with open(ruta, "rb") as f:
                z.writestr(info, f.read(), zipfile.ZIP_DEFLATED)' "$SALIDA")
echo "Listo: $SALIDA ($(du -h "$SALIDA" | cut -f1)). En el Mac: abrir y doble clic en «Instalar Helpert.command»."
