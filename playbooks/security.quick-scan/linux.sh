#!/bin/bash
# Análisis rápido con ClamAV de donde suele llegar algo dudoso: Descargas, Escritorio y las carpetas temporales.
# Corre con la identidad de la persona (solo lee lo que ella puede leer). No borra ni mueve nada: solo dice qué encontró.
set -u
usuario=${HP_USUARIO:-}
casa=$(getent passwd "$usuario" 2>/dev/null | cut -d: -f6)
firmas() { ls /var/lib/clamav/daily.c[lv]d /var/lib/clamav/main.c[lv]d >/dev/null 2>&1; }
puedo() {
  command -v clamscan >/dev/null || { echo "Este equipo no tiene antivirus (ClamAV). No instalo uno nuevo: si hace falta, lo decide soporte."; return 1; }
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$casa" ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide o no encuentro su carpeta personal."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo analizar las carpetas de otra persona."; return 1; }
}
carpetas() { for d in "$casa/Descargas" "$casa/Downloads" "$casa/Escritorio" "$casa/Desktop" /tmp /var/tmp; do [ -d "$d" ] && echo "$d"; done; }
como_persona() { if [ "$(id -u)" -eq 0 ]; then runuser -u "$usuario" -- "$@"; else "$@"; fi; }

case ${1:-} in
diagnosticar)
  puedo || exit 3
  firmas || { echo "El antivirus (ClamAV) no tiene firmas descargadas: primero hay que actualizarlo."; exit 1; }
  echo "Puedo hacer un análisis rápido con ClamAV de tus Descargas, tu Escritorio y las carpetas temporales."
  echo "Tarda unos minutos y no borra nada: solo te digo qué encontró."
  exit 0 ;;
comprobar)
  puedo || exit 3
  firmas || { echo "El antivirus no tiene firmas descargadas: primero hay que actualizarlo."; exit 3; }
  exit 0 ;;
aplicar)
  dirs=(); while IFS= read -r d; do dirs+=("$d"); done < <(carpetas)
  [ ${#dirs[@]} -gt 0 ] || { echo "No encontré carpetas que analizar."; exit 1; }
  salida=$(como_persona timeout 1700 clamscan -r -i --no-summary --max-filesize=100M --max-scansize=300M "${dirs[@]}" 2>/dev/null); r=$?
  [ "$r" -eq 124 ] && { echo "El análisis tardó demasiado y lo detuve."; exit 1; }
  hallados=$(printf '%s\n' "$salida" | grep ' FOUND$')
  if [ -n "$hallados" ]; then
    echo "El antivirus encontró $(printf '%s\n' "$hallados" | wc -l) archivo(s) peligroso(s):"
    printf '%s\n' "$hallados" | head -5 | sed 's|^.*/\([^/]*\): \(.*\) FOUND$|- \1 (\2)|'
    echo "No borré nada. No abras esos archivos y avisa a soporte para que decida qué hacer con ellos."
    exit 0
  fi
  [ "$r" -le 2 ] || { echo "El antivirus no pudo terminar el análisis."; exit 1; }
  echo "El análisis rápido terminó y no encontró nada peligroso."
  [ "$r" -eq 2 ] && echo "Algunos archivos no se pudieron leer (por ejemplo, de otras personas) y quedaron sin revisar."
  exit 0 ;;
verificar)
  command -v clamscan >/dev/null && firmas || { echo "El antivirus ya no está disponible."; exit 1; }
  echo "El análisis terminó; el antivirus sigue instalado y con firmas."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
