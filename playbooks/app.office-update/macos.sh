#!/bin/bash
# Actualizar Microsoft Office: pide a Microsoft AutoUpdate (msupdate --install, en la sesión de la persona, como ella)
# que instale las actualizaciones de las apps de Microsoft ya instaladas. Lo que esté abierto termina de actualizarse
# al cerrarlo. AutoUpdate respeta lo que la empresa configure por MDM. Bash 3.2.
set -u
MSU='/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/msupdate'
usuario=${HP_USUARIO:-}
uid=$([ -n "$usuario" ] && id -u "$usuario" 2>/dev/null)

puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$uid" ]; } || { echo "No sé qué persona lo pide."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo actualizar la cuenta de otra persona."; return 1; }
}
# en la sesión gráfica de la persona, con su usuario
sesion() { if [ "$(id -u)" -eq 0 ]; then launchctl asuser "$uid" sudo -u "$usuario" "$@"; else "$@"; fi; }
con_sesion() { [ "$(id -u)" -ne 0 ] || launchctl print "gui/$uid" >/dev/null 2>&1; }
version() {  # de la primera app de Office que encuentre
  for a in "Microsoft Word" "Microsoft Excel" "Microsoft Outlook" "Microsoft PowerPoint"; do
    [ -d "/Applications/$a.app" ] && { defaults read "/Applications/$a.app/Contents/Info" CFBundleShortVersionString 2>/dev/null; return; }
  done
}

case ${1:-} in
diagnosticar)
  puedo || exit 3
  [ -x "$MSU" ] || { echo "No encontré Microsoft AutoUpdate en este equipo: si tienes Office, lo actualiza la App Store o soporte."; exit 3; }
  v=$(version)
  [ -n "$v" ] || { echo "No encontré Microsoft Office instalado en este equipo."; exit 3; }
  echo "Tienes Microsoft Office, versión $v. Puedo pedirle a Microsoft AutoUpdate que instale sus actualizaciones; puede tardar varios minutos."
  echo "Lo que tengas abierto termina de actualizarse cuando lo cierres."
  exit 0 ;;
comprobar)
  puedo || exit 3
  [ -x "$MSU" ] || { echo "No encontré Microsoft AutoUpdate en este equipo."; exit 3; }
  con_sesion || { echo "Necesito que tengas la sesión abierta en este equipo para actualizar Office."; exit 3; }
  exit 0 ;;
aplicar)
  puedo || exit 1
  con_sesion || { echo "Necesito que tengas la sesión abierta en este equipo para actualizar Office."; exit 1; }
  sesion "$MSU" --install >/dev/null 2>&1 || { echo "Microsoft AutoUpdate no pudo instalar las actualizaciones. Revisa que haya internet y vuelve a intentarlo; si sigue, avisa a soporte."; exit 1; }
  echo "Instalé las actualizaciones de Office. Si algún programa de Office estaba abierto, ciérralo y ábrelo de nuevo para terminar."
  exit 0 ;;
verificar)
  puedo || exit 1
  [ -x "$MSU" ] || { echo "Microsoft AutoUpdate ya no está en el equipo: avisa a soporte."; exit 1; }
  if sesion "$MSU" --list 2>/dev/null | grep -qi 'no updates available'; then echo "Listo: Office está al día (versión $(version))."
  else echo "Office tiene actualizaciones listas que terminan de aplicarse cuando cierres sus programas."; fi
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
