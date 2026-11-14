#!/bin/bash
# Revisar el proxy del equipo (macOS): el que usa la red activa según scutil --proxy (en macOS el proxy es de cada
# servicio de red, no de cada persona). Prueba si responde y si sin proxy hay internet. Solo revisa: termina con 10.
set -u
PRUEBA=http://example.com/
px() { printf '%s\n' "$conf" | awk -v k="$1" '$1 == k {print $3; exit}'; }
limpio() { local v=${1#*://}; v=${v##*@}; echo "${v%%/*}"; }
# código HTTP de la prueba (por el proxy si se da uno); vacío si no hubo respuesta
http() {
  local c
  if [ -n "${1:-}" ]; then c=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 8 -x "http://$1" "$PRUEBA" 2>/dev/null)
  else c=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 8 --noproxy '*' "${2:-$PRUEBA}" 2>/dev/null); fi
  [ "${c:-000}" != 000 ] && echo "$c"
}

case ${1:-} in
diagnosticar)
  conf=$(scutil --proxy 2>/dev/null)
  tipo=; proxy=; pac=
  if [ "$(px HTTPSEnable)" = 1 ] && [ -n "$(px HTTPSProxy)" ]; then tipo=manual; proxy="$(limpio "$(px HTTPSProxy)"):$(px HTTPSPort)"
  elif [ "$(px HTTPEnable)" = 1 ] && [ -n "$(px HTTPProxy)" ]; then tipo=manual; proxy="$(limpio "$(px HTTPProxy)"):$(px HTTPPort)"
  elif [ "$(px ProxyAutoConfigEnable)" = 1 ]; then tipo=pac; pac=$(px ProxyAutoConfigURLString)
  elif [ "$(px ProxyAutoDiscoveryEnable)" = 1 ]; then tipo=auto; fi
  proxy=${proxy%:}
  directo=$(http "")
  case $tipo in
  manual)
    c=$(http "$proxy")
    if [ "$c" = 407 ]; then echo "El proxy configurado ($proxy) responde: pide identificarse, lo normal en una empresa."
    elif [ -n "$c" ]; then echo "El proxy configurado ($proxy) responde y deja salir a internet."
    else
      echo "El proxy configurado ($proxy) no responde: por eso no cargan las páginas."
      [ -n "$directo" ] && echo "Sin proxy sí hay internet: si ya no deberías usarlo, soporte lo quita."
    fi ;;
  pac)
    if [ -n "$pac" ] && [ -n "$(http "" "$pac")" ]; then echo "El equipo toma el proxy de un archivo de configuración automática, y ese archivo responde."
    else echo "El equipo toma el proxy de un archivo de configuración automática${pac:+ ($(limpio "$pac"))}, pero ese archivo no responde: por eso pueden fallar las páginas."; fi ;;
  auto)
    echo "El equipo busca el proxy solo en la red (detección automática); no lo puedo probar directamente."
    [ -n "$directo" ] && echo "Sin proxy sí hay internet." || echo "Sin proxy tampoco hay internet." ;;
  *)
    if [ -n "$directo" ]; then echo "Este equipo no usa proxy y llega bien a internet: el problema no es el proxy."
    else echo "Este equipo no usa proxy y no llega a internet: el problema no es el proxy (prueba «Sin internet o Wi-Fi»)."; fi
    echo "Si una página dice «error de proxy», puede que el navegador tenga su propio proxy: revísalo en su configuración." ;;
  esac
  [ -n "$tipo" ] && echo "Está en Ajustes del Sistema > Red > (tu red) > Detalles > Proxies. Cambiarlo lo hace soporte."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
