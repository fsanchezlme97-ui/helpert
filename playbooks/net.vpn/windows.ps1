# Conectar la VPN: las VPN de Windows de la libreta de teléfonos para todos (ProgramData) y de la persona (su AppData,
# leída con su token). Conecta la indicada en HP_VPN o la primera configurada, con rasdial en su sesión (tarea
# programada como ella, que se borra después), para que use la contraseña que ella guardó. Las VPN de otros programas
# (Cisco, FortiClient, GlobalProtect...) no se ven aquí. HP_VPN solo se compara con los nombres de la libreta.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$vpn = "$env:HP_VPN"
$PBK = 'Microsoft\Network\Connections\Pbk\rasphone.pbk'

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
# VPN (Type=2) de una libreta: @{ Nombre; Libreta }; sin comillas ni \ al final del nombre, que va entre comillas a rasdial
function DeLibreta($ruta) {
  if (-not [IO.File]::Exists($ruta)) { return }
  $n = $null
  foreach ($l in [IO.File]::ReadAllLines($ruta)) {
    if ($l -match '^\[(.+)\]\s*$') { $n = $Matches[1] }
    elseif ($n -and $l -match '^Type=2\s*$' -and $n -notmatch '"|\\$') { [pscustomobject]@{ Nombre = $n; Libreta = $ruta }; $n = $null }
  }
}
function Preparar {
  $script:sid = SidDe $env:HP_USUARIO
  if (-not $sid) { return 'No sé qué persona lo pide.' }
  $script:perfil = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'").LocalPath
  $script:tok = Token $sid
  $l = New-Object Collections.Generic.List[object]
  foreach ($v in @(DeLibreta ([IO.Path]::Combine($env:ProgramData, $PBK)))) { $l.Add($v) }
  $script:suyas = $l
  if ($perfil -and $tok) { ComoPersona $tok { foreach ($v in @(DeLibreta ([IO.Path]::Combine($perfil, 'AppData\Roaming', $PBK)))) { $suyas.Add($v) } } }
}
function Nombres { @($suyas | ForEach-Object { $_.Nombre }) }
# conectadas: Windows crea una interfaz con el nombre de la conexión mientras está arriba
function Activas { $a = @(Get-NetIPInterface -ConnectionState Connected -ErrorAction SilentlyContinue | ForEach-Object { $_.InterfaceAlias }); @(Nombres | Where-Object { $a -contains $_ }) }
function Elegida {
  if ($vpn) { @($suyas | Where-Object { $_.Nombre -eq $vpn }) | Select-Object -First 1 } else { @($suyas) | Select-Object -First 1 }
}
function Internet { @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | Where-Object { "$($_.IPv4Connectivity)" -eq 'Internet' -or "$($_.IPv6Connectivity)" -eq 'Internet' }).Count -gt 0 }
# rasdial como la persona, en su sesión; devuelve su código (0 = conectada) o $null si no terminó
function Marcar($e) {
  $t = 'Helpert-vpn-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
  $a = New-ScheduledTaskAction -Execute "$env:SystemRoot\System32\rasdial.exe" -Argument "`"$($e.Nombre)`" /PHONEBOOK:`"$($e.Libreta)`""
  $p = New-ScheduledTaskPrincipal -UserId $env:HP_USUARIO -LogonType Interactive
  $c = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
  $r = $null
  $null = Register-ScheduledTask -TaskName $t -Action $a -Principal $p -Settings $c -Force
  try {
    Start-ScheduledTask -TaskName $t
    for ($i = 0; $i -lt 30; $i++) {
      Start-Sleep -Seconds 2
      $inf = Get-ScheduledTaskInfo -TaskName $t
      if ("$((Get-ScheduledTask -TaskName $t).State)" -notin 'Running', 'Queued' -and $inf.LastTaskResult -ne 267011) { $r = $inf.LastTaskResult; break }
    }
    if ($null -eq $r) { Stop-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue }
  } finally { Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue }
  $r
}
$suyas = @()

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      if (-not $tok) { 'Necesito que tengas la sesión abierta en este equipo para revisar tus VPN.'; exit 3 }
      if (-not $suyas.Count) { 'Este equipo no tiene ninguna VPN de Windows configurada; soporte tiene que configurarla.'; exit 1 }
      $a = @(Activas)
      if ($a.Count -and (-not $vpn -or $a -contains $vpn)) { "La VPN «$($a[0])» ya está conectada."; exit 10 }
      $e = Elegida
      if (-not $e) { "No encontré la VPN «$vpn». Las configuradas son: $((Nombres) -join ', ')."; exit 1 }
      "La VPN «$($e.Nombre)» está desconectada."
      exit 0
    }
    'comprobar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      if (-not $tok) { 'Necesito que tengas la sesión abierta en este equipo para conectar tu VPN.'; exit 3 }
      if (-not (Elegida)) { 'No encontré esa VPN en este equipo.'; exit 3 }
      if (-not (Internet)) { 'Primero hace falta internet: el equipo no tiene conexión.'; exit 3 }
      exit 0
    }
    'aplicar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      $e = Elegida
      if (-not $tok -or -not $e) { 'No encontré tu sesión o la VPN para conectarla.'; exit 1 }
      $r = Marcar $e
      if ($r -ne 0) { "La VPN «$($e.Nombre)» no conectó: puede pedir una contraseña o un código que solo tú tienes. Conéctala desde el icono de red de la barra de tareas."; exit 1 }
      "Conecté la VPN «$($e.Nombre)»."
      exit 0
    }
    'verificar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      $e = Elegida
      if (-not $e) { 'No encontré la VPN.'; exit 1 }
      for ($i = 0; $i -lt 5 -and (Activas) -notcontains $e.Nombre; $i++) { Start-Sleep -Seconds 1 }
      if ((Activas) -notcontains $e.Nombre) { "La VPN «$($e.Nombre)» sigue desconectada."; exit 1 }
      "La VPN «$($e.Nombre)» está conectada."
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
