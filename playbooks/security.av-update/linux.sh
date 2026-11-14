#!/bin/bash
# Actualizar las firmas de ClamAV con freshclam. No instala ningún antivirus.
# Si el servicio de actualización automática está corriendo, se detiene mientras tanto (si no, freshclam choca con él).
set -u
BASE=/var/lib/clamav
# días desde que cambiaron las firmas diarias; nada si no hay firmas
edad() {
  local m
  m=$(stat -c %Y "$BASE"/daily.cvd "$BASE"/daily.cld 2>/dev/null | sort -n | tail -1)
  [ -n "$m" ] && echo $(( ($(date +%s) - m) / 86400 ))
}
servicio() { for s in clamav-freshclam freshclam; do systemctl is-active -q "$s" 2>/dev/null && { echo "$s"; return; }; done; }

case ${1:-} in
diagnosticar)
  command -v freshclam >/dev/null || { echo "Este equipo no tiene ClamAV, el antivirus que Helpert sabe actualizar en Linux. No instalo uno nuevo: si hace falta, lo decide soporte."; exit 3; }
  d=$(edad)
  [ -z "$d" ] && { echo "ClamAV no tiene firmas descargadas. Puedo descargarlas ahora."; exit 0; }
  [ "$d" -lt 1 ] && { echo "Las firmas de ClamAV están al día (se actualizaron hace menos de un día)."; exit 10; }
  echo "Las firmas de ClamAV tienen $d día(s). Puedo descargar las nuevas ahora."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para actualizar el antivirus."; exit 3; }
  command -v freshclam >/dev/null || { echo "Este equipo no tiene ClamAV."; exit 3; }
  exit 0 ;;
aplicar)
  s=$(servicio)
  [ -n "$s" ] && systemctl stop "$s" 2>/dev/null
  timeout 540 freshclam --quiet >/dev/null 2>&1; r=$?
  [ -n "$s" ] && systemctl start "$s" 2>/dev/null
  # freshclam: 0 = descargó firmas nuevas, 1 = ya estaban al día
  case $r in
  0) echo "Descargué las firmas nuevas de ClamAV." ;;
  1) echo "El servidor de ClamAV no tenía firmas más nuevas que las del equipo." ;;
  124) echo "La descarga de firmas tardó demasiado; puede que la red esté lenta o la bloquee."; exit 1 ;;
  *) echo "No se pudieron descargar las firmas de ClamAV; puede que no haya internet o que la red bloquee el servidor de ClamAV."; exit 1 ;;
  esac
  exit 0 ;;
verificar)
  d=$(edad)
  [ -n "$d" ] && [ "$d" -le 1 ] || { echo "Las firmas de ClamAV siguen desactualizadas."; exit 1; }
  echo "Las firmas de ClamAV están al día."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
