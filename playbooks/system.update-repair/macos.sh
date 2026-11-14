#!/bin/bash
# Reparar Actualización de software de macOS sin instalar nada:
# - si quedó configurado un servidor de actualizaciones que no es el de Apple (CatalogURL puesto a mano), lo quita
#   (softwareupdate --clear-catalog); si lo puso la empresa con un perfil (MDM), no se toca;
# - vuelve a arrancar el servicio de actualizaciones (softwareupdated; launchd lo abre de nuevo al usarlo);
# - comprueba que responde buscando actualizaciones (softwareupdate --list: busca, no descarga ni instala).
# La falta de espacio se informa (eso lo arregla «Liberar espacio en disco»). Bash 3.2, sin timeout: se usa tope.
set -u
PREF=/Library/Preferences/com.apple.SoftwareUpdate
GESTIONADA="/Library/Managed Preferences/com.apple.SoftwareUpdate"
vol=/System/Volumes/Data; [ -d "$vol" ] || vol=/

tope() {  # corre «$2...» con un tope de $1 segundos (macOS no trae timeout); sale con 124 si se cortó
  local s=$1; shift
  "$@" & local p=$!
  ( sleep "$s"; pkill -P "$p"; kill "$p" ) >/dev/null 2>&1 &
  local v=$!
  wait "$p"; local c=$?
  if kill -0 "$v" 2>/dev/null; then kill "$v" 2>/dev/null; else c=124; fi
  return "$c"
}
# una instalación en curso (por la línea de órdenes, un instalador o el asistente de macOS)
ocupado() { pgrep -x 'softwareupdate|installer|InstallAssistant|osinstallersetupd|startosinstall' >/dev/null; }
gestionado() { defaults read "$GESTIONADA" CatalogURL >/dev/null 2>&1; }
propio() { defaults read "$PREF" CatalogURL >/dev/null 2>&1 && ! gestionado; }  # servidor puesto a mano
responde() {  # el servicio contesta a una búsqueda (con o sin actualizaciones pendientes)
  local t c; t=$(mktemp) || return 1
  tope 240 softwareupdate --list >"$t" 2>&1
  grep -qE 'No new software available|Label:|Title:' "$t"; c=$?
  rm -f "$t"; return "$c"
}
espacio() {
  local g; g=$(df -g "$vol" 2>/dev/null | awk 'NR == 2 {print $4 + 0}')
  [ "${g:-99}" -lt 20 ] && echo "Quedan solo $g GB libres y las actualizaciones de macOS suelen necesitar unos 20 GB: pídeme liberar espacio en disco."
}

case ${1:-} in
diagnosticar)
  command -v softwareupdate >/dev/null || { echo "No encuentro la herramienta de actualizaciones de macOS (softwareupdate)."; exit 1; }
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para revisar las actualizaciones."; exit 3; }
  ocupado && { echo "Hay una instalación o actualización en curso: espera a que termine y vuelve a intentarlo."; exit 1; }
  r=""
  propio && r="El Mac busca actualizaciones en un servidor que no es el de Apple (quedó configurado aparte).
"
  responde || r="${r}El servicio de actualizaciones no responde bien al buscar actualizaciones.
"
  if [ -n "$r" ]; then
    echo "Encontré lo que puede hacer fallar las actualizaciones:"; printf '%s' "$r"
    gestionado && echo "Tu empresa dirige las actualizaciones a su propio servidor (perfil de gestión): eso no lo toco."
    espacio
    echo "Puedo repararlo sin instalar nada nuevo: quito ese servidor, si lo hay, y reinicio el servicio de actualizaciones."
    exit 0
  fi
  if gestionado; then echo "El servicio de actualizaciones responde bien; usa el servidor de tu empresa (perfil de gestión)."; else echo "El servicio de actualizaciones responde bien y usa el servidor de Apple."; fi
  espacio
  echo "Si las actualizaciones siguen fallando, dale a soporte el mensaje de error exacto."
  exit 10 ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para reparar las actualizaciones."; exit 3; }
  command -v softwareupdate >/dev/null || { echo "No encuentro la herramienta de actualizaciones de macOS."; exit 3; }
  ocupado && { echo "Hay una instalación o actualización en curso: espera a que termine."; exit 3; }
  exit 0 ;;
aplicar)
  ocupado && { echo "Hay una instalación o actualización en curso: no toqué nada."; exit 1; }
  if propio; then
    softwareupdate --clear-catalog >/dev/null 2>&1
    propio && defaults delete "$PREF" CatalogURL >/dev/null 2>&1
    propio && { echo "No pude quitar el servidor de actualizaciones que quedó configurado: lo tiene que ver soporte."; exit 1; }
  fi
  launchctl kickstart -k system/com.apple.softwareupdated >/dev/null 2>&1 || killall softwareupdated >/dev/null 2>&1
  sleep 3
  echo "Reparé el servicio de actualizaciones sin instalar nada nuevo."
  exit 0 ;;
verificar)
  propio && { echo "Sigue configurado un servidor de actualizaciones que no es el de Apple."; exit 1; }
  responde || { echo "El servicio de actualizaciones sigue sin responder. Revisa que tengas Internet; si lo tienes, avisa a soporte."; exit 1; }
  echo "El servicio de actualizaciones responde bien. Ya puedes volver a intentar la actualización."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
