#!/bin/bash
# Recuperar el sonido en macOS: el volumen y el silencio se leen y cambian en la sesión de la persona (osascript con su
# usuario, vía launchctl asuser), nunca como root. Si el sonido no responde, reinicia coreaudiod (el servicio de
# sonido de macOS, uno para todo el equipo: launchd lo vuelve a arrancar solo). Compatible con bash 3.2.
set -u
QUE="La salida de sonido"
usuario=${HP_USUARIO:-}
uid=$(id -u "$usuario" 2>/dev/null)
puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$uid" ]; } || { echo "No sé qué persona lo pide."; return 1; }
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para actuar en tu sesión."; return 1; }
  pgrep -x -U "$uid" Dock >/dev/null || { echo "No encontré tu sesión abierta en este Mac."; return 1; }
}
tope() {  # corre «$2...» con un tope de $1 segundos (macOS no trae timeout); sale con 124 si se cortó
  local s=$1; shift
  "$@" & local p=$!
  ( sleep "$s"; pkill -P "$p"; kill "$p" ) >/dev/null 2>&1 &
  local v=$!
  wait "$p"; local c=$?
  if kill -0 "$v" 2>/dev/null; then kill "$v" 2>/dev/null; else c=124; fi
  return "$c"
}
sesion() { tope 15 launchctl asuser "$uid" sudo -u "$usuario" osascript "$@" 2>/dev/null </dev/null; }
# «volumen silencio»: volumen en %, silencio 0/1; «nada» si la salida elegida no deja cambiar el volumen (o no hay
# ninguna); vacío si el sonido no responde
vol() {
  sesion -e 'set s to get volume settings' -e 'if output volume of s is missing value then return "nada"' \
    -e 'if output muted of s is true then return (output volume of s as text) & " 1"' -e 'return (output volume of s as text) & " 0"'
}
numero() { case ${1:-} in ''|*[!0-9]*) return 1 ;; esac; }
NADA="No hay una salida de sonido a la que le pueda cambiar el volumen desde el equipo (pasa con monitores HDMI y algunos adaptadores): súbelo en el propio parlante o monitor."

case ${1:-} in
diagnosticar)
  puedo || exit 3
  read -r v m <<< "$(vol)"
  if [ -z "${v:-}" ]; then
    sesion -e 'return 1' >/dev/null || { echo "No pude entrar a tu sesión para revisar el sonido."; exit 3; }
    echo "El servicio de sonido no responde."; exit 0
  fi
  [ "$v" = nada ] && { echo "$NADA"; exit 10; }
  numero "$v" || { echo "No pude leer el volumen de tu sesión."; exit 1; }
  [ "${m:-}" = 0 ] && [ "$v" -ge 20 ] && { echo "$QUE no está silenciada y su volumen es $v %."; exit 10; }
  [ "${m:-}" = 1 ] && echo "$QUE está silenciada."
  [ "$v" -lt 20 ] && echo "$QUE está al $v %."
  exit 0 ;;
comprobar)
  puedo || exit 3
  exit 0 ;;
aplicar)
  puedo || exit 1
  if [ -z "$(vol)" ]; then
    # solo si la sesión responde: si no, el problema no es el sonido y no se reinicia el de todo el equipo
    sesion -e 'return 1' >/dev/null || { echo "No pude entrar a tu sesión para arreglar el sonido."; exit 1; }
    killall coreaudiod 2>/dev/null
    sleep 3
  fi
  read -r v _ <<< "$(vol)"
  [ -n "${v:-}" ] || { echo "El servicio de sonido sigue sin responder: reinicia el equipo; si sigue igual, avisa a soporte."; exit 1; }
  [ "$v" = nada ] && { echo "$NADA"; exit 1; }
  numero "$v" || { echo "No pude leer el volumen de tu sesión."; exit 1; }
  sesion -e 'set volume output muted false' >/dev/null || { echo "No pude quitar el silencio en tu sesión."; exit 1; }
  [ "$v" -lt 20 ] && sesion -e 'set volume output volume 60' >/dev/null
  echo "Quité el silencio y dejé el volumen en un nivel audible."
  exit 0 ;;
verificar)
  puedo || exit 1
  read -r v m <<< "$(vol)"
  { numero "${v:-}" && [ "${m:-}" = 0 ] && [ "$v" -ge 20 ]; } || { echo "$QUE sigue silenciada o sin responder."; exit 1; }
  echo "$QUE funciona: volumen $v %, sin silencio. Si aún no oyes nada, revisa que estén conectados los parlantes o audífonos que usas."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
