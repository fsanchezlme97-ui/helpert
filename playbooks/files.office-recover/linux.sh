#!/bin/bash
# Recuperar documentos sin guardar: copia las copias de recuperación automática de LibreOffice (instalado normal,
# Flatpak o Snap) a «Recuperados» dentro de Documentos. No borra ni mueve nada: solo copia, nunca sobrescribe.
# Todo con los permisos de la persona (runuser). En Linux no hay Word, Excel ni PowerPoint.
set -u
usuario=${HP_USUARIO:-}
casa=$(getent passwd "$usuario" | cut -d: -f6)
FUENTES=(".config/libreoffice/4/user/backup" ".var/app/org.libreoffice.LibreOffice/config/libreoffice/4/user/backup"
         "snap/libreoffice/current/.config/libreoffice/4/user/backup")

como() { if [ "$(id -u)" -eq 0 ]; then runuser -u "$usuario" -- "$@"; else "$@"; fi; }
puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$casa" ] && [ "$casa" != / ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide o no encontré su carpeta personal."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo revisar los archivos de otra persona."; return 1; }
}
copias() {  # «fecha<TAB>ruta», las más recientes primero
  for f in "${FUENTES[@]}"; do como find "$casa/$f" -maxdepth 1 -type f -printf '%T@\t%TY-%Tm-%Td %TH:%TM\t%p\n' 2>/dev/null; done | sort -rn | cut -f2-
}
destino() {  # «Recuperados» dentro de su carpeta de documentos (la de user-dirs.dirs, si está dentro de su carpeta)
  d=$(como sed -n 's/^XDG_DOCUMENTS_DIR="\(.*\)"$/\1/p' "$casa/.config/user-dirs.dirs" 2>/dev/null | head -1)
  d=${d/#\$HOME/$casa}
  case $d in "$casa"/?*) ;; *) d="" ;; esac
  if [ -z "$d" ]; then for x in Documentos Documents; do [ -d "$casa/$x" ] && { d="$casa/$x"; break; }; done; fi
  echo "${d:-$casa/Documentos}/Recuperados"
}
copiada() { como cmp -s -- "$1" "$2/${1##*/}"; }

case ${1:-} in
diagnosticar)
  puedo || exit 3
  c=$(copias)
  if [ -z "$c" ]; then
    echo "No encontré copias de recuperación de LibreOffice en tu carpeta."
    echo "Abre LibreOffice: si tenía algo que recuperar, te lo ofrece al empezar. Si guardaste el documento alguna vez, prueba «Buscar un archivo» o «Recuperar un archivo de la papelera»."
    exit 10
  fi
  echo "Encontré $(grep -c . <<< "$c") copia(s) de recuperación:"
  head -5 <<< "$c" | while IFS=$'\t' read -r fecha ruta; do echo "- ${ruta##*/} ($fecha)"; done
  d=$(destino)
  echo "Si sigo, las copio a ${d/#"$casa"/\~} (no se borra nada)."
  exit 0 ;;
comprobar)
  puedo || exit 3
  [ -n "$(copias)" ] || { echo "Ya no hay copias de recuperación."; exit 3; }
  exit 0 ;;
aplicar)
  puedo || exit 1
  d=$(destino)
  como mkdir -p -- "$d" || { echo "No pude crear la carpeta $d."; exit 1; }
  n=0 f=0
  while IFS=$'\t' read -r _ ruta; do
    [ -n "$ruta" ] || continue
    copiada "$ruta" "$d" && continue
    b=${ruta##*/}; [ -e "$d/$b" ] && b="$(date +%Y%m%d-%H%M%S)-$b"
    if como cp -p -- "$ruta" "$d/$b"; then n=$((n + 1)); else f=$((f + 1)); fi
  done <<< "$(copias)"
  [ "$f" -eq 0 ] || { echo "No pude copiar $f archivo(s) a $d."; exit 1; }
  echo "Copié $n documento(s) a ${d/#"$casa"/\~}. Ábrelos desde ahí con LibreOffice y guárdalos con el nombre que quieras."
  exit 0 ;;
verificar)
  puedo || exit 1
  d=$(destino) falta=0
  while IFS=$'\t' read -r _ ruta; do
    [ -n "$ruta" ] || continue
    copiada "$ruta" "$d" || como find "$d" -maxdepth 1 -type f -name "*-${ruta##*/}" 2>/dev/null | grep -q . || falta=$((falta + 1))
  done <<< "$(copias)"
  [ "$falta" -eq 0 ] || { echo "Faltan $falta copia(s) en ${d/#"$casa"/\~}."; exit 1; }
  echo "Las copias de recuperación están en ${d/#"$casa"/\~}."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
