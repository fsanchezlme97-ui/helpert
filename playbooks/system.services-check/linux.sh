#!/bin/bash
# Revisar los servicios esenciales (lista fija: impresión, red, DNS, hora; y en la sesión de la persona, sonido y
# búsqueda) e iniciar los que están habilitados pero detenidos. Nunca toca otros servicios ni reinicia los que funcionan.
set -u
SISTEMA="cups.socket cups.service NetworkManager.service systemd-networkd.service systemd-resolved.service chronyd.service chrony.service systemd-timesyncd.service"
PERSONA="pipewire.socket pipewire-pulse.socket wireplumber.service pulseaudio.socket localsearch-3.service tracker-miner-fs-3.service"

usuario=${HP_USUARIO:-}
uid=$(id -u "$usuario" 2>/dev/null)
con_sesion() { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$uid" ] && [ -d "/run/user/$uid/systemd" ]; }
ctl() {  # ctl sistema|persona <argumentos de systemctl>; los de la persona, en su sesión y con su usuario
  local a=$1; shift
  if [ "$a" = persona ]; then runuser -u "$usuario" -- env XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user "$@"
  else systemctl "$@"; fi
}
# los que hacen lo mismo: si uno funciona, los otros no faltan (y nunca se arrancan dos: chrony detiene a timesyncd)
grupo() {
  case $1 in
    systemd-timesyncd.service|chrony*.service) echo hora ;; NetworkManager.service|systemd-networkd.service) echo red ;;
    pipewire-pulse.socket|pulseaudio.socket) echo pulse ;; localsearch-3.service|tracker-miner-fs-3.service) echo busqueda ;;
    *) echo "$1" ;;
  esac
}
otro_activo() {  # otro_activo ámbito unidad lista: alguna unidad del mismo grupo está activa
  for o in $3; do
    [ "$o" != "$2" ] && [ "$(grupo "$o")" = "$(grupo "$2")" ] && [ "$(ctl "$1" is-active "$o" 2>/dev/null)" = active ] && return 0
  done
  return 1
}
# habilitado, detenido (no arrancando), sin una condición que lo excluya en este equipo y sin un socket que lo arranque al usarlo
falta() {
  [ "$(ctl "$1" is-enabled "$2" 2>/dev/null)" = enabled ] || return 1
  case $(ctl "$1" is-active "$2" 2>/dev/null) in inactive|failed) ;; *) return 1 ;; esac
  [ "$(ctl "$1" show -p ConditionResult --value "$2" 2>/dev/null)" = no ] &&
    [ "$(ctl "$1" show -p ConditionTimestampMonotonic --value "$2" 2>/dev/null)" != 0 ] && return 1
  case $2 in *.service) [ "$(ctl "$1" is-active "${2%.service}.socket" 2>/dev/null)" = active ] && return 1 ;; esac
  return 0
}
detenidos() {  # una línea «ámbito unidad» por cada servicio esencial que debería estar activo y no lo está (uno por grupo)
  vistos=" "
  for u in $SISTEMA; do
    case $vistos in *" $(grupo "$u") "*) continue ;; esac
    falta sistema "$u" && ! otro_activo sistema "$u" "$SISTEMA" && { echo "sistema $u"; vistos="$vistos$(grupo "$u") "; }
  done
  con_sesion || return 0
  for u in $PERSONA; do
    case $vistos in *" $(grupo "$u") "*) continue ;; esac
    falta persona "$u" && ! otro_activo persona "$u" "$PERSONA" && { echo "persona $u"; vistos="$vistos$(grupo "$u") "; }
  done
}
para_que() {
  case $1 in
    cups*) echo "impresión" ;; NetworkManager*|systemd-networkd*) echo "red" ;; systemd-resolved*) echo "DNS (nombres de sitios web)" ;;
    *timesyncd*|chrony*) echo "hora automática" ;; pipewire*|wireplumber*|pulseaudio*) echo "sonido" ;; *) echo "búsqueda de archivos" ;;
  esac
}
lista() { while read -r _ u; do echo "- ${u%.*} ($(para_que "$u"))"; done; }

case ${1:-} in
diagnosticar)
  command -v systemctl >/dev/null || { echo "No puedo revisar los servicios en este equipo (no usa systemd)."; exit 1; }
  d=$(detenidos)
  if [ -z "$d" ]; then
    echo "Los servicios esenciales (impresión, red, DNS, hora$(con_sesion && echo ", sonido, búsqueda")) están funcionando."
    con_sesion || echo "No revisé el sonido ni la búsqueda porque no encontré tu sesión abierta en este equipo."
    exit 10
  fi
  echo "Hay $(echo "$d" | wc -l) servicio(s) esencial(es) detenido(s) que deberían estar activos:"
  echo "$d" | head -6 | lista
  echo "Los volvería a iniciar; no toco ningún otro servicio."
  exit 0 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para iniciar servicios."; exit 3; }
  [ -n "$(detenidos)" ] || { echo "Ya no hay servicios esenciales detenidos."; exit 3; }
  exit 0 ;;
aplicar)
  ok=0 mal=""
  while read -r a u; do
    [ -n "$u" ] || continue
    ctl "$a" reset-failed "$u" 2>/dev/null
    if ctl "$a" start "$u" 2>/dev/null; then ok=$((ok + 1)); else mal="$mal ${u%.*}"; fi
  done <<< "$(detenidos)"
  [ -z "$mal" ] || { echo "Inicié $ok servicio(s), pero no arrancaron:$mal. Avisa a soporte para que lo revise."; exit 1; }
  echo "Volví a iniciar $ok servicio(s) esencial(es)."
  exit 0 ;;
verificar)
  sleep 2
  d=$(detenidos)
  [ -z "$d" ] || { echo "Todavía hay servicios esenciales detenidos:"; echo "$d" | head -6 | lista; exit 1; }
  echo "Los servicios esenciales están funcionando."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
