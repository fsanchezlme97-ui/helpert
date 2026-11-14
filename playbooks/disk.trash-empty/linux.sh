#!/bin/bash
# Vaciar la papelera de la persona (estándar freedesktop: ~/.local/share/Trash/{files,info,expunged}). Definitivo.
# Todo con los permisos de la persona (runuser): find -delete no sigue enlaces, así que nada fuera de su papelera.
set -u
usuario=${HP_USUARIO:-}
casa=$(getent passwd "$usuario" | cut -d: -f6)
T="$casa/.local/share/Trash"

como() { if [ "$(id -u)" -eq 0 ]; then runuser -u "$usuario" -- "$@"; else "$@"; fi; }
puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$casa" ] && [ "$casa" != / ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide o no encontré su carpeta personal."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo tocar la papelera de otra persona."; return 1; }
}
elementos() { como find "$T/files" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l; }
mb() { como du -sm "$T/files" 2>/dev/null | cut -f1; }

case ${1:-} in
diagnosticar)
  puedo || exit 3
  n=$(elementos)
  [ "$n" -gt 0 ] || { echo "Tu papelera ya está vacía."; exit 10; }
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
  for d in files info expunged; do [ -d "$T/$d" ] && como find "$T/$d" -mindepth 1 -delete 2>/dev/null; done
  n=$(elementos)
  [ "$n" -eq 0 ] || { echo "No pude borrar $n elemento(s) de la papelera (puede que no tengas permiso sobre ellos)."; exit 1; }
  echo "Vacié la papelera: liberé unos ${m:-0} MB."
  exit 0 ;;
verificar)
  puedo || exit 1
  n=$(elementos)
  [ "$n" -eq 0 ] || { echo "En la papelera quedan $n elemento(s)."; exit 1; }
  echo "La papelera está vacía."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
