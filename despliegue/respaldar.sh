#!/usr/bin/env bash
# Respaldo diario de la base de Helpert (lo lanza helpert-respaldo.timer): pg_dump en formato propio, se guardan 14.
# Restaurar: pg_restore --clean --if-exists -d "$HELPERT_DB" /var/backups/helpert/helpert-AAAAMMDD-HHMM.dump
# Copia también estos archivos fuera de la VPS (con la clave maestra de /etc/helpert/servidor.env, aparte).
set -euo pipefail
while IFS= read -r linea; do
  [[ "$linea" =~ ^HELPERT_DB=(.*)$ ]] && HELPERT_DB="${BASH_REMATCH[1]}"
done < /etc/helpert/servidor.env
umask 077
destino=/var/backups/helpert/helpert-$(date +%Y%m%d-%H%M).dump
pg_dump --format=custom --no-owner --file="$destino.parcial" "$HELPERT_DB"
mv "$destino.parcial" "$destino"
ls -1t /var/backups/helpert/helpert-*.dump | tail -n +15 | xargs -r rm --
echo "Respaldo: $destino ($(du -h "$destino" | cut -f1))"
