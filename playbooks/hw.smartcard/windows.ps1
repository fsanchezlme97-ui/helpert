# Revisar el lector de tarjetas o DNIe: si Windows detecta el lector (clase SmartCardReader) y reiniciar el servicio
# de tarjetas inteligentes (SCardSvr). No instala controladores ni toca certificados.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

function Admin { (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Servicio { Get-Service SCardSvr -ErrorAction SilentlyContinue }
# sin ningún lector, Get-PnpDevice da error en vez de una lista vacía
function Lectores { @(try { Get-PnpDevice -Class SmartCardReader -PresentOnly -ErrorAction Stop } catch { }) }
function Motivo {
  $s = Servicio
  if (-not $s) { return 'Este equipo no tiene el servicio de tarjetas inteligentes de Windows.' }
  if ("$($s.StartType)" -eq 'Disabled') { return 'El servicio de tarjetas inteligentes está desactivado en este equipo: eso lo decide soporte.' }
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = Motivo; if ($m) { $m; if (Servicio) { exit 3 } else { exit 1 } }
      $l = @(Lectores)
      if ($l.Count -eq 0) {
        'El equipo no detecta ningún lector de tarjetas.'
        'Desconecta el lector o el token, espera 5 segundos y conéctalo en otro puerto. Si el lector es del teclado o de la laptop, reinicia el equipo.'
        exit 10
      }
      $bien = @($l | Where-Object { $_.Status -eq 'OK' })
      if ($bien.Count -eq 0) {
        "El equipo detecta el lector «$($l[0].FriendlyName)», pero Windows dice que tiene un problema (código $($l[0].ConfigManagerErrorCode))."
        'Desconéctalo y conéctalo en otro puerto; si sigue igual, soporte tiene que revisar su controlador.'
        exit 10
      }
      "El equipo detecta el lector «$($bien[0].FriendlyName)»."
      'Voy a reiniciar el servicio de tarjetas. Cierra antes el navegador o el programa de firma que la estaba usando.'
      exit 0
    }
    'comprobar' {
      if (-not (Admin)) { 'Helpert necesita privilegios de administrador para reiniciar el servicio de tarjetas.'; exit 3 }
      $m = Motivo; if ($m) { $m; exit 3 }
      exit 0
    }
    'aplicar' {
      try { Restart-Service SCardSvr -Force } catch { 'No pude reiniciar el servicio de tarjetas.'; exit 1 }
      Start-Sleep -Seconds 2
      'Reinicié el servicio de tarjetas.'
      exit 0
    }
    'verificar' {
      for ($i = 0; $i -lt 5 -and (Servicio).Status -ne 'Running'; $i++) { Start-Sleep -Seconds 1 }
      if ((Servicio).Status -ne 'Running') { 'El servicio de tarjetas no volvió a arrancar: avisa a soporte.'; exit 1 }
      $bien = @(Lectores | Where-Object { $_.Status -eq 'OK' })
      if ($bien.Count -eq 0) { 'El servicio funciona, pero el equipo ya no detecta el lector: desconéctalo y conéctalo en otro puerto.'; exit 1 }
      "El servicio de tarjetas funciona y detecta «$($bien[0].FriendlyName)». Saca la tarjeta, vuelve a ponerla y abre de nuevo el programa de firma o el navegador."
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
