#!/bin/bash
# Ver qué detectó ClamAV en los últimos 30 días, según los registros de su análisis automático (clamd y clamonacc).
# Solo lectura: termina con 10. Sacar o borrar un archivo lo decide soporte.
set -u
UNIDADES=(-u clamav-daemon -u clamav-clamonacc -u clamd@scan -u clamonacc)
detecciones() {
  journalctl -q --no-pager --since "30 days ago" "${UNIDADES[@]}" 2>/dev/null | grep ' FOUND'
  find /var/log/clamav -name '*.log' -mtime -30 -exec grep -h ' FOUND' {} + 2>/dev/null
}
vigila() { for s in clamav-daemon clamav-clamonacc clamd@scan clamonacc; do systemctl is-active -q "$s" 2>/dev/null && return 0; done; return 1; }

case ${1:-} in
diagnosticar)
  command -v clamscan >/dev/null || command -v clamd >/dev/null || { echo "Este equipo no tiene antivirus (ClamAV), así que no hay detecciones que revisar."; exit 3; }
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para leer los registros del antivirus."; exit 3; }
  d=$(detecciones | awk '!visto[$0]++')
  if [ -z "$d" ]; then
    if vigila; then echo "ClamAV no registró amenazas en los últimos 30 días."
    else echo "ClamAV no tiene activo el análisis automático, así que no hay un registro de detecciones que revisar."; fi
    echo "Los análisis que se hacen a mano (como el análisis rápido de Helpert) no quedan registrados."
    exit 10
  fi
  echo "ClamAV detectó $(printf '%s\n' "$d" | wc -l) amenaza(s) en los últimos 30 días, por ejemplo:"
  printf '%s\n' "$d" | tail -8 | sed 's|^.*/\([^/:]*\): \(.*\) FOUND.*$|- \1 (\2)|'
  echo "ClamAV solo avisa: no mueve ni borra archivos salvo que soporte lo haya configurado así. No abras esos archivos y avisa a soporte."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
