#!/bin/bash
# Revisar el lector de tarjetas o DNIe en macOS: si el Mac ve el lector (system_profiler, sección de lectores) y
# reiniciar el servicio de tarjetas (cierra com.apple.ifdreader y com.apple.ctkpcscd; launchd los vuelve a abrir al usarlos).
# No instala controladores ni toca certificados.
set -u
lectores() {
  system_profiler SPSmartCardsDataType 2>/dev/null | awk '
    /^ *Readers:$/ { r = 1; next }
    /^ *[A-Za-z][A-Za-z ()]*:$/ { r = 0 }
    r && /#[0-9]+:/ { sub(/^ *#[0-9]+: */, ""); sub(/ *\(ATR.*$/, ""); print }' | sort -u | head -3 | paste -sd, - | sed 's/,/, /g'
}

case ${1:-} in
diagnosticar)
  command -v system_profiler >/dev/null || { echo "No puedo revisar los lectores de tarjetas de este Mac."; exit 1; }
  l=$(lectores)
  if [ -z "$l" ]; then
    echo "El Mac no detecta ningún lector de tarjetas."
    echo "Desconecta el lector o el token, espera 5 segundos y conéctalo en otro puerto; si usas un adaptador, conéctalo directo al Mac."
    exit 10
  fi
  echo "El Mac detecta el lector: $l."
  echo "Voy a reiniciar el servicio de tarjetas. Cierra antes el navegador o el programa de firma que la estaba usando."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para reiniciar el servicio de tarjetas."; exit 3; }
  exit 0 ;;
aplicar)
  # por la ruta completa: el nombre corto del proceso que compara «pkill -x» se corta a 16 letras
  p=$(pgrep -f '/com\.apple\.(ifdreader|ctkpcscd)( |$)' 2>/dev/null)
  if [ -z "$p" ]; then echo "El servicio de tarjetas no estaba en marcha: se abrirá solo al usar la tarjeta."; exit 0; fi
  kill $p 2>/dev/null
  sleep 3
  echo "Reinicié el servicio de tarjetas."
  exit 0 ;;
verificar)
  l=$(lectores)
  [ -n "$l" ] || { echo "El Mac ya no detecta el lector: desconéctalo y conéctalo en otro puerto; si sigue igual, avisa a soporte."; exit 1; }
  echo "El Mac detecta el lector: $l. Saca la tarjeta, vuelve a ponerla y abre de nuevo el programa de firma o el navegador."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
