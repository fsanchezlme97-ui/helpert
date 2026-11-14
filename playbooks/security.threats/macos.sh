#!/bin/bash
# Ver qué detectó el antivirus en macOS: los análisis automáticos de XProtect Remediator de los últimos 3 días (registro
# unificado; macOS no guarda mucho más) y, si el equipo tiene Microsoft Defender (mdatp), su historial de amenazas.
# Solo lectura: termina con 10. Sacar un archivo de la cuarentena lo decide soporte.
set -u
export LC_ALL=C
PREDICADO='subsystem == "com.apple.XProtectFramework.PluginAPI" && category == "XPEvent.structured"'
tope() {  # corre «$2...» con un tope de $1 segundos (macOS no trae timeout); sale con 124 si se cortó
  local s=$1; shift
  "$@" & local p=$!
  ( sleep "$s"; pkill -P "$p"; kill "$p" ) >/dev/null 2>&1 &
  local v=$!
  wait "$p"; local c=$?
  if kill -0 "$v" 2>/dev/null; then kill "$v" 2>/dev/null; else c=124; fi
  return "$c"
}
# «dd/mm hh:mm: familia (qué hizo)» de cada detección de XProtect Remediator en el registro leído
xprotect() {
  printf '%s\n' "$1" | grep -viE 'NoThreatDetected|No threat detected|MRT completed' |
    grep -iE '"status_message":"[^"]*(threat ?detected|remediat)' | while IFS= read -r l; do
      f=$(printf '%s\n' "$l" | grep -oE 'XProtectRemediator[A-Za-z0-9]+' | head -1 | sed 's/^XProtectRemediator//')
      w=$(printf '%s\n' "$l" | sed -n -E 's/^[0-9]{4}-([0-9]{2})-([0-9]{2}) ([0-9]{2}:[0-9]{2}).*/\2\/\1 \3/p')
      if printf '%s\n' "$l" | grep -qi remediat; then q='XProtect la eliminó'; else q='detectada'; fi
      echo "- ${w:-hace poco}: ${f:-amenaza sin nombre} (${q})."
    done | awk '!visto[$0]++'
}
# «- nombre en «archivo»: qué hizo» de cada amenaza del historial de Defender (salida de «mdatp threat list»)
defender() {
  printf '%s\n' "$1" | awk '
    function valor(l) { sub(/^[^:]*: */, "", l); gsub(/"/, "", l); return l }
    function sale() {
      if (n == "") return
      e = (s == "quarantined") ? "aislada en cuarentena" : (s == "removed") ? "eliminada" : (s == "cleaned") ? "limpiada" : \
          (s == "allowed") ? "permitida" : (s == "infected") ? "detectada, sin resolver" : (s != "") ? s : "sin datos de qué hizo"
      a = r; sub(/,.*$/, "", a); gsub(/\[|\]/, "", a); sub(/^.*\//, "", a)
      print "- " n ((a != "") ? " en «" a "»" : "") ": " e "."; n = ""; s = ""; r = ""
    }
    /^ *Id:/ { sale() }
    /^ *Name:/ { n = valor($0) }
    /^ *Status:/ { s = valor($0) }
    /^ *(Path|File paths?):/ { r = valor($0) }
    END { sale() }'
}

case ${1:-} in
diagnosticar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para leer el registro del antivirus."; exit 3; }
  command -v log >/dev/null || { echo "No puedo leer el registro de macOS en este equipo."; exit 1; }
  r=$(tope 40 log show --info --last 3d --style syslog --predicate "$PREDICADO" 2>/dev/null); c=$?
  x=$(xprotect "$r")
  d=""; dc=0
  if command -v mdatp >/dev/null; then
    t=$(tope 12 mdatp threat list 2>/dev/null); dc=$?
    printf '%s\n' "$t" | grep -qiE '^ *no threats?( |\.|$)' && t=""
    d=$(defender "$t")
    [ "$dc" -eq 0 ] && { [ -n "$d" ] || [ -z "$(printf '%s' "$t" | tr -d '[:space:]')" ]; } || dc=1  # salida que no entiendo
  fi
  nx=$(printf '%s\n' "$x" | grep -c .); nd=$(printf '%s\n' "$d" | grep -c .)
  if [ $((nx + nd)) -eq 0 ]; then
    [ "$c" -eq 0 ] || { echo "No pude leer a tiempo el registro de XProtect, el antivirus de macOS: vuelve a intentarlo en un rato o avisa a soporte."; exit 1; }
    [ "$dc" -eq 0 ] || { echo "No pude leer el historial de Microsoft Defender: avisa a soporte."; exit 1; }
    printf '%s\n' "$r" | grep -q '"status_message"' || { echo "No encontré resultados de los análisis automáticos de XProtect de los últimos 3 días, así que no puedo saber si detectó algo. Si el antivirus te avisó de algo, avisa a soporte."; exit 1; }
    echo "XProtect, el antivirus de macOS, no registró amenazas en los últimos 3 días."
    command -v mdatp >/dev/null && echo "Microsoft Defender tampoco tiene amenazas en su historial."
    echo "macOS guarda pocos días de este registro: si el aviso fue antes, soporte puede revisarlo en su consola."
    exit 10
  fi
  echo "El antivirus registró $((nx + nd)) amenaza(s). Las más recientes:"
  [ "$nx" -gt 0 ] && printf '%s\n' "$x" | tail -4
  [ "$nd" -gt 0 ] && printf '%s\n' "$d" | tail -4 | sed 's/^- /- Microsoft Defender: /'
  [ "$c" -eq 0 ] || echo "No pude leer todo el registro de XProtect: puede haber más."
  [ "$dc" -eq 0 ] || echo "No pude leer el historial de Microsoft Defender."
  echo "No abras esos archivos. Si falta un archivo tuyo que necesitas, soporte decide si se puede recuperar."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
