#!/bin/bash
# Ver los últimos archivos que la persona modificó en su carpeta personal (30 días, sin carpetas ocultas de programas).
# Solo lectura: el diagnóstico informa y termina con 10. Con los permisos de la persona (runuser), no como root.
set -u
usuario=${HP_USUARIO:-}
casa=$(getent passwd "$usuario" | cut -d: -f6)

como() { if [ "$(id -u)" -eq 0 ]; then runuser -u "$usuario" -- "$@"; else "$@"; fi; }
puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$casa" ] && [ "$casa" != / ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide o no encontré su carpeta personal."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo revisar la carpeta de otra persona."; return 1; }
}

case ${1:-} in
diagnosticar)
  puedo || exit 3
  l=$( { como timeout 90 find "$casa" -xdev \( -name '.*' -prune \) -o -type f -mtime -30 -printf '%T@\t%TY-%Tm-%Td %TH:%TM\t%P\n' 2>/dev/null; echo "X	$?"; } |
       sort -rn | awk -F'\t' '$1 == "X" { if ($2 == 124) c = 1; next } n < 10 { print $2 "  ~/" $3; n++ } END { if (c) print "X" }')
  cortada=0; [ "${l##*$'\n'}" = X ] && { cortada=1; l=${l%X}; l=${l%$'\n'}; }
  if [ -z "$l" ]; then
    echo "No encontré archivos tuyos modificados en los últimos 30 días dentro de tu carpeta personal."
    echo "Puede estar en una memoria USB, una carpeta de red o en la nube; si recuerdas parte del nombre, usa «Buscar un archivo»."
  else
    echo "Estos son los últimos archivos que modificaste (los más recientes primero):"
    echo "$l"
    echo "Si recuerdas parte del nombre, «Buscar un archivo» también busca en la papelera."
  fi
  [ "$cortada" = 1 ] && echo "Tu carpeta es muy grande y no alcancé a revisarla entera: puede haber otros más recientes."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
