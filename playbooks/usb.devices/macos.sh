#!/bin/bash
# Revisar los dispositivos USB en macOS: lista lo que el equipo detecta por USB (el plano IOUSB del registro de I/O, sin
# los concentradores). macOS no tiene una forma de reiniciar la detección de USB desde un programa (lo que hace udev
# en Linux o pnputil en Windows): solo informa y le dice a la persona que lo desconecte y lo vuelva a conectar.
set -u
export LC_ALL=C

# «nombre (fabricante)» de cada dispositivo USB, sin concentradores (bDeviceClass 9); nada si no hay ninguno
dispositivos() {
  printf '%s\n' "$1" | awk '
    function valor(l) { sub(/^[^=]*= "?/, "", l); sub(/"$/, "", l); return l }
    function sale() {
      if (dev && clase != "" && clase != 9) {  # sin bDeviceClass no es un dispositivo (p. ej. un controlador)
        n = (p != "") ? p : sprintf("dispositivo sin nombre (%04x:%04x)", v, q)
        print n ((m != "") ? " (" m ")" : "")
      }
      dev = 0; p = ""; m = ""; clase = ""; v = 0; q = 0
    }
    /\+-o / { sale(); if ($0 ~ /<class / && $0 !~ /<class IORegistryEntry/) dev = 1; next }
    /"USB Product Name" = / { p = valor($0) }
    /"USB Vendor Name" = / { m = valor($0) }
    /"bDeviceClass" = / { clase = valor($0) + 0 }
    /"idVendor" = / { v = valor($0) + 0 }
    /"idProduct" = / { q = valor($0) + 0 }
    END { sale() }' | sort -u
}
resumen() {
  l=$(dispositivos "$1"); n=$(printf '%s\n' "$l" | grep -c .)
  [ "$n" -gt 0 ] || { echo "El equipo no detecta ningún dispositivo USB conectado."; return; }
  echo "El equipo detecta $n dispositivo(s) USB:"
  printf '%s\n' "$l" | grep . | head -6 | sed 's/^/- /'
  [ "$n" -gt 6 ] && echo "… y $((n - 6)) más."
}
portatil_apple() { [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] && pmset -g batt 2>/dev/null | grep -q InternalBattery; }
NO_SE='En macOS no puedo reiniciar la detección de USB desde un programa: desconéctalo, espera 5 segundos y conéctalo en otro puerto.'

case ${1:-} in
diagnosticar)
  command -v ioreg >/dev/null || { echo "No puedo ver los dispositivos USB de este Mac."; exit 1; }
  r=$(ioreg -p IOUSB -l -w0 2>/dev/null)
  printf '%s\n' "$r" | grep -q '+-o Root' || { echo "No pude consultar los dispositivos USB de este Mac."; exit 1; }
  resumen "$r"
  echo "$NO_SE"
  portatil_apple && echo "Si al conectarlo aparece «¿Permitir que se conecte el accesorio?», pulsa Permitir: si no, macOS no lo deja funcionar."
  echo "Si lo que falla es una memoria, usa «Abrir una memoria USB»."
  exit 10 ;;
comprobar) echo "$NO_SE"; exit 3 ;;
aplicar|verificar) echo "$NO_SE"; exit 1 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
