#!/bin/bash
# Encontrar lo que más ocupa en la carpeta personal. Solo lectura: el diagnóstico informa y termina con 10.
# Recorre la carpeta una sola vez, con los permisos de la persona (runuser), y con tope de tiempo.
set -u
usuario=${HP_USUARIO:-}
casa=$(getent passwd "$usuario" | cut -d: -f6)
TAM='function t(b) { return b >= 1073741824 ? sprintf("%.1f GB", b / 1073741824) : sprintf("%d MB", b / 1048576) }'

como() { if [ "$(id -u)" -eq 0 ]; then runuser -u "$usuario" -- "$@"; else "$@"; fi; }
puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$casa" ] && [ "$casa" != / ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide o no encontré su carpeta personal."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo revisar la carpeta de otra persona."; return 1; }
}

case ${1:-} in
diagnosticar)
  puedo || exit 3
  # «T total», «D bytes carpeta» (primer nivel), «F bytes archivo» (de 100 MB o más) y «X» si se acabó el tiempo
  datos=$( { como timeout 240 find "$casa" -xdev -type f -printf '%s\t%P\n' 2>/dev/null; echo "X	$?"; } | awk -F'\t' '
    $1 == "X" { if ($2 == 124) print "X"; next }
    { i = index($2, "/"); d = i ? substr($2, 1, i - 1) : "(archivos sueltos)"; t[d] += $1; total += $1
      if ($1 >= 104857600) print "F\t" $1 "\t" $2 }
    END { printf "T\t%.0f\n", total; for (d in t) printf "D\t%.0f\t%s\n", t[d], d }')
  total=$(awk -F'\t' '$1 == "T" { print $2 }' <<< "$datos")
  [ "${total:-0}" -gt 0 ] || { echo "Tu carpeta personal está vacía o no pude leerla."; exit 10; }
  libre=$(df -BG --output=avail "$casa" 2>/dev/null | tail -1 | tr -dc 0-9)
  echo "Tu carpeta personal ocupa $(awk "$TAM"' BEGIN { print t('"$total"') }')${libre:+; en el disco quedan $libre GB libres}."
  echo "Lo que más ocupa: $(awk -F'\t' '$1 == "D"' <<< "$datos" | sort -t$'\t' -k2,2nr | head -5 |
    awk -F'\t' "$TAM"' { printf "%s%s (%s)", s, $3, t($2); s = ", " }')."
  grandes=$(awk -F'\t' '$1 == "F"' <<< "$datos" | sort -t$'\t' -k2,2nr | head -5 | awk -F'\t' "$TAM"' { printf "- ~/%s (%s)\n", $3, t($2) }')
  [ -n "$grandes" ] && { echo "Los archivos más grandes:"; echo "$grandes"; }
  echo "Las carpetas que empiezan con punto son de programas; para limpiar temporales y caché usa «Liberar espacio en disco»."
  grep -q '^X' <<< "$datos" && echo "Tu carpeta es muy grande y no alcancé a revisarla entera: las cifras son de lo que alcancé a ver."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
