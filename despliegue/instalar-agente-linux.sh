#!/bin/bash
# Instala (o desinstala) Helpert en un equipo Linux con systemd: servicio del equipo (root) y bandeja (cada usuario).
#   sudo despliegue/instalar-agente-linux.sh --paquete DIR          # lo usa helpert-instalar.run (empaquetar-linux.sh)
#   sudo despliegue/instalar-agente-linux.sh --servidor URL --clave-publica F (--token-archivo F | --inscripcion-archivo F)
#        [--playbooks DIR] [--bin DIR] [--bandeja F] [--sin-bandeja]
#   sudo despliegue/instalar-agente-linux.sh --desinstalar
# Al reinstalar sin token ni inscripción se conserva el token del equipo. Los secretos van en archivos, no como argumentos.
set -eu
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
UNIDAD=$(dirname "$0")/helpert-agente.service
BIN=$RAIZ/agente/target/release
BANDEJA=$RAIZ/bandeja/target/release/helpert-bandeja
ICONO=$RAIZ/bandeja/iconos/icono.png
PB=$RAIZ/playbooks
uso() { sed -n '3,6p' "$0"; exit 2; }
while [ $# -gt 0 ]; do
  case $1 in
    --paquete) P=$2; SERVIDOR=$(cat "$P/servidor.txt"); PUB=$P/playbooks.pub; INSCRIPCION_F=$P/inscripcion
               PB=$P/playbooks; BIN=$P/bin; BANDEJA=$P/bin/helpert-bandeja; ICONO=$P/helpert.png; UNIDAD=$P/helpert-agente.service; shift 2 ;;
    --servidor) SERVIDOR=$2; shift 2 ;;
    --token-archivo) TOKEN_F=$2; shift 2 ;;
    --inscripcion-archivo) INSCRIPCION_F=$2; shift 2 ;;
    --clave-publica) PUB=$2; shift 2 ;;
    --playbooks) PB=$2; shift 2 ;;
    --bin) BIN=$2; shift 2 ;;
    --bandeja) BANDEJA=$2; shift 2 ;;
    --sin-bandeja) BANDEJA=; shift ;;
    --desinstalar) DESINSTALAR=1; shift ;;
    *) uso ;;
  esac
done
[ "$(id -u)" -eq 0 ] || { echo "Ejecútalo con sudo."; exit 1; }
BANDEJA_ARCHIVOS="/usr/local/bin/helpert-bandeja /etc/xdg/autostart/helpert-bandeja.desktop /usr/share/applications/helpert.desktop /usr/share/icons/hicolor/256x256/apps/helpert.png /usr/share/icons/hicolor/scalable/apps/helpert.svg"  # el .svg: icono de versiones anteriores

if [ "${DESINSTALAR:-}" ]; then
  systemctl disable --now helpert-agente 2>/dev/null || true
  pkill -x helpert-bandeja 2>/dev/null || true
  rm -f /etc/systemd/system/helpert-agente.service /usr/local/bin/helpert-agente /usr/local/bin/helpert $BANDEJA_ARCHIVOS
  rm -rf /usr/lib/helpert /etc/helpert
  systemctl daemon-reload
  echo "Helpert desinstalado."
  exit 0
fi

[ -n "${SERVIDOR:-}" ] && [ -n "${PUB:-}" ] || uso
for f in "$BIN/helpert-agente" "$BIN/helpert" "$PUB" "$UNIDAD" ${BANDEJA:+"$BANDEJA" "$ICONO"}; do
  [ -f "$f" ] || { echo "Falta $f"; exit 1; }
done
ls "$PB"/*/firma.ed25519 >/dev/null 2>&1 || { echo "Los playbooks de $PB no están firmados."; exit 1; }

# Token del equipo: el dado, el que ya tenía (reinstalación) o uno nuevo con la clave de inscripción.
if [ -n "${TOKEN_F:-}" ]; then
  TOKEN=$(tr -d '[:space:]' < "$TOKEN_F")
elif [ -f /etc/helpert/agente.toml ] && grep -q '^token = ' /etc/helpert/agente.toml; then
  TOKEN=$(sed -n 's/^token = "\(.*\)"$/\1/p' /etc/helpert/agente.toml)
elif [ -n "${INSCRIPCION_F:-}" ]; then
  CLAVE=$(tr -d '[:space:]' < "$INSCRIPCION_F")
  NOMBRE=$(hostname | tr -c 'A-Za-z0-9._\n-' '-' | cut -c1-64)
  case $CLAVE in *[!A-Za-z0-9_-]*|'') echo "Clave de inscripción no válida."; exit 1 ;; esac
  # La clave va por la entrada estándar de curl, no en la línea de comandos.
  RESP=$(printf '{"nombre":"%s","clave":"%s"}' "$NOMBRE" "$CLAVE" |
         curl -fsS --max-time 30 -H 'Content-Type: application/json' --data-binary @- "${SERVIDOR%/}/v1/inscribir") ||
    { echo "No pude registrar el equipo en $SERVIDOR."; exit 1; }
  TOKEN=$(printf '%s' "$RESP" | sed -n 's/.*"token":"\([A-Za-z0-9_-]*\)".*/\1/p')
