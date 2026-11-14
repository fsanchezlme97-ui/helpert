#!/bin/bash
# Probar si un sitio o sistema responde: el nombre (DNS), la conexión (https y, si no, http) y el certificado.
# Prueba directa, sin el proxy de la persona. Solo revisa: termina con 10.
set -u
sitio=$(printf '%s' "${HP_SITIO:-}" | tr 'A-Z' 'a-z' | sed 's/^\.*//; s/\.*$//')
# código HTTP en la salida y el de curl como estado: 0 bien, 6 nombre, 7 sin conexión, 28 sin respuesta, 35/51/60 TLS
web() { curl -s -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 15 "$1" 2>/dev/null; }
certificado() {  # el certificado que da el sitio (PEM)
  timeout 10 openssl s_client -connect "$sitio:443" -servername "$sitio" </dev/null 2>/dev/null | sed -n '/-BEGIN CERT/,/-END CERT/p'
}

case ${1:-} in
diagnosticar)
  case $sitio in ''|-*|*..*) echo "Necesito la dirección del sitio, por ejemplo intranet.empresa.pe."; exit 1 ;; esac
  command -v curl >/dev/null || { echo "Falta la herramienta curl en este equipo para probar el sitio."; exit 1; }
  ips=$(timeout 8 getent ahosts "$sitio" 2>/dev/null | awk '!v[$1]++ {print $1}' | head -3 | paste -sd ' ' -)
  if [ -z "$ips" ]; then
    echo "Falla el nombre: el equipo no encuentra la dirección de $sitio."
    echo "Revisa que esté bien escrito. Si es un sistema de la empresa, puede que solo funcione en la red de la oficina o con la VPN."
    exit 10
  fi
  codigo=$(web "https://$sitio/"); e=$?
  case $e in
  0)
    case $codigo in
    5*) echo "$sitio responde, pero con un error del propio sitio (código $codigo): el problema es del sitio, no de tu equipo. Avisa a soporte." ;;
    401|403) echo "$sitio responde bien, pero te pide permiso para entrar (código $codigo): si no tienes acceso, lo pide soporte." ;;
    *) echo "$sitio responde bien: el nombre, la conexión y el certificado están correctos." ;;
    esac
    echo "Si no abre en tu navegador, prueba «Limpiar la caché de nombres» o «Revisar el proxy del equipo»." ;;
  35|51|58|59|60|77|83|90|91)
    pem=$(certificado)
    if [ -n "$pem" ] && ! printf '%s\n' "$pem" | openssl x509 -noout -checkend 0 >/dev/null 2>&1; then
      fin=$(printf '%s\n' "$pem" | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
      echo "Falla el certificado: el de $sitio venció${fin:+ ($fin)}. Lo tiene que renovar quien administra el sitio; avisa a soporte."
    else
      echo "Falla el certificado: el de $sitio no es de confianza para este equipo o no corresponde a esa dirección."
      echo "Si es un sistema de la empresa, puede que falte instalar su certificado: lo revisa soporte."
    fi ;;
  *)
    if [ "$e" != 6 ] && web "http://$sitio/" >/dev/null; then
      echo "$sitio responde solo sin cifrado (http://$sitio), no por https: prueba esa dirección."
    elif [ "$e" = 28 ]; then
      echo "Falla la conexión: $sitio no responde a tiempo. Puede estar caído o muy lento; si es de la empresa, quizás necesitas la VPN."
    else
      echo "Falla la conexión: el nombre se encuentra, pero el equipo no logra conectarse con $sitio."
      echo "Puede estar caído o bloqueado por un firewall; si es de la empresa, quizás necesitas la VPN. Si sigue así, avisa a soporte."
    fi ;;
  esac
  echo "Dirección de $sitio: $ips."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
