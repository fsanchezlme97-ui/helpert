#!/bin/bash
# Ver qué programa usa internet: los 5 programas con más conexiones abiertas (TCP y UDP conectadas, con ss), sin contar
# las del propio equipo (127.0.0.1, ::1). Cuenta conexiones, no lo que gasta cada una. Solo revisa: no cierra nada.
set -u

case ${1:-} in
diagnosticar)
  command -v ss >/dev/null || { echo "Falta la herramienta ss en este equipo para ver las conexiones."; exit 1; }
  # columnas de ss -tunpH: Netid State Recv-Q Send-Q Local Peer Process; el programa va en users:(("nombre",pid=…
  top=$(ss -tunpH 2>/dev/null | awk '
    $2 == "ESTAB" && $6 !~ /^(127\.|\[::1\]|\[::ffff:127\.)/ {
      p = "(del sistema)"; if (match($0, /users:\(\("[^"]+"/)) p = substr($0, RSTART + 9, RLENGTH - 10); n[p]++; t++ }
    END {for (p in n) print n[p] "\t" p; if (t) print t "\tTOTAL"}' | sort -t "$(printf '\t')" -k1,1nr)
  total=$(printf '%s\n' "$top" | awk -F'\t' '$2 == "TOTAL" {print $1}')
  [ -n "$total" ] || { echo "Ahora mismo ningún programa está conectado a internet."; exit 10; }
  lista=$(printf '%s\n' "$top" | awk -F'\t' '$2 != "TOTAL"' | head -5)
  primero=$(printf '%s\n' "$lista" | head -1 | cut -f2); n1=$(printf '%s\n' "$lista" | head -1 | cut -f1)
  echo "El programa con más conexiones abiertas es $primero ($n1 de $total)."
  printf '%s\n' "$lista" | awk -F'\t' '{print "- " $2 ": " $1 " conexión(es)"}'
  echo "Muchas conexiones no siempre es mucho consumo, pero las descargas, las actualizaciones y la sincronización con la nube suelen ser las que más gastan."
  echo "Si no estás usando alguno, puedes cerrarlo tú; yo no cierro nada."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
