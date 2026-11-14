# Revisar la suspensión: qué programa, servicio o controlador la impide ahora (powercfg /requests), qué despertó al
# equipo la última vez (evento 1 de Power-Troubleshooter), qué dispositivos pueden despertarlo y qué hace la tapa con
# batería. Sin leer textos que cambian con el idioma salvo los nombres que da powercfg. Solo lectura: termina con 10.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

# con la salida redirigida, 5.1 convierte el stderr de un programa en error: aquí se ignora
function Powercfg { $ErrorActionPreference = 'Continue'; & "$env:SystemRoot\System32\powercfg.exe" @args 2>$null }
function Lista($x) { (@($x) | Select-Object -Unique -First 4) -join ', ' }
# quién impide la suspensión: líneas «[PROCESS] \Device\...\chrome.exe», «[SERVICE] ...\svchost.exe (wuauserv)», «[DRIVER] Nombre (ID)»
function Bloquean {
  foreach ($l in @(Powercfg /requests)) {
    if ("$l" -match '^\[[^\]]+\]\s*(.+)$') { $t = $Matches[1].Trim() } else { continue }
    if ($t -match '^(\\|[A-Za-z]:\\)') {
      if ($t -match '\(([^)]+)\)\s*$') { $Matches[1] } else { ($t -split '\\')[-1] }
    } else { $t -replace '\s*\([^)]*\)\s*$', '' }
  }
}
function UltimoDespertar {
  $ev = @(try { Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Power-Troubleshooter'; Id = 1 } -MaxEvents 1 -ErrorAction Stop } catch { })
  if ($ev.Count -eq 0) { return $null }
  $d = @(([xml]$ev[0].ToXml()).Event.EventData.Data)
  $fuente = "$(($d | Where-Object { $_.Name -eq 'WakeSourceText' } | Select-Object -First 1).'#text')".Trim()
  if (-not $fuente) { $fuente = 'una causa que Windows no anotó (suele ser una tarea programada o una actualización)' }
  "La última vez se despertó el $($ev[0].TimeCreated.ToString('dd/MM/yyyy HH:mm', [Globalization.CultureInfo]::InvariantCulture)) por: $fuente."
}
# dispositivos con permiso para despertar al equipo (MSPower_DeviceWakeEnable), con su nombre
function Despiertan {
  $si = @(try { Get-CimInstance -Namespace root/wmi -ClassName MSPower_DeviceWakeEnable -ErrorAction Stop | Where-Object { $_.Enable } } catch { })
  if ($si.Count -eq 0) { return @() }
  $nombres = @{}
  foreach ($p in @(Get-CimInstance Win32_PnPEntity -Property PNPDeviceID, Name)) { if ($p.PNPDeviceID) { $nombres["$($p.PNPDeviceID)".ToUpper()] = $p.Name } }
  foreach ($w in $si) { $n = $nombres[("$($w.InstanceName)" -replace '_\d+$', '').ToUpper()]; if ($n) { $n } }
}
# con batería, cerrar la tapa no hace nada (índice 0): el valor en batería es el último 0x… de la salida
function TapaNoSuspende {
  if (@(Get-CimInstance Win32_Battery).Count -eq 0) { return $false }
  $v = @([regex]::Matches((@(Powercfg /query SCHEME_CURRENT SUB_BUTTONS LIDACTION) -join "`n"), '0x[0-9a-fA-F]{8}'))
  $v.Count -ge 2 -and [Convert]::ToInt32($v[-1].Value, 16) -eq 0
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $yo = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
      if (-not $yo.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'Helpert necesita privilegios de administrador para revisar la suspensión.'; exit 3 }
      $avisos = @()
      $b = @(Bloquean)
      if ($b.Count) { $avisos += "Ahora impide la suspensión: $(Lista $b). Ciérralo o termina lo que esté haciendo (una descarga, una llamada, un video)." }
      if (TapaNoSuspende) { $avisos += 'Con batería, al cerrar la tapa el equipo no hace nada (no se suspende); por eso gasta batería. Puedes cambiarlo en el Panel de control > Opciones de energía.' }
      if ($avisos.Count) { 'Encontré lo que puede estar fallando con la suspensión:'; $avisos | ForEach-Object { "- $_" } }
      else { 'La suspensión está activa y ningún programa la está impidiendo ahora.' }
      $u = UltimoDespertar; if ($u) { $u }
      $d = @(Despiertan)
      if ($d.Count) { "Pueden despertar al equipo: $(Lista $d). Si se despierta solo, revisa esos dispositivos o pide a soporte que les quite el permiso." }
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
