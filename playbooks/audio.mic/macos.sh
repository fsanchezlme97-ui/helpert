#!/bin/bash
# Recuperar el micrófono en macOS: el volumen de entrada se lee y cambia en la sesión de la persona (osascript con su
# usuario, vía launchctl asuser), nunca como root. macOS no tiene un «silencio» del micrófono aparte: volumen 0 es el
# silencio. Si el sonido no responde, reinicia coreaudiod (el servicio de sonido de macOS, uno para todo el equipo:
# launchd lo vuelve a arrancar solo). Compatible con bash 3.2.
set -u
QUE="El micrófono"
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
# «volumen silencio»: volumen en %, silencio 0/1 (1 si está en 0); «nada» si el micrófono elegido no deja cambiar el
# volumen (o no hay ninguno); vacío si el sonido no responde
vol() {
  sesion -e 'set v to input volume of (get volume settings)' -e 'if v is missing value then return "nada"' \
    -e 'if v is 0 then return "0 1"' -e 'return (v as text) & " 0"'
}
numero() { case ${1:-} in ''|*[!0-9]*) return 1 ;; esac; }
NADA="No encontré un micrófono al que le pueda cambiar el volumen desde el equipo: o no hay ninguno conectado o el tuyo no lo permite (pasa con algunos micrófonos USB). Revisa que esté conectado y, si tiene botón de silencio, que esté activo."

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
  [ "${m:-}" = 0 ] && [ "$v" -ge 20 ] && { echo "$QUE no está silenciado y su volumen es $v %."; exit 10; }
  if [ "${m:-}" = 1 ]; then echo "$QUE está silenciado (volumen en 0 %)."; else echo "$QUE está al $v %."; fi
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
  if [ "$v" -lt 20 ]; then sesion -e 'set volume input volume 60' >/dev/null || { echo "No pude subir el volumen del micrófono en tu sesión."; exit 1; }; fi
  echo "Quité el silencio y dejé el volumen en un nivel audible."
  exit 0 ;;
verificar)
  puedo || exit 1
  read -r v m <<< "$(vol)"
  { numero "${v:-}" && [ "${m:-}" = 0 ] && [ "$v" -ge 20 ]; } || { echo "$QUE sigue silenciado o sin responder."; exit 1; }
  echo "$QUE funciona: volumen $v %, sin silencio. Si aún no te escuchan, revisa en la llamada que esté elegido este micrófono y que el programa tenga permiso en Ajustes del Sistema > Privacidad y seguridad > Micrófono."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
