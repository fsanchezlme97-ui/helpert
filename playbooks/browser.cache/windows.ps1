# Limpiar la caché del navegador: solo las carpetas de caché (en AppData\Local), nunca el perfil (contraseñas, historial,
# cookies). Solo de navegadores cerrados: con el navegador abierto, la caché se vuelve a escribir y puede corromperse.
# Lo que toca la carpeta de la persona se hace con su propio token (el de su sesión), nunca como SYSTEM: así un enlace
# o una unión que ella haya creado no puede llevar a SYSTEM a borrar archivos ajenos.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
# nombre -> proceso, carpeta de perfiles dentro de AppData\Local y carpetas de caché de cada perfil
$NAV = [ordered]@{
  Chrome   = @('chrome', 'Google\Chrome\User Data', 'Cache', 'Code Cache', 'GPUCache')
  Edge     = @('msedge', 'Microsoft\Edge\User Data', 'Cache', 'Code Cache', 'GPUCache')
  Brave    = @('brave', 'BraveSoftware\Brave-Browser\User Data', 'Cache', 'Code Cache', 'GPUCache')
  # en Windows, Chromium también corre como chrome.exe
  Chromium = @('chrome', 'Chromium\User Data', 'Cache', 'Code Cache', 'GPUCache')
  Firefox  = @('firefox', 'Mozilla\Firefox\Profiles', 'cache2')
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
function ComoPersona($tok, [scriptblock]$b) {
  if ($tok -is [string]) { & $b } else { [Security.Principal.WindowsIdentity]::RunImpersonated($tok, [Action]$b) }
}
function Abierto($n) {
  @(Get-CimInstance Win32_Process -Filter "Name='$($NAV[$n][0]).exe'" | Where-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid -eq $sid }).Count -gt 0
}
function MB($d) {
  $s = 0
  try { foreach ($f in (New-Object IO.DirectoryInfo $d).EnumerateFiles('*', [IO.SearchOption]::AllDirectories)) { $s += $f.Length } } catch {}
  $s
}
# carpetas de caché que existen, con su tamaño; corre con el token de la persona
function Buscar {
  foreach ($n in $NAV.Keys) {
    $v = $NAV[$n]
    $base = [IO.Path]::Combine($local, $v[1])
    if (-not [IO.Directory]::Exists($base)) { continue }
    foreach ($perfil in [IO.Directory]::GetDirectories($base)) {
      foreach ($c in $v[2..($v.Count - 1)]) {
        $d = [IO.Path]::Combine($perfil, $c)
        if ([IO.Directory]::Exists($d)) { $cache.Add([pscustomobject]@{ Nav = $n; Ruta = $d; Bytes = (MB $d) }) }
      }
    }
  }
}
function Preparar {
  $script:sid = SidDe $env:HP_USUARIO
  if (-not $sid) { return 'No sé qué persona lo pide.' }
  $perfil = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'").LocalPath
  if (-not $perfil) { return 'No encontré tu carpeta personal en este equipo.' }
  $script:local = [IO.Path]::Combine($perfil, 'AppData\Local')
  $script:tok = Token $sid
  if (-not $tok) { return 'Necesito que tengas la sesión abierta en este equipo para limpiar tu navegador.' }
}
$cache = New-Object Collections.Generic.List[object]

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      $null = ComoPersona $tok { Buscar }
      if ($cache.Count -eq 0) { 'No encontré caché de navegadores en tu carpeta.'; exit 10 }
      foreach ($g in ($cache | Group-Object Nav)) {
        $b = 0; foreach ($c in $g.Group) { $b += $c.Bytes }; $mb = [math]::Round($b / 1MB)
        if (Abierto $g.Name) { "$($g.Name): $mb MB de caché (está abierto, aunque sea en segundo plano: ciérralo antes de que lo limpie)" }
        else { "$($g.Name): $mb MB de caché." }
      }
      exit 0
    }
    'comprobar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      exit 0
    }
    'aplicar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      $null = ComoPersona $tok { Buscar }
      $abiertos = @($NAV.Keys | Where-Object { Abierto $_ })
      $borrar = @($cache | Where-Object { $abiertos -notcontains $_.Nav })
      # el navegador vuelve a crear la carpeta de caché al abrirse
      $null = ComoPersona $tok { foreach ($c in $borrar) { try { [IO.Directory]::Delete($c.Ruta, $true) } catch {} } }
      $limpios = @($borrar | ForEach-Object { $_.Nav } | Sort-Object -Unique)
      $sigue = @($cache | Where-Object { $abiertos -contains $_.Nav } | ForEach-Object { $_.Nav } | Sort-Object -Unique)
      if ($limpios.Count -eq 0) { "No limpié nada: $($sigue -join ', ') sigue abierto. Ciérralo y vuelve a pedírmelo."; exit 1 }
      $extra = ''; if ($sigue.Count) { $extra = " No toqué $($sigue -join ', ') porque estaba abierto." }
      "Limpié la caché de: $($limpios -join ', ').$extra"
      exit 0
    }
    'verificar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      $null = ComoPersona $tok { Buscar }
      # lo que quede de navegadores cerrados son archivos que no se pudieron borrar
      $quedan = @($cache | Where-Object { -not (Abierto $_.Nav) })
      $b = 0; foreach ($c in $quedan) { $b += $c.Bytes }; $mb = [math]::Round($b / 1MB)
      if ($mb -gt 5) { "No pude borrar $mb MB de caché de $(@($quedan | ForEach-Object { $_.Nav } | Sort-Object -Unique) -join ', ')."; exit 1 }
      'Listo. Abre de nuevo el navegador y la página; la primera vez puede tardar un poco más.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
