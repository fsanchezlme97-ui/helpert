#!/bin/bash
# Recuperar documentos sin guardar (macOS): copia las copias de recuperación automática de Word, Excel y PowerPoint
# (en sus contenedores, carpetas «AutoRecovery») y de LibreOffice a ~/Documents/Recuperados. No borra ni mueve nada:
# solo copia, nunca sobrescribe. Todo con los permisos de la persona (sudo -u). macOS puede negar el acceso a los
# contenedores de otras apps y a Documentos (TCC): si pasa, se dice.
set -u
usuario=${HP_USUARIO:-}
casa=$(dscl . -read "/Users/$usuario" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')

como() { if [ "$(id -u)" -eq 0 ]; then sudo -u "$usuario" "$@"; else "$@"; fi; }
puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$casa" ] && [ "$casa" != / ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide o no encontré su carpeta personal."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo revisar los archivos de otra persona."; return 1; }
}
copias() {  # rutas, las más recientes primero; los errores de permiso quedan en $e
  { for a in Word Excel Powerpoint; do
      d="$casa/Library/Containers/com.microsoft.$a/Data/Library"
      [ -d "$d" ] && como find "$d" -type f -ipath '*autorecovery*' ! -name '.*' -exec stat -f '%m'$'\t''%N' {} +
    done
    d="$casa/Library/Application Support/LibreOffice/4/user/backup"
    [ -d "$d" ] && como find "$d" -maxdepth 1 -type f ! -name '.*' -exec stat -f '%m'$'\t''%N' {} +
  } 2>> "$e" | sort -rn | cut -f2-
}
D="$casa/Documents/Recuperados"
copiada() { como cmp -s "$1" "$D/${1##*/}"; }
tcc() { grep -q 'Operation not permitted' "$e" && echo "macOS no me dejó entrar en algunas carpetas protegidas: pide a soporte que le dé a Helpert «Acceso total al disco»."; }

case ${1:-} in
diagnosticar|comprobar|aplicar|verificar)
  e=$(mktemp) || { echo "No pude crear un archivo temporal."; exit 1; }
  trap 'rm -f "$e"' EXIT ;;
esac
case ${1:-} in
diagnosticar)
  puedo || exit 3
  c=$(copias)
  if [ -z "$c" ]; then
    echo "No encontré copias de recuperación de Word, Excel, PowerPoint ni LibreOffice en tu carpeta."
    tcc || echo "Abre el programa: si tenía algo que recuperar, te lo ofrece al empezar."
    exit 10
  fi
  echo "Encontré $(echo "$c" | wc -l | tr -d ' ') copia(s) de recuperación:"
  echo "$c" | head -5 | while IFS= read -r r; do echo "- ${r##*/}"; done
  echo "Si sigo, las copio a ~/Documents/Recuperados (no se borra nada)."
  tcc
  exit 0 ;;
comprobar)
  puedo || exit 3
  [ -n "$(copias)" ] || { echo "Ya no hay copias de recuperación."; exit 3; }
  exit 0 ;;
aplicar)
  puedo || exit 1
  como mkdir -p "$D" 2>> "$e" || { tcc || echo "No pude crear la carpeta Recuperados en Documentos."; exit 1; }
  n=0 f=0
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    copiada "$r" && continue
    b=${r##*/}; [ -e "$D/$b" ] && b="$(date +%Y%m%d-%H%M%S)-$b"
    if como cp -p "$r" "$D/$b" 2>> "$e"; then n=$((n + 1)); else f=$((f + 1)); fi
  done <<< "$(copias)"
  [ "$f" -eq 0 ] || { echo "No pude copiar $f archivo(s) a ~/Documents/Recuperados."; tcc; exit 1; }
  echo "Copié $n documento(s) a ~/Documents/Recuperados. Ábrelos desde ahí y guárdalos con el nombre que quieras."
  exit 0 ;;
verificar)
  puedo || exit 1
  falta=0
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    copiada "$r" || como find "$D" -maxdepth 1 -type f -name "*-${r##*/}" 2>/dev/null | grep -q . || falta=$((falta + 1))
  done <<< "$(copias)"
  [ "$falta" -eq 0 ] || { echo "Faltan $falta copia(s) en ~/Documents/Recuperados."; exit 1; }
  echo "Las copias de recuperación están en ~/Documents/Recuperados."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
