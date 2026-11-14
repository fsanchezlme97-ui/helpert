#!/bin/bash
# Instala (o desinstala) Helpert en un Mac (macOS 13 o más nuevo): servicio del equipo (root, launchd) y bandeja en la
# barra de menús (cada usuario).
#   sudo despliegue/instalar-agente-macos.sh --paquete DIR      # lo usa «Instalar Helpert.command» (empaquetar-macos.sh)
#   sudo despliegue/instalar-agente-macos.sh --servidor URL --clave-publica F (--token-archivo F | --inscripcion-archivo F)
#        [--playbooks DIR] [--bin DIR] [--app Helpert.app] [--sin-bandeja]
#   sudo despliegue/instalar-agente-macos.sh --desinstalar
# Al reinstalar sin token ni inscripción se conserva el token del equipo. Los secretos van en archivos, no como argumentos.
# Bash 3.2 (el de macOS).
set -eu
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
PLIST=$(dirname "$0")/pe.helpert.agente.plist
BIN=$RAIZ/agente/target/release
APP=$RAIZ/bandeja/target/release/Helpert.app
PB=$RAIZ/playbooks
uso() { sed -n '4,7p' "$0"; exit 2; }
while [ $# -gt 0 ]; do
  case $1 in
    --paquete) P=$2; SERVIDOR=$(cat "$P/servidor.txt"); PUB=$P/playbooks.pub; INSCRIPCION_F=$P/inscripcion
               PB=$P/playbooks; BIN=$P/bin; APP=$P/Helpert.app; PLIST=$P/pe.helpert.agente.plist; shift 2 ;;
    --servidor) SERVIDOR=$2; shift 2 ;;
    --token-archivo) TOKEN_F=$2; shift 2 ;;
    --inscripcion-archivo) INSCRIPCION_F=$2; shift 2 ;;
    --clave-publica) PUB=$2; shift 2 ;;
    --playbooks) PB=$2; shift 2 ;;
    --bin) BIN=$2; shift 2 ;;
    --app) APP=$2; shift 2 ;;
    --sin-bandeja) APP=; shift ;;
    --desinstalar) DESINSTALAR=1; shift ;;
    *) uso ;;
  esac
done
[ "$(id -u)" -eq 0 ] || { echo "Ejecútalo con sudo."; exit 1; }
DAEMON=/Library/LaunchDaemons/pe.helpert.agente.plist
AGENTE=/Library/LaunchAgents/pe.helpert.bandeja.plist
# la persona con sesión gráfica abierta (la bandeja se abre en su sesión); vacío si nadie
CONSOLA=$(stat -f %Su /dev/console 2>/dev/null || true)
[ "$CONSOLA" = root ] && CONSOLA=
uid_consola() { id -u "$CONSOLA" 2>/dev/null; }

if [ "${DESINSTALAR:-}" ]; then
  launchctl bootout system/pe.helpert.agente 2>/dev/null || true
  [ -n "$CONSOLA" ] && launchctl bootout "gui/$(uid_consola)/pe.helpert.bandeja" 2>/dev/null || true
  pkill -x helpert-bandeja 2>/dev/null || true
  rm -f "$DAEMON" "$AGENTE" /usr/local/bin/helpert-agente /usr/local/bin/helpert
  rm -rf /usr/local/lib/helpert /etc/helpert /Applications/Helpert.app /var/run/helpert
  echo "Helpert desinstalado."
  exit 0
fi

[ -n "${SERVIDOR:-}" ] && [ -n "${PUB:-}" ] || uso
for f in "$BIN/helpert-agente" "$BIN/helpert" "$PUB" "$PLIST"; do
  [ -f "$f" ] || { echo "Falta $f"; exit 1; }
