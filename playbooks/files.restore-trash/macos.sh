#!/bin/bash
# Recuperar de la papelera de macOS (~/.Trash). La carpeta de origen solo la guarda el Finder, en ~/.Trash/.DS_Store
# (formato sin documentar): registros «nombre en la papelera, ptbL, ustr, carpeta» y «…, ptbN, ustr, nombre original»
# (largo de 4 bytes en caracteres y texto UTF-16BE). Se buscan esos registros por su marca, sin recorrer el árbol.
# Lo que no tiene registro (borrado con rm o por un programa) se queda donde está y se dice: nunca se inventa un destino.
# Todo con los permisos de la persona (sudo -u). macOS protege la papelera: sin «Acceso total al disco» no se puede leer.
# HP_NOMBRE ya viene validado: letras, números, punto, guion y guion bajo (sin comodines). Bash 3.2.
set -u
usuario=${HP_USUARIO:-}
nombre=${HP_NOMBRE:-}
casa=$(dscl . -read "/Users/$usuario" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p')
T="$casa/.Trash"
# argumentos: papelera y palabra. Escribe «nombre en la papelera<TAB>ruta original» (vacía si no se sabe), lo último
# que entró primero (por la fecha de cambio, que pone el traslado a la papelera)
LEER='use Encode; use Unicode::Normalize;
my ($T, $q) = @ARGV; my $d = ""; my (%l, %n);
if (open(my $f, "<:raw", "$T/.DS_Store")) { local $/; $d = <$f> // "" }
while ($d =~ /ptb([LN])ustr/g) {
  my ($t, $p) = ($1, pos($d) - 8);
  for my $k (1 .. 1024) {  # el nombre va justo antes: su largo k (4 bytes) y 2k bytes de texto
    my $i = $p - 2 * $k - 4; last if $i < 0;
    next if unpack("N", substr($d, $i, 4)) != $k;
    my $m = unpack("N", substr($d, $p + 8, 4)); last if $m > 4096 || $p + 12 + 2 * $m > length $d;
    my $clave = NFC(decode("UTF-16BE", substr($d, $i + 4, 2 * $k)));
    my $v = decode("UTF-16BE", substr($d, $p + 12, 2 * $m));
    if ($t eq "L") { $l{$clave} = $v } else { $n{$clave} = $v }
    last;
  }
}
opendir(my $h, $T) or exit 2;
my @e;
for my $x (readdir $h) {
  next if $x eq "." || $x eq ".." || $x eq ".DS_Store" || $x =~ /[\t\n]/;
  my $u = NFC(decode("UTF-8", $x));
  next if index(lc $u, lc $q) < 0;
  my @s = lstat("$T/$x") or next;
  my $r = "";
  if (defined $l{$u}) {
    (my $c = $l{$u}) =~ s{^/*(System/Volumes/Data/)?}{/};
    $c =~ s{/*$}{/};
    my $o = $n{$u} // $u;
    $r = $c . $o unless $o =~ m{[/\t\n]} || $c =~ /[\t\n]/;
  }
  push @e, [$s[10], $x, encode("UTF-8", $r)];
}
print "$_->[1]\t$_->[2]\n" for sort { $b->[0] <=> $a->[0] } @e;'

como() { if [ "$(id -u)" -eq 0 ]; then sudo -u "$usuario" "$@"; else "$@"; fi; }
puedo() {
  { [ -n "$usuario" ] && [ "$usuario" != root ] && [ -n "$casa" ] && [ "$casa" != / ] && [ -d "$casa" ]; } || { echo "No sé qué persona lo pide o no encontré su carpeta personal."; return 1; }
  [ "$(id -u)" -eq 0 ] || [ "$(id -un)" = "$usuario" ] || { echo "No puedo tocar la papelera de otra persona."; return 1; }
  [ -n "$nombre" ] || { echo "Necesito una palabra del nombre del archivo."; return 1; }
  [ -x /usr/bin/perl ] || { echo "Falta una herramienta de macOS (perl) para leer de dónde venía cada archivo. Pide a soporte que lo revise."; return 1; }
  [ -d "$T" ] || return 0
  como ls "$T" >/dev/null 2>&1 || { echo "macOS no me deja abrir tu papelera: pide a soporte que le dé a Helpert «Acceso total al disco», o recupéralo tú desde la Papelera del Dock (clic derecho > Recuperar)."; return 1; }
}
lista() { [ -d "$T" ] && como /usr/bin/perl -e "$LEER" "$T" "$nombre" 2>/dev/null; }
hallados() { lista | awk -F'\t' '$2 != ""' | head -5; }   # los 5 más recientes que se pueden devolver
sin_origen() { lista | awk -F'\t' '$2 == "" {print $1}'; }
corta() { case $1 in "$casa"/*) echo "~${1#"$casa"}" ;; *) echo "$1" ;; esac; }

case ${1:-} in
diagnosticar)
  puedo || exit 3
  h=$(hallados); s=$(sin_origen)
  if [ -z "$h$s" ]; then echo "No encontré nada con «${nombre}» en el nombre en tu papelera. Si la vaciaste, soporte puede revisar las copias de seguridad."; exit 10; fi
  if [ -n "$h" ]; then
    echo "Encontré en la papelera:"
    echo "$h" | while IFS=$'\t' read -r f ruta; do echo "- $f (estaba en $(corta "${ruta%/*}"))"; done
    [ "$(echo "$h" | wc -l)" -gt 1 ] && echo "Si sigo, devuelvo todos a su carpeta."
  fi
  if [ -n "$s" ]; then
    echo "En la papelera también está $(echo "$s" | head -3 | paste -sd, - | sed 's/,/, /g'), pero macOS no guardó de qué carpeta venía: ábrelo desde la Papelera del Dock y arrástralo a donde quieras."
  fi
  [ -n "$h" ] || exit 10
  exit 0 ;;
comprobar)
  puedo || exit 3
  [ -n "$(hallados)" ] || { echo "Ya no está en la papelera, o macOS no guardó de qué carpeta venía."; exit 3; }
  exit 0 ;;
aplicar)
  puedo || exit 1
  n=0
  while IFS=$'\t' read -r f ruta; do
    [ -n "$f" ] || continue
    destino=$ruta base=${ruta##*/} dir=${ruta%/*}
    if como test -e "$destino"; then  # ya hay otro con ese nombre: se deja al lado, nunca se sobrescribe
      case $base in ?*.*) destino="$dir/${base%.*} (recuperado).${base##*.}" ;; *) destino="$ruta (recuperado)" ;; esac
      como test -e "$destino" && destino="$dir/$(date +%H%M%S) $base"
    fi
    como mkdir -p -- "$dir" && como mv -n -- "$T/$f" "$destino" && ! como test -e "$T/$f" && n=$((n + 1)) &&
      echo "- Recuperado en $(corta "$destino")"
  done <<EOF
$(hallados)
EOF
  [ "$n" -gt 0 ] || { echo "No pude recuperar el archivo: puede que ya no tengas permiso para escribir en su carpeta."; exit 1; }
  exit 0 ;;
verificar)
  puedo || exit 1
  # aplicar devuelve los 5 más recientes: si quedan, o no se pudieron mover o había más de 5 con ese nombre
  h=$(hallados)
  [ -z "$h" ] || { echo "Todavía quedan en la papelera: $(echo "$h" | cut -f1 | paste -sd, - | sed 's/,/, /g')."; exit 1; }
  echo "Listo: el archivo volvió a su carpeta."
  exit 0 ;;
*) echo "Paso no válido"; exit 2 ;;
esac
