#!/bin/bash
# Desbloquear un sitio en /etc/hosts: quita el sitio (y su www.) de las líneas que lo nombran, con copia para deshacer.
# De una línea con varios nombres solo se quita ese nombre; nunca se tocan localhost ni el nombre del propio equipo.
# El archivo se reescribe en su sitio (cat >) para conservar dueño, permisos y etiqueta de SELinux.
set -u
HOSTS=/etc/hosts
sitio=$(printf '%s' "${HP_SITIO:-}" | tr 'A-Z' 'a-z' | sed 's/^\.*//; s/\.*$//; s/^www\.//')

valido() {
  case $sitio in
  ''|-*|*..*) echo "Necesito la dirección del sitio, por ejemplo intranet.empresa.pe."; return 1 ;;
  localhost|localhost.*|localdomain|ip6-*|broadcasthost) echo "«$sitio» es el propio equipo: esas líneas no se tocan."; return 1 ;;
  esac
  [ "$sitio" = "$(uname -n | tr 'A-Z' 'a-z')" ] && { echo "«$sitio» es el nombre de este equipo: esas líneas no se tocan."; return 1; }
  return 0
}
# ver: las líneas que nombran el sitio; quitar: el archivo sin el sitio (una línea sin nombres se borra)
filtrar() {
  awk -v s="$sitio" -v modo="$1" '
    { d = $0; c = ""; i = index(d, "#"); if (i) { c = substr(d, i); d = substr(d, 1, i - 1) }
      n = split(d, f); quito = 0; resto = f[1]
      for (k = 2; k <= n; k++) { h = tolower(f[k]); sub(/\.$/, "", h); if (h == s || h == "www." s) quito = 1; else resto = resto " " f[k] }
      if (modo == "ver") { if (quito) print; next }
      if (!quito) { print; next }
      if (resto != f[1]) print resto (c != "" ? " " c : "")
    }' "$HOSTS"
}
cuantas() { filtrar ver 2>/dev/null | grep -c .; }

case ${1:-} in
diagnosticar)
  valido || exit 1
  [ -r "$HOSTS" ] || { echo "No puedo leer el archivo hosts del equipo."; exit 1; }
  n=$(cuantas)
  [ "$n" -gt 0 ] || { echo "El archivo hosts no tiene nada de $sitio: el problema está en otra parte (prueba «Probar si un sitio o sistema responde»)."; exit 10; }
  echo "El archivo hosts del equipo desvía $sitio a otra dirección ($n línea(s)):"
  filtrar ver | head -3 | cut -c1-100 | sed 's/^/- /'
  echo "Puedo quitar $sitio de esas líneas y guardar una copia para deshacerlo."
  echo "Si soporte puso esa línea a propósito (por ejemplo, para un servidor interno), avísales antes."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para cambiar el archivo hosts."; exit 3; }
  valido || exit 3
  [ -w "$HOSTS" ] || { echo "No puedo escribir en el archivo hosts del equipo."; exit 3; }
  [ "$(cuantas)" -gt 0 ] || { echo "El archivo hosts ya no tiene nada de $sitio."; exit 3; }
  exit 0 ;;
aplicar)
  valido || exit 1
  n=$(cuantas)
  [ "$n" -gt 0 ] || { echo "El archivo hosts ya no tenía nada de $sitio."; exit 0; }
  t=$(mktemp) || { echo "No pude preparar el cambio; no toqué nada."; exit 1; }
  trap 'rm -f "$t"' EXIT
  rm -f "$HOSTS".helpert-*  # deshacer devuelve solo el último cambio, nunca una copia vieja
  copia="$HOSTS.helpert-$(date +%Y%m%d-%H%M%S)"
  cp -p "$HOSTS" "$copia" 2>/dev/null || { echo "No pude guardar la copia del archivo hosts; no toqué nada."; exit 1; }
  filtrar quitar > "$t" || { echo "No pude preparar el cambio; no toqué nada."; exit 1; }
  if ! { cat "$t" > "$HOSTS"; } 2>/dev/null; then
    { cat "$copia" > "$HOSTS"; } 2>/dev/null
    echo "No pude cambiar el archivo hosts (puede que esté protegido): lo revisa soporte."; exit 1
  fi
  echo "Quité $sitio del archivo hosts ($n línea(s)) y guardé una copia para deshacerlo."
  echo "Cierra y vuelve a abrir el navegador para que tome el cambio."
  exit 0 ;;
verificar)
  [ "$(cuantas)" -eq 0 ] || { echo "El archivo hosts todavía desvía $sitio."; exit 1; }
  echo "El archivo hosts ya no desvía $sitio."
  exit 0 ;;
deshacer)
  copia=$(ls -1 "$HOSTS".helpert-* 2>/dev/null | tail -1)
  [ -n "$copia" ] || { echo "No encontré la copia del archivo hosts para deshacer el cambio."; exit 1; }
  { cat "$copia" > "$HOSTS"; } 2>/dev/null || { echo "No pude devolver el archivo hosts a como estaba."; exit 1; }
  rm -f "$copia"
  echo "Devolví el archivo hosts a como estaba antes del cambio."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