fi
[ -n "${TOKEN:-}" ] || { echo "Falta el token del equipo (--token-archivo o --inscripcion-archivo)."; exit 1; }

# La bandeja necesita WebKitGTK y AppIndicator; se instalan con el gestor de paquetes si faltan.
if [ -n "$BANDEJA" ] && LANG=C ldd "$BANDEJA" | grep -q 'not found'; then
  if command -v apt-get >/dev/null; then apt-get install -y libwebkit2gtk-4.1-0 libayatana-appindicator3-1
  elif command -v dnf >/dev/null; then dnf install -y webkit2gtk4.1 libayatana-appindicator-gtk3
  elif command -v pacman >/dev/null; then pacman -S --needed --noconfirm webkit2gtk-4.1 libayatana-appindicator
  fi
  ! LANG=C ldd "$BANDEJA" | grep 'not found' || { echo "Faltan bibliotecas para la bandeja (arriba)."; exit 1; }
fi

install -Dm755 "$BIN/helpert-agente" /usr/local/bin/helpert-agente
install -Dm755 "$BIN/helpert" /usr/local/bin/helpert
# Copia propia de root: el usuario no puede tocar los playbooks que el agente ejecuta (además de la firma).
rm -rf /usr/lib/helpert/playbooks
install -d -m755 /usr/lib/helpert
cp -r --no-preserve=ownership "$PB" /usr/lib/helpert/playbooks
chown -R root:root /usr/lib/helpert && chmod -R u+rwX,go+rX,go-w /usr/lib/helpert
install -Dm644 "$PUB" /etc/helpert/playbooks.pub
umask 077
cat > /etc/helpert/agente.toml <<EOT
servidor = "$SERVIDOR"
token = "$TOKEN"
playbooks = "/usr/lib/helpert/playbooks"
clave_publica = "/etc/helpert/playbooks.pub"
socket = "/run/helpert/agente.sock"
EOT
umask 022
install -Dm644 "$UNIDAD" /etc/systemd/system/helpert-agente.service
systemctl daemon-reload
systemctl enable helpert-agente >/dev/null 2>&1
systemctl restart helpert-agente

if [ -n "$BANDEJA" ]; then
  pkill -x helpert-bandeja 2>/dev/null || true  # la versión anterior; el instalador abre la nueva como el usuario
  install -Dm755 "$BANDEJA" /usr/local/bin/helpert-bandeja
  install -Dm644 "$ICONO" /usr/share/icons/hicolor/256x256/apps/helpert.png
  rm -f /usr/share/icons/hicolor/scalable/apps/helpert.svg  # icono de versiones anteriores: el tema lo prefería al PNG
  ENTRADA='[Desktop Entry]
Type=Application
Name=Helpert
Comment=Soporte TI: cuéntale qué le pasa a tu equipo
Icon=helpert
Categories=Utility;'
  printf '%s\nExec=/usr/local/bin/helpert-bandeja --abrir\n' "$ENTRADA" > /usr/share/applications/helpert.desktop
  printf '%s\nExec=/usr/local/bin/helpert-bandeja\nNoDisplay=true\nX-GNOME-Autostart-enabled=true\n' "$ENTRADA" > /etc/xdg/autostart/helpert-bandeja.desktop
  chmod 644 /usr/share/applications/helpert.desktop /etc/xdg/autostart/helpert-bandeja.desktop
  gtk-update-icon-cache -q /usr/share/icons/hicolor 2>/dev/null || true
fi

sleep 1
systemctl is-active --quiet helpert-agente || { journalctl -u helpert-agente -n 20 --no-pager; exit 1; }
echo "Helpert instalado y en marcha. El icono aparece en la bandeja al iniciar sesión; en la terminal: helpert"
