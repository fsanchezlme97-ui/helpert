# Revisar el escáner: si Windows lo detecta (dispositivos de imagen que no son cámaras) y reiniciar el servicio de
# escaneo (Adquisición de imágenes de Windows, stisvc). No instala controladores.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

function Servicio { Get-Service stisvc -ErrorAction SilentlyContinue }
function Admin { (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
# sin ningún dispositivo de esa clase, Get-PnpDevice da error en vez de una lista vacía
function Escaneres { @(@(try { Get-PnpDevice -Class Image -PresentOnly -ErrorAction Stop } catch { }) | Where-Object { $_.FriendlyName -notmatch 'cam|video|\bIR\b' }) }
function Motivo {
  $s = Servicio
  if (-not $s) { return 'Este equipo no tiene el servicio de escaneo de Windows (Adquisición de imágenes de Windows).' }
  if ("$($s.StartType)" -eq 'Disabled') { return 'El servicio de escaneo está desactivado en este equipo: eso lo decide soporte.' }
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = Motivo; if ($m) { $m; if (Servicio) { exit 3 } else { exit 1 } }
      $e = @(Escaneres)
      if ($e.Count) {
        "El equipo detecta el escáner «$($e[0].FriendlyName)»."
        $mal = @($e | Where-Object { $_.Status -ne 'OK' })
        if ($mal.Count) { "Windows dice que tiene un problema (código $($mal[0].ConfigManagerErrorCode)): si sigue después de reiniciar el servicio, soporte tiene que revisar su controlador." }
      } else {
        'El equipo no detecta ningún escáner. Si es USB, desconéctalo y conéctalo en otro puerto; si es de red, revisa que esté encendido y en la misma red.'
      }
      'Voy a reiniciar el servicio de escaneo.'
      exit 0
    }
    'comprobar' {
      if (-not (Admin)) { 'Helpert necesita privilegios de administrador para reiniciar el servicio de escaneo.'; exit 3 }
      $m = Motivo; if ($m) { $m; exit 3 }
      exit 0
    }
    'aplicar' {
      try { Restart-Service stisvc -Force } catch { 'No pude reiniciar el servicio de escaneo.'; exit 1 }
      Start-Sleep -Seconds 2
      'Reinicié el servicio de escaneo.'
      exit 0
    }
    'verificar' {
      for ($i = 0; $i -lt 5 -and (Servicio).Status -ne 'Running'; $i++) { Start-Sleep -Seconds 1 }
      if ((Servicio).Status -ne 'Running') { 'El servicio de escaneo no volvió a arrancar: avisa a soporte.'; exit 1 }
      $e = @(Escaneres | Where-Object { $_.Status -eq 'OK' })
      if ($e.Count -eq 0) { 'El servicio de escaneo funciona, pero el equipo sigue sin detectar el escáner. Revisa el cable o la red; si sigue igual, pide a soporte que revise su controlador.'; exit 1 }
      "El servicio de escaneo funciona y detecta «$($e[0].FriendlyName)». Prueba escanear de nuevo."
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
