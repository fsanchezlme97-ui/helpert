#!/bin/bash
# Optimizar el disco: TRIM (fstrim) en los SSD y desfragmentación en los discos mecánicos (rotacionales y sin TRIM):
# e4defrag en ext4 y xfs_fsr en XFS, si la herramienta está. Btrfs no se desfragmenta: rompería las instantáneas y las
# copias compartidas (reflinks) y podría llenar el disco. Las dos herramientas mueven datos sin cambiar nombres, dueños
# ni permisos, y se pueden cortar a medias sin daño: cada una lleva su tope de tiempo.
set -u
TOPE=780  # segundos para desfragmentar en total; deja margen al timeout del manifiesto (1800 s) y de las pruebas

ssd() { lsblk -dnro NAME,ROTA,DISC-GRAN,TYPE 2>/dev/null | awk '$4 == "disk" && $1 !~ /^zram/ && $3 != "0B" && $3 != "0" { print $1 }'; }
hdd() { lsblk -dnro NAME,ROTA,TYPE 2>/dev/null | awk '$3 == "disk" && $2 == 1 { print $1 }'; }
# «tipo dispositivo punto_de_montaje» de lo montado en discos mecánicos (rotacionales y sin TRIM); lsblk escribe los
# espacios como \x20
mecanicos() {
  lsblk -nrpo NAME,ROTA,DISC-GRAN,FSTYPE,MOUNTPOINT 2>/dev/null |
    awk 'NF == 5 && $2 == 1 && ($3 == "0B" || $3 == "0") && ($4 == "ext4" || $4 == "xfs" || $4 == "btrfs") && !visto[$5]++ { print $4, $1, $5 }' |
    while read -r t d m; do printf '%s %s %b\n' "$t" "$d" "$m"; done
}
herramienta() { case $1 in ext4) echo e4defrag ;; xfs) echo xfs_fsr ;; esac; }
# los que se pueden desfragmentar: ext4 o XFS con su herramienta instalada
desfragmentables() { mecanicos | while read -r t d m; do h=$(herramienta "$t"); [ -n "$h" ] && command -v "$h" >/dev/null && echo "$t $d $m"; done; }
lista() { cut -d' ' -f3- | paste -sd, | sed 's/,/, /g'; }

case ${1:-} in
diagnosticar)
  command -v lsblk >/dev/null || { echo "Falta la herramienta lsblk para ver los discos."; exit 1; }
  s=$(ssd) m=$(mecanicos) d=$(desfragmentables) hay=0
  if [ -n "$s" ]; then
    if command -v fstrim >/dev/null; then
      echo "Tu disco ($(echo $s)) admite TRIM: si sigo, le aviso qué espacio está libre para que no se ponga lento."
      systemctl is-enabled fstrim.timer >/dev/null 2>&1 && echo "El sistema ya lo hace solo cada semana; hacerlo ahora no hace daño."
      hay=1
    else echo "Tu disco admite TRIM, pero falta la herramienta fstrim para pasarlo."; fi
  fi
  if [ -n "$d" ]; then
    echo "Tu disco mecánico ($(echo "$d" | lista)) se puede desfragmentar: si sigo, lo hago (hasta unos 13 minutos; el equipo irá más lento mientras)."
    hay=1
  fi
  b=$(echo "$m" | awk '$1 == "btrfs"' | lista)
  [ -n "$b" ] && echo "En $b (btrfs) no desfragmento: rompería las instantáneas y las copias compartidas y podría llenar el disco."
  falta=0
  echo "$m" | grep -q '^ext4 ' && ! command -v e4defrag >/dev/null && { echo "Para desfragmentar ext4 falta la herramienta e4defrag (paquete e2fsprogs)."; falta=1; }
  echo "$m" | grep -q '^xfs ' && ! command -v xfs_fsr >/dev/null && { echo "Para desfragmentar XFS falta la herramienta xfs_fsr (paquete xfsprogs)."; falta=1; }
  [ "$hay" = 1 ] && exit 0
  { [ -n "$s" ] || [ "$falta" = 1 ]; } && exit 1
  if [ -n "$(hdd)" ]; then
    echo "Si va lento, revisa cuánto espacio libre queda («Liberar espacio en disco») o su estado («Revisar la salud del disco»)."
    exit 10
  fi
  echo "No encontré discos que se puedan optimizar en este equipo."
  exit 10 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para optimizar el disco."; exit 3; }
  { [ -n "$(ssd)" ] && command -v fstrim >/dev/null; } || [ -n "$(desfragmentables)" ] || { echo "Ningún disco admite TRIM ni se puede desfragmentar con lo que tiene el equipo."; exit 3; }
  exit 0 ;;
aplicar)
  hecho=0 mal=0
  if [ -n "$(ssd)" ] && command -v fstrim >/dev/null; then
    salida=$(fstrim -av 2>/dev/null); c=$?
    n=$(grep -c . <<< "$salida")
    # 0: todo bien; 64: algunos sistemas de archivos no lo admiten (normal); 32: falló en todos
    if { [ "$c" -eq 0 ] || [ "$c" -eq 64 ]; } && [ "$n" -gt 0 ]; then
      echo "Pasé TRIM en $n parte(s) del disco. El efecto se nota con el uso, sobre todo al guardar archivos."; hecho=1
    else echo "No pude pasar TRIM al disco."; mal=1; fi
  fi
  d=$(desfragmentables) cortado=0
  while read -r t dev m; do
    [ -n "$t" ] || continue
    resto=$((TOPE - SECONDS)); [ "$resto" -ge 60 ] || { cortado=1; break; }
    # los archivos en uso o que no se pueden mover se saltan (y la herramienta sale con error): es normal.
    # e4defrag acepta el punto de montaje; xfs_fsr, el dispositivo (con uno dado, su -t no cuenta: el tope es timeout)
    if [ "$t" = ext4 ]; then timeout "$resto" e4defrag "$m" >/dev/null 2>&1; else timeout "$resto" xfs_fsr "$dev" >/dev/null 2>&1; fi
    [ $? -eq 124 ] && cortado=1
  done <<< "$d"
  if [ -n "$d" ]; then
    echo "Desfragmenté el disco mecánico ($(echo "$d" | lista))."; hecho=1
    [ "$cortado" = 1 ] && echo "No alcanzó el tiempo para terminar: lo que quedó se puede seguir otro día pidiéndomelo de nuevo."
  fi
  [ "$hecho" = 1 ] || { [ "$mal" = 1 ] || echo "No había nada que optimizar."; exit 1; }
  exit 0 ;;
verificar)
  # TRIM y la desfragmentación no dejan una marca que se pueda leer después: basta con que hayan terminado bien
  echo "Listo: el disco quedó optimizado."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
