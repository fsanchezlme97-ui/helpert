#!/bin/bash
# Liberar /boot quitando núcleos antiguos (Debian/Ubuntu con dpkg, Fedora con dnf). Nunca se tocan el núcleo en uso,
# los más nuevos que él (por ejemplo, uno recién instalado que espera un reinicio) ni el anterior a él.
# Si el núcleo en uso no viene de un paquete (compilado a mano), no se toca nada. Arch no guarda núcleos antiguos.
set -u
actual=$(uname -r)

uso() { df --output=pcent /boot 2>/dev/null | tail -1 | tr -dc 0-9; }
gestor() { if command -v dpkg-query >/dev/null; then echo deb; elif command -v rpm >/dev/null && command -v dnf >/dev/null; then echo rpm; fi; }
versiones() {  # instaladas, de la más vieja a la más nueva
  case $(gestor) in
  deb) dpkg-query -W -f='${Package} ${db:Status-Abbrev}\n' 'linux-image-[0-9]*' 'linux-image-unsigned-[0-9]*' 2>/dev/null |
       awk '$2 ~ /^.i/ { sub(/^linux-image-(unsigned-)?/, "", $1); print $1 }' ;;
  rpm) rpm -q --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' kernel-core kernel 2>/dev/null | grep -v ' ' ;;
  esac | sort -uV
}
sobran() {  # las más viejas que la anterior a la que está en uso
  v=$(versiones)
  grep -qxF -- "$actual" <<< "$v" || return 0
  awk -v a="$actual" '$0 == a { exit } { print }' <<< "$v" | head -n -1
}
paquetes() {  # todos los paquetes de esas versiones (imagen, módulos, cabeceras)
  case $(gestor) in
  deb) dpkg-query -W -f='${Package} ${db:Status-Abbrev}\n' 'linux-*' 2>/dev/null | awk '$2 ~ /^.[iUHFWt]/ { print $1 }' ;;
  # kernel-headers y kernel-tools no son de un núcleo concreto: quitarlos se llevaría compiladores y otros programas
  rpm) rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\t%{VERSION}-%{RELEASE}.%{ARCH}\n' 'kernel*' 2>/dev/null | grep -Ev '^kernel-(headers|tools)' ;;
  esac | awk -F'\t' -v l="$(sobran | paste -sd' ')" 'BEGIN { n = split(l, v, " ") }
    { for (i = 1; i <= n; i++) if ($2 == v[i] || substr($1, length($1) - length(v[i])) == "-" v[i]) { print $1; next } }'
}

case ${1:-} in
diagnosticar)
  g=$(gestor)
  [ -n "$g" ] || { echo "Este sistema no guarda núcleos antiguos que yo pueda quitar. /boot está al $(uso)%: si las actualizaciones fallan, pide a soporte que lo revise."; exit 3; }
  grep -qxF -- "$actual" <<< "$(versiones)" || { echo "El núcleo que usas ($actual) no viene de un paquete del sistema: no toco nada. Pide a soporte que revise /boot."; exit 3; }
  s=$(sobran)
  if [ -z "$s" ]; then
    echo "/boot está al $(uso)% y no hay núcleos antiguos que quitar: solo están el que usas y el anterior."
    [ "$(uso)" -ge 90 ] && echo "Aun así está casi lleno: pide a soporte que lo revise."
    exit 10
  fi
  echo "/boot está al $(uso)%. Hay $(grep -c . <<< "$s") núcleo(s) antiguo(s) que ya no se usan: $(echo $s)."
  echo "Si sigo, los quito y dejo el que usas ($actual) y el anterior. Después vuelve a intentar la actualización."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para quitar núcleos."; exit 3; }
  [ -n "$(sobran)" ] || { echo "Ya no hay núcleos antiguos que quitar."; exit 3; }
  if [ "$(gestor)" = deb ] && command -v fuser >/dev/null && fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock >/dev/null 2>&1; then
    echo "Hay otra instalación o actualización en curso: espera a que termine y vuelve a pedírmelo."; exit 3
  fi
  exit 0 ;;
aplicar)
  mapfile -t p < <(paquetes)
  [ ${#p[@]} -gt 0 ] || { echo "No encontré los paquetes de los núcleos antiguos."; exit 1; }
  antes=$(uso)
  # dpkg y no apt: con /boot lleno, apt suele negarse por la actualización que quedó a medias
  if [ "$(gestor)" = deb ]; then DEBIAN_FRONTEND=noninteractive dpkg --purge "${p[@]}" >/dev/null 2>&1; c=$?
  else dnf remove -y "${p[@]}" >/dev/null 2>&1; c=$?; fi
  [ "$c" -eq 0 ] || { echo "No pude quitar los núcleos antiguos: el sistema de paquetes dio un error. Pide a soporte que lo revise."; exit 1; }
  echo "Quité ${#p[@]} paquete(s) de núcleos antiguos. /boot pasó del $antes% al $(uso)%."
  echo "Vuelve a intentar la actualización del sistema."
  exit 0 ;;
verificar)
  [ -z "$(sobran)" ] || { echo "Todavía quedan núcleos antiguos: $(echo $(sobran))."; exit 1; }
  [ "$(uso)" -lt 90 ] || { echo "Quité los núcleos antiguos, pero /boot sigue al $(uso)%: pide a soporte que lo revise."; exit 1; }
  echo "/boot está al $(uso)%, con espacio para las actualizaciones."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
