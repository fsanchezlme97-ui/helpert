#!/bin/bash
# Liberar espacio en disco en macOS: temporales de más de 7 días (sueltos en /private/tmp y /private/var/tmp, y la
# carpeta temporal de la persona), cachés de la persona (~/Library/Caches) de más de 30 días y registros antiguos del
# sistema (los ya rotados y comprimidos de /private/var/log y los informes de error de /Library/Logs/DiagnosticReports,
# de más de 30 días). La papelera y los documentos no se tocan.
# Como root solo se borran archivos sueltos de carpetas del sistema, sin entrar en subcarpetas (en /tmp cualquiera crea
# carpetas o enlaces); lo de la persona, con su usuario (sudo -u): find -delete no sigue enlaces. Bash 3.2.
set -u
usuario=${HP_USUARIO:-}
casa=$([ -n "$usuario" ] && [ "$usuario" != root ] && dscl . -read "/Users/$usuario" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
vol=/System/Volumes/Data; [ -d "$vol" ] || vol=/  # en APFS los datos viven en su propio volumen

como() { if [ "$(id -u)" -eq 0 ]; then sudo -u "$usuario" "$@"; else "$@"; fi; }
persona() { [ -n "$casa" ] && [ "$casa" != / ] && [ -d "$casa" ] && { [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ]; }; }
uso() { df -k "$vol" 2>/dev/null | awk 'NR == 2 {print $5 + 0}'; }
libre() { df -m "$vol" 2>/dev/null | awk 'NR == 2 {print $4 + 0}'; }
mb() { awk '{s += $1} END {printf "%d", s / 1048576}'; }
# cada función busca lo que se puede borrar; «$@» es la acción de find (sumar el tamaño o -delete)
temporales() { find /private/tmp /private/var/tmp -xdev -mindepth 1 -maxdepth 1 -type f -mtime +7 -atime +7 "$@" 2>/dev/null; }
registros() {
  find /private/var/log -xdev -mindepth 1 -maxdepth 1 -type f \( -name '*.gz' -o -name '*.bz2' \) -mtime +30 "$@" 2>/dev/null
  find /Library/Logs/DiagnosticReports -xdev -mindepth 1 -maxdepth 1 -type f -mtime +30 "$@" 2>/dev/null
}
# la carpeta temporal de la persona (/var/folders/…/T), la que le da macOS
tmp_persona() {
  local d; d=$(como getconf DARWIN_USER_TEMP_DIR 2>/dev/null)
  case $d in /private/var/folders/?*|/var/folders/?*) ;; *) return 0 ;; esac
  como find "$d" -xdev -mindepth 1 -type f -mtime +7 -atime +7 "$@" 2>/dev/null
}
cache() { [ -d "$casa/Library/Caches" ] && como find "$casa/Library/Caches" -xdev -mindepth 1 -type f -mtime +30 -atime +30 "$@" 2>/dev/null; }
tam() { "$@" -exec stat -f %z {} + | mb; }

case ${1:-} in
diagnosticar)
  t=$(tam temporales); l=$(tam registros); c=0
  persona && c=$(( $(tam tmp_persona) + $(tam cache) ))
  total=$((t + c + l)); u=$(uso)
  echo "El disco de datos está al ${u:-?}% de uso."
  echo "Se pueden liberar unos $total MB: $t MB de temporales, $c MB de tus temporales y caché antigua y $l MB de registros antiguos del sistema."
  persona || echo "No revisé tus temporales ni tu caché porque no sé qué persona lo pide."
  { [ "$total" -ge 100 ] || [ "${u:-0}" -ge 90 ]; } && exit 0
  echo "Hay espacio suficiente y poco que limpiar."
  exit 10 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para limpiar el disco."; exit 3; }
  exit 0 ;;
aplicar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para limpiar el disco."; exit 1; }
  antes=$(libre)
  temporales -delete
  registros -delete
  persona && { tmp_persona -delete; cache -delete; }
  sleep 2
  liberado=$(( $(libre) - ${antes:-0} )); [ "$liberado" -ge 0 ] || liberado=0
  echo "Liberé $liberado MB. El disco quedó al $(uso)% de uso."
  # con instantáneas locales de Time Machine, el espacio de lo borrado vuelve cuando macOS las quita
  tmutil listlocalsnapshots "$vol" 2>/dev/null | grep -q 'com\.apple\.' &&
    echo "Parte del espacio puede tardar en aparecer: macOS lo devuelve cuando borra sus copias locales de Time Machine (en menos de 24 horas)."
  exit 0 ;;
verificar)
  u=$(uso)
  [ -n "$u" ] || { echo "No pude leer el uso del disco."; exit 1; }
  [ "$u" -lt 95 ] || { echo "El disco sigue casi lleno ($u%)."; exit 1; }
  echo "El disco está al $u%, con espacio suficiente."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
