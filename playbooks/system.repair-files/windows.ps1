# Reparar archivos de Windows: primero la imagen del sistema (DISM, con Repair-WindowsImage) y después los archivos
# (sfc /scannow). Sin leer textos de sfc ni dism, que cambian con el idioma: el estado viene del cmdlet y lo que hizo
# SFC se cuenta en las líneas [SR] que añade a CBS.log (siempre en inglés).
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$CBS = "$env:SystemRoot\Logs\CBS\CBS.log"

function Admin { (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Hay { [bool](Get-Command Repair-WindowsImage -ErrorAction SilentlyContinue) }
function Estado { "$((Repair-WindowsImage -Online -CheckHealth -WarningAction SilentlyContinue).ImageHealthState)" }  # Healthy, Repairable o NonRepairable
function Pendiente { Test-Path -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending' }
function Largo { if (Test-Path -LiteralPath $CBS) { (Get-Item -LiteralPath $CBS).Length } else { 0 } }
# lo que se escribió en CBS.log desde la posición $desde (si el archivo se renovó, desde el principio)
function Nuevo($desde) {
  if (-not (Test-Path -LiteralPath $CBS)) { return '' }
  $f = New-Object IO.FileStream $CBS, ([IO.FileMode]::Open), ([IO.FileAccess]::Read), ([IO.FileShare]::ReadWrite)
  try {
    if ($f.Length -ge $desde) { [void]$f.Seek($desde, [IO.SeekOrigin]::Begin) }
    (New-Object IO.StreamReader $f).ReadToEnd()
  } finally { $f.Dispose() }
}
function NoPuedo {
  if (-not (Admin)) { return 'Helpert necesita privilegios de administrador para reparar Windows.' }
  if (-not (Hay)) { return 'Este Windows no tiene la herramienta de reparación (DISM) disponible.' }
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = NoPuedo; if ($m) { $m; exit 3 }
      if (Pendiente) { 'Windows tiene una actualización a medio instalar que necesita reiniciar. Reinicia el equipo y vuelve a pedirme la reparación.'; exit 1 }
      $e = Estado
      if ($e -eq 'NonRepairable') { 'Windows tiene daños que no se pueden reparar desde aquí. Avisa a soporte: puede hacer falta reinstalarlo.'; exit 1 }
      if ($e -eq 'Repairable') { 'Windows tiene archivos del sistema dañados que se pueden reparar.' }
      else { 'Windows no tiene daños anotados, pero la revisión completa puede encontrar archivos dañados que aún no se detectaron.' }
      'Revisaría y repararía los archivos del sistema (SFC y DISM). Tarda entre 10 y 30 minutos; puedes seguir usando el equipo.'
      exit 0
    }
    'comprobar' {
      $m = NoPuedo; if ($m) { $m; exit 3 }
      if (Pendiente) { 'Primero hay que reiniciar el equipo: hay una actualización a medio instalar.'; exit 3 }
      exit 0
    }
    'aplicar' {
      $avisos = @()
      # 1. la imagen (de ahí saca SFC las copias buenas); usa Windows Update para bajar lo que falte
      try { $null = Repair-WindowsImage -Online -RestoreHealth -NoRestart -WarningAction SilentlyContinue }
      catch { $avisos += 'No pude reparar la imagen de Windows (puede que falte internet o que la empresa bloquee Windows Update).' }
      # 2. los archivos
      $desde = Largo
      $ErrorActionPreference = 'Continue'
      & "$env:SystemRoot\System32\sfc.exe" /scannow 2>$null | Out-Null
      $ErrorActionPreference = 'Stop'
      $log = Nuevo $desde
      if ($log -notmatch '\[SR\]') { 'No pude ejecutar la revisión de archivos (SFC). Reinicia el equipo y vuelve a intentarlo; si sigue igual, avisa a soporte.'; exit 1 }
      $malos = ([regex]::Matches($log, '\[SR\] (Cannot repair member file|Could not reproject corrupted file)')).Count
      $arreglados = ([regex]::Matches($log, '\[SR\] Repairing corrupted file')).Count
      if ($malos -gt 0) {
        "Reparé $arreglados archivo(s), pero quedaron $malos que no se pudieron reparar. Avisa a soporte."
        $avisos; exit 1
      }
      if ($arreglados -gt 0) { "Revisé los archivos del sistema y reparé $arreglados archivo(s) dañado(s). Reinicia el equipo cuando puedas." }
      else { 'Revisé los archivos del sistema y no encontré ninguno dañado.' }
      $avisos
      exit 0
    }
    'verificar' {
      $e = Estado
      if ($e -ne 'Healthy') { 'Windows todavía tiene daños en sus archivos. Avisa a soporte.'; exit 1 }
      'Los archivos de Windows están en buen estado.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
