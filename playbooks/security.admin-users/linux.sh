#!/bin/bash
# Ver qué cuentas tienen permisos de administrador: miembros de sudo, wheel o admin, y los grupos o cuentas a los que
# sudoers da todos los permisos. Solo lectura: termina con 10. Dar o quitar permisos lo hace soporte.
set -u
REGLAS=(/etc/sudoers /etc/sudoers.d/*)
# reglas de sudoers que dan todos los permisos («... ALL» al final); $1 = '%' para grupos, '' para cuentas
reglas() {
  grep -hE "^[[:space:]]*$1[A-Za-z_][^[:space:]]*[[:space:]].*ALL[[:space:]]*\$" "${REGLAS[@]}" 2>/dev/null |
    sed -E "s/^[[:space:]]*$1([^[:space:]]+).*/\1/" | grep -vE '^(Defaults|root|Cmnd_Alias|User_Alias|Host_Alias|Runas_Alias)$'
}
# «cuenta<TAB>por qué»
cuentas() {
  { printf '%s\n' sudo wheel admin; reglas %; } | sort -u | while IFS= read -r g; do
    linea=$(getent group "$g")
    gid=$(echo "$linea" | cut -d: -f3)
    m=$([ -n "$linea" ] && { echo "$linea" | cut -d: -f4 | tr , '\n'; getent passwd | awk -F: -v g="$gid" '$4 == g {print $1}'; } | grep -v '^$')
    if [ -n "$m" ]; then printf '%s\n' "$m" | while IFS= read -r u; do printf '%s\tgrupo %s\n' "$u" "$g"; done
    # un grupo de sudoers sin miembros a la vista (p. ej. del dominio): se nombra el grupo entero
    else case $g in sudo|wheel|admin) ;; *) printf 'todos los del grupo «%s»\tregla de sudo\n' "$g" ;; esac; fi
  done
  reglas '' | while IFS= read -r u; do printf '%s\tregla propia\n' "$u"; done
}

case ${1:-} in
diagnosticar)
  [ "$(id -u)" -eq 0 ] || echo "(Sin privilegios de administrador no puedo leer las reglas de sudo; la lista puede quedar incompleta.)"
  l=$(cuentas | grep -v '^root	' | sort -u | awk -F'\t' '{a[$1] = a[$1] ? a[$1] ", " $2 : $2} END {for (u in a) print "- " u " (" a[u] ")"}' | sort)
  if [ -z "$l" ]; then echo "Ninguna cuenta de persona tiene permisos de administrador en este equipo; solo la cuenta del sistema (root)."; exit 10; fi
  echo "Estas $(printf '%s\n' "$l" | wc -l) cuenta(s) tienen permisos de administrador en este equipo:"
  printf '%s\n' "$l" | head -8
  [ "$(printf '%s\n' "$l" | wc -l)" -gt 8 ] && echo "… y $(( $(printf '%s\n' "$l" | wc -l) - 8 )) más."
  echo "Además está la cuenta del sistema (root). Dar o quitar permisos lo hace soporte."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
