# Revisar la salud del disco: el estado que Windows lee de cada disco físico (Get-PhysicalDisk, que viene de SMART),
# sus contadores de fiabilidad (desgaste y errores de lectura sin corregir, si el disco los da), el aviso de falla
# de SMART (MSStorageDriver_FailurePredictStatus) y los errores de disco del registro del sistema en los últimos
# 7 días (disk 7, 51 y 153). Dice si conviene cambiarlo. Solo lectura: termina con 10.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

function Salud($d) {  # @(clase, frase): mal, sano o nada
  $quien = "$($d.FriendlyName) ($([math]::Round($d.Size / 1GB)) GB)"
  $r = $null; try { $r = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { }
  $h = "$($d.HealthStatus)"  # llega como nombre o como número según la versión
  $err = 0; $uso = 0
  if ($r) { $err = [int64]$r.ReadErrorsUncorrected; $uso = [int]$r.Wear }
  if ($h -eq 'Unhealthy' -or $h -eq '2') { return @('mal', "- ${quien}: el propio disco avisa que está fallando.") }
  if ($err -gt 0) { return @('mal', "- ${quien}: tuvo $err error(es) de lectura que no pudo corregir.") }
  if ($uso -ge 90) { return @('mal', "- ${quien}: está gastado al $uso % de su vida útil.") }
  if ($h -eq 'Warning' -or $h -eq '1') { return @('mal', "- ${quien}: Windows marca su estado como «Advertencia».") }
  if ($h -eq 'Healthy' -or $h -eq '0') { $x = ''; if ($uso -gt 0) { $x = " (gastado al $uso %)" }; return @('sano', "- ${quien}: sano$x.") }
  @('nada', "- ${quien}: no informa su estado.")
}
function ErroresDisco {
  try { @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'disk'; Id = 7, 51, 153; StartTime = (Get-Date).AddDays(-7) } -MaxEvents 500 -ErrorAction Stop).Count } catch { 0 }
}
function Predice { @(try { Get-CimInstance -Namespace root\wmi -ClassName MSStorageDriver_FailurePredictStatus -ErrorAction Stop } catch { }) | Where-Object { $_.PredictFailure } }

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $ds = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | Sort-Object DeviceId)
      if ($ds.Count -eq 0) { 'No pude leer los discos de este equipo (puede que necesite privilegios de administrador).'; exit 1 }
      $lineas = @(); $malos = 0; $sanos = 0
      foreach ($d in $ds) {
        $s = Salud $d
        if ($s[0] -eq 'mal') { $malos++ } elseif ($s[0] -eq 'sano') { $sanos++ }
        $lineas += $s[1]
      }
      $p = @(Predice).Count
      if ($p) { $malos++; $lineas += "- Un disco avisa por SMART que va a fallar." }
      $ev = ErroresDisco
      if ($malos) { 'Conviene cambiar el disco: haz copia de tus archivos importantes cuanto antes y avisa a soporte.' }
      elseif ($ev) { 'El disco dice estar sano, pero Windows registró errores de disco en los últimos 7 días: haz copia de tus archivos importantes y avisa a soporte.' }
      elseif ($sanos) { 'El disco está sano según su estado SMART; no hace falta cambiarlo.' }
      else { 'Ningún disco de este equipo informa su estado: no puedo decir si conviene cambiarlo. Pide a soporte que lo revise.' }
      $lineas | Select-Object -First 5
      if ($ev) { "- Windows registró $ev error(es) de disco en los últimos 7 días." }
      if (-not $malos -and -not $ev -and $sanos) { 'Si el equipo se sigue congelando, la causa puede ser otra (poca memoria o disco lleno): pide a soporte que lo revise.' }
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
