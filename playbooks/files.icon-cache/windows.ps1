# Borrar la caché de iconos y miniaturas de la persona (AppData\Local\IconCache.db y Microsoft\Windows\Explorer\
# iconcache_*.db / thumbcache_*.db); se rehace sola. Se borra con el token de la persona, nunca como SYSTEM.
# El Explorador de la persona (solo el suyo, por SID) tiene esos archivos abiertos: se cierra un momento para borrarlos
# y Windows lo vuelve a abrir; si no vuelve, se abre en su sesión con una tarea programada como ella (y se borra).
# Sus programas no se cierran; las ventanas de carpetas sí. Lo que otro programa tenga abierto se rehace al cerrar sesión.
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
function Suyos {  # explorer.exe de la persona
  @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object { $o = (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid; $o -and $o -eq $sid })
}
function Esperar($seg) { for ($i = 0; $i -lt $seg; $i++) { if (@(Suyos).Count) { return $true }; Start-Sleep -Seconds 1 }; @(Suyos).Count -gt 0 }
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
function AbrirComoPersona {  # explorer.exe en la sesión de la persona, con su cuenta
  $t = 'Helpert-iconos-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
  try {
    $a = New-ScheduledTaskAction -Execute "$env:SystemRoot\explorer.exe"
    $p = New-ScheduledTaskPrincipal -UserId $env:HP_USUARIO -LogonType Interactive
    $c = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries  # si no, con batería no arranca
    $null = Register-ScheduledTask -TaskName $t -Action $a -Principal $p -Settings $c -Force
    Start-ScheduledTask -TaskName $t
    $null = Esperar 10
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
      'Si sigo, cierro un momento tu Explorador para borrarla (la barra de tareas parpadea y se cierran las ventanas de carpetas; tus programas siguen abiertos) y se rehace sola.'
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
      # el token ya está tomado (Token lo saca de la sesión, no del proceso): cerrar el Explorador no lo invalida
      $ex = @(Suyos)
      foreach ($x in $ex) { Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue }
      foreach ($x in $ex) { Wait-Process -Id $x.ProcessId -Timeout 5 -ErrorAction SilentlyContinue }
      $null = ComoPersona $tok { Borrar }
      if ($ex.Count) {
        Start-Sleep -Seconds 2
        if (-not (Esperar 10)) { AbrirComoPersona }
        if (-not (Esperar 1)) { 'Borré la caché, pero tu escritorio no volvió a abrirse. Cierra sesión y vuelve a entrar.'; exit 1 }
      }
      if ($cuenta.Bien -eq 0 -and $cuenta.Usados) { 'No pude borrar la caché: otro programa la está usando. Cierra sesión y vuelve a entrar para que se rehaga.'; exit 1 }
      "Borré $($cuenta.Bien) archivo(s) de la caché de iconos y miniaturas (de $mb MB en total); se rehace sola."
      if ($cuenta.Usados) { "$($cuenta.Usados) archivo(s) estaban en uso por otro programa: se rehacen cuando cierres sesión y vuelvas a entrar." }
      exit 0
    }
    'verificar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      $null = ComoPersona $tok { Buscar }
      $v = Viejos
      if ($v -gt 0 -and $v -eq $cache.Count) { 'La caché antigua sigue ahí: otro programa la está usando. Cierra sesión y vuelve a entrar para que se rehaga.'; exit 1 }
      if ($v -gt 0) { "Quedan $v archivo(s) de la caché antigua en uso por otro programa: se rehacen cuando cierres sesión y vuelvas a entrar." }
      else { 'La caché antigua ya no está. Si algún icono sigue en blanco, cierra sesión y vuelve a entrar.' }
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
