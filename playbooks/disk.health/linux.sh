#!/bin/bash
# Revisar la salud del disco: estado SMART de cada disco (smartctl, de smartmontools) y los errores de lectura que el
# kernel registró en los últimos 7 días. Dice si conviene cambiarlo. Solo lectura: termina con 10.
set -u
discos() { lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2 == "disk" && $1 !~ /\/(zram|loop|ram|nbd)[0-9]/ {print $1}'; }
# «veces disco» de los errores de lectura del kernel (I/O error, dev sda…) de los últimos 7 días
errores() {
  { journalctl -k -q --no-pager -o cat --since "-7d" 2>/dev/null || dmesg 2>/dev/null; } |
    grep -Ei 'I/O error, dev|critical medium error, dev|unrecovered read error' |
    grep -oE 'dev (sd[a-z]+|nvme[0-9]+n[0-9]+|mmcblk[0-9]+|vd[a-z]+|hd[a-z]+)' | sort | uniq -c | awk '{print $1, $3}'
}
tam() { lsblk -dno SIZE "$1" 2>/dev/null | sed -E 's/ //g; s/([0-9])G$/\1 GB/; s/([0-9])T$/\1 TB/; s/([0-9])M$/\1 MB/'; }
# «clase|frase» del disco $1: mal, sano o nada (no da datos SMART)
salud() {
  t=$(smartctl -i -H -A "$1" 2>/dev/null)  # su código de salida es una máscara de bits, no un fallo: no se usa
  modelo=$(echo "$t" | sed -n -E 's/^(Device Model|Model Number|Product): *//p' | head -1)
  quien="${modelo:-${1#/dev/}} ($(tam "$1"))"
  h=$(echo "$t" | grep -E 'overall-health self-assessment|SMART Health Status')
  sect=$(echo "$t" | awk '$2 ~ /^(Reallocated_Sector_Ct|Current_Pending_Sector|Offline_Uncorrectable)$/ && $10 ~ /^[0-9]+$/ {s += $10} END {print s + 0}')
  uso=$(echo "$t" | sed -n -E 's/^Percentage Used: *([0-9]+)%.*/\1/p'); uso=${uso:-0}
  med=$(echo "$t" | sed -n -E 's/^Media and Data Integrity Errors: *([0-9,]+).*/\1/p' | tr -d ,); med=${med:-0}
  crit=$(echo "$t" | sed -n -E 's/^Critical Warning: *(0x[0-9a-fA-F]+).*/\1/p'); crit=${crit:-0x00}
  [ -n "$h" ] || { echo "nada|- $quien: no informa su estado SMART."; return; }
  if echo "$h" | grep -Eq 'FAILED|FAILURE' || [ "$crit" != 0x00 ]; then echo "mal|- $quien: el propio disco avisa que está fallando."
  elif [ "$sect" -gt 0 ] || [ "$med" -gt 0 ]; then echo "mal|- $quien: tiene $((sect + med)) sector(es) dañado(s)."
  elif [ "$uso" -ge 90 ]; then echo "mal|- $quien: está gastado al $uso % de su vida útil."
  else extra=""; [ "$uso" -gt 0 ] && extra=" (gastado al $uso %)"; echo "sano|- $quien: sano$extra."; fi
}

case ${1:-} in
diagnosticar)
  d=$(discos)
  [ -n "$d" ] || { echo "No encontré discos que revisar en este equipo."; exit 1; }
  e=$(errores)
  if ! command -v smartctl >/dev/null; then
    if [ -n "$e" ]; then
      echo "El sistema registró errores de lectura del disco en los últimos 7 días: haz copia de tus archivos importantes y avisa a soporte para que lo revise."
      echo "$e" | head -4 | while read -r n x; do echo "- $x: $n error(es)."; done
      echo "No pude leer su estado SMART: falta la herramienta smartmontools."
      exit 10
    fi
    echo "No puedo leer el estado SMART del disco: falta la herramienta smartmontools. Pide a soporte que la instale o que revise el disco."
    exit 1
  fi
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para leer el estado del disco."; exit 3; }
  lineas="" malos=0 sanos=0
  for x in $d; do
    r=$(salud "$x")
    case ${r%%|*} in mal) malos=$((malos + 1)) ;; sano) sanos=$((sanos + 1)) ;; esac
    lineas="$lineas${r#*|}"$'\n'
  done
  if [ "$malos" -gt 0 ]; then echo "Conviene cambiar el disco: haz copia de tus archivos importantes cuanto antes y avisa a soporte."
  elif [ -n "$e" ]; then echo "El disco dice estar sano, pero el sistema registró errores de lectura en los últimos 7 días: haz copia de tus archivos importantes y avisa a soporte."
  elif [ "$sanos" -gt 0 ]; then echo "El disco está sano según su estado SMART; no hace falta cambiarlo."
  else echo "Ningún disco de este equipo informa su estado SMART: no puedo decir si conviene cambiarlo. Pide a soporte que lo revise."; fi
  printf '%s' "$lineas" | head -5
  [ -n "$e" ] && echo "$e" | head -2 | while read -r n x; do echo "- Errores de lectura en $x: $n en los últimos 7 días."; done
  [ "$malos" -eq 0 ] && [ -z "$e" ] && [ "$sanos" -gt 0 ] && echo "Si el equipo se sigue congelando, la causa puede ser otra (poca memoria o disco lleno): pide a soporte que lo revise."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
