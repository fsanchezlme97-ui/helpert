#!/bin/bash
# Optimizar el disco: TRIM (fstrim) en los SSD. En Linux los discos mecánicos no se desfragmentan: ext4, xfs y btrfs
# reparten los archivos para no fragmentarse, así que en ese caso solo se informa.
set -u

ssd() { lsblk -dnro NAME,ROTA,DISC-GRAN,TYPE 2>/dev/null | awk '$4 == "disk" && $1 !~ /^zram/ && $3 != "0B" && $3 != "0" { print $1 }'; }
hdd() { lsblk -dnro NAME,ROTA,TYPE 2>/dev/null | awk '$3 == "disk" && $2 == 1 { print $1 }'; }

case ${1:-} in
diagnosticar)
  command -v lsblk >/dev/null || { echo "Falta la herramienta lsblk para ver los discos."; exit 1; }
  s=$(ssd)
  if [ -n "$s" ]; then
    command -v fstrim >/dev/null || { echo "Tu disco admite TRIM, pero falta la herramienta fstrim para pasarlo."; exit 1; }
    echo "Tu disco ($(echo $s)) admite TRIM: si sigo, le aviso qué espacio está libre para que no se ponga lento."
    systemctl is-enabled fstrim.timer >/dev/null 2>&1 && echo "El sistema ya lo hace solo cada semana; hacerlo ahora no hace daño."
    exit 0
  fi
  if [ -n "$(hdd)" ]; then
    echo "Tu disco es mecánico. En Linux no hace falta desfragmentarlo: el sistema de archivos ya evita la fragmentación."
    echo "Si va lento, revisa cuánto espacio libre queda («Liberar espacio en disco») o su estado («Revisar la salud del disco»)."
    exit 10
  fi
  echo "No encontré discos que se puedan optimizar en este equipo."
  exit 10 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para optimizar el disco."; exit 3; }
  command -v fstrim >/dev/null || { echo "Falta la herramienta fstrim."; exit 3; }
  [ -n "$(ssd)" ] || { echo "Ningún disco admite TRIM."; exit 3; }
  exit 0 ;;
aplicar)
  command -v fstrim >/dev/null || { echo "Falta la herramienta fstrim."; exit 1; }
  salida=$(fstrim -av 2>/dev/null); c=$?
  n=$(grep -c . <<< "$salida")
  # 0: todo bien; 64: algunos sistemas de archivos no lo admiten (normal); 32: falló en todos
  { [ "$c" -eq 0 ] || [ "$c" -eq 64 ]; } && [ "$n" -gt 0 ] || { echo "No pude pasar TRIM al disco."; exit 1; }
  echo "Pasé TRIM en $n parte(s) del disco. El efecto se nota con el uso, sobre todo al guardar archivos."
  exit 0 ;;
verificar)
  # TRIM no deja una marca que se pueda leer después: basta con que haya terminado bien
  echo "Listo: el disco quedó optimizado."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
