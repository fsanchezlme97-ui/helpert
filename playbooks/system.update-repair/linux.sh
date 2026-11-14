#!/bin/bash
# Reparar el gestor de paquetes sin instalar ni quitar nada:
# - apt: termina de configurar los paquetes a medio instalar (dpkg --configure -a) y vacía la caché de descargas.
# - dnf: reconstruye la base de datos de rpm y vacía la caché de metadatos.
# - pacman: quita el bloqueo que dejó una actualización cortada (si no hay ninguna en curso) y las descargas a medias.
# Las dependencias rotas o las copias duplicadas se arreglan instalando o quitando paquetes: eso lo ve soporte.
set -u
gestor() {
  if command -v dpkg >/dev/null && command -v apt-get >/dev/null; then echo apt
  elif command -v dnf >/dev/null && command -v rpm >/dev/null; then echo dnf
  elif command -v pacman >/dev/null; then echo pacman; fi
}
ocupado() { pgrep -x 'apt|apt-get|aptitude|dpkg|unattended-upgr|dnf|dnf5|yum|rpm|pacman' >/dev/null; }
reparable() {  # lo que este procedimiento arregla, una línea por problema
  case $(gestor) in
  apt) n=$(dpkg --audit 2>/dev/null | grep -c '^ [^ ]')
       [ "$n" -gt 0 ] && echo "Hay $n paquete(s) a medio instalar o configurar." ;;
  dnf) rpm -q rpm >/dev/null 2>&1 || echo "La base de datos de paquetes está dañada." ;;
  pacman) [ -e /var/lib/pacman/db.lck ] && ! ocupado && echo "Quedó bloqueado por una actualización que se cortó."
          ls /var/cache/pacman/pkg/*.part >/dev/null 2>&1 && echo "Hay descargas de paquetes a medias." ;;
  esac
}
soporte() {  # lo que necesita instalar o quitar paquetes
  case $(gestor) in
  apt) apt-get check -qq >/dev/null 2>&1 || echo "Hay dependencias rotas entre paquetes." ;;
  dnf) dnf -q check 2>/dev/null | grep -q . && echo "Hay paquetes duplicados o con dependencias rotas." ;;
  pacman) pacman -Dk >/dev/null 2>&1 || echo "Hay paquetes con dependencias rotas." ;;
  esac
}

case ${1:-} in
diagnosticar)
  [ -n "$(gestor)" ] || { echo "No reconozco el gestor de paquetes de este sistema."; exit 1; }
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para revisar los paquetes."; exit 3; }
  ocupado && { echo "Hay una instalación o actualización en curso: espera a que termine y vuelve a intentarlo."; exit 1; }
  r=$(reparable); s=$(soporte)
  if [ -n "$r" ]; then
    echo "Encontré lo que hace fallar las actualizaciones:"; echo "$r"
    [ -n "$s" ] && echo "$s Eso no lo puedo arreglar sin instalar o quitar paquetes: lo tiene que ver soporte."
    echo "Puedo repararlo sin instalar nada nuevo."
    exit 0
  fi
  [ -n "$s" ] && { echo "$s Repararlo necesita instalar o quitar paquetes: lo tiene que ver soporte."; exit 1; }
  echo "El gestor de paquetes está bien: no hay paquetes a medio instalar ni bloqueos. Si las actualizaciones siguen fallando, dale a soporte el mensaje de error exacto."
  exit 10 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para reparar los paquetes."; exit 3; }
  [ -n "$(gestor)" ] || { echo "No reconozco el gestor de paquetes de este sistema."; exit 3; }
  ocupado && { echo "Hay una instalación o actualización en curso: espera a que termine."; exit 3; }
  exit 0 ;;
aplicar)
  case $(gestor) in
  apt)
    # sin preguntas: conserva la configuración actual de cada programa
    DEBIAN_FRONTEND=noninteractive dpkg --configure -a --force-confdef --force-confold </dev/null >/dev/null 2>&1 ||
      { echo "No pude terminar de configurar los paquetes: lo tiene que ver soporte."; exit 1; }
    apt-get clean >/dev/null 2>&1 ;;
  dnf)
    rpm --rebuilddb >/dev/null 2>&1 || { echo "No pude reconstruir la base de datos de paquetes: lo tiene que ver soporte."; exit 1; }
    dnf -q clean all >/dev/null 2>&1 ;;
  pacman)
    ocupado || rm -f /var/lib/pacman/db.lck
    find /var/cache/pacman/pkg -maxdepth 1 -type f -name '*.part' -delete 2>/dev/null ;;
  esac
  echo "Reparé el gestor de paquetes sin instalar nada nuevo."
  exit 0 ;;
verificar)
  r=$(reparable)
  [ -z "$r" ] || { echo "Sigue el problema: $r"; exit 1; }
  echo "El gestor de paquetes quedó bien. Ya puedes volver a intentar la actualización."
  s=$(soporte); [ -n "$s" ] && echo "$s Eso lo tiene que ver soporte."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
