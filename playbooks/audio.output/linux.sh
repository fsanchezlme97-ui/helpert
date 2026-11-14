#!/bin/bash
# Recuperar el sonido (PipeWire con wpctl; PulseAudio con pactl). Todo corre en la sesión de la persona, nunca como root.
set -u
DEF=@DEFAULT_AUDIO_SINK@ PA=sink PADEF=@DEFAULT_SINK@ QUE="La salida de sonido"

usuario=${HP_USUARIO:-}
uid=$(id -u "$usuario" 2>/dev/null)
sesion() {  # como root: con el usuario de la persona y su carpeta de sesión (ahí están los sockets del sonido)
  if [ "$(id -u)" -eq 0 ]; then runuser -u "$usuario" -- env XDG_RUNTIME_DIR="/run/user/$uid" "$@"; else "$@"; fi
}
puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$uid" ]; } || { echo "No sé qué persona lo pide."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo revisar la sesión de otra persona."; return 1; }
}
wp() { command -v wpctl >/dev/null && sesion wpctl status >/dev/null 2>&1; }
vol() {  # «volumen silencio»: volumen en % entero, silencio 0/1; nada si el servicio de sonido no responde
  if wp; then
    sesion wpctl get-volume "$DEF" 2>/dev/null | awk '{printf "%d %d\n", $2 * 100 + 0.5, /MUTED/ ? 1 : 0}'
  else
    v=$(sesion pactl "get-$PA-volume" "$PADEF" 2>/dev/null | grep -o '[0-9]*%' | head -1 | tr -d %)
    m=$(sesion pactl "get-$PA-mute" "$PADEF" 2>/dev/null | grep -q yes && echo 1 || echo 0)
    [ -n "$v" ] && echo "$v $m"
  fi
}

case ${1:-} in
diagnosticar)
  puedo || exit 3
  read -r v m <<< "$(vol)"
  [ -n "${v:-}" ] || { echo "El servicio de sonido de tu sesión no responde."; exit 0; }
  [ "$m" = 0 ] && [ "$v" -ge 20 ] && { echo "$QUE no está silenciada y su volumen es $v %."; exit 10; }
  [ "$m" = 1 ] && echo "$QUE está silenciada."
  [ "$v" -lt 20 ] && echo "$QUE está al $v %."
  exit 0 ;;
comprobar)
  puedo || exit 3
  exit 0 ;;
aplicar)
  if [ -z "$(vol)" ]; then
    sesion systemctl --user restart wireplumber pipewire pipewire-pulse 2>/dev/null || sesion systemctl --user restart pulseaudio 2>/dev/null
    sleep 3
  fi
  if wp; then
    sesion wpctl set-mute "$DEF" 0
    read -r v _ <<< "$(vol)"; [ "${v:-0}" -lt 20 ] && sesion wpctl set-volume "$DEF" 0.6
  else
    sesion pactl "set-$PA-mute" "$PADEF" 0
    read -r v _ <<< "$(vol)"; [ "${v:-0}" -lt 20 ] && sesion pactl "set-$PA-volume" "$PADEF" 60%
  fi
  echo "Quité el silencio y dejé el volumen en un nivel audible."
  exit 0 ;;
verificar)
  read -r v m <<< "$(vol)"
  { [ -n "${v:-}" ] && [ "$m" = 0 ] && [ "$v" -ge 20 ]; } || { echo "$QUE sigue silenciada o sin responder."; exit 1; }
  echo "$QUE funciona: volumen $v %, sin silencio. Si aún no oyes nada, revisa que estén conectados los parlantes o audífonos que usas."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
