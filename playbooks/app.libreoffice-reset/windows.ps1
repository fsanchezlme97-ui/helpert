# Restablecer LibreOffice: renombra el perfil de la persona (AppData\Roaming\LibreOffice\4) a 4.helpert-<fecha> para
# que LibreOffice cree uno nuevo. Deshacer devuelve el más reciente (el nuevo queda a un lado). Los documentos no se
# tocan. Solo con LibreOffice cerrado. Lo que toca la carpeta de la persona se hace con su propio token, nunca como SYSTEM.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$NOMBRE = 'LibreOffice'
$PROCS = @('soffice', 'soffice.bin')
$OBJETO = 'AppData\Roaming\LibreOffice\4'  # dentro de la carpeta personal
$SUFIJO = '\.helpert-\d{8}-\d{6}$'

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
  if (-not $tok) { return "Necesito que tengas la sesión abierta en este equipo para restablecer LibreOffice." }
}
function Procesos {
  @(Get-CimInstance Win32_Process | Where-Object { $PROCS -contains ("$($_.Name)" -replace '\.exe$', '') } |
      Where-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid -eq $sid })
}
function Existe($r) { [IO.File]::Exists($r) -or [IO.Directory]::Exists($r) }
function Mover($de, $a) { if ([IO.Directory]::Exists($de)) { [IO.Directory]::Move($de, $a) } else { [IO.File]::Move($de, $a) } }
# si existe, y sus copias de otras veces (la más reciente al final); corre con el token de la persona
function Revisar {
  $script:ruta = [IO.Path]::Combine($perfil, $OBJETO)
  $script:hay = Existe $ruta
  $d = [IO.Path]::GetDirectoryName($ruta); $n = [IO.Path]::GetFileName($ruta)
  $script:copias = @()
  if ([IO.Directory]::Exists($d)) {
    $script:copias = @([IO.Directory]::GetFileSystemEntries($d, "$n.helpert-*") | Where-Object { $_ -match $SUFIJO } | Sort-Object)
  }
}
function Renombrar {
  Revisar
  $script:hecho = $false
  try { Mover $ruta "$ruta.helpert-$(Get-Date -Format 'yyyyMMdd-HHmmss')"; $script:hecho = $true } catch {}
}
# lo que se haya creado de nuevo queda a un lado (.helpert-nuevo-<fecha>) y la copia más reciente vuelve a su lugar
function Devolver {
  Revisar
  $script:hecho = $false
  if (-not $copias.Count) { return }
  try {
    if ($hay) { Mover $ruta "$ruta.helpert-nuevo-$(Get-Date -Format 'yyyyMMdd-HHmmss')" }
    Mover $copias[-1] $ruta; $script:hecho = $true
  } catch {}
}
$hay = $false; $copias = @(); $hecho = $false

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      ComoPersona $tok { Revisar }
      if (-not $hay) { 'No encontré un perfil de LibreOffice en tu carpeta: se crea solo la primera vez que lo abres.'; exit 10 }
      'Encontré tu perfil de LibreOffice. Lo renombraría para que empiece con uno nuevo; tus documentos no se tocan.'
      'Tus ajustes, diccionario personal y macros quedan guardados en el perfil viejo y se pueden recuperar deshaciendo.'
      if (@(Procesos).Count) { "$NOMBRE está abierto: ciérralo antes de que lo restablezca." }
      exit 0
    }
    'comprobar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      ComoPersona $tok { Revisar }
      if (-not $hay) { 'No encontré un perfil de LibreOffice en tu carpeta: se crea solo la primera vez que lo abres.'; exit 3 }
      if (@(Procesos).Count) { "$NOMBRE está abierto: guarda tus documentos, ciérralo y vuelve a pedírmelo."; exit 3 }
      exit 0
    }
    'aplicar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      if (@(Procesos).Count) { "$NOMBRE está abierto: no toqué nada."; exit 1 }
      ComoPersona $tok { Renombrar }
      if (-not $hecho) { 'No pude renombrar tu perfil de LibreOffice: puede que siga abierto (también el inicio rápido junto al reloj).'; exit 1 }
      'Renombré tu perfil de LibreOffice. Ábrelo: empezará con la configuración inicial. Si quieres volver al anterior, se puede deshacer.'
      exit 0
    }
    'verificar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      if (@(Procesos).Count) { "$NOMBRE ya está abierto con un perfil nuevo."; exit 0 }
      ComoPersona $tok { Revisar }
      if ($hay -or -not $copias.Count) { 'El perfil viejo de LibreOffice sigue en su lugar.'; exit 1 }
      'Listo: LibreOffice creará un perfil nuevo al abrirlo.'
      exit 0
    }
    'deshacer' {
      $m = Preparar; if ($m) { $m; exit 1 }
      if (@(Procesos).Count) { "$NOMBRE está abierto: ciérralo y vuelve a pedírmelo."; exit 1 }
      ComoPersona $tok { Devolver }
      if (-not $copias.Count) { 'No encontré un perfil anterior de LibreOffice que devolver.'; exit 1 }
      if (-not $hecho) { 'No pude devolver tu perfil anterior de LibreOffice: ciérralo (también el inicio rápido) y vuelve a pedírmelo.'; exit 1 }
      'Devolví tu perfil anterior de LibreOffice, con tus ajustes de antes.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
