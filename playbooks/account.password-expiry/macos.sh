#!/bin/bash
# Ver cuándo vence la contraseña de la cuenta local de la persona: la regla «vence cada N días» de pwpolicy (de la
# cuenta o general) y la fecha del último cambio (accountPolicyData). Las cuentas del dominio no se consultan desde
# aquí: lo dice. Solo lectura: termina con 10.
set -u
export LC_ALL=C
usuario=${HP_USUARIO:-}
cada() { sed -n '/<key>policyAttributeExpiresEveryNDays<\/key>/{n;s/[^0-9]//g;p;}' | head -1; }

case ${1:-} in
diagnosticar)
  { [ -n "$usuario" ] && dscl . -read "/Users/$usuario" RecordName >/dev/null 2>&1; } || { echo "No sé qué persona lo pide."; exit 3; }
  if dscl . -read "/Users/$usuario" OriginalNodeName 2>/dev/null | grep -q 'Active Directory'; then
    echo "Tu cuenta es de la empresa (dominio): la fecha de vencimiento la lleva el dominio y desde este Mac no la puedo ver."
    echo "Normalmente te avisa al entrar unos días antes. Si necesitas la fecha exacta, pídela a soporte."
    exit 10
  fi
  n=$(pwpolicy -u "$usuario" -getaccountpolicies 2>/dev/null | cada)
  [ -n "$n" ] || n=$(pwpolicy -getaccountpolicies 2>/dev/null | cada)
  [ -n "$n" ] && [ "$n" -gt 0 ] || { echo "Tu contraseña no tiene fecha de vencimiento en este Mac."; exit 10; }
  u=$(dscl . -read "/Users/$usuario" accountPolicyData 2>/dev/null | sed -n '/<key>passwordLastSetTime<\/key>/{n;s/[^0-9.]//g;p;}' | cut -d. -f1 | head -1)
  [ -n "$u" ] || { echo "Tu contraseña vence cada $n día(s), pero no encuentro cuándo la cambiaste por última vez. Pide la fecha a soporte."; exit 10; }
  v=$(( u + n * 86400 )); d=$(( (v - $(date +%s)) / 86400 ))
  if [ "$v" -lt "$(date +%s)" ]; then echo "Tu contraseña venció el $(date -r "$v" '+%d/%m/%Y'): el Mac te pedirá cambiarla."; exit 10; fi
  echo "Tu contraseña vence el $(date -r "$v" '+%d/%m/%Y') (en $d día(s))."
  [ "$d" -le 7 ] && echo "Cámbiala pronto: en Configuración del Sistema > Usuarios y grupos."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