done
[ -z "$APP" ] || [ -x "$APP/Contents/MacOS/helpert-bandeja" ] || { echo "Falta $APP"; exit 1; }
ls "$PB"/*/firma.ed25519 >/dev/null 2>&1 || { echo "Los playbooks de $PB no están firmados."; exit 1; }

# Token del equipo: el dado, el que ya tenía (reinstalación) o uno nuevo con la clave de inscripción.
TOKEN=
if [ -n "${TOKEN_F:-}" ]; then
  TOKEN=$(tr -d '[:space:]' < "$TOKEN_F")
elif [ -f /etc/helpert/agente.toml ] && grep -q '^token = ' /etc/helpert/agente.toml; then
  TOKEN=$(sed -n 's/^token = "\(.*\)"$/\1/p' /etc/helpert/agente.toml)
elif [ -n "${INSCRIPCION_F:-}" ]; then
  CLAVE=$(tr -d '[:space:]' < "$INSCRIPCION_F")
  NOMBRE=$( (scutil --get ComputerName 2>/dev/null || hostname) | LC_ALL=C tr -c 'A-Za-z0-9._\n-' '-' | cut -c1-64)
  case $CLAVE in *[!A-Za-z0-9_-]*|'') echo "Clave de inscripción no válida."; exit 1 ;; esac
  # La clave va por la entrada estándar de curl, no en la línea de comandos.
  RESP=$(printf '{"nombre":"%s","clave":"%s"}' "$NOMBRE" "$CLAVE" |
         curl -fsS --max-time 30 -H 'Content-Type: application/json' --data-binary @- "${SERVIDOR%/}/v1/inscribir") ||
    { echo "No pude registrar el equipo en $SERVIDOR."; exit 1; }
  TOKEN=$(printf '%s' "$RESP" | sed -n 's/.*"token":"\([A-Za-z0-9_-]*\)".*/\1/p')
fi
[ -n "$TOKEN" ] || { echo "Falta el token del equipo (--token-archivo o --inscripcion-archivo)."; exit 1; }

launchctl bootout system/pe.helpert.agente 2>/dev/null || true  # la versión anterior
install -d -m 755 -o root -g wheel /usr/local/bin /usr/local/lib/helpert /etc/helpert
install -m 755 -o root -g wheel "$BIN/helpert-agente" "$BIN/helpert" /usr/local/bin/
# Copia propia de root: el usuario no puede tocar los playbooks que el agente ejecuta (además de la firma).
rm -rf /usr/local/lib/helpert/playbooks
cp -R "$PB" /usr/local/lib/helpert/playbooks
chown -R root:wheel /usr/local/lib/helpert && chmod -R u+rwX,go+rX,go-w /usr/local/lib/helpert
install -m 644 -o root -g wheel "$PUB" /etc/helpert/playbooks.pub
umask 077
cat > /etc/helpert/agente.toml <<EOT
servidor = "$SERVIDOR"
token = "$TOKEN"
playbooks = "/usr/local/lib/helpert/playbooks"
clave_publica = "/etc/helpert/playbooks.pub"
socket = "/var/run/helpert/agente.sock"
EOT
umask 022
# lo bajado de internet lleva la marca de cuarentena: Gatekeeper no dejaría arrancar al servicio
xattr -dr com.apple.quarantine /usr/local/bin/helpert-agente /usr/local/bin/helpert /usr/local/lib/helpert 2>/dev/null || true
install -m 644 -o root -g wheel "$PLIST" "$DAEMON"
launchctl bootstrap system "$DAEMON"

if [ -n "$APP" ]; then
  [ -n "$CONSOLA" ] && launchctl bootout "gui/$(uid_consola)/pe.helpert.bandeja" 2>/dev/null || true
  pkill -x helpert-bandeja 2>/dev/null || true
  rm -rf /Applications/Helpert.app
  cp -R "$APP" /Applications/Helpert.app
  chown -R root:wheel /Applications/Helpert.app && chmod -R go-w /Applications/Helpert.app
  xattr -dr com.apple.quarantine /Applications/Helpert.app 2>/dev/null || true
  cat > "$AGENTE" <<'EOT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>pe.helpert.bandeja</string>
  <key>ProgramArguments</key><array><string>/Applications/Helpert.app/Contents/MacOS/helpert-bandeja</string></array>
  <key>RunAtLoad</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
EOT
  chown root:wheel "$AGENTE" && chmod 644 "$AGENTE"
  # la bandeja de quien tiene la sesión abierta ahora; las demás personas la verán al iniciar sesión
  [ -n "$CONSOLA" ] && launchctl bootstrap "gui/$(uid_consola)" "$AGENTE" 2>/dev/null || true
fi

for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ -S /var/run/helpert/agente.sock ] && break
  sleep 1
done
if ! launchctl print system/pe.helpert.agente 2>/dev/null | grep -q 'state = running' || [ ! -S /var/run/helpert/agente.sock ]; then
  echo "El servicio de Helpert no quedó en marcha:"; tail -n 20 /var/log/helpert-agente.log 2>/dev/null; exit 1
fi
echo "Helpert instalado y en marcha. El icono aparece en la barra de menús; en la terminal: helpert"
