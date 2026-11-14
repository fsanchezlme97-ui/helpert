#!/bin/bash
# Entorno de desarrollo en este equipo: PostgreSQL propio en .dev, playbooks firmados con una clave de prueba,
# equipo registrado, servidor y agente (sin privilegios: los pasos que necesitan root fallan en «comprobar» y se escalan).
# Uso: ./dev.sh        luego, en otra terminal: HELPERT_SOCKET=.dev/agente.sock agente/target/debug/helpert
#      consola web:    http://127.0.0.1:8765/consola   (crea tu cuenta con: ./dev.sh usuario tu@correo admin)
#      bandeja/chat:   inicia sesión con un código de: ./dev.sh persona tu@correo "Mi organización"
# Con el playbook inofensivo de pruebas (sí llega a aplicar): DEV=.dev-pruebas PLAYBOOKS=pruebas/playbooks PUERTO=8766 ./dev.sh
set -eu
cd "$(dirname "$0")"
D=$(realpath -m "${DEV:-.dev}")
PB=$(realpath "${PLAYBOOKS:-playbooks}")
PUERTO=${PUERTO:-8765}
PG=$PWD/.dev    # un solo PostgreSQL de desarrollo; cada entorno usa su propia base
BASE=$(basename "$D" | tr -c 'a-z0-9\n' '_')
DSN="postgresql://helpert@/$BASE?host=$PG/pgsock"
mkdir -p "$D" "$PG/pgsock"
chmod 700 "$PG/pgsock"   # el clúster de desarrollo usa trust: solo tu usuario llega al socket
srv() { uv run -q --project server helpert-server --config "$D/helpert-server.toml" "$@"; }

[ -d "$PG/pg" ] || initdb -D "$PG/pg" -U helpert --auth=trust -E UTF8 --locale=C.UTF-8 >/dev/null
pg_ctl -D "$PG/pg" status >/dev/null || pg_ctl -D "$PG/pg" -l "$PG/pg.log" -o "-k $PG/pgsock -c listen_addresses=''" -w start >/dev/null
psql -h "$PG/pgsock" -U helpert -d postgres -tAc "SELECT 1 FROM pg_database WHERE datname = '$BASE'" | grep -q 1 \
  || createdb -h "$PG/pgsock" -U helpert "$BASE"
[ "${1:-}" = pg ] && { echo "PostgreSQL de desarrollo listo: $DSN"; exit; }

if [ ! -f "$D/helpert-server.toml" ]; then
  cat > "$D/helpert-server.toml" <<EOT
base_datos = "$DSN"
playbooks = "$PB"
umbral_confianza = 0.7
# En desarrollo solo Ollama local. Para probar una API como principal, copia el bloque de server/helpert-server.example.toml.
[[ia]]
proveedor = "ollama"
modelo = "gemma4:e4b"
url = "http://localhost:11434"
EOT
fi
if [ "${1:-}" = usuario ]; then srv usuario-consola "$2" --rol "${3:-admin}" ${4:+--empresa "$4"}; exit; fi
if [ "${1:-}" = persona ]; then srv persona "$2" --empresa "${3:-Mi organización}"; exit; fi

[ -f "$D/claves/playbooks.key" ] || uv run -q --project server helpert-server claves "$D/claves"
uv run -q --project server helpert-server firmar "$PB" --clave "$D/claves/playbooks.key"
if [ ! -f "$D/agente.toml" ]; then
  token=$(srv equipo-nuevo "$(hostname)-dev")
  cat > "$D/agente.toml" <<EOT
servidor = "http://127.0.0.1:$PUERTO"
token = "$token"
playbooks = "$PB"
clave_publica = "$D/claves/playbooks.pub"
socket = "$D/agente.sock"
EOT
  chmod 600 "$D/agente.toml"
fi
(cd agente && cargo build -q)
# Clave de inscripción de desarrollo: la usa el instalador (despliegue/empaquetar-linux.sh) para registrar el equipo.
[ -f "$D/inscripcion" ] || (umask 077; head -c 32 /dev/urandom | base64 | tr '+/' '-_' | tr -d '=\n' > "$D/inscripcion")
grep -q '^inscripcion_env' "$D/helpert-server.toml" || sed -i '1i inscripcion_env = "HELPERT_INSCRIPCION"' "$D/helpert-server.toml"
export HELPERT_INSCRIPCION=$(cat "$D/inscripcion")
# Clave maestra de desarrollo: cifra las claves de API que se guardan desde la consola.
[ -f "$D/clave-maestra" ] || (umask 077; head -c 32 /dev/urandom | base64 | tr '+/' '-_' > "$D/clave-maestra")
export HELPERT_CLAVE_MAESTRA=$(cat "$D/clave-maestra")
# Clave pública: el servidor comprueba con ella las versiones del agente que se publican.
grep -q '^clave_publica' "$D/helpert-server.toml" || sed -i '1i clave_publica = "claves/playbooks.pub"' "$D/helpert-server.toml"
# uv directo (no la función srv, que corre en un subshell): así kill $S llega al servidor
uv run -q --project server helpert-server --config "$D/helpert-server.toml" servir --puerto "$PUERTO" & S=$!
trap 'kill $S 2>/dev/null' EXIT
until (echo > /dev/tcp/127.0.0.1/$PUERTO) 2>/dev/null; do kill -0 $S 2>/dev/null || { echo "El servidor no arrancó (¿puerto $PUERTO ocupado?)"; exit 1; }; sleep 0.5; done
agente/target/debug/helpert-agente "$D/agente.toml"
