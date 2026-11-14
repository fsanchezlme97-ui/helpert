#!/usr/bin/env bash
# Instala el servidor de Helpert en una VPS Debian 12+/Ubuntu 24.04+ (como root, desde una copia del repositorio
# con los playbooks YA firmados en tu equipo: la clave privada nunca viaja a la VPS).
#
#   sudo ./despliegue/instalar-servidor.sh --dominio helpert.miempresa.pe --clave-publica ./playbooks.pub
#        [--db-env]   usa HELPERT_DB de /etc/helpert/servidor.env (Supabase u otro PostgreSQL) en vez de uno local
#
# Deja: usuario «helpert», el código en /opt/helpert, PostgreSQL local (si no se pide otro), /etc/helpert con la
# configuración y los secretos generados, Caddy con HTTPS para el dominio, el servicio systemd, el respaldo diario
# y el cortafuegos (22, 80, 443). Se puede volver a ejecutar para actualizar: no pisa secretos ni la configuración.
set -euo pipefail

DOMINIO="" PUB="" DB_ENV=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dominio) DOMINIO="$2"; shift 2 ;;
    --clave-publica) PUB="$2"; shift 2 ;;
    --db-env) DB_ENV=1; shift ;;
    *) echo "Opción desconocida: $1" >&2; exit 2 ;;
  esac
