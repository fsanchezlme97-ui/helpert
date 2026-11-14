#!/bin/bash
# Reconstruir el índice de Spotlight del disco del sistema (mdutil -E: lo borra y Spotlight lo vuelve a llenar solo).
# Si la indexación está apagada (puede ser decisión de soporte o de la empresa), no se enciende.
set -u

estado() { mdutil -s / 2>/dev/null; }

case ${1:-} in
diagnosticar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para revisar Spotlight."; exit 3; }
  command -v mdutil >/dev/null || { echo "Falta la herramienta mdutil de Spotlight."; exit 1; }
  case $(estado) in
  *"Indexing enabled"*)
    echo "La búsqueda de Spotlight está activada."
    echo "Si sigo, borro su índice y lo vuelve a crear desde cero: tarda un rato (hasta horas si tienes muchos archivos) y mientras tanto la búsqueda encuentra menos."
    exit 0 ;;
  *disabled*) echo "Spotlight tiene la indexación apagada en este equipo (puede ser decisión de soporte o de la empresa): no la cambio."; exit 3 ;;
  *) echo "No pude ver el estado de Spotlight."; exit 1 ;;
  esac ;;
comprobar)
  [ "$(id -u)" -eq 0 ] || { echo "Helpert necesita privilegios de administrador para reconstruir Spotlight."; exit 3; }
  case $(estado) in *"Indexing enabled"*) exit 0 ;; esac
  echo "La indexación de Spotlight no está activada."; exit 3 ;;
aplicar)
  mdutil -E / >/dev/null 2>&1 || { echo "No pude borrar el índice de Spotlight."; exit 1; }
  echo "Borré el índice de Spotlight; se está volviendo a llenar. Dale un rato antes de buscar de nuevo."
  exit 0 ;;
verificar)
  case $(estado) in *"Indexing enabled"*) echo "Spotlight está activado y rehaciendo su índice: irá encontrando más archivos a medida que termine."; exit 0 ;; esac
  echo "Spotlight no quedó activado."; exit 1 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
