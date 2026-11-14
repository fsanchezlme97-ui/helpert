#!/bin/bash
# Revisar el proxy del equipo: el de la persona en GNOME (gsettings) o KDE (kioslaverc), leídos como ella, y el de todo
# el equipo en /etc/environment. Prueba si el proxy responde y si sin proxy hay internet. Solo revisa: termina con 10.
# El usuario y la contraseña que pueda llevar la dirección del proxy nunca se muestran.
set -u
usuario=${HP_USUARIO:-}
casa=$(getent passwd "$usuario" 2>/dev/null | cut -d: -f6)
PRUEBA=http://example.com/
como() {  # como root: con el usuario de la persona (sus archivos, nunca como root)
  if [ "$(id -u)" -eq 0 ]; then runuser -u "$usuario" -- env HOME="$casa" "$@"; else "$@"; fi
}
persona() { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -d "$casa" ] && { [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ]; }; }
# «host:puerto» sin esquema, usuario ni ruta
limpio() { local v=${1#*://}; v=${v##*@}; echo "${v%%/*}"; }
gs() { como gsettings get "$@" 2>/dev/null | tr -d "'"; }
# deja en $tipo (manual, auto, pac o nada), $proxy (host:puerto), $pac y $origen lo que esté configurado
leer() {
  tipo=; proxy=; pac=; origen=
  if persona && command -v gsettings >/dev/null; then
    case $(gs org.gnome.system.proxy mode) in
    manual) h=$(gs org.gnome.system.proxy.https host); p=$(gs org.gnome.system.proxy.https port)
            [ -n "$h" ] || { h=$(gs org.gnome.system.proxy.http host); p=$(gs org.gnome.system.proxy.http port); }
            [ "${p:-0}" = 0 ] && p=8080
            [ -n "$h" ] && { tipo=manual; proxy="$(limpio "$h"):$p"; origen="tu configuración de GNOME"; return; } ;;
    auto) pac=$(gs org.gnome.system.proxy autoconfig-url); tipo=auto; [ -n "$pac" ] && tipo=pac; origen="tu configuración de GNOME"; return ;;
    esac
  fi
  if persona && [ -f "$casa/.config/kioslaverc" ]; then
    k=$(como cat "$casa/.config/kioslaverc" 2>/dev/null)
    val() { printf '%s\n' "$k" | awk -F= -v c="$1" '$1 == c {sub(/^[^=]*=/, ""); print; exit}'; }
    case $(val ProxyType) in
    1) h=$(val httpsProxy); [ -n "$h" ] || h=$(val httpProxy)
       [ -n "$h" ] && { tipo=manual; proxy=$(limpio "$(echo "$h" | tr ' ' ':')"); origen="tu configuración de KDE"; return; } ;;
    2) tipo=pac; pac=$(val "Proxy Config Script"); origen="tu configuración de KDE"; return ;;
    3) tipo=auto; origen="tu configuración de KDE"; return ;;
    esac
  fi
  h=$(grep -iE '^[[:space:]]*(export[[:space:]]+)?(https?|all)_proxy=' /etc/environment 2>/dev/null | head -1 | cut -d= -f2- | tr -d "\"' ")
  [ -n "$h" ] && { tipo=manual; proxy=$(limpio "$h"); origen="la configuración de todo el equipo (/etc/environment)"; }
}
# código HTTP de la prueba (por el proxy si se da uno); vacío si no hubo respuesta
http() {
  local c
  if [ -n "${1:-}" ]; then c=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 8 -x "http://$1" "$PRUEBA" 2>/dev/null)
  else c=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 8 --noproxy '*' "${2:-$PRUEBA}" 2>/dev/null); fi
  [ "${c:-000}" != 000 ] && echo "$c"
}

case ${1:-} in
diagnosticar)
  leer
  command -v curl >/dev/null || { echo "Proxy: ${proxy:-${pac:-${tipo:-ninguno}}}. No puedo probarlo: falta la herramienta curl en este equipo."; exit 10; }
  directo=$(http "")
  case $tipo in
  manual)
    c=$(http "$proxy")
    if [ "$c" = 407 ]; then echo "El proxy configurado ($proxy) responde: pide identificarse, lo normal en una empresa."
    elif [ -n "$c" ]; then echo "El proxy configurado ($proxy) responde y deja salir a internet."
    else
      echo "El proxy configurado ($proxy) no responde: por eso no cargan las páginas."
      [ -n "$directo" ] && echo "Sin proxy sí hay internet: si ya no deberías usarlo, soporte lo quita."
    fi
    echo "Lo tomé de $origen." ;;
  pac)
    if [ -n "$(http "" "$pac")" ]; then echo "El equipo toma el proxy de un archivo de configuración automática, y ese archivo responde."
    else echo "El equipo toma el proxy de un archivo de configuración automática ($(limpio "$pac")), pero ese archivo no responde: por eso pueden fallar las páginas."; fi
    echo "Lo tomé de $origen." ;;
  auto)
    echo "El equipo busca el proxy solo en la red (detección automática); no lo puedo probar directamente."
    [ -n "$directo" ] && echo "Sin proxy sí hay internet." || echo "Sin proxy tampoco hay internet." ;;
  *)
    if [ -n "$directo" ]; then echo "Este equipo no usa proxy y llega bien a internet: el problema no es el proxy."
    else echo "Este equipo no usa proxy y no llega a internet: el problema no es el proxy (prueba «Sin internet o Wi-Fi»)."; fi
    echo "Si una página dice «error de proxy», puede que el navegador tenga su propio proxy: revísalo en su configuración." ;;
  esac
  [ "$tipo" != "" ] && echo "Cambiar el proxy lo hace soporte."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
