#!/bin/bash
# Ver las extensiones del navegador: lista las de Chrome, Edge, Brave, Chromium y Firefox de la persona (leyendo sus
# perfiles con JavaScript de osascript, que viene con macOS) y las de Safari (pluginkit, en su sesión). Solo lectura,
# con el usuario de la persona: termina con 10. Bash 3.2.
set -u
usuario=${HP_USUARIO:-}
casa=$([ -n "$usuario" ] && dscl . -read "/Users/$usuario" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
uid=$([ -n "$usuario" ] && id -u "$usuario" 2>/dev/null)
# recibe la carpeta personal; devuelve una línea por perfil con extensiones
LEER='
ObjC.import("Foundation");
function run(argv) {
  var casa = argv[0], fm = $.NSFileManager.defaultManager, salida = [];
  var AS = casa + "/Library/Application Support/";
  var CHROMES = [["Chrome", "Google/Chrome"], ["Edge", "Microsoft Edge"], ["Brave", "BraveSoftware/Brave-Browser"], ["Chromium", "Chromium"]];
  function leer(r) { var t = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(r, $.NSUTF8StringEncoding, null)); if (typeof t !== "string") throw new Error("no"); return JSON.parse(t.replace(/^﻿/, "")); }
  function carpetas(d) {
    var l = ObjC.deepUnwrap(fm.contentsOfDirectoryAtPathError(d, null)) || [];
    return l.filter(function (x) { var dir = Ref(); return fm.fileExistsAtPathIsDirectory(d + "/" + x, dir) && dir[0]; }).sort();
  }
  function nombreChrome(d) {
    var v = carpetas(d); if (!v.length) return null;
    d = d + "/" + v[v.length - 1];
    var m = leer(d + "/manifest.json");
    if (m.theme) return null;
    var n = m.name || "", r = /^__MSG_(.+)__$/.exec(n);
    if (r) {
      var clave = r[1].toLowerCase(), locs = ["es", "es_419", m.default_locale, "en", "en_US"];
      for (var i = 0; i < locs.length; i++) {
        if (!locs[i]) continue;
        try { var msj = leer(d + "/_locales/" + locs[i] + "/messages.json"); } catch (e) { continue; }
        for (var k in msj) if (k.toLowerCase() === clave && msj[k].message) return msj[k].message;
      }
    }
    return n;
  }
  function anotar(nav, nombres) {
    if (!nombres.length) return;
    var extra = nombres.length > 8 ? " y " + (nombres.length - 8) + " más" : "";
    salida.push(nav + ": " + nombres.slice(0, 8).join(", ") + extra + ".");
  }
  CHROMES.forEach(function (c) {
    var base = AS + c[1];
    var perfiles = carpetas(base).filter(function (p) { return /^(Default|Profile \d+)$/.test(p); });
    perfiles.forEach(function (p) {
      var nombres = carpetas(base + "/" + p + "/Extensions").map(function (id) {
        try { return nombreChrome(base + "/" + p + "/Extensions/" + id); } catch (e) { return id; }
      }).filter(function (x) { return x; });
      anotar(perfiles.length > 1 ? c[0] + " (perfil " + p + ")" : c[0], nombres);
    });
  });
  var ff = AS + "Firefox/Profiles", perfiles = carpetas(ff);
  perfiles.forEach(function (p) {
    try { var addons = leer(ff + "/" + p + "/extensions.json").addons || []; } catch (e) { return; }
    var nombres = addons.filter(function (a) { return a.type === "extension" && ["app-builtin", "app-system-defaults"].indexOf(a.location) < 0; })
      .map(function (a) { var n = (a.defaultLocale && a.defaultLocale.name) || a.id; return a.active ? n : n + " (desactivada)"; });
    anotar(perfiles.length > 1 ? "Firefox (perfil " + p.replace(/^[^.]*\./, "") + ")" : "Firefox", nombres);
  });
  return salida.join("\n");
}
'

puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -d "$casa" ] && [ -n "$uid" ]; } || { echo "No sé qué persona lo pide."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo revisar el navegador de otra persona."; return 1; }
}
como() { if [ "$(id -u)" -eq 0 ]; then sudo -u "$usuario" "$@"; else "$@"; fi; }
sesion() { if [ "$(id -u)" -eq 0 ]; then launchctl asuser "$uid" sudo -u "$usuario" "$@"; else "$@"; fi; }
# extensiones de Safari: el nombre de la app que las trae (lo que la persona ve en Safari > Ajustes > Extensiones)
safari() {
  for p in com.apple.Safari.web-extension com.apple.Safari.content-blocker com.apple.Safari.extension; do
    sesion pluginkit -mAv -p "$p" 2>/dev/null
  done | grep -o '/[^/]*\.app/Contents/PlugIns/' | sed 's#^/##; s#\.app/Contents/PlugIns/$##' | sort -u | paste -sd, - | sed 's/,/, /g'
}

case ${1:-} in
diagnosticar)
  puedo || exit 3
  r=$(como osascript -l JavaScript -e "$LEER" "$casa" 2>/dev/null)
  s=$(safari)
  [ -n "$s" ] && r="${r}${r:+
}Safari: $s."
  if [ -z "$r" ]; then echo "No encontré extensiones en tus navegadores."; exit 10; fi
  echo "Encontré extensiones en $(printf '%s\n' "$r" | grep -c .) navegador(es) o perfil(es):"
  printf '%s\n' "$r" | head -7 | sed 's/^/- /'
  echo "Si alguna no la reconoces o no la instalaste tú, quítala desde los ajustes de extensiones del navegador o pide ayuda a soporte."
  exit 10 ;;
*) echo "Este procedimiento solo revisa; no cambia nada."; exit 2 ;;
esac
