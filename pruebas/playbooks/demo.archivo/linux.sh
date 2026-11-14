#!/bin/bash
set -u
f="/tmp/helpert-prueba-$HP_NOMBRE"
case ${1:-} in
diagnosticar) echo "Se creará $f."; exit 0 ;;
comprobar) exit 0 ;;
aplicar) echo "paso=$1 usuario=${HP_USUARIO:-} path=$PATH" > "$f" && echo "Creé $f." ;;
verificar) [ -f "$f" ] && echo "Existe $f." ;;
deshacer) rm -f "$f" && echo "Borré $f." ;;
*) exit 2 ;;
esac
