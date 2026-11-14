# Abrir una memoria USB o disco externo: si Windows lo detecta pero lo dejó sin conexión o sin letra de unidad,
# lo pone en línea y le asigna una letra (la ven todas las sesiones, como al conectarla). Nunca formatea ni repara.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

# discos USB, SD o MMC que no son los del sistema (el tipo de bus llega como nombre o como número según la versión)
function Externos {
  @(Get-Disk -ErrorAction SilentlyContinue | Where-Object {
      @('USB', 'SD', 'MMC', '7', '12', '13') -contains "$($_.BusType)" -and -not $_.IsBoot -and -not $_.IsSystem })
}
function Particiones($d) { @(Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue) }
function Letras { @(Externos | ForEach-Object { Particiones $_ } | Where-Object { [int]$_.DriveLetter -ne 0 } | ForEach-Object { "$($_.DriveLetter):" }) }
# particiones con un sistema de archivos que Windows lee, pero sin letra
function SinAbrir {
  foreach ($d in (Externos)) {
    if ($d.IsOffline) { continue }
    foreach ($p in (Particiones $d)) {
      if ([int]$p.DriveLetter -ne 0 -or $p.IsHidden -or $p.IsSystem) { continue }
      $v = Get-Volume -Partition $p -ErrorAction SilentlyContinue
      if ($v -and $v.FileSystem) { $p }
    }
  }
}
function Apagados { @(Externos | Where-Object { $_.IsOffline }) }

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      if (@(Externos).Count -eq 0) { 'El equipo no detecta ninguna memoria USB ni disco externo. Desconéctala, espera 5 segundos y conéctala en otro puerto; si sigue sin aparecer, puede estar dañada.'; exit 10 }
      $off = @(Apagados); $s = @(SinAbrir)
      if ($off.Count -eq 0 -and $s.Count -eq 0) {
        $l = @(Letras)
        if ($l.Count) { "La memoria está conectada y abierta: búscala en el Explorador de archivos, en «Este equipo», como unidad $($l -join ', ')."; exit 10 }
        'La memoria está conectada, pero Windows no reconoce lo que tiene adentro: puede estar dañada o sin formato. No la formatees si tiene archivos importantes; pide ayuda a soporte.'
        exit 10
      }
      if ($off.Count) { 'El equipo detecta la memoria, pero Windows la dejó sin conexión.' } else { 'El equipo detecta la memoria, pero no está abierta (no tiene letra de unidad).' }
      exit 0
    }
    'comprobar' {
      $yo = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
      if (-not $yo.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'Helpert necesita privilegios de administrador para abrir la memoria.'; exit 3 }
      exit 0
    }
    'aplicar' {
      foreach ($d in (Apagados)) { try { Set-Disk -Number $d.Number -IsOffline $false } catch {} }
      Start-Sleep -Seconds 2
      foreach ($p in @(SinAbrir)) { try { Add-PartitionAccessPath -DiskNumber $p.DiskNumber -PartitionNumber $p.PartitionNumber -AssignDriveLetter } catch {} }
      Start-Sleep -Seconds 1
      $l = @(Letras)
      if ($l.Count -eq 0) { 'No pude abrir la memoria: Windows no le asignó una letra de unidad.'; exit 1 }
      "- Abierta como unidad $($l -join ', ')"
      exit 0
    }
    'verificar' {
      $l = @(Letras)
      if (@(Apagados).Count -or @(SinAbrir).Count -or $l.Count -eq 0) { 'No pude abrir la memoria: puede tener un formato que el equipo no lee o estar dañada.'; exit 1 }
      "La memoria está abierta: búscala en el Explorador de archivos, en «Este equipo», como unidad $($l -join ', ')."
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
