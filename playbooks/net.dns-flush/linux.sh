#!/bin/bash
# Limpiar la caché de nombres (DNS): la de systemd-resolved y, si está, la de nscd. No reinicia la red.
set -u
resuelve() { timeout 5 getent hosts example.com >/dev/null 2>&1; }
resolved() { command -v resolvectl >/dev/null && systemctl is-active --quiet systemd-resolved 2>/dev/null; }
nscd_activo() { command -v nscd >/dev/null && systemctl is-active --quiet nscd 2>/dev/null; }
guardados() { resolvectl statistics 2>/dev/null | awk -F: '/Current Cache Size/ {gsub(/ /, "", $2); print $2; exit}'; }

case ${1:-} in
diagnosticar)
  if ! resolved && ! nscd_activo; then
    echo "Este equipo no guarda una caché de nombres, así que no hay nada que borrar."
    resuelve || echo "Ojo: los nombres de dominio no se resuelven; prueba «Sin internet o Wi-Fi»."
    exit 10
  fi
  n=$(guardados)
  echo "Puedo borrar la caché de nombres del equipo${n:+ (tiene $n nombres guardados)}."
  echo "Así el equipo vuelve a preguntar la dirección de cada página o sistema. No corta la red."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para borrar la caché de nombres."; exit 3; }
  resolved || nscd_activo || { echo "Este equipo no tiene una caché de nombres que borrar."; exit 3; }
  exit 0 ;;
aplicar)
  ok=0
  if resolved && resolvectl flush-caches 2>/dev/null; then ok=1; fi
  if nscd_activo && nscd -i hosts 2>/dev/null; then ok=1; fi
  [ "$ok" = 1 ] || { echo "No pude borrar la caché de nombres."; exit 1; }
  echo "Borré la caché de nombres. Cierra y vuelve a abrir el navegador para que también olvide las direcciones viejas."
  exit 0 ;;
verificar)
  resuelve || { echo "Borré la caché, pero los nombres de dominio no se resuelven: prueba «Sin internet o Wi-Fi»."; exit 1; }
  echo "La caché de nombres está limpia y el equipo resuelve bien los nombres de dominio."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
