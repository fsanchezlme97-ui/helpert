#!/bin/bash
# Actualizar las aplicaciones de la tienda del sistema: Flatpak (las del sistema como root y las que la persona instaló
# para sí, con su usuario) y Snap. Solo actualiza lo ya instalado (y lo que esas apps necesitan); no instala nada nuevo.
set -u
usuario=${HP_USUARIO:-}
casa=$([ -n "$usuario" ] && getent passwd "$usuario" | cut -d: -f6)

como() { if [ "$(id -u)" -eq 0 ]; then runuser -u "$usuario" -- "$@"; else "$@"; fi; }
hay_flatpak() { command -v flatpak >/dev/null; }
hay_snap() { command -v snap >/dev/null && snap version >/dev/null 2>&1; }
# Flatpak de la persona: solo si es una persona (no root) y tiene apps instaladas para sí
flatpak_persona() { hay_flatpak && [ -n "$usuario" ] && [ "$usuario" != root ] && [ -d "$casa" ] && como test -d "$casa/.local/share/flatpak/app"; }
pendientes() {  # cuántas actualizaciones hay, en total
  local n=0 x
  if hay_flatpak; then x=$(flatpak remote-ls --updates --system --columns=application 2>/dev/null | grep -c .); n=$((n + x)); fi
  if flatpak_persona; then x=$(como flatpak remote-ls --updates --user --columns=application 2>/dev/null | grep -c .); n=$((n + x)); fi
  if hay_snap; then x=$(snap refresh --list 2>/dev/null | tail -n +2 | grep -c .); n=$((n + x)); fi
  echo "$n"
}
tiendas() { { hay_flatpak && echo Flatpak; hay_snap && echo Snap; } | paste -sd' ' | sed 's/ / y /'; }

case ${1:-} in
diagnosticar)
  t=$(tiendas)
  [ -n "$t" ] || { echo "Este equipo no usa Flatpak ni Snap: no hay aplicaciones de la tienda que actualizar. Los demás programas se actualizan con las actualizaciones del sistema."; exit 3; }
  n=$(pendientes)
  [ "$n" -gt 0 ] || { echo "Las aplicaciones de $t están al día."; exit 10; }
  echo "Hay $n actualización(es) pendiente(s) de aplicaciones de $t. Las instalaría; puede tardar varios minutos."
  echo "Conviene cerrar los programas que se van a actualizar: Snap deja para después los que estén abiertos."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para actualizar las aplicaciones."; exit 3; }
  [ -n "$(tiendas)" ] || { echo "Este equipo no usa Flatpak ni Snap."; exit 3; }
  exit 0 ;;
aplicar)
  mal=()
  if hay_flatpak; then flatpak update --system -y --noninteractive >/dev/null 2>&1 || mal+=("Flatpak"); fi
  if flatpak_persona; then como flatpak update --user -y --noninteractive >/dev/null 2>&1 || mal+=("tus apps de Flatpak"); fi
  if hay_snap; then snap refresh >/dev/null 2>&1 || mal+=("Snap"); fi
  [ ${#mal[@]} -eq 0 ] || { echo "No pude terminar de actualizar: ${mal[*]}. Revisa que haya internet y vuelve a intentarlo; si sigue, avisa a soporte."; exit 1; }
  echo "Actualicé las aplicaciones de $(tiendas). Si alguna estaba abierta, ciérrala y ábrela de nuevo para usar la versión nueva."
  exit 0 ;;
verificar)
  n=$(pendientes)
  [ "$n" -eq 0 ] || { echo "Quedan $n actualización(es) sin aplicar, quizá de programas que están abiertos: ciérralos y vuelve a pedírmelo."; exit 1; }
  echo "Listo: las aplicaciones de $(tiendas) están al día."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
