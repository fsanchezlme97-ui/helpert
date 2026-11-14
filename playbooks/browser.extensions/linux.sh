#!/bin/bash
# Ver las extensiones del navegador: lista las de Firefox, Chrome, Chromium, Edge y Brave de la persona (también Flatpak
# y Snap). Solo lectura, con el usuario de la persona: termina con 10. Necesita python3 para leer los JSON de los perfiles.
set -u
usuario=${HP_USUARIO:-}
casa=$([ -n "$usuario" ] && getent passwd "$usuario" | cut -d: -f6)
# recibe la carpeta personal; escribe una línea por perfil con extensiones y una primera línea con el total
LEER='
import json, os, sys
casa = sys.argv[1]
CHROMES = [("Chrome", ".config/google-chrome"), ("Chrome", ".var/app/com.google.Chrome/config/google-chrome"),
           ("Chromium", ".config/chromium"), ("Chromium", "snap/chromium/common/chromium"),
           ("Chromium", ".var/app/org.chromium.Chromium/config/chromium"), ("Edge", ".config/microsoft-edge"),
           ("Brave", ".config/BraveSoftware/Brave-Browser"), ("Brave", ".var/app/com.brave.Browser/config/BraveSoftware/Brave-Browser")]
FIREFOX = [".mozilla/firefox", ".config/mozilla/firefox", "snap/firefox/common/.mozilla/firefox", ".var/app/org.mozilla.firefox/.mozilla/firefox"]
def leer(r):
    with open(r, encoding="utf-8-sig") as f: return json.load(f)
def carpetas(d):
    try: return sorted(x for x in os.listdir(d) if os.path.isdir(os.path.join(d, x)))
    except OSError: return []
def nombre_chrome(d):  # d: Extensions/<id>; el nombre puede venir traducido (__MSG_clave__)
    v = carpetas(d)
    if not v: return None
    d = os.path.join(d, v[-1])
    m = leer(os.path.join(d, "manifest.json"))
    if "theme" in m: return None
    n = m.get("name", "")
    if n.startswith("__MSG_") and n.endswith("__"):
        clave = n[6:-2].lower()
        for loc in ("es", "es_419", m.get("default_locale"), "en", "en_US"):
            try: msj = leer(os.path.join(d, "_locales", loc or "-", "messages.json"))
            except Exception: continue
            for k, val in msj.items():
                if k.lower() == clave: return val.get("message", n)
    return n
salida = []
total = 0
def anotar(nav, nombres):
    global total
    total += len(nombres)
    if nombres:
        extra = " y %d más" % (len(nombres) - 8) if len(nombres) > 8 else ""
        salida.append("%s: %s%s." % (nav, ", ".join(nombres[:8]), extra))
for nav, rel in CHROMES:
    base = os.path.join(casa, rel)
    perfiles = [p for p in carpetas(base) if p == "Default" or p.startswith("Profile ")]
    for p in perfiles:
        nombres = []
        for i in carpetas(os.path.join(base, p, "Extensions")):
            try: n = nombre_chrome(os.path.join(base, p, "Extensions", i))
            except Exception: n = i
            if n: nombres.append(n)
        anotar(nav if len(perfiles) == 1 else "%s (perfil %s)" % (nav, p), nombres)
for rel in FIREFOX:
    base = os.path.join(casa, rel)
    perfiles = [p for p in carpetas(base) if os.path.isfile(os.path.join(base, p, "extensions.json"))]
    for p in perfiles:
        try: addons = leer(os.path.join(base, p, "extensions.json")).get("addons", [])
        except Exception: continue
        nombres = []
        for a in addons:
            if a.get("type") != "extension" or a.get("location") in ("app-builtin", "app-system-defaults"): continue
            n = (a.get("defaultLocale") or {}).get("name") or a.get("id", "?")
            nombres.append(n if a.get("active") else n + " (desactivada)")
        anotar("Firefox" if len(perfiles) == 1 else "Firefox (perfil %s)" % p.split(".", 1)[-1], nombres)
if total == 0:
    print("No encontré extensiones en tus navegadores.")
else:
    print("Encontré %d extensión(es) en tus navegadores:" % total)
    for l in salida[:7]: print("- " + l)
    if len(salida) > 7: print("- y %d perfil(es) más." % (len(salida) - 7))
    print("Si alguna no la reconoces o no la instalaste tú, quítala desde el menú de extensiones del navegador o pide ayuda a soporte.")
'

puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo revisar el navegador de otra persona."; return 1; }
}
como() { if [ "$(id -u)" -eq 0 ]; then runuser -u "$usuario" -- "$@"; else "$@"; fi; }

case ${1:-} in
diagnosticar)
  puedo || exit 3
  command -v python3 >/dev/null || { echo "No puedo leer las extensiones: a este equipo le falta python3. Pide a soporte que lo revise."; exit 1; }
  r=$(como python3 -I -c "$LEER" "$casa" 2>/dev/null)
  [ -n "$r" ] || { echo "No pude leer los perfiles de tus navegadores."; exit 1; }
  echo "$r"
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
