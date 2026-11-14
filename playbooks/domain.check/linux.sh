#!/bin/bash
# Revisar la unión con el dominio (realmd: SSSD o winbind): si el equipo sigue unido, si encuentra los servidores del
# dominio por DNS y si su cuenta de equipo sigue valiendo (adcli testjoin o wbinfo -t). Solo lectura: termina con 10.
set -u

case ${1:-} in
diagnosticar)
  if ! command -v realm >/dev/null; then
    { [ -e /etc/sssd/sssd.conf ] || command -v wbinfo >/dev/null; } && { echo "Este equipo tiene herramientas de dominio, pero no realmd, así que no puedo saber si sigue unido. Si tu cuenta de la empresa no entra, avisa a soporte."; exit 1; }
    echo "Este equipo no está unido a ningún dominio de la empresa. Si debería estarlo, avisa a soporte para que lo una."; exit 10
  fi
  d=$(realm list --name-only 2>/dev/null | head -1)
  [ -n "$d" ] || { echo "Este equipo no está unido a ningún dominio de la empresa. Si debería estarlo, avisa a soporte para que lo una."; exit 10; }
  if ! getent hosts "$d" >/dev/null 2>&1; then
    echo "El equipo está unido al dominio $d, pero no encuentra sus servidores."
    echo "Conéctate a la red de la oficina o a la VPN y vuelve a intentarlo. Si ya lo estás, avisa a soporte."
    exit 10
  fi
  [ "$(id -u)" -eq 0 ] || { echo "El equipo está unido al dominio $d y lo encuentra en la red. Sin privilegios de administrador no puedo probar la relación de confianza."; exit 10; }
  r=127
  if realm list 2>/dev/null | grep -q 'client-software: winbind'; then
    command -v wbinfo >/dev/null && { timeout 20 wbinfo -t >/dev/null 2>&1; r=$?; }
  elif command -v adcli >/dev/null; then
    timeout 20 adcli testjoin --domain="$d" >/dev/null 2>&1; r=$?
  fi
  case $r in
  0) echo "El equipo sigue unido al dominio $d, llega a sus servidores y la relación de confianza funciona."
     echo "Si tu cuenta no entra, puede ser la contraseña o un bloqueo de la cuenta: revísalo con soporte." ;;
  127) echo "El equipo está unido al dominio $d y lo encuentra en la red, pero no tengo con qué probar la relación de confianza (falta adcli o wbinfo). Si tu cuenta no entra, avisa a soporte." ;;
  124) echo "El equipo está unido al dominio $d, pero sus servidores no respondieron a tiempo. Conéctate a la red de la oficina o a la VPN; si sigue igual, avisa a soporte." ;;
  *) echo "El equipo está unido al dominio $d y lo encuentra en la red, pero el dominio no acepta la cuenta del equipo: la relación de confianza puede estar rota."
     echo "Soporte tiene que revisarla o volver a unir el equipo." ;;
  esac
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
