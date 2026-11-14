#!/bin/bash
# Reiniciar el escritorio de la persona en macOS: el Dock, la barra de menús (SystemUIServer) y el Finder, solo los
# suyos (por su UID). macOS los vuelve a abrir solo; los demás programas no se tocan. Compatible con bash 3.2.
set -u
PARTES="Dock SystemUIServer Finder"
usuario=${HP_USUARIO:-}
uid=$(id -u "$usuario" 2>/dev/null)
puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$uid" ]; } || { echo "No sé qué persona lo pide."; return 1; }
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para actuar en tu sesión."; return 1; }
  pgrep -x -U "$uid" Dock >/dev/null || { echo "No encontré tu sesión abierta en este Mac."; return 1; }
}
faltan() { for p in $PARTES; do pgrep -x -U "$uid" "$p" >/dev/null || echo "$p"; done; }

case ${1:-} in
diagnosticar)
  puedo || exit 3
  echo "Puedo reiniciar el Dock, la barra de menús y el Finder de tu sesión; tus programas abiertos no se cierran."
  echo "Las ventanas del Finder se cierran y vuelven a abrirse solas."
  exit 0 ;;
comprobar)
  puedo || exit 3
  exit 0 ;;
aplicar)
  for p in $PARTES; do pkill -x -U "$uid" "$p" 2>/dev/null; done
  for _ in 1 2 3 4 5 6 7 8 9 10; do sleep 1; [ -z "$(faltan)" ] && break; done
  # si el Finder no volvió solo, se abre en la sesión de la persona, con su usuario
  pgrep -x -U "$uid" Finder >/dev/null || launchctl asuser "$uid" sudo -u "$usuario" /usr/bin/open -a Finder 2>/dev/null
  echo "Reinicié el Dock, la barra de menús y el Finder. Tus programas siguen abiertos."
  exit 0 ;;
verificar)
  for _ in 1 2 3 4 5; do [ -z "$(faltan)" ] && break; sleep 1; done
  f=$(faltan | paste -sd, - | sed 's/,/, /g')
  [ -z "$f" ] || { echo "No volvió a arrancar: $f. Cierra sesión y vuelve a entrar; si sigue igual, avisa a soporte."; exit 1; }
  echo "El Dock, la barra de menús y el Finder volvieron a funcionar."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
