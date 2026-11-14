#!/usr/bin/env bash
# Respaldo diario de la base de Helpert (lo lanza helpert-respaldo.timer): pg_dump en formato propio, se guardan 14.
# Restaurar (base local): sudo -u helpert pg_restore --clean --if-exists -d helpert /var/backups/helpert/helpert-AAAAMMDD-HHMM.dump
# Copia también estos archivos fuera de la VPS (con la clave maestra de /etc/helpert/servidor.env, aparte).
set -euo pipefail
while IFS= read -r linea; do
  [[ "$linea" =~ ^HELPERT_DB=(.*)$ ]] && HELPERT_DB="${BASH_REMATCH[1]}"
done < /etc/helpert/servidor.env
# la cadena puede llevar contraseña: va a pg_dump por variables PG* (no por argumentos, que se ven en ps)
while IFS= read -r -d '' par; do export "$par"; done < <(HELPERT_DB="$HELPERT_DB" /opt/helpert/server/.venv/bin/python -c '
import os, psycopg
nombres = {"host": "PGHOST", "port": "PGPORT", "user": "PGUSER", "password": "PGPASSWORD", "dbname": "PGDATABASE", "sslmode": "PGSSLMODE"}
for k, v in psycopg.conninfo.conninfo_to_dict(os.environ["HELPERT_DB"]).items():
    if k in nombres: print(f"{nombres[k]}={v}", end="\0")')
unset HELPERT_DB
umask 077
destino=/var/backups/helpert/helpert-$(date +%Y%m%d-%H%M).dump
pg_dump --format=custom --no-owner --file="$destino.parcial"
mv "$destino.parcial" "$destino"
ls -1t /var/backups/helpert/helpert-*.dump | tail -n +15 | xargs -r rm --
echo "Respaldo: $destino ($(du -h "$destino" | cut -f1))"
