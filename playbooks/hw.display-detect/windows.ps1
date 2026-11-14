# Detectar un monitor externo: qué pantallas tiene activas Windows (root\wmi, WmiMonitorConnectionParams y
# WmiMonitorID) y pedirle que vuelva a buscar dispositivos (pnputil /scan-devices). No cambia la resolución ni el orden.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
# tipo de conexión: interna (0x80000000), LVDS (6), DisplayPort integrado (11) o UDI integrado (13) son la del equipo
$INTERNAS = @(2147483648, -2147483648, 6, 11, 13)

function Admin { (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Pnp { $ErrorActionPreference = 'Continue'; $null = & pnputil.exe @args 2>$null; $LASTEXITCODE }
# en una máquina virtual o sin monitores, estas clases dan «no admitido» en vez de una lista vacía
function Wmi($clase) { @(try { Get-CimInstance -Namespace root\wmi -ClassName $clase -ErrorAction Stop } catch { }) }
function Pantallas {
  $ids = Wmi 'WmiMonitorID'
  foreach ($c in (Wmi 'WmiMonitorConnectionParams')) {
    if ($c.Active -eq $false) { continue }
    $t = [int64]$c.VideoOutputTechnology
    $id = @($ids | Where-Object { $_.InstanceName -eq $c.InstanceName }) | Select-Object -First 1
    $n = ''; if ($id -and $id.UserFriendlyName) { $n = (-join [char[]]@($id.UserFriendlyName | Where-Object { $_ -ne 0 })).Trim() }
    $interna = $INTERNAS -contains $t
    if ($interna) { $n = 'pantalla del equipo' }
    elseif (-not $n) { $n = switch ($t) { 0 { 'monitor VGA' } 4 { 'monitor DVI' } 5 { 'monitor HDMI' } 10 { 'monitor DisplayPort' } 15 { 'pantalla inalámbrica' } default { 'monitor externo' } } }
    New-Object PSObject -Property @{ Interna = $interna; Nombre = $n }
  }
}
# con pantalla propia hace falta una externa más; sin ella (un equipo de escritorio), dos
function Bien($p) {
  $ext = @($p | Where-Object { -not $_.Interna }).Count; $int = @($p | Where-Object { $_.Interna }).Count
  $ext -ge 1 -and ($int -ge 1 -or $ext -ge 2)
}
function Vistas($p) { @($p | ForEach-Object { $_.Nombre }) -join ', ' }

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $p = @(Pantallas)
      if (Bien $p) {
        "Windows detecta estas pantallas: $(Vistas $p)."
        'Si una se ve negra, pulsa la tecla Windows + P y elige «Extender» o «Duplicar».'
        exit 10
      }
      if ($p.Count) { "Windows solo detecta: $(Vistas $p). No ve el monitor externo." } else { 'Windows no detecta ninguna pantalla externa.' }
      'Voy a pedirle a Windows que vuelva a buscar dispositivos.'
      exit 0
    }
    'comprobar' {
      if (-not (Admin)) { 'Helpert necesita privilegios de administrador para buscar dispositivos.'; exit 3 }
      exit 0
    }
    'aplicar' {
      if ((Pnp /scan-devices) -ne 0) { 'No pude pedirle a Windows que vuelva a buscar dispositivos (esta versión de Windows quizá no lo permite).'; exit 1 }
      Start-Sleep -Seconds 5
      'Le pedí a Windows que vuelva a buscar dispositivos.'
      exit 0
    }
    'verificar' {
      $p = @(Pantallas)
      if (-not (Bien $p)) { 'Sigue sin detectar el monitor externo. Revisa que esté encendido, con el cable bien puesto en los dos lados y en la entrada correcta (HDMI, DisplayPort); prueba otro cable o puerto. Si usas una base o adaptador, desconéctalo y conéctalo.'; exit 1 }
      "Windows detecta estas pantallas: $(Vistas $p). Si una se ve negra, pulsa Windows + P y elige «Extender»."
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
