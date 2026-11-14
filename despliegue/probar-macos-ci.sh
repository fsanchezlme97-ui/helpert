#!/bin/bash
# Prueba de punta a punta en macOS (la corre la CI en macos-latest): servidor con un PostgreSQL de Homebrew, el agente
# instalado de verdad con instalar-agente-macos.sh (launchd, root), una consulta por el socket desde este usuario
# con «helpert --estado» y la desinstalación. Usa una clave de firma de un solo uso; nada de esto es de producción.
#   despliegue/probar-macos-ci.sh DIST   (DIST: lo que dejó armar-macos.sh)
set -eu
RAIZ=$(cd "$(dirname "$0")/.." && pwd)
DIST=$(cd "$1" && pwd)
T=$(mktemp -d)
srv() { uv run -q --project "$RAIZ/server" helpert-server "$@"; }

brew install -q postgresql@16 >/dev/null
PGBIN=$(brew --prefix postgresql@16)/bin
"$PGBIN/initdb" -D "$T/pg" -U postgres --auth=trust >/dev/null
"$PGBIN/pg_ctl" -D "$T/pg" -l "$T/pg.log" -o "-p 5432 -k $T" -w start >/dev/null
"$PGBIN/createdb" -h localhost -U postgres helpert_ci
srv claves "$T/claves"
cp -R "$RAIZ/pruebas/playbooks" "$T/pb"
srv firmar "$T/pb" --clave "$T/claves/playbooks.key"
printf 'base_datos = "postgresql://postgres@localhost/helpert_ci"\nplaybooks = "%s"\n[[ia]]\nproveedor = "ollama"\nmodelo = "x"\nurl = "http://127.0.0.1:9"\n' \
  "$T/pb" > "$T/helpert-server.toml"
srv --config "$T/helpert-server.toml" equipo-nuevo ci-macos | tail -1 > "$T/token"
srv --config "$T/helpert-server.toml" servir --puerto 8765 2> "$T/servidor.log" &
SERVIDOR=$!
trap 'kill $SERVIDOR 2>/dev/null; sudo "$RAIZ/despliegue/instalar-agente-macos.sh" --desinstalar >/dev/null 2>&1 || true' EXIT
for _ in $(seq 60); do curl -fs http://127.0.0.1:8765/salud >/dev/null && break; sleep 1; done

falla() { echo "FALLA: $*"; sudo tail -n 30 /var/log/helpert-agente.log 2>/dev/null; tail -n 30 "$T/servidor.log"; exit 1; }
sudo "$RAIZ/despliegue/instalar-agente-macos.sh" --servidor http://127.0.0.1:8765 --clave-publica "$T/claves/playbooks.pub" \
  --token-archivo "$T/token" --playbooks "$T/pb" --bin "$DIST/bin" --app "$DIST/Helpert.app" || falla "el instalador"
[ "$(stat -f '%Su %Lp' /etc/helpert/agente.toml)" = "root 600" ] || falla "agente.toml debe ser de root y 600"
[ "$(stat -f %Su /usr/local/lib/helpert/playbooks)" = root ] || falla "los playbooks deben ser de root"
[ -x /Applications/Helpert.app/Contents/MacOS/helpert-bandeja ] || falla "no quedó Helpert.app"
r=$(/usr/local/bin/helpert --estado) || falla "la consulta por el socket: $r"
echo "helpert --estado: $r"
sudo "$RAIZ/despliegue/instalar-agente-macos.sh" --desinstalar
! launchctl print system/pe.helpert.agente >/dev/null 2>&1 || falla "el servicio sigue cargado tras desinstalar"
[ ! -e /usr/local/bin/helpert-agente ] && [ ! -e /etc/helpert ] || falla "quedaron archivos tras desinstalar"
echo "Servicio, socket y servidor en macOS: bien."
