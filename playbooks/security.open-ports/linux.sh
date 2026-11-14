#!/bin/bash
# Ver qué programas aceptan conexiones desde la red: puertos TCP en escucha y UDP abiertos, sin contar los que solo
# atienden al propio equipo (127.0.0.1, ::1). Solo lectura: termina con 10.
set -u
puertos() {
  ss -H -tulnp 2>/dev/null | awk '{
    loc = $5; puerto = loc; sub(/.*:/, "", puerto); host = substr(loc, 1, length(loc) - length(puerto) - 1)
    if (host ~ /^127\.|^\[::1\]|%lo$|^\[::ffff:127\./) next
    prog = "programa desconocido"
    if (match($0, /users:\(\("[^"]+"/)) prog = substr($0, RSTART + 9, RLENGTH - 10)
    print puerto "/" $1 ": " prog
  }' | sort -u | sort -t/ -k1,1n
}

case ${1:-} in
diagnosticar)
  command -v ss >/dev/null || { echo "No encuentro la herramienta para ver los puertos (ss)."; exit 1; }
  l=$(puertos)
  [ -z "$l" ] && { echo "Ningún programa acepta conexiones desde la red en este equipo."; exit 10; }
  n=$(printf '%s\n' "$l" | wc -l)
  echo "Hay $n puerto(s) abiertos a la red. Puerto y programa:"
  printf '%s\n' "$l" | head -7 | sed 's/^/- /'
  [ "$n" -gt 7 ] && echo "… y $((n - 7)) más."
  echo "Que un puerto esté abierto no quiere decir que el cortafuegos deje entrar conexiones de afuera."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
