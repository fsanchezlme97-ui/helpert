#!/bin/bash
# Ver cuándo vence la contraseña de la cuenta local de la persona, con los datos de /etc/shadow (sin textos de chage,
# que cambian con el idioma). Las cuentas del dominio no están ahí: lo dice. Solo lectura: termina con 10.
set -u
usuario=${HP_USUARIO:-}
fecha() { date -u -d "@$(( $1 * 86400 ))" '+%d/%m/%Y'; }

case ${1:-} in
diagnosticar)
  { [ -n "$usuario" ] && getent passwd "$usuario" >/dev/null 2>&1; } || { echo "No sé qué persona lo pide."; exit 3; }
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para ver el vencimiento de la contraseña."; exit 3; }
  s=$(getent shadow "$usuario" 2>/dev/null)
  if [ -z "$s" ]; then
    echo "Tu cuenta es de la empresa (dominio): la fecha de vencimiento la lleva el dominio y desde este equipo no la puedo ver."
    echo "Normalmente te avisa al entrar unos días antes. Si necesitas la fecha exacta, pídela a soporte."
    exit 10
  fi
  IFS=: read -r _ _ ultimo _ max _ _ caduca _ <<< "$s"
  hoy=$(( $(date +%s) / 86400 ))
  if [ "${ultimo:-x}" = 0 ]; then echo "Tienes que cambiar tu contraseña la próxima vez que entres al equipo."
  elif [ -z "$ultimo" ] || [ -z "$max" ] || [ "$max" -ge 99999 ]; then echo "Tu contraseña no tiene fecha de vencimiento en este equipo."
  else
    v=$(( ultimo + max )); d=$(( v - hoy ))
    if [ "$d" -lt 0 ]; then echo "Tu contraseña venció el $(fecha "$v"): el equipo te pedirá cambiarla al entrar."
    else
      echo "Tu contraseña vence el $(fecha "$v") (en $d día(s))."
      [ "$d" -le 7 ] && echo "Cámbiala pronto: en Configuración > Usuarios, o con la orden «passwd» en una terminal."
    fi
  fi
  [ -n "$caduca" ] && echo "Además, tu cuenta deja de funcionar el $(fecha "$caduca"); para extenderla, habla con soporte."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
