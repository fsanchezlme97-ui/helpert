#!/bin/bash
# Revisar OneDrive: si está instalado, su versión, si está abierto para la persona (sus procesos), sus carpetas de
# OneDrive (~/Library/CloudStorage/OneDrive-*, revisadas con su usuario) y el espacio libre del disco. Solo lectura:
# termina con 10. Bash 3.2.
set -u
PATRON='OneDrive\.app/'  # procesos de la app, por la ruta de su ejecutable
usuario=${HP_USUARIO:-}
casa=$([ -n "$usuario" ] && dscl . -read "/Users/$usuario" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')

puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo revisar la cuenta de otra persona."; return 1; }
}
como() { if [ "$(id -u)" -eq 0 ]; then sudo -u "$usuario" "$@"; else "$@"; fi; }
app() { for a in /Applications/OneDrive.app "$casa/Applications/OneDrive.app"; do como test -d "$a" && { echo "$a"; return; }; done; }
# carpetas de OneDrive de la persona (una por línea): las nuevas en CloudStorage y las viejas en su carpeta personal
carpetas() {
  como find "$casa/Library/CloudStorage" -mindepth 1 -maxdepth 1 -name 'OneDrive*' 2>/dev/null
  como find "$casa" -mindepth 1 -maxdepth 1 -type d -name 'OneDrive*' 2>/dev/null
}

case ${1:-} in
diagnosticar)
  puedo || exit 3
  a=$(app)
  [ -n "$a" ] || { echo "OneDrive no está instalado en este equipo. Si lo necesitas, pide a soporte que lo instale."; exit 10; }
  v=$(como defaults read "$a/Contents/Info" CFBundleShortVersionString 2>/dev/null)
  if pgrep -u "$usuario" -f "$PATRON" >/dev/null; then abierto=1; echo "OneDrive${v:+ (versión $v)} está abierto."
  else abierto=0; echo "OneDrive${v:+ (versión $v)} está instalado, pero no está abierto: por eso no sincroniza. Ábrelo desde Aplicaciones."; fi
  c=$(carpetas)
  if [ -z "$c" ]; then echo "No encontré tu carpeta de OneDrive: ábrelo y entra con tu cuenta del trabajo."
  else printf '%s\n' "$c" | head -3 | while IFS= read -r d; do echo "Tu carpeta de OneDrive: ${d#"$casa"/}."; done; fi
  libre=$(df -k "$casa" 2>/dev/null | awk 'NR == 2 {printf "%.1f", $4 / 1048576}')
  [ -n "$libre" ] && echo "El disco tiene $libre GB libres."
  if [ -n "$libre" ] && [ "${libre%.*}" -lt 2 ]; then echo "Queda poco espacio: OneDrive no puede descargar archivos así. Libera espacio o deja archivos «solo en línea»."
  elif [ "$abierto" = 1 ]; then echo "Si sigue sin sincronizar, haz clic en el ícono de la nube en la barra de menús: ahí OneDrive dice qué error tiene."; fi
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
