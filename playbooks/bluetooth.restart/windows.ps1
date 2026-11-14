# Reactivar el Bluetooth: reinicia el servicio de Bluetooth (bthserv) y enciende su radio con la API de radios de Windows (Windows.Devices.Radios).
# Si Windows no deja encender la radio desde el servicio (o la apagó la persona y no lo permite), se le dice cómo
# hacerlo ella. Una política de la empresa que prohíbe el Bluetooth, o un adaptador desactivado en el Administrador de
# dispositivos (puede ser a propósito), no se tocan: los ve soporte.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

# el adaptador (radio), no los dispositivos emparejados ni los enumeradores, que también son de la clase Bluetooth
function Adaptador {
  @(Get-CimInstance Win32_PnPEntity -Filter "PNPClass='Bluetooth'" | Where-Object { $_.DeviceID -notmatch '^(BTH|SWD)' }) | Select-Object -First 1
}
function Servicio { Get-Service -Name bthserv -ErrorAction SilentlyContinue }
function Prohibido {
  $p = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Connectivity' -Name AllowBluetooth -ErrorAction SilentlyContinue
  $p -and $p.AllowBluetooth -eq 0
}
# la radio Bluetooth de la API de WinRT; $null si no se puede leer desde aquí
$asTask = $null
function Esperar($op, [type]$t) {
  if (-not $asTask) {
    $script:asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
  }
  $k = $asTask.MakeGenericMethod($t).Invoke($null, @($op))
  if (-not $k.Wait(5000)) { throw 'tiempo' }
  $k.Result
}
function Radio {
  try {
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
    $null = [Windows.Devices.Radios.Radio, Windows.System.Devices, ContentType = WindowsRuntime]
    $l = Esperar ([Windows.Devices.Radios.Radio]::GetRadiosAsync()) ([Collections.Generic.IReadOnlyList[Windows.Devices.Radios.Radio]])
    @($l | Where-Object { "$($_.Kind)" -eq 'Bluetooth' }) | Select-Object -First 1
  } catch { $null }
}
function Estado { $r = Radio; $e = "$($r.State)"; if ($e -in 'On', 'Off', 'Disabled') { $e } else { 'NoSe' } }  # Disabled = interruptor
# enciende la radio; $true si Windows lo permitió
function Encender {
  try {
    $r = Radio; if (-not $r) { return $false }
    if ("$(Esperar ([Windows.Devices.Radios.Radio]::RequestAccessAsync()) ([Windows.Devices.Radios.RadioAccessStatus]))" -ne 'Allowed') { return $false }
    "$(Esperar ($r.SetStateAsync([Windows.Devices.Radios.RadioState]::On)) ([Windows.Devices.Radios.RadioAccessStatus]))" -eq 'Allowed'
  } catch { $false }
}
$COMO = 'Enciéndelo tú en Configuración > Bluetooth y dispositivos (o en el botón de Bluetooth de la barra de tareas) y revisa que no esté en modo avión.'

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      if (Prohibido) { 'Una política de la empresa no permite el Bluetooth en este equipo: si lo necesitas, pídeselo a soporte.'; exit 3 }
      $a = Adaptador; $s = Servicio
      if (-not $a) { 'No encontré un adaptador Bluetooth en este equipo.'; exit 1 }
      if (-not $s) { 'Este equipo no tiene el servicio de Bluetooth de Windows.'; exit 1 }
      if ("$($s.StartType)" -eq 'Disabled') { 'El servicio de Bluetooth está desactivado en este equipo (puede ser una política de la empresa): avisa a soporte.'; exit 3 }
      $e = Estado
      if ($a.ConfigManagerErrorCode -eq 0 -and "$($s.Status)" -eq 'Running' -and $e -eq 'On') { 'El Bluetooth está encendido y el servicio funciona.'; exit 10 }
      if ($a.ConfigManagerErrorCode -eq 22) { 'El adaptador Bluetooth está desactivado en el Administrador de dispositivos (puede ser a propósito): pide a soporte que lo revise.'; exit 3 }
      if ($a.ConfigManagerErrorCode -ne 0) { "El adaptador Bluetooth tiene un problema (código $($a.ConfigManagerErrorCode))." }
      if ("$($s.Status)" -ne 'Running') { 'El servicio de Bluetooth está detenido.' }
      if ($e -eq 'Disabled') { 'El Bluetooth está apagado con el interruptor o la tecla del equipo: enciéndelo ahí, que yo no puedo.'; exit 1 }
      if ($e -eq 'Off') { 'El Bluetooth está apagado (o el equipo está en modo avión).' }
      if ($e -eq 'NoSe') { 'No puedo ver desde aquí si el Bluetooth está encendido; reinicio su servicio y trato de encenderlo.' }
      exit 0
    }
    'comprobar' {
      $yo = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
      if (-not $yo.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'Helpert necesita privilegios de administrador para reiniciar el Bluetooth.'; exit 3 }
      if (Prohibido) { 'Una política de la empresa no permite el Bluetooth en este equipo.'; exit 3 }
      if (-not (Adaptador) -or -not (Servicio)) { 'No encontré un adaptador Bluetooth.'; exit 3 }
      exit 0
    }
    'aplicar' {
      try { Restart-Service -Name bthserv -Force } catch { 'No se pudo reiniciar el servicio de Bluetooth.'; exit 1 }
      Start-Sleep -Seconds 2
      $e = Estado
      if ($e -ne 'On' -and -not (Encender)) { "Reinicié el servicio de Bluetooth, pero Windows no me deja encenderlo desde aquí. $COMO"; exit 0 }
      'Reinicié el servicio de Bluetooth y lo encendí.'
      exit 0
    }
    'verificar' {
      $a = Adaptador; $s = Servicio
      if (-not $a -or $a.ConfigManagerErrorCode -ne 0 -or "$($s.Status)" -ne 'Running') { 'El adaptador o el servicio de Bluetooth siguen sin funcionar. Reinicia el equipo; si sigue igual, avisa a soporte.'; exit 1 }
      $e = Estado
      for ($i = 0; $i -lt 4 -and $e -eq 'Off'; $i++) { Start-Sleep -Seconds 1; $e = Estado }
      if ($e -eq 'NoSe') { "El servicio de Bluetooth funciona, pero no puedo confirmar desde aquí que esté encendido. $COMO"; exit 1 }
      if ($e -ne 'On') { "El Bluetooth sigue apagado. $COMO"; exit 1 }
      'El Bluetooth está encendido. Si tu dispositivo no se conecta solo, apágalo y vuelve a encenderlo.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
