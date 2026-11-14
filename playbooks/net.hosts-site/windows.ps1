# Desbloquear un sitio en el archivo hosts: quita el sitio (y su www.) de las líneas que lo nombran, con copia para
# deshacer. De una línea con varios nombres solo se quita ese nombre; nunca se tocan localhost ni el nombre del equipo.
# Se lee y se escribe byte a byte (Latin-1): las líneas que no cambian quedan igual, sea el archivo ANSI o UTF-8.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$HOSTS = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
$L1 = [Text.Encoding]::GetEncoding(28591)
$sitio = "$env:HP_SITIO".ToLower().Trim('.')
if ($sitio.StartsWith('www.')) { $sitio = $sitio.Substring(4) }

function Admin { (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function NoValido {
  if (-not $sitio -or $sitio.StartsWith('-') -or $sitio.Contains('..')) { return 'Necesito la dirección del sitio, por ejemplo intranet.empresa.pe.' }
  if ($sitio -match '^(localhost(\..*)?|localdomain|broadcasthost|ip6-.*)$') { return "«$sitio» es el propio equipo: esas líneas no se tocan." }
  if ($sitio -eq "$env:COMPUTERNAME".ToLower()) { return "«$sitio» es el nombre de este equipo: esas líneas no se tocan." }
}
function Texto { $L1.GetString([IO.File]::ReadAllBytes($HOSTS)) }
function Lineas { [regex]::Split((Texto), '\r?\n') }
# la línea sin el sitio; $null si no lo nombra; '' si no le queda ningún nombre
function SinSitio($l) {
  $d = $l; $c = ''; $i = $l.IndexOf('#')
  if ($i -ge 0) { $c = $l.Substring($i); $d = $l.Substring(0, $i) }
  $f = @($d.Trim() -split '\s+')
  if ($f.Count -lt 2) { return $null }
  $q = @($f[1..($f.Count - 1)] | Where-Object { $h = $_.ToLower().TrimEnd('.'); $h -ne $sitio -and $h -ne "www.$sitio" })
  if ($q.Count -eq $f.Count - 1) { return $null }
  if ($q.Count -eq 0) { return '' }
  $r = (@($f[0]) + $q) -join ' '
  if ($c) { $r += " $c" }
  $r
}
function Afectadas { @(foreach ($l in Lineas) { if ($null -ne (SinSitio $l)) { $l } }) }
# en su sitio (Truncate): conserva los permisos y funciona aunque el archivo esté oculto
function Escribir($bytes) { $s = [IO.File]::Open($HOSTS, 'Truncate', 'Write'); try { $s.Write($bytes, 0, $bytes.Length) } finally { $s.Close() } }
function Copias { @(Get-ChildItem -LiteralPath (Split-Path $HOSTS) -Filter 'hosts.helpert-*' -File -ErrorAction SilentlyContinue | Sort-Object Name) }

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = NoValido; if ($m) { $m; exit 1 }
      if (-not (Test-Path -LiteralPath $HOSTS)) { "El equipo no tiene archivo hosts, así que no es lo que bloquea $sitio."; exit 10 }
      $l = Afectadas
      if ($l.Count -eq 0) { "El archivo hosts no tiene nada de ${sitio}: el problema está en otra parte (prueba «Probar si un sitio o sistema responde»)."; exit 10 }
      "El archivo hosts del equipo desvía $sitio a otra dirección ($($l.Count) línea(s)):"
      foreach ($x in @($l | Select-Object -First 3)) { $x = $x.Trim(); if ($x.Length -gt 100) { $x = $x.Substring(0, 100) }; "- $x" }
      "Puedo quitar $sitio de esas líneas y guardar una copia para deshacerlo."
      'Si soporte puso esa línea a propósito (por ejemplo, para un servidor interno), avísales antes.'
      exit 0
    }
    'comprobar' {
      if (-not (Admin)) { 'Helpert necesita privilegios de administrador para cambiar el archivo hosts.'; exit 3 }
      $m = NoValido; if ($m) { $m; exit 3 }
      if (-not (Test-Path -LiteralPath $HOSTS)) { 'El equipo no tiene archivo hosts.'; exit 3 }
      if ((Get-Item -LiteralPath $HOSTS).IsReadOnly) { 'El archivo hosts está protegido contra cambios (solo lectura), quizás por la empresa: lo revisa soporte.'; exit 3 }
      if ((Afectadas).Count -eq 0) { "El archivo hosts ya no tiene nada de $sitio."; exit 3 }
      exit 0
    }
    'aplicar' {
      $m = NoValido; if ($m) { $m; exit 1 }
      $antes = [IO.File]::ReadAllBytes($HOSTS); $t = $L1.GetString($antes)
      $n = (Afectadas).Count
      if ($n -eq 0) { "El archivo hosts ya no tenía nada de $sitio."; exit 0 }
      $fin = "`n"; if ($t.Contains("`r`n")) { $fin = "`r`n" }
      $nuevas = foreach ($l in [regex]::Split($t, '\r?\n')) { $s = SinSitio $l; if ($null -eq $s) { $l } elseif ($s) { $s } }
      Copias | Remove-Item -Force  # deshacer devuelve solo el último cambio, nunca una copia vieja
      $copia = "$HOSTS.helpert-$(Get-Date -Format yyyyMMdd-HHmmss)"
      try { [IO.File]::WriteAllBytes($copia, $antes) } catch { 'No pude guardar la copia del archivo hosts; no toqué nada.'; exit 1 }
      try { Escribir ($L1.GetBytes((@($nuevas) -join $fin))) } catch {
        try { Escribir $antes } catch { }
        'No pude cambiar el archivo hosts (puede que el antivirus o una política de la empresa lo protejan): lo revisa soporte.'; exit 1
      }
      "Quité $sitio del archivo hosts ($n línea(s)) y guardé una copia para deshacerlo."
      'Cierra y vuelve a abrir el navegador para que tome el cambio.'
      exit 0
    }
    'verificar' {
      if ((Afectadas).Count -gt 0) { "El archivo hosts todavía desvía $sitio."; exit 1 }
      "El archivo hosts ya no desvía $sitio."
      exit 0
    }
    'deshacer' {
      $c = Copias | Select-Object -Last 1
      if (-not $c) { 'No encontré la copia del archivo hosts para deshacer el cambio.'; exit 1 }
      try { Escribir ([IO.File]::ReadAllBytes($c.FullName)) } catch { 'No pude devolver el archivo hosts a como estaba.'; exit 1 }
      Remove-Item -LiteralPath $c.FullName -Force
      'Devolví el archivo hosts a como estaba antes del cambio.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
