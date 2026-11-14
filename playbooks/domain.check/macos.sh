#!/bin/bash
# Revisar la unión del Mac con el dominio (Active Directory): si sigue unido (dsconfigad) y si el servicio de
# directorio lo ve conectado (odutil). Solo lectura: termina con 10.
set -u
export LC_ALL=C

case ${1:-} in
diagnosticar)
  d=$(dsconfigad -show 2>/dev/null | sed -n 's/^[[:space:]]*Active Directory Domain[[:space:]]*=[[:space:]]*//p' | head -1)
  [ -n "$d" ] || { echo "Este Mac no está unido a un dominio de la empresa (Active Directory). Si debería estarlo, avisa a soporte."; exit 10; }
  e=$(odutil show nodenames 2>/dev/null | grep '/Active Directory/' | grep -v 'All Domains' | head -1)
  [ -n "$e" ] || e=$(odutil show nodenames 2>/dev/null | grep '/Active Directory/' | head -1)
  case $e in
  *Online*) echo "El Mac sigue unido al dominio $d y está conectado a sus servidores."
            echo "Si tu cuenta no entra, puede ser la contraseña o un bloqueo de la cuenta: revísalo con soporte." ;;
  *Offline*) echo "El Mac está unido al dominio $d, pero no llega a sus servidores."
             echo "Conéctate a la red de la oficina o a la VPN y vuelve a intentarlo. Si ya lo estás, la unión puede estar rota: avisa a soporte." ;;
  *) echo "El Mac está unido al dominio $d, pero no pude saber si está conectado a sus servidores. Si tu cuenta no entra, avisa a soporte." ;;
  esac
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
