# Reiniciar el equipo: shutdown.exe programa el reinicio en 2 minutos (lo guarda Windows, no este proceso) y muestra el
# aviso a quien tenga la sesión abierta. Windows no deja consultar un reinicio programado: verificar busca en el registro
# de eventos la solicitud de Helpert (evento 1074, que se escribe al pedirlo) sin una cancelación (1075) posterior.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$AVISO = 'Helpert: el equipo se reiniciará en 2 minutos. Guarda tu trabajo y cierra los programas.'

function Eventos($id, $desde) {
  try { @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'User32'; Id = $id; StartTime = $desde } -ErrorAction Stop) } catch { @() }
}
function Programado {
  # solo pedidos desde el último arranque (si no, el de antes del reinicio contaría) y de los últimos 10 minutos
  $desde = (Get-Date).AddMinutes(-10); $arranque = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
  if ($arranque -gt $desde) { $desde = $arranque }
  # el comentario va en los datos del evento (no en el texto, que cambia con el idioma)
  $pedido = @(Eventos 1074 $desde | Where-Object { @($_.Properties | Where-Object { "$($_.Value)" -like 'Helpert:*' }).Count }) | Select-Object -First 1
  if (-not $pedido) { return $false }
  -not @(Eventos 1075 $pedido.TimeCreated | Where-Object { $_.TimeCreated -gt $pedido.TimeCreated }).Count
}
function Pendiente {
  (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
  (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      if (Programado) { 'Ya hay un reinicio programado en este equipo.'; exit 10 }
      $dias = [int][math]::Floor(((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalDays)
      "El equipo lleva $dias día(s) sin reiniciarse."
      if (Pendiente) { 'Hay una actualización instalada que necesita reiniciar para terminar.' }
      'Puedo programar un reinicio en 2 minutos, con un aviso en tu pantalla para que guardes tu trabajo.'
      exit 0
    }
    'comprobar' {
      $yo = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
      if (-not $yo.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'Helpert necesita privilegios de administrador para reiniciar el equipo.'; exit 3 }
      exit 0
    }
    'aplicar' {
      # con 'Stop', una línea de stderr de shutdown.exe cortaría el script: lo que importa es su código de salida
      $ErrorActionPreference = 'Continue'
      $null = & "$env:SystemRoot\System32\shutdown.exe" /r /t 120 /d p:0:0 /c $AVISO 2>$null
      $c = $LASTEXITCODE; $ErrorActionPreference = 'Stop'
      if ($c -eq 1190) { 'Ya había un reinicio programado en este equipo: sigue en pie.'; exit 0 }  # ERROR_SHUTDOWN_IS_SCHEDULED
      if ($c -ne 0) { "Windows no aceptó programar el reinicio (código $c)."; exit 1 }
      "Programé el reinicio para las $((Get-Date).AddMinutes(2).ToString('HH:mm')), dentro de 2 minutos. Windows te muestra el aviso en la pantalla: guarda tu trabajo y cierra los programas."
      exit 0
    }
    'verificar' {
      if (-not (Programado)) { 'No encuentro ningún reinicio programado.'; exit 1 }
      'El reinicio está programado: el equipo se reiniciará en unos minutos.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
