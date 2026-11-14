#!/bin/bash
# Sin internet o Wi-Fi (NetworkManager). Uso: linux.sh diagnosticar|comprobar|aplicar|verificar
# Ojo: aplicar corta la red unos segundos. Solo sirve si el equipo aún llega al servidor de Helpert (red local).
set -u
conectividad() { nmcli networking connectivity check 2>/dev/null; }
dns_ok() { timeout 5 getent hosts example.com >/dev/null 2>&1; }

case ${1:-} in
diagnosticar)
  command -v nmcli >/dev/null || { echo "Este equipo no usa NetworkManager."; exit 1; }
  c=$(conectividad); ruta=$(ip route show default 2>/dev/null | head -1)
  if [ "$c" = full ] && dns_ok; then echo "La conexión a internet funciona y los nombres de dominio se resuelven."; exit 10; fi
  echo "Conectividad: ${c:-desconocida}. Puerta de enlace: ${ruta:-ninguna}."
  dns_ok || echo "Los nombres de dominio no se resuelven."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para reiniciar la red."; exit 3; }
  exit 0 ;;
aplicar)
  resolvectl flush-caches 2>/dev/null
  nmcli networking off && sleep 2 && nmcli networking on || { echo "No se pudo reiniciar la red."; exit 1; }
  for _ in $(seq 30); do [ "$(conectividad)" = full ] && break; sleep 1; done
  echo "Limpié la caché DNS y reinicié la red."
  exit 0 ;;
verificar)
  [ "$(conectividad)" = full ] && dns_ok || { echo "Sigue sin haber conexión a internet."; exit 1; }
  echo "La conexión a internet volvió."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
