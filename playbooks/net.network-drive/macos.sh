#!/bin/bash
# Reconectar unidades de red (macOS): las del equipo que monta el automontador (autofs): las de /etc/fstab de tipo nfs,
# smbfs, afpfs, webdav o url sin «net» ni «noauto» (mapa -static) y las de los mapas directos («/-  mapa») de
# /etc/auto_master. Las vuelve a leer (automount -vc) y entra en cada carpeta, como la persona si se sabe quién es
# (las de SMB usan sus credenciales), para que se monte. Las que la persona conecta desde el Finder no están aquí.
# shortcut: los mapas indirectos (/carpeta mapa) y los de «net» (/Network/Servers) no se revisan; añadirlos si aparecen.
set -u
usuario=${HP_USUARIO:-}
uid=$(id -u "$usuario" 2>/dev/null)
tope() {  # corre «$2...» con un tope de $1 segundos (macOS no trae timeout); sale con 124 si se cortó
  local s=$1; shift
  "$@" & local p=$!
  ( sleep "$s"; pkill -P "$p"; kill "$p" ) >/dev/null 2>&1 &
  local v=$!
  wait "$p"; local c=$?
  if kill -0 "$v" 2>/dev/null; then kill "$v" 2>/dev/null; else c=124; fi
  return "$c"
}
de_red() {
  awk '$1 !~ /^#/ && ($3 == "nfs" || $3 == "smbfs" || $3 == "afpfs" || $3 == "webdav" || $3 == "url") && $4 !~ /(^|,)(net|noauto)(,|$)/ && $2 ~ /^\// {print $2}' /etc/fstab 2>/dev/null
  awk '$1 == "/-" && $2 !~ /^[-+]/ {print $2}' /etc/auto_master 2>/dev/null | while read -r m; do
    case $m in /*) ;; *) m=/etc/$m ;; esac
    awk '$1 ~ /^\// {print $1}' "$m" 2>/dev/null
  done
}
montada() { mount 2>/dev/null | grep -F " on $1 (" | grep -vq '(autofs'; }
caidas() { de_red | while read -r p; do montada "$p" || echo "$p"; done; }
lista() { paste -sd, - | sed 's/,/, /g'; }
entrar() {  # el automontador monta la carpeta al entrar en ella
  if [ -n "$uid" ] && [ "$usuario" != root ]; then tope 20 sudo -n -u "$usuario" ls -- "$1" >/dev/null 2>&1
  else tope 20 ls -- "$1" >/dev/null 2>&1; fi
}

case ${1:-} in
diagnosticar)
  if [ -z "$(de_red)" ]; then
    echo "Este Mac no tiene unidades de red configuradas para todo el equipo."
    echo "Si la carpeta la conectabas desde el Finder (Ir > Conectarse al servidor), vuelve a conectarla ahí; si no sabes la dirección, pídela a soporte."
    exit 10
  fi
  c=$(caidas)
  [ -n "$c" ] || { echo "Todas las unidades de red están conectadas: $(de_red | lista)."; exit 10; }
  echo "Estas unidades de red no están conectadas: $(echo "$c" | lista)."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para montar unidades de red."; exit 3; }
  command -v automount >/dev/null || { echo "Este Mac no tiene el automontador de unidades de red."; exit 3; }
  exit 0 ;;
aplicar)
  automount -vc >/dev/null 2>&1 || { echo "No pude volver a leer las unidades de red del equipo."; exit 1; }
  caidas | while read -r p; do [ "$SECONDS" -lt 60 ] && entrar "$p"; done  # cada una hasta 20 s, sin pasarse del límite
  echo "Volví a conectar las unidades de red."
  exit 0 ;;
verificar)
  [ -n "$(de_red)" ] || { echo "No encontré las unidades de red del equipo para comprobarlas."; exit 1; }
  c=$(caidas)
  [ -z "$c" ] || { echo "No se pudieron conectar: $(echo "$c" | lista). Puede que el servidor no responda."; exit 1; }
  echo "Todas las unidades de red están conectadas."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
