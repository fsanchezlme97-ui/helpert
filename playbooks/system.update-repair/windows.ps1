# Reparar Windows Update sin instalar nada: para sus servicios, renombra las carpetas de descargas y de firmas
# (SoftwareDistribution y catroot2, que Windows vuelve a crear) con el sufijo .helpert-<fecha>, vuelve a arrancar los
# servicios y, si el almacén de componentes está dañado, lo repara (DISM RestoreHealth). Eso tarda y va al final,
# con los servicios ya arrancados, para que un corte por tiempo no los deje parados.
# No activa servicios desactivados ni salta políticas de la empresa: eso lo decide soporte.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$SERVICIOS = 'wuauserv', 'bits', 'cryptsvc'
$CARPETAS = "$env:SystemRoot\SoftwareDistribution", "$env:SystemRoot\System32\catroot2"
$POLITICA = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'

function Valor($ruta, $nombre) { try { (Get-ItemProperty -LiteralPath $ruta -Name $nombre -ErrorAction Stop).$nombre } catch { $null } }
function Admin { (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Bloqueo {
  if ((Valor $POLITICA 'DisableWindowsUpdateAccess') -eq 1) { return 'Una política de la empresa bloquea Windows Update en este equipo: lo tiene que revisar soporte.' }
  $off = @($SERVICIOS | Where-Object { (Get-CimInstance Win32_Service -Filter "Name='$_'").StartMode -eq 'Disabled' })
  if ($off.Count) { return "El servicio $($off -join ', ') está desactivado (puede ser una decisión de la empresa): lo tiene que revisar soporte." }
}
function Pendiente {
  (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
  (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
}
# fallos de búsqueda, descarga o instalación de los últimos 30 días
function Fallos {
  try {
    @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-WindowsUpdateClient/Operational'; Id = 20, 25, 31; StartTime = (Get-Date).AddDays(-30) } -ErrorAction Stop).Count
  } catch { 0 }
}
# Healthy, Repairable o NonRepairable; $null si no se pudo revisar
function Salud { try { "$((Repair-WindowsImage -Online -CheckHealth -ErrorAction Stop).ImageHealthState)" } catch { $null } }
function Ocupado { try { (New-Object -ComObject Microsoft.Update.Installer).IsBusy } catch { $false } }

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      if (-not (Admin)) { 'Helpert necesita privilegios de administrador para revisar Windows Update.'; exit 3 }
      $b = Bloqueo; if ($b) { $b; exit 3 }
      $f = Fallos; $s = Salud
      if ($f -eq 0 -and $s -ne 'Repairable' -and $s -ne 'NonRepairable') {
        'No veo fallos de Windows Update en los últimos 30 días ni daños en los componentes del sistema.'
        if (Pendiente) { 'Hay un reinicio pendiente: reinicia el equipo y vuelve a intentar la actualización.' }
        'Si sigue fallando, dale a soporte el código de error que muestra Windows Update.'
        exit 10
      }
      if ($f) { "Windows Update registró $f fallo(s) en los últimos 30 días." }
      if ($s -eq 'NonRepairable') { 'Los componentes del sistema están dañados y no se pueden reparar desde aquí: lo tiene que ver soporte.'; exit 1 }
      if ($s -eq 'Repairable') { 'Los componentes del sistema tienen daños que se pueden reparar.' }
      'Puedo reiniciar los componentes de Windows Update (sin instalar nada); tarda unos minutos.'
      if (Pendiente) { 'Antes hay que reiniciar el equipo: tiene un reinicio pendiente.' }
      exit 0
    }
    'comprobar' {
      if (-not (Admin)) { 'Helpert necesita privilegios de administrador para reparar Windows Update.'; exit 3 }
      $b = Bloqueo; if ($b) { $b; exit 3 }
      if (Pendiente) { 'Hay un reinicio pendiente de una actualización: reinicia el equipo primero y vuelve a intentarlo.'; exit 3 }
      if (Ocupado) { 'Windows está instalando actualizaciones ahora: espera a que termine.'; exit 3 }
      exit 0
    }
    'aplicar' {
      $sufijo = '.helpert-' + (Get-Date -Format 'yyyyMMdd-HHmm')
      $hechas = 0; $m = $null
      try {
        foreach ($n in $SERVICIOS) { Stop-Service -Name $n -Force -ErrorAction Stop }
        foreach ($c in $CARPETAS) {
          if (Test-Path -LiteralPath $c) { Rename-Item -LiteralPath $c -NewName ((Split-Path -Leaf $c) + $sufijo); $hechas++ }
        }
      } catch {
        $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
        $m = "No pude reiniciar los componentes de Windows Update: $($e.Message)"
      } finally {
        foreach ($n in $SERVICIOS) { try { Start-Service -Name $n -ErrorAction Stop } catch {} }
      }
      if ($m) { $m; exit 1 }
      "Reinicié los componentes de Windows Update ($hechas carpeta(s) renombradas con el sufijo $sufijo)."
      if ((Salud) -eq 'Repairable') {
        try { $null = Repair-WindowsImage -Online -RestoreHealth -NoRestart -ErrorAction Stop; 'También reparé los componentes del sistema.' }
        catch { 'No pude reparar los componentes del sistema: lo tiene que ver soporte.'; exit 1 }
      }
      exit 0
    }
    'verificar' {
      # wuauserv y bits arrancan cuando hacen falta y se paran solos: basta con que no estén desactivados
      $mal = @($SERVICIOS | Where-Object { (Get-CimInstance Win32_Service -Filter "Name='$_'").StartMode -eq 'Disabled' })
      if ((Get-Service -Name cryptsvc).Status -ne 'Running') { $mal += 'cryptsvc' }
      if ($mal.Count) { "El servicio $($mal -join ', ') no quedó funcionando."; exit 1 }
      $s = Salud
      if ($s -eq 'Repairable' -or $s -eq 'NonRepairable') { 'Los componentes del sistema siguen dañados: lo tiene que ver soporte.'; exit 1 }
      'Windows Update quedó listo. Vuelve a buscar actualizaciones en Configuración > Windows Update.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
