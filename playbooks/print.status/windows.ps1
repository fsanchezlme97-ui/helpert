# Ver las impresoras y su estado: las instaladas en el equipo (Get-Printer), la predeterminada de la persona (en su
# rama del registro) y si están en pausa, sin conexión o con trabajos. Las que la persona conectó desde un servidor
# (\\servidor\impresora) son de su sesión: se nombran, pero su estado no se ve desde el servicio. Solo lectura: termina con 10.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

function SidDe($cuenta) {  # solo cuentas de personas (locales, de dominio o de Entra ID), nunca SYSTEM ni de servicio
  if (-not $cuenta) { return $null }
  try { $s = (New-Object Security.Principal.NTAccount($cuenta)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { return $null }
  if ($s -match '^S-1-(5-21|12-1)-') { $s }
}
function Valor($ruta, $nombre) {
  try { (Get-ItemProperty -LiteralPath $ruta -Name $nombre -ErrorAction Stop).$nombre } catch { $null }
}
# estado de Get-Printer (MSFT_Printer.PrinterStatus) en palabras; los normales no se nombran
$ESTADOS = @{ 1 = 'en pausa'; 2 = 'con un error'; 4 = 'con un atasco de papel'; 5 = 'sin papel'; 7 = 'con un problema de papel'; 8 = 'sin conexión'; 13 = 'no disponible'; 19 = 'sin tóner'; 21 = 'necesita que alguien la revise'; 23 = 'con una tapa abierta' }
function Estado($p) {
  $e = @()
  $s = [int]$p.PrinterStatus
  if ($ESTADOS.ContainsKey($s)) { $e += $ESTADOS[$s] }
  if ($p.WorkOffline -and $s -ne 8) { $e += 'sin conexión' }
  if ($p.JobCount) { $e += "$($p.JobCount) trabajo(s) en cola" }
  if ($e.Count) { $e -join ', ' } else { 'lista' }
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      if ((Get-Service Spooler -ErrorAction SilentlyContinue).Status -ne 'Running') { 'El servicio de impresión está detenido: «Liberar cola de impresión» lo vuelve a arrancar.'; exit 10 }
      $t = @(Get-Printer -ErrorAction SilentlyContinue | Sort-Object Name)
      $sid = SidDe $env:HP_USUARIO
      $red = @(); $d = $null
      if ($sid) {
        $red = @(Get-ChildItem -LiteralPath "Registry::HKEY_USERS\$sid\Printers\Connections" -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName -replace ',', '\' })
        $d = Valor "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows NT\CurrentVersion\Windows" 'Device'
        if ($d) { $d = ($d -split ',')[0] }
      }
      $nombres = @($t | ForEach-Object { $_.Name }); $red = @($red | Where-Object { $nombres -notcontains $_ })
      if (-not $d) { $x = @($t | Where-Object { $_.Default }); if ($x.Count) { $d = $x[0].Name } }
      $n = $t.Count + $red.Count
      if ($n -eq 0) { 'Este equipo no tiene impresoras instaladas; si necesitas una, soporte tiene que instalarla.'; exit 10 }
      if ($d) { "Hay $n impresora(s); la predeterminada es «$d»." } else { "Hay $n impresora(s) y ninguna es la predeterminada." }
      foreach ($p in ($t | Select-Object -First 7)) {
        $marca = ''; if ($p.Name -eq $d) { $marca = ' (predeterminada)' }
        "- $($p.Name)${marca}: $(Estado $p)."
      }
      if ($t.Count -gt 7) { "… y $($t.Count - 7) más en este equipo." }
      if ($red.Count) { "Conectadas desde un servidor (desde aquí no veo su estado): $(@($red | Select-Object -First 3) -join ', ')." }
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
