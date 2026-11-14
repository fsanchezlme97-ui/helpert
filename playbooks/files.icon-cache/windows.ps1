# Borrar la caché de iconos y miniaturas de la persona (AppData\Local\IconCache.db y Microsoft\Windows\Explorer\
# iconcache_*.db / thumbcache_*.db); se rehace sola. Se borra con el token de la persona, nunca como SYSTEM.
# El Explorador no se cierra (es el escritorio): los archivos que tenga abiertos no se pueden borrar y se rehacen al
# cerrar sesión. Después, «ie4uinit -show» en su sesión (tarea programada como ella) le pide que refresque los iconos.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

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
function Preparar {
  $script:sid = SidDe $env:HP_USUARIO
  if (-not $sid) { return 'No sé qué persona lo pide.' }
  $perfil = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'").LocalPath
  if (-not $perfil) { return 'No encontré tu carpeta personal en este equipo.' }
  $script:local = [IO.Path]::Combine($perfil, 'AppData\Local')
  $script:tok = Token $sid
  if (-not $tok) { return 'Necesito que tengas la sesión abierta en este equipo para borrar tu caché de iconos.' }
}
# con el token de la persona
function Buscar {
  $cache.Clear()
  $e = New-Object IO.DirectoryInfo ([IO.Path]::Combine($local, 'Microsoft\Windows\Explorer'))
  if ($e.Exists) { foreach ($p in 'iconcache_*.db', 'thumbcache_*.db') { foreach ($f in $e.GetFiles($p)) { $cache.Add($f) } } }
  $v = New-Object IO.FileInfo ([IO.Path]::Combine($local, 'IconCache.db'))
  if ($v.Exists) { $cache.Add($v) }
}
function Borrar { foreach ($f in $cache) { try { $f.Delete(); $cuenta.Bien++ } catch { $cuenta.Usados++ } } }
function Viejos { $hace = [DateTime]::Now.AddMinutes(-10); @($cache | Where-Object { $_.LastWriteTime -lt $hace }).Count }
function MB { $b = 0; foreach ($f in $cache) { $b += $f.Length }; [math]::Round($b / 1MB) }
# ie4uinit -show en la sesión de la persona; si no se puede, no pasa nada: se rehacen al cerrar sesión
function Refrescar {
  $ie = [IO.Path]::Combine($env:SystemRoot, 'System32\ie4uinit.exe')
  if (-not [IO.File]::Exists($ie)) { return }
  $t = 'Helpert-iconos-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
  try {
    $a = New-ScheduledTaskAction -Execute $ie -Argument '-show'
    $p = New-ScheduledTaskPrincipal -UserId $env:HP_USUARIO -LogonType Interactive
    $null = Register-ScheduledTask -TaskName $t -Action $a -Principal $p -Force
    Start-ScheduledTask -TaskName $t
    Start-Sleep -Seconds 1
    for ($i = 0; $i -lt 20 -and "$((Get-ScheduledTask -TaskName $t).State)" -in 'Running', 'Queued'; $i++) { Start-Sleep -Milliseconds 500 }
  } catch {} finally { try { Unregister-ScheduledTask -TaskName $t -Confirm:$false } catch {} }
}
$cache = New-Object Collections.Generic.List[object]
$cuenta = @{ Bien = 0; Usados = 0 }

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      $null = ComoPersona $tok { Buscar }
      if ($cache.Count -eq 0) { 'No encontré caché de iconos ni de miniaturas en tu carpeta: no hay nada que borrar.'; 'Si los iconos siguen en blanco, cierra sesión y vuelve a entrar.'; exit 10 }
      "Tu caché de iconos y miniaturas tiene $($cache.Count) archivo(s) y ocupa $(MB) MB."
      'Si sigo, la borro y se rehace sola. Lo que el Explorador tenga abierto se rehace cuando cierres sesión y vuelvas a entrar.'
      exit 0
    }
    'comprobar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      exit 0
    }
    'aplicar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      $null = ComoPersona $tok { Buscar }
      $mb = MB
      $null = ComoPersona $tok { Borrar }
      Refrescar
      if ($cuenta.Bien -eq 0 -and $cuenta.Usados) { 'No pude borrar la caché: el Explorador la está usando. Cierra sesión y vuelve a entrar para que se rehaga.'; exit 1 }
      "Borré $($cuenta.Bien) archivo(s) de la caché de iconos y miniaturas (de $mb MB en total) y le pedí a Windows que refresque los iconos."
      if ($cuenta.Usados) { "$($cuenta.Usados) archivo(s) estaban en uso por el Explorador: se rehacen cuando cierres sesión y vuelvas a entrar." }
      exit 0
    }
    'verificar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      $null = ComoPersona $tok { Buscar }
      $v = Viejos
      if ($v -gt 0 -and $v -eq $cache.Count) { 'La caché antigua sigue ahí: el Explorador la está usando. Cierra sesión y vuelve a entrar para que se rehaga.'; exit 1 }
      if ($v -gt 0) { "Quedan $v archivo(s) de la caché antigua en uso por el Explorador: se rehacen cuando cierres sesión y vuelvas a entrar." }
      else { 'La caché antigua ya no está. Si algún icono sigue en blanco, cierra sesión y vuelve a entrar.' }
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
