# Revisar los dispositivos USB: lista lo que Windows detecta por USB (sin concentradores ni las interfaces de cada
# dispositivo), con el nombre que el propio dispositivo informa, y reinicia la detección (pnputil /scan-devices).
# No reinicia ni desconecta ningún dispositivo (una memoria a medio escribir se dañaría).
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

function Admin { (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Pnp { $ErrorActionPreference = 'Continue'; $null = & pnputil.exe @args 2>$null; $LASTEXITCODE }
function Usb {
  @(Get-CimInstance Win32_PnPEntity -ErrorAction SilentlyContinue | Where-Object {
      $_.PNPDeviceID -like 'USB\*' -and $_.PNPDeviceID -notlike 'USB\ROOT_HUB*' -and $_.PNPDeviceID -notlike '*&MI_*' -and
      @('usbhub', 'usbhub3') -notcontains "$($_.Service)" -and $_.ConfigManagerErrorCode -ne 45 })
}
# el nombre que informa el dispositivo («USB Receiver») dice más que el de Windows («Dispositivo compuesto USB»)
function Nombre($d) {
  $n = $null
  try { $n = (Get-PnpDeviceProperty -InstanceId $d.PNPDeviceID -KeyName 'DEVPKEY_Device_BusReportedDeviceDesc' -ErrorAction Stop).Data } catch { }
  if (-not $n) { $n = $d.Name }
  if (-not $n) { $n = 'Dispositivo desconocido' }
  $n
}
function ConError($l) { @($l | Where-Object { $_.ConfigManagerErrorCode -ne 0 }) }
function Resumen($l) {
  if ($l.Count -eq 0) { 'Windows no detecta ningún dispositivo USB conectado.'; return }
  "Windows detecta $($l.Count) dispositivo(s) USB:"
  foreach ($d in ($l | Select-Object -First 6)) { $m = ''; if ($d.ConfigManagerErrorCode -ne 0) { $m = ' (con error)' }; "- $(Nombre $d)$m" }
  if ($l.Count -gt 6) { "… y $($l.Count - 6) más." }
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $l = @(Usb)
      Resumen $l
      if (@(ConError $l).Count) { 'Alguno tiene un error: puede ser el cable, el puerto o su controlador.' }
      'Voy a reiniciar la detección de USB. Si lo que falla es una memoria, usa «Abrir una memoria USB».'
      exit 0
    }
    'comprobar' {
      if (-not (Admin)) { 'Helpert necesita privilegios de administrador para reiniciar la detección de USB.'; exit 3 }
      exit 0
    }
    'aplicar' {
      if ((Pnp /scan-devices) -ne 0) { 'No pude reiniciar la detección de USB (esta versión de Windows quizá no lo permite).'; exit 1 }
      Start-Sleep -Seconds 5
      'Reinicié la detección de USB.'
      exit 0
    }
    'verificar' {
      $l = @(Usb); $mal = @(ConError $l)
      if ($mal.Count) { "Sigue con error: $(@($mal | Select-Object -First 3 | ForEach-Object { Nombre $_ }) -join ', '). Conéctalo en otro puerto o con otro cable; si sigue igual, soporte tiene que revisar su controlador."; exit 1 }
      Resumen $l
      'Si el tuyo no aparece, desconéctalo, espera 5 segundos y conéctalo en otro puerto.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
