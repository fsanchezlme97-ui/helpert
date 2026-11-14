#!/bin/bash
# Arma helpert-instalar.run: un solo archivo que instala Helpert en un equipo Linux (servicio + bandeja).
# En el equipo: «sh helpert-instalar.run» (sudo en terminal; sin terminal, ventana de polkit).
#   despliegue/empaquetar-linux.sh --servidor https://helpert.empresa.pe --clave-publica playbooks.pub \
#        --inscripcion-archivo inscripcion.txt [--salida helpert-instalar.run]
# Los playbooks ya deben estar firmados (fuera de la VPS). shortcut: el instalador lleva la clave de inscripción
# de la organización (quien lo tenga puede registrar equipos); antes del piloto, aprobación en la consola.
set -eu
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
SALIDA=$PWD/helpert-instalar.run
while [ $# -gt 0 ]; do
  case $1 in
    --servidor) SERVIDOR=$2; shift 2 ;;
    --clave-publica) PUB=$2; shift 2 ;;
    --inscripcion-archivo) INSCRIPCION_F=$2; shift 2 ;;
    --salida) SALIDA=$2; shift 2 ;;
    *) sed -n '4,5p' "$0"; exit 2 ;;
  esac
done
[ -n "${SERVIDOR:-}" ] && [ -n "${PUB:-}" ] && [ -n "${INSCRIPCION_F:-}" ] || { sed -n '4,5p' "$0"; exit 2; }
ls "$RAIZ"/playbooks/*/firma.ed25519 >/dev/null 2>&1 || { echo "Firma los playbooks primero."; exit 1; }

(cd "$RAIZ/agente" && cargo build --release -q)
(cd "$RAIZ/bandeja" && cargo build --release -q)
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
mkdir "$D/bin"
cp "$RAIZ"/agente/target/release/{helpert-agente,helpert} "$RAIZ/bandeja/target/release/helpert-bandeja" "$D/bin/"
cp -r "$RAIZ/playbooks" "$D/playbooks"
cp "$PUB" "$D/playbooks.pub"
cp "$RAIZ/bandeja/iconos/icono.png" "$D/helpert.png"
cp "$RAIZ/despliegue/helpert-agente.service" "$RAIZ/despliegue/instalar-agente-linux.sh" "$D/"
printf '%s\n' "$SERVIDOR" > "$D/servidor.txt"
(umask 077; cp "$INSCRIPCION_F" "$D/inscripcion")

cat > "$SALIDA" <<'EOT'
#!/bin/sh
# Instalador de Helpert (soporte TI). En una terminal: sh helpert-instalar.run
set -u
D=$(mktemp -d) || exit 1
trap 'rm -rf "$D"' EXIT
L=$(awk '/^__PAQUETE__$/ { print NR + 1; exit }' "$0")
tail -n +"$L" "$0" | tar -xz -C "$D" || exit 1  # tail, no sed: los datos comprimidos son binarios
avisa() { notify-send -a Helpert -i "$D/helpert.svg" "$@" 2>/dev/null; echo "$@"; }  # sin sesión gráfica (root, SSH) solo se imprime
if [ "$(id -u)" -eq 0 ]; then
  sh_root=
elif [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ] && command -v pkexec >/dev/null && ! [ -t 0 ]; then
  sh_root=pkexec  # ventana de contraseña del escritorio
else
  sh_root=sudo
fi
if $sh_root /bin/bash "$D/instalar-agente-linux.sh" --paquete "$D" > "$D/registro.txt" 2>&1; then
  cat "$D/registro.txt"
  [ "$(id -u)" -ne 0 ] && (setsid /usr/local/bin/helpert-bandeja --abrir >/dev/null 2>&1 &)
  avisa "Helpert está instalado" "Lo verás en la bandeja del sistema. Cuéntale qué le pasa a tu equipo."
else
  cat "$D/registro.txt"
  avisa -u critical "No se pudo instalar Helpert" "$(tail -n 3 "$D/registro.txt")"
  exit 1
fi
exit 0
__PAQUETE__
EOT
tar -czf - -C "$D" . >> "$SALIDA"
chmod 755 "$SALIDA"
echo "Listo: $SALIDA ($(du -h "$SALIDA" | cut -f1))"
