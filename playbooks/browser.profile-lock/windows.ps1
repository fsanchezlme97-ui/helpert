# Desbloquear el perfil del navegador: si Firefox, Chrome, Edge, Brave o Chromium de la persona de verdad están cerrados
# (ningún proceso suyo con ese nombre, por SID), borra el archivo de bloqueo que quedó: parent.lock de cada perfil de
# Firefox, lockfile de la carpeta User Data de los demás. Nada más del perfil.
# Lo que toca la carpeta de la persona se hace con su propio token (el de su sesión), nunca como SYSTEM.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
# nombre -> proceso, carpeta (Roaming o Local), ruta de los datos y archivo de bloqueo
$NAV = [ordered]@{
  Firefox  = @('firefox', 'Roaming', 'Mozilla\Firefox\Profiles', 'parent.lock')
  Chrome   = @('chrome', 'Local', 'Google\Chrome\User Data', 'lockfile')
  Edge     = @('msedge', 'Local', 'Microsoft\Edge\User Data', 'lockfile')
  Brave    = @('brave', 'Local', 'BraveSoftware\Brave-Browser\User Data', 'lockfile')
  # en Windows, Chromium también corre como chrome.exe
  Chromium = @('chrome', 'Local', 'Chromium\User Data', 'lockfile')
}

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
  if (-not $tok) { return "Necesito que tengas la sesión abierta en este equipo para revisar tu navegador." }
}
function Abierto($n) {
  @(Get-CimInstance Win32_Process -Filter "Name='$($NAV[$n][0]).exe'" | Where-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid -eq $sid }).Count -gt 0
}
# archivos de bloqueo que existen; corre con el token de la persona
function Revisar {
  $l = New-Object Collections.Generic.List[object]
  foreach ($n in $NAV.Keys) {
    $v = $NAV[$n]
    $base = [IO.Path]::Combine($perfil, 'AppData', $v[1], $v[2])
    if (-not [IO.Directory]::Exists($base)) { continue }
    $dirs = @($base); if ($n -eq 'Firefox') { $dirs = [IO.Directory]::GetDirectories($base) }
    foreach ($d in $dirs) { $f = [IO.Path]::Combine($d, $v[3]); if ([IO.File]::Exists($f)) { $l.Add([pscustomobject]@{ Nav = $n; Ruta = $f }) } }
  }
  $script:bloqueos = $l
}
function Quitar { foreach ($b in $borrar) { try { [IO.File]::Delete($b.Ruta) } catch {} } }
$bloqueos = @(); $borrar = @()

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      ComoPersona $tok { Revisar }
      $navs = @($bloqueos | ForEach-Object { $_.Nav } | Sort-Object -Unique)
      $abiertos = @($navs | Where-Object { Abierto $_ }); $cerrados = @($navs | Where-Object { $abiertos -notcontains $_ })
      foreach ($n in $cerrados) { "${n}: quedó un bloqueo del perfil y el navegador está cerrado; lo puedo quitar." }
      if ($abiertos.Count) { "$($abiertos -join ', ') sigue abierto para ti, aunque no se vea una ventana (a veces queda en segundo plano): no es un bloqueo que haya quedado. Ciérralo con «Cerrar un programa congelado» o reinicia el equipo." }
      if ($cerrados.Count) { exit 0 }
      if (-not $abiertos.Count) { 'No encontré ningún perfil de navegador bloqueado en tu carpeta.' }
      exit 10
    }
    'comprobar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      ComoPersona $tok { Revisar }
      if (-not @($bloqueos | Where-Object { -not (Abierto $_.Nav) }).Count) { 'No hay bloqueos que quitar en navegadores cerrados.'; exit 3 }
      exit 0
    }
    'aplicar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      ComoPersona $tok { Revisar }
      $borrar = @($bloqueos | Where-Object { -not (Abierto $_.Nav) })
      if (-not $borrar.Count) { 'No quité nada: el navegador está abierto o ya no tenía bloqueo.'; exit 1 }
      ComoPersona $tok { Quitar }
      "Quité el bloqueo del perfil de: $(@($borrar | ForEach-Object { $_.Nav } | Sort-Object -Unique) -join ', '). Ya puedes abrirlo."
      exit 0
    }
    'verificar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      ComoPersona $tok { Revisar }
      $quedan = @($bloqueos | Where-Object { -not (Abierto $_.Nav) } | ForEach-Object { $_.Nav } | Sort-Object -Unique)
      if ($quedan.Count) { "$($quedan -join ', ') sigue con el perfil bloqueado: no pude quitar el bloqueo."; exit 1 }
      'Listo: ningún navegador cerrado tiene el perfil bloqueado. Ábrelo de nuevo.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