done
[ "$(id -u)" = 0 ] || { echo "Ejecútalo con sudo." >&2; exit 1; }
[[ "$DOMINIO" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] || { echo "--dominio no válido (p. ej. helpert.miempresa.pe)" >&2; exit 2; }
[ -f "$PUB" ] && grep -qE '^[0-9a-f]{64}$' "$PUB" || { echo "--clave-publica: falta playbooks.pub (helpert-server claves, en tu equipo)" >&2; exit 2; }
REPO="$(cd "$(dirname "$0")/.." && pwd)"
for m in "$REPO"/playbooks/*/manifest.toml; do
  [ -f "$(dirname "$m")/firma.ed25519" ] || { echo "$(dirname "$m"): sin firmar. Fírmalos en tu equipo: helpert-server firmar ../playbooks --clave ..." >&2; exit 1; }
done

echo "== Paquetes"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q caddy curl rsync sudo ca-certificates $([ "$DB_ENV" = 1 ] && echo postgresql-client || echo postgresql)
if ! command -v uv >/dev/null; then
  curl -LsSf https://astral.sh/uv/install.sh | env UV_UNMANAGED_INSTALL=/usr/local/bin sh
fi

echo "== Usuario y código"
id helpert >/dev/null 2>&1 || useradd --system --create-home --home-dir /home/helpert --shell /usr/sbin/nologin helpert
mkdir -p /opt/helpert
# el código es de root (el servicio no puede modificarlo); solo el entorno de Python es del usuario helpert
rsync -a --delete --exclude .git --exclude .dev --exclude 'target/' --exclude 'node_modules/' --exclude 'server/.venv' --exclude '*.key' \
  "$REPO"/ /opt/helpert/
chown -R root:root /opt/helpert
mkdir -p /opt/helpert/server/.venv && chown -R helpert: /opt/helpert/server/.venv
(cd /opt/helpert/server && sudo -u helpert env HOME=/home/helpert uv sync --frozen -q)
# «helpert-server» en la VPS: corre como el usuario helpert con los secretos del archivo, sin ponerlos en la línea de órdenes
install -m 755 /opt/helpert/despliegue/helpert-server-vps /usr/local/bin/helpert-server

echo "== Configuración en /etc/helpert"
install -d -m 750 -o root -g helpert /etc/helpert
install -m 644 "$PUB" /etc/helpert/playbooks.pub
ENV=/etc/helpert/servidor.env
if [ ! -f "$ENV" ]; then
  umask 027
  {
    echo "# Secretos del servidor de Helpert. Guarda una copia de HELPERT_CLAVE_MAESTRA fuera de la VPS:"
    echo "# sin ella no se pueden leer las claves de API guardadas en la consola."
    [ "$DB_ENV" = 1 ] && echo "HELPERT_DB=postgresql://CAMBIA-ESTO" || echo "HELPERT_DB=postgresql://helpert@/helpert?host=/var/run/postgresql"
    echo "HELPERT_CLAVE_MAESTRA=$(head -c 32 /dev/urandom | base64 | tr '+/' '-_')"
    echo "HELPERT_INSCRIPCION=$(head -c 24 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=')"
    echo "# HELPERT_IA_CLAVE=...     (o guárdala en Consola → Administración → IA)"
    echo "# HELPERT_SMTP_CLAVE=..."
  } > "$ENV"
  umask 022
  chown root:helpert "$ENV"; chmod 640 "$ENV"
  echo "   Creado $ENV con una clave maestra y una clave de inscripción nuevas."
fi
TOML=/etc/helpert/helpert-server.toml
if [ ! -f "$TOML" ]; then
  sed -e 's|^playbooks = .*|playbooks = "/opt/helpert/playbooks"|' /opt/helpert/server/helpert-server.example.toml > "$TOML"
  chown root:helpert "$TOML"; chmod 640 "$TOML"
fi

if [ "$DB_ENV" = 0 ]; then
  echo "== PostgreSQL local (por socket, sin contraseña: solo el usuario helpert del sistema entra)"
  systemctl enable --now postgresql
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='helpert'" | grep -q 1 || sudo -u postgres createuser helpert
  sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='helpert'" | grep -q 1 || sudo -u postgres createdb -O helpert helpert
fi

echo "== Servicio y respaldo"
install -m 644 /opt/helpert/despliegue/helpert-server.service /etc/systemd/system/
install -m 644 /opt/helpert/despliegue/helpert-respaldo.service /opt/helpert/despliegue/helpert-respaldo.timer /etc/systemd/system/
install -d -m 700 -o helpert -g helpert /var/backups/helpert
systemctl daemon-reload
systemctl enable helpert-respaldo.timer >/dev/null
systemctl start helpert-respaldo.timer
if grep -q CAMBIA-ESTO "$ENV"; then
  echo "   Pon la cadena de tu PostgreSQL en HELPERT_DB ($ENV) y vuelve a ejecutar este script."
  exit 0
fi
systemctl enable helpert-server >/dev/null
systemctl restart helpert-server

echo "== Caddy (HTTPS automático para $DOMINIO; el registro DNS debe apuntar ya a esta VPS)"
[ -f /etc/caddy/Caddyfile ] && ! grep -q "Helpert" /etc/caddy/Caddyfile && cp /etc/caddy/Caddyfile /etc/caddy/Caddyfile.antes-de-helpert
sed "s|^helpert.ejemplo.pe {|$DOMINIO {|" /opt/helpert/despliegue/Caddyfile > /etc/caddy/Caddyfile
systemctl enable caddy >/dev/null
systemctl reload-or-restart caddy

if command -v ufw >/dev/null; then
  echo "== Cortafuegos"
  ufw allow OpenSSH >/dev/null; ufw allow 80/tcp >/dev/null; ufw allow 443/tcp >/dev/null; ufw --force enable >/dev/null
fi

echo "== Revisión"
for _ in $(seq 20); do curl -fsS http://127.0.0.1:8000/salud >/dev/null 2>&1 && break; sleep 1; done
helpert-server revisar || true
cat <<EOF

Listo. Lo que queda (una sola vez):
  1. Cuenta de administración (pide la contraseña sin mostrarla):
     sudo helpert-server usuario-consola TU-CORREO --rol admin
  2. Consola: https://$DOMINIO/consola → Administración → IA (clave de API) y Inscripción.
  3. Paquete de Windows, en tu equipo: ./despliegue/empaquetar-windows.sh --servidor https://$DOMINIO ...
     (la clave de inscripción está en $ENV, HELPERT_INSCRIPCION)
  4. Comprueba todo cuando quieras: sudo helpert-server revisar
EOF
