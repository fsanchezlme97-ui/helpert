#!/bin/bash
# Reconstruir el índice de búsqueda de la persona: LocalSearch / Tracker 3 (GNOME) con «reset -s», o Baloo (KDE) con
# «purge»; el indexador vuelve a llenarlo solo. Todo en la sesión de la persona (runuser + su bus de sesión), nunca
# como root. Si el escritorio no usa índice (la búsqueda recorre las carpetas cada vez), no aplica.
set -u
usuario=${HP_USUARIO:-}
casa=$(getent passwd "$usuario" | cut -d: -f6)
uid=$(id -u "$usuario" 2>/dev/null)

sesion() {
  if [ "$(id -u)" -eq 0 ]; then runuser -u "$usuario" -- env HOME="$casa" XDG_RUNTIME_DIR="/run/user/$uid" DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$uid/bus" "$@"
  else "$@"; fi
}
puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$uid" ] && [ -n "$casa" ] && [ "$casa" != / ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo tocar la sesión de otra persona."; return 1; }
}
corriendo() { pgrep -u "$uid" '^(localsearch|tracker-miner-f|baloo_file)' >/dev/null; }
indexador() {  # el que está funcionando en su sesión; si ninguno, el que esté instalado
  local p; p=$(ps -o comm= -u "$uid" 2>/dev/null | grep -Eo '^(localsearch|tracker-miner-f|baloo_file)' | head -1)
  case $p in
  localsearch) echo localsearch ;; tracker-miner-f) echo tracker3 ;;
  baloo_file) command -v balooctl6 >/dev/null && echo balooctl6 || echo balooctl ;;
  *) for c in localsearch tracker3 balooctl6 balooctl; do command -v "$c" >/dev/null && { echo "$c"; return; }; done ;;
  esac
}
indice() { case $1 in balooctl*) echo "$casa/.local/share/baloo" ;; *) echo "$casa/.cache/tracker3/files" ;; esac; }
sin_sesion() { [ -S "/run/user/$uid/bus" ] || { echo "Necesito que tengas la sesión abierta en este equipo para reconstruir tu búsqueda."; return 0; }; return 1; }

case ${1:-} in
diagnosticar)
  puedo || exit 3
  i=$(indexador)
  [ -n "$i" ] || { echo "Tu escritorio no usa un índice de búsqueda: la búsqueda revisa las carpetas cada vez, así que no hay nada que reconstruir."; exit 3; }
  sin_sesion && exit 3
  mb=$(sesion du -sm "$(indice "$i")" 2>/dev/null | cut -f1)
  echo "La búsqueda de archivos usa un índice${mb:+ que ocupa $mb MB}$(corriendo || echo ', pero el indexador no está funcionando ahora')."
  echo "Si sigo, lo borro y se vuelve a llenar solo: tarda un rato (hasta horas si tienes muchos archivos) y mientras tanto la búsqueda encuentra menos."
  exit 0 ;;
comprobar)
  puedo || exit 3
  [ -n "$(indexador)" ] || { echo "Tu escritorio no usa un índice de búsqueda."; exit 3; }
  sin_sesion && exit 3
  exit 0 ;;
aplicar)
  puedo || exit 1
  sin_sesion && exit 1
  i=$(indexador)
  case $i in
  localsearch|tracker3)
    sesion "$i" reset -s </dev/null >/dev/null 2>&1 || { echo "No pude borrar el índice de búsqueda."; exit 1; }
    sesion systemctl --user start localsearch-3.service >/dev/null 2>&1 || sesion systemctl --user start tracker-miner-fs-3.service >/dev/null 2>&1 ;;
  balooctl*)
    sesion "$i" purge </dev/null >/dev/null 2>&1 || { echo "No pude borrar el índice de búsqueda."; exit 1; }
    corriendo || sesion "$i" enable >/dev/null 2>&1 ;;
  *) echo "Tu escritorio no usa un índice de búsqueda."; exit 1 ;;
  esac
  echo "Borré el índice de búsqueda; se está volviendo a llenar. Dale un rato antes de buscar de nuevo."
  exit 0 ;;
verificar)
  puedo || exit 1
  for _ in 1 2 3 4 5 6 7 8 9 10; do corriendo && break; sleep 1; done
  corriendo || { echo "El indexador de búsqueda no volvió a arrancar: cierra sesión y vuelve a entrar."; exit 1; }
  echo "El indexador está trabajando: la búsqueda irá encontrando más archivos a medida que termine."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
