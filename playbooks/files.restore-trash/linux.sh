#!/bin/bash
# Recuperar de la papelera (estándar freedesktop: ~/.local/share/Trash/{files,info}). Todo con los permisos de la persona.
# HP_NOMBRE ya viene validado: letras, números, punto, guion y guion bajo (sin comodines).
set -u
usuario=${HP_USUARIO:-}
nombre=${HP_NOMBRE:-}
casa=$(getent passwd "$usuario" | cut -d: -f6)
T="$casa/.local/share/Trash"

como() { if [ "$(id -u)" -eq 0 ]; then runuser -u "$usuario" -- "$@"; else "$@"; fi; }
puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo tocar la papelera de otra persona."; return 1; }
}
# «archivo_en_papelera<TAB>ruta_original», los más recientes primero (máximo 5)
hallados() {
  como find "$T/files" -mindepth 1 -maxdepth 1 -iname "*$nombre*" -printf '%T@\t%f\n' 2>/dev/null | sort -rn | head -5 | cut -f2 |
  while IFS= read -r f; do
    info="$T/info/$f.trashinfo"
    [ -f "$info" ] || continue
    ruta=$(como sed -n 's/^Path=//p' "$info" | head -1)  # con los permisos de la persona: un enlace no lee archivos ajenos
    ruta=$(printf '%b' "${ruta//%/\\x}")   # la ruta viene codificada como URL (%20 = espacio)
    [[ $ruta == /* ]] || ruta="$casa/$ruta"
    printf '%s\t%s\n' "$f" "$ruta"
  done
}

case ${1:-} in
diagnosticar)
  puedo || exit 3
  h=$(hallados)
  [ -n "$h" ] || { echo "No encontré nada con «$nombre» en el nombre en tu papelera. Si la vaciaste, soporte puede revisar las copias de seguridad."; exit 10; }
  echo "Encontré en la papelera:"
  echo "$h" | while IFS=$'\t' read -r f ruta; do echo "- $f (estaba en ${ruta%/*})"; done
  [ "$(echo "$h" | wc -l)" -gt 1 ] && echo "Si sigo, devuelvo todos a su carpeta."
  exit 0 ;;
comprobar)
  puedo || exit 3
  [ -n "$(hallados)" ] || { echo "Ya no está en la papelera."; exit 3; }
  exit 0 ;;
aplicar)
  n=0
  while IFS=$'\t' read -r f ruta; do
    destino=$ruta base=${ruta##*/} dir=${ruta%/*}
    if [ -e "$destino" ]; then  # ya hay otro con ese nombre: se deja al lado, nunca se sobrescribe
      if [[ $base == ?*.* ]]; then destino="$dir/${base%.*} (recuperado).${base##*.}"; else destino="$ruta (recuperado)"; fi
      [ -e "$destino" ] && destino="$dir/$(date +%H%M%S) $base"
    fi
    como mkdir -p "${destino%/*}" && como mv -n -- "$T/files/$f" "$destino" && como rm -f -- "$T/info/$f.trashinfo" && n=$((n + 1)) &&
      echo "- Recuperado en ${destino/#"$casa"/\~}"
  done <<< "$(hallados)"
  [ "$n" -gt 0 ] || { echo "No pude recuperar el archivo."; exit 1; }
  exit 0 ;;
verificar)
  echo "Listo: el archivo volvió a su carpeta."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
