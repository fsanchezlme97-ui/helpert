# Revisar el lector de huellas: si Windows detecta el lector (clase Biometric, sin las cámaras de reconocimiento
# facial) y reiniciar el servicio biométrico de Windows (WbioSrvc). No registra huellas. Si una política de la
# empresa desactiva la biometría, lo dice y sale con 3.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

function Valor($ruta, $nombre) {
  try { (Get-ItemProperty -LiteralPath $ruta -Name $nombre -ErrorAction Stop).$nombre } catch { $null }
}
function Admin { (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Servicio { Get-Service WbioSrvc -ErrorAction SilentlyContinue }
# sin ningún lector, Get-PnpDevice da error en vez de una lista vacía
function Lectores { @(@(try { Get-PnpDevice -Class Biometric -PresentOnly -ErrorAction Stop } catch { }) | Where-Object { $_.FriendlyName -notmatch 'face|facial|rostro' }) }
function Motivo {
  $b = 'HKLM:\SOFTWARE\Policies\Microsoft\Biometrics'
  if ((Valor $b 'Enabled') -eq 0 -or (Valor "$b\Credential Provider" 'Enabled') -eq 0) { return 'Una política de la empresa no permite usar la huella en este equipo: eso lo decide soporte.' }
  $s = Servicio
  if (-not $s) { return 'Este equipo no tiene el servicio biométrico de Windows.' }
  if ("$($s.StartType)" -eq 'Disabled') { return 'El servicio biométrico de Windows está desactivado en este equipo: eso lo decide soporte.' }
}
$REGISTRAR = 'Si nunca registraste tu huella, hazlo en Configuración > Cuentas > Opciones de inicio de sesión (Helpert no registra huellas).'

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = Motivo; if ($m) { $m; if ($m -like 'Este equipo no tiene*') { exit 1 } else { exit 3 } }
      $l = @(Lectores)
      if ($l.Count -eq 0) { 'El equipo no detecta ningún lector de huellas. Si es externo, desconéctalo, espera 5 segundos y conéctalo en otro puerto.'; exit 10 }
      $mal = @($l | Where-Object { $_.Status -ne 'OK' })
      "El equipo detecta el lector «$($l[0].FriendlyName)»."
      if ($mal.Count) { "Windows dice que tiene un problema (código $($mal[0].ConfigManagerErrorCode)): si sigue después de reiniciar el servicio, soporte tiene que revisar su controlador." }
      $REGISTRAR
      'Voy a reiniciar el servicio de huellas.'
      exit 0
    }
    'comprobar' {
      if (-not (Admin)) { 'Helpert necesita privilegios de administrador para reiniciar el servicio de huellas.'; exit 3 }
      $m = Motivo; if ($m) { $m; exit 3 }
      exit 0
    }
    'aplicar' {
      try { Restart-Service WbioSrvc -Force } catch { 'No pude reiniciar el servicio de huellas.'; exit 1 }
      Start-Sleep -Seconds 2
      'Reinicié el servicio de huellas.'
      exit 0
    }
    'verificar' {
      for ($i = 0; $i -lt 5 -and (Servicio).Status -ne 'Running'; $i++) { Start-Sleep -Seconds 1 }
      if ((Servicio).Status -ne 'Running') { 'El servicio de huellas no volvió a arrancar: avisa a soporte.'; exit 1 }
      $bien = @(Lectores | Where-Object { $_.Status -eq 'OK' })
      if ($bien.Count -eq 0) { 'El servicio funciona, pero el lector sigue con problemas: soporte tiene que revisar su controlador.'; exit 1 }
      'El lector de huellas funciona. Bloquea la sesión (Windows + L) y prueba entrar con tu huella.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
