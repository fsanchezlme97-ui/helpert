#!/bin/bash
# Vaciar la papelera de la persona (macOS: ~/.Trash). Definitivo. Todo con los permisos de la persona (sudo -u):
# find -delete no sigue enlaces. macOS protege la papelera: sin «Acceso total al disco» para Helpert no se puede leer.
set -u
usuario=${HP_USUARIO:-}
casa=$(dscl . -read "/Users/$usuario" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
T="$casa/.Trash"

como() { if [ "$(id -u)" -eq 0 ]; then sudo -u "$usuario" "$@"; else "$@"; fi; }
puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$casa" ] && [ "$casa" != / ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide o no encontré su carpeta personal."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo tocar la papelera de otra persona."; return 1; }
  [ -d "$T" ] || return 0
  como ls "$T" >/dev/null 2>&1 || { echo "macOS no me deja abrir tu papelera: pide a soporte que le dé a Helpert «Acceso total al disco», o vacíala tú desde el Dock (clic derecho en la Papelera)."; return 1; }
}
elementos() { como find "$T" -mindepth 1 -maxdepth 1 ! -name .DS_Store 2>/dev/null | wc -l | tr -d ' '; }
mb() { como du -sk "$T" 2>/dev/null | awk '{ printf "%d", $1 / 1024 }'; }

case ${1:-} in
diagnosticar)
  puedo || exit 3
  n=$(elementos)
  [ "${n:-0}" -gt 0 ] || { echo "Tu papelera ya está vacía."; exit 10; }
  echo "Tu papelera tiene $n elemento(s) y ocupa $(mb) MB."
  echo "Si sigo, la vacío definitivamente: lo que hay en ella ya no se podrá recuperar."
  exit 0 ;;
comprobar)
  puedo || exit 3
  [ "$(elementos)" -gt 0 ] || { echo "La papelera ya está vacía."; exit 3; }
  exit 0 ;;
aplicar)
  puedo || exit 1
  m=$(mb)
  como find "$T" -mindepth 1 -delete 2>/dev/null
  n=$(elementos)
  [ "${n:-0}" -eq 0 ] || { echo "No pude borrar $n elemento(s) de la papelera (puede que no tengas permiso sobre ellos)."; exit 1; }
  echo "Vacié la papelera: liberé unos ${m:-0} MB."
  exit 0 ;;
verificar)
  puedo || exit 1
  n=$(elementos)
  [ "${n:-0}" -eq 0 ] || { echo "En la papelera quedan $n elemento(s)."; exit 1; }
  echo "La papelera está vacía."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
