# Reparar la plantilla de Word: renombra la plantilla Normal de la persona (AppData\Roaming\Microsoft\Templates\
# Normal.dotm) a Normal.dotm.helpert-<fecha> para que Word cree una nueva. Deshacer la devuelve (la nueva queda a un
# lado). Solo con Word cerrado. Lo que toca la carpeta de la persona se hace con su propio token, nunca como SYSTEM.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$NOMBRE = 'Word'
$PROCS = @('winword')
$OBJETO = 'AppData\Roaming\Microsoft\Templates\Normal.dotm'  # dentro de la carpeta personal
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
  if (-not $tok) { return "Necesito que tengas la sesión abierta en este equipo para reparar tu plantilla de Word." }
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
      if (-not $hay) { 'No encontré tu plantilla Normal de Word: Word crea una nueva al abrirse, así que no es la causa.'; exit 10 }
      'Encontré tu plantilla Normal de Word. La renombraría para que Word cree una nueva, limpia; tus documentos no se tocan.'
      'Si guardaste en ella estilos, macros o autotextos, quedan en la copia y se pueden recuperar deshaciendo.'
      if (@(Procesos).Count) { "$NOMBRE está abierto: ciérralo antes de que cambie la plantilla." }
      exit 0
    }
    'comprobar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      ComoPersona $tok { Revisar }
      if (-not $hay) { 'No encontré tu plantilla Normal de Word: Word crea una nueva al abrirse, así que no es la causa.'; exit 3 }
      if (@(Procesos).Count) { "$NOMBRE está abierto: guarda tus documentos, ciérralo y vuelve a pedírmelo."; exit 3 }
      exit 0
    }
    'aplicar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      if (@(Procesos).Count) { "$NOMBRE está abierto: no toqué nada."; exit 1 }
      ComoPersona $tok { Renombrar }
      if (-not $hecho) { 'No pude renombrar tu plantilla Normal: puede que Word u Outlook la estén usando. Ciérralos y vuelve a pedírmelo.'; exit 1 }
      'Renombré tu plantilla Normal. Abre Word: creará una nueva. Si quieres volver a la anterior, se puede deshacer.'
      exit 0
    }
    'verificar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      if (@(Procesos).Count) { "$NOMBRE ya está abierto con una plantilla nueva."; exit 0 }
      ComoPersona $tok { Revisar }
      if ($hay -or -not $copias.Count) { 'La plantilla Normal vieja sigue en su lugar.'; exit 1 }
      'Listo: Word creará una plantilla Normal nueva al abrirse.'
      exit 0
    }
    'deshacer' {
      $m = Preparar; if ($m) { $m; exit 1 }
      if (@(Procesos).Count) { "$NOMBRE está abierto: ciérralo y vuelve a pedírmelo."; exit 1 }
      ComoPersona $tok { Devolver }
      if (-not $copias.Count) { 'No encontré una copia de tu plantilla Normal que devolver.'; exit 1 }
      if (-not $hecho) { 'No pude devolver tu plantilla Normal: puede que Word u Outlook la estén usando.'; exit 1 }
      'Devolví tu plantilla Normal anterior. Abre Word de nuevo.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
