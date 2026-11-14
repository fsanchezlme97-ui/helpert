#!/bin/bash
# Ver qué programas aceptan conexiones desde la red: puertos TCP en escucha y UDP abiertos, sin contar los que solo
# atienden al propio Mac (127.0.0.1, ::1). Los UDP de 49152 en adelante se omiten: son puertos de paso que cada
# programa usa para sus propias consultas. Solo lectura: termina con 10.
set -u
export LC_ALL=C
puertos() {
  { lsof -nP +c 0 -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 {print "tcp", $1, $9}'
    lsof -nP +c 0 -iUDP 2>/dev/null | awk 'NR > 1 {print "udp", $1, $9}'; } |
  awk '{
    if ($3 ~ /->/) next
    puerto = $3; sub(/.*:/, "", puerto); host = substr($3, 1, length($3) - length(puerto) - 1)
    if (host ~ /^127\.|^\[::1\]$|^localhost$/ || puerto !~ /^[0-9]+$/) next
    if ($1 == "udp" && puerto + 0 >= 49152) next
    prog = $2; gsub(/\\x20/, " ", prog)
    print puerto "/" $1 ": " prog
  }' | sort -u | sort -t/ -k1,1n
}

case ${1:-} in
diagnosticar)
  command -v lsof >/dev/null || { echo "No encuentro la herramienta para ver los puertos (lsof)."; exit 1; }
  l=$(puertos)
  [ -z "$l" ] && { echo "Ningún programa acepta conexiones desde la red en este Mac."; exit 10; }
  n=$(printf '%s\n' "$l" | wc -l | tr -d ' ')
  echo "Hay $n puerto(s) abiertos a la red. Puerto y programa:"
  printf '%s\n' "$l" | head -7 | sed 's/^/- /'
  [ "$n" -gt 7 ] && echo "… y $((n - 7)) más."
  echo "Que un puerto esté abierto no quiere decir que el cortafuegos deje entrar conexiones de afuera."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
