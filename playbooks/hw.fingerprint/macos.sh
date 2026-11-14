#!/bin/bash
# Revisar Touch ID en macOS: si el servicio de biometría (biometrickitd) responde y ve huellas registradas (bioutil),
# y reiniciarlo (launchd lo vuelve a arrancar solo). No registra huellas: solo dice si la persona no tiene ninguna.
# Compatible con bash 3.2.
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
# 0 si el servicio de Touch ID contesta: cuenta las huellas de todo el equipo (en un Mac sin Touch ID falla)
responde() {
  command -v bioutil >/dev/null || return 1
  r=$(tope 15 bioutil -c -s 2>/dev/null) && echo "$r" | grep -qi template
}
# huellas registradas por la persona (el número de su línea que no es su UID); nada si no se sabe
huellas() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$uid" ]; } || return 0
  tope 15 bioutil -c -s 2>/dev/null | grep -E "(^|[^0-9])$uid([^0-9]|$)" | grep -oE '[0-9]+' | grep -vx "$uid" | head -1
}

case ${1:-} in
diagnosticar)
  responde || { echo "No pude confirmar que este Mac tenga Touch ID funcionando: o no tiene o macOS no lo detecta. Si usas un teclado con Touch ID, conéctalo con su cable, espera 5 segundos y vuelve a probar."; exit 10; }
  echo "El equipo detecta Touch ID."
  [ "$(huellas)" = 0 ] && echo "No tienes ninguna huella registrada: regístrala en Ajustes del Sistema > Touch ID y contraseña (Helpert no registra huellas)."
  echo "Voy a reiniciar el servicio de huellas."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para reiniciar el servicio de huellas."; exit 3; }
  responde || { echo "El equipo no detecta Touch ID."; exit 3; }
  exit 0 ;;
aplicar)
  # si no estaba corriendo, launchd lo arranca cuando haga falta
  pkill -x biometrickitd 2>/dev/null || ! pgrep -x biometrickitd >/dev/null || { echo "No pude reiniciar el servicio de huellas."; exit 1; }
  sleep 2
  echo "Reinicié el servicio de huellas."
  exit 0 ;;
verificar)
  for _ in 1 2 3; do responde && break; sleep 2; done
  responde || { echo "El servicio de huellas no responde: reinicia el equipo; si sigue igual, avisa a soporte."; exit 1; }
  echo "El lector de huellas funciona. Bloquea la pantalla (Control+Cmd+Q) y prueba entrar con tu huella. Después de reiniciar el Mac, la primera vez siempre pide la contraseña."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
