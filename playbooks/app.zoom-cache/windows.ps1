# Limpiar los datos de Zoom: cierra Zoom de la persona (sus procesos, por SID) y vacía sus carpetas de datos y registros
# (AppData\Roaming\Zoom\data y logs; no la del programa, bin), salvo los fondos virtuales propios (VirtualBkgnd_*).
# Hay que volver a iniciar sesión. Las grabaciones (en Documentos\Zoom) no se tocan.
# Lo que toca la carpeta de la persona se hace con su propio token (el de su sesión), nunca como SYSTEM: así un enlace
# o una unión que ella haya creado no puede llevar a SYSTEM a borrar archivos ajenos.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$NOMBRE = 'Zoom'
$PROCS = @('zoom', 'zoomwebviewhost', 'zwebview2agent', 'aomhost64')
# dentro de la carpeta personal: se borra lo que tienen adentro
$CARPETAS = @('AppData\Roaming\Zoom\data', 'AppData\Roaming\Zoom\logs')

function SidDe($cuenta) {  # solo cuentas de personas (locales, de dominio o de Entra ID), nunca SYSTEM ni de servicio
  if (-not $cuenta) { return $null }
  try { $s = (New-Object Security.Principal.NTAccount($cuenta)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { return $null }
  if ($s -match '^S-1-(5-21|12-1)-') { $s }
}
function Token($sid) {
  if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq $sid) { return 'yo' }
  $s = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid -eq $sid })
  if ($s.Count -eq 0) { return $null }
  Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class HpWts { [DllImport("wtsapi32.dll", SetLastError = true)] public static extern bool WTSQueryUserToken(uint sesion, out IntPtr token); }'
  $h = [IntPtr]::Zero
  if (-not [HpWts]::WTSQueryUserToken([uint32]$s[0].SessionId, [ref]$h)) { return $null }
  New-Object Microsoft.Win32.SafeHandles.SafeAccessTokenHandle $h
}
# con el token de la persona; lo que escribe el bloque se pierde, así que deja sus resultados en variables $script:
function ComoPersona($tok, [scriptblock]$b) {
  if ($tok -is [string]) { $null = & $b } else { [Security.Principal.WindowsIdentity]::RunImpersonated($tok, [Action]$b) }
}
function Preparar {
  $script:sid = SidDe $env:HP_USUARIO
  if (-not $sid) { return 'No sé qué persona lo pide.' }
  $script:perfil = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'").LocalPath
  if (-not $perfil) { return 'No encontré tu carpeta personal en este equipo.' }
  $script:tok = Token $sid
  if (-not $tok) { return "Necesito que tengas la sesión abierta en este equipo para limpiar $NOMBRE." }
}
function Procesos {
  @(Get-CimInstance Win32_Process | Where-Object { $PROCS -contains ("$($_.Name)" -replace '\.exe$', '') } |
      Where-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid -eq $sid })
}
function Cerrar {
  foreach ($p in @(Procesos)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
  for ($i = 0; $i -lt 10; $i++) { if (@(Procesos).Count -eq 0) { return $true }; Start-Sleep -Seconds 1 }
  $false
}
function Bytes($d) {
  $s = 0
  try { foreach ($f in (New-Object IO.DirectoryInfo $d).EnumerateFiles('*', [IO.SearchOption]::AllDirectories)) { $s += $f.Length } } catch {}
  $s
}
# carpetas que existen y su tamaño en MB (sin los fondos virtuales); corre con el token de la persona
function Revisar {
  $script:carpetas = @(foreach ($c in $CARPETAS) { $d = [IO.Path]::Combine($perfil, $c); if ([IO.Directory]::Exists($d)) { $d } })
  $b = 0
  foreach ($d in $carpetas) {
    try { $todo = (New-Object IO.DirectoryInfo $d).GetFileSystemInfos() } catch { continue }
    foreach ($x in $todo) { if ($x.Name -notlike 'VirtualBkgnd_*') { if ($x -is [IO.DirectoryInfo]) { $b += Bytes $x.FullName } else { $b += $x.Length } } }
  }
  $script:mb = [math]::Round($b / 1MB)
}
function Vaciar($d) {  # todo menos los fondos virtuales propios
  try { $todo = (New-Object IO.DirectoryInfo $d).GetFileSystemInfos() } catch { return }
  foreach ($x in $todo) { if ($x.Name -like 'VirtualBkgnd_*') { continue }; try { if ($x -is [IO.DirectoryInfo]) { $x.Delete($true) } else { $x.Delete() } } catch {} }
}
$carpetas = @(); $mb = 0

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      ComoPersona $tok { Revisar }
      if ($carpetas.Count -eq 0) { "No encontré datos de Zoom en tu carpeta: o no lo usas en este equipo o ya están limpios."; exit 10 }
      "Zoom tiene $mb MB de datos temporales. Los borraría; después tendrás que volver a iniciar sesión en Zoom."
      if (@(Procesos).Count) { "Zoom está abierto: lo voy a cerrar antes de limpiar (si estás en una reunión, se corta)." }
      exit 0
    }
    'comprobar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      ComoPersona $tok { Revisar }
      if ($carpetas.Count -eq 0) { 'No hay datos de Zoom que limpiar.'; exit 3 }
      exit 0
    }
    'aplicar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      if (-not (Cerrar)) { "No pude cerrar $NOMBRE, así que no borré nada."; exit 1 }
      ComoPersona $tok { Revisar }
      $antes = $mb
      ComoPersona $tok { foreach ($d in $carpetas) { Vaciar $d } }
      "Cerré Zoom y borré sus datos temporales ($antes MB). Ábrelo e inicia sesión de nuevo."
      exit 0
    }
    'verificar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      if (@(Procesos).Count) { 'Zoom ya está abierto de nuevo.'; exit 0 }
      ComoPersona $tok { Revisar }
      if ($mb -gt 2) { "No pude borrar $mb MB de datos de Zoom."; exit 1 }
      'Listo: los datos de Zoom están limpios. Ábrelo e inicia sesión de nuevo.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
