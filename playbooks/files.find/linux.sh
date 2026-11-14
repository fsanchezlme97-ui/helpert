#!/bin/bash
# Buscar un archivo por nombre en la carpeta personal de la persona. Solo lectura: el diagnóstico busca y termina con 10,
# así el servidor nunca ofrece «aplicar». La búsqueda corre con los permisos de la persona (runuser), no como root.
# HP_NOMBRE ya viene validado por el agente: solo letras, números, punto, guion y guion bajo (sin comodines).
set -u
usuario=${HP_USUARIO:-}
nombre=${HP_NOMBRE:-}

case ${1:-} in
diagnosticar)
  { [ -n "$usuario" ] && [ "$usuario" != root ]; } || { echo "No sé qué persona pide la búsqueda."; exit 3; }
  casa=$(getent passwd "$usuario" | cut -d: -f6)
  [ -d "$casa" ] || { echo "No encontré la carpeta personal de $usuario."; exit 3; }
  if [ "$(id -u)" -eq 0 ]; then como=(runuser -u "$usuario" --)
  elif [ "$(id -un)" = "$usuario" ]; then como=()
  else echo "No puedo buscar en la carpeta de otra persona."; exit 3; fi
  # más recientes primero; sin carpetas ocultas salvo la papelera
  buscar() { "${como[@]}" find "$1" -xdev \( -name '.*' -prune \) -o -iname "*$nombre*" -printf '%T@\t%TY-%Tm-%Td %TH:%TM\t%p\n' 2>/dev/null \
             | sort -rn | head -15 | cut -f2- | sed "s|\t$casa|  ~|"; }
  hallados=$(buscar "$casa")
  papelera=$(buscar "$casa/.local/share/Trash/files" | sed 's|~/.local/share/Trash/files/|papelera: |')
  if [ -z "$hallados$papelera" ]; then
    echo "No encontré archivos con «$nombre» en el nombre dentro de tu carpeta personal ni en la papelera."
    echo "Prueba con otra palabra del nombre, o puede estar en una memoria USB o una carpeta compartida."
    exit 10
  fi
  [ -n "$hallados" ] && { echo "Encontré estos archivos con «$nombre» en el nombre (los más recientes primero):"; echo "$hallados"; }
  [ -n "$papelera" ] && { echo "En la papelera (puedes restaurarlos desde ahí):"; echo "$papelera"; }
  exit 10 ;;
*) echo "Este procedimiento solo busca; no cambia nada."; exit 2 ;;
esac
