#!/bin/bash
# Ver los inicios de sesión (en la pantalla del Mac o por red) de los últimos 7 días, con «last», y los intentos
# fallidos que quedaron en el registro unificado (contraseña equivocada, SSH, Compartir pantalla). Solo lectura: 10.
set -u
export LC_ALL=C
limite() { perl -e 'alarm shift; exec @ARGV' "$@"; }  # macOS no trae timeout
PRED='(process == "opendirectoryd" AND eventMessage CONTAINS[c] "authentication failed") OR (process == "screensharingd" AND eventMessage CONTAINS "Authentication: FAILED") OR (process BEGINSWITH "sshd" AND (eventMessage CONTAINS "Failed password" OR eventMessage CONTAINS "Invalid user"))'
# «cuenta mes día hora origen» de cada inicio en la pantalla (console) o por red (con equipo de origen)
sesiones() {
  dias=$(for i in 0 1 2 3 4 5 6; do date -v-"$i"d '+%b %e'; done | awk '{printf "|%s %d", $1, $2} END {print "|"}')
  last 2>/dev/null | awk -v dias="$dias" '{
    for (i = 2; i <= NF; i++) if ($i ~ /^(Mon|Tue|Wed|Thu|Fri|Sat|Sun)$/) break
    if (i > NF || $1 ~ /^(reboot|shutdown|wtmp|_)/) next
    if (index(dias, "|" $(i + 1) " " ($(i + 2) + 0) "|") == 0) next
    if ($2 != "console" && i <= 3) next
    print $1, $(i + 1), $(i + 2), $(i + 3), (i > 3 ? $3 : "")
  }'
}

case ${1:-} in
diagnosticar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para leer el registro de inicios de sesión."; exit 3; }
  s=$(sesiones)
  f=$(limite 45 log show --last 7d --style compact --predicate "$PRED" 2>/dev/null); r=$?
  ns=$(printf '%s' "$s" | grep -c .)
  od=$(printf '%s\n' "$f" | grep -ci 'authentication failed'); ss=$(printf '%s\n' "$f" | grep -c 'Authentication: FAILED')
  sh=$(printf '%s\n' "$f" | grep -cE 'Failed password|Invalid user')
  if [ "$r" -ne 0 ]; then echo "En los últimos 7 días hubo $ns inicio(s) de sesión. No pude revisar los intentos fallidos: el registro tardó demasiado en responder."
  else echo "En los últimos 7 días hubo $ns inicio(s) de sesión y $((od + ss + sh)) intento(s) fallido(s)."; fi
  printf '%s\n' "$s" | awk 'NF {n[$1]++; f[$1] = sprintf("%02d/%02d", $3, (index("JanFebMarAprMayJunJulAugSepOctNovDec", $2) + 2) / 3); h[$1] = $4; por[$1] = $5}
    END {for (u in n) print u, n[u], f[u], h[u], por[u]}' | head -4 |
    while read -r u n d h por; do
      if [ -n "$por" ]; then donde="por red desde $por"; else donde="en la pantalla del Mac"; fi
      echo "- $u: $n inicio(s); el último el $d a las $h, $donde."
    done
  [ "$od" -gt 0 ] && echo "- $od contraseña(s) equivocada(s) en este Mac (al entrar, desbloquear o pedir permisos)."
  [ "$ss" -gt 0 ] && echo "- $ss intento(s) fallido(s) por Compartir pantalla."
  [ "$sh" -gt 0 ] && echo "- $sh intento(s) fallido(s) por red (SSH)."
  echo "macOS guarda un registro limitado: lo más viejo de la semana puede ya no estar."
  [ $((od + ss + sh)) -gt 0 ] && echo "Si no reconoces algún intento, cambia tu contraseña y avisa a soporte."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
