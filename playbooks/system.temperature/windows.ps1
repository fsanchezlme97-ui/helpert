# Revisar la temperatura: la de las zonas térmicas que Windows conoce (contador ThermalZoneInformation por CIM, con
# respaldo en MSAcpi_ThermalZoneTemperature), si está frenando el procesador por calor y los programas que más
# procesador usan. Muchos equipos no exponen sus sensores a Windows: entonces se dice. Solo lectura: termina con 10.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $c = $null; $freno = $false
      try {
        foreach ($z in @(Get-CimInstance Win32_PerfFormattedData_Counters_ThermalZoneInformation -ErrorAction Stop)) {
          $k = [double]$z.HighPrecisionTemperature / 10; if (-not $k) { $k = [double]$z.Temperature }  # en kelvin
          if ($k -gt 273) { $v = [int]($k - 273.15); if ($null -eq $c -or $v -gt $c) { $c = $v } }
          if ($z.PercentPassiveLimit -and $z.PercentPassiveLimit -lt 100) { $freno = $true }
        }
      } catch {}
      if ($null -eq $c) {
        try {
          foreach ($z in @(Get-CimInstance -Namespace root\wmi -ClassName MSAcpi_ThermalZoneTemperature -ErrorAction Stop)) {
            $v = [int]($z.CurrentTemperature / 10 - 273.15); if ($v -gt 0 -and ($null -eq $c -or $v -gt $c)) { $c = $v }
          }
        } catch {}
      }
      if ($null -eq $c) { 'No pude leer la temperatura: este equipo no muestra sus sensores a Windows.' }
      elseif ($c -ge 90) { "El equipo está muy caliente: $c °C." }
      elseif ($c -ge 80) { "El equipo está caliente: $c °C." }
      else { "La temperatura del equipo es normal: $c °C." }
      if ($freno) { 'Windows está frenando el procesador para que no se caliente más.' }

      # uso de procesador de cada programa en 2 segundos, sumado por programa (un navegador son muchos procesos)
      $nucleos = 0; foreach ($p in Get-CimInstance Win32_Processor) { $nucleos += $p.NumberOfLogicalProcessors }; if ($nucleos -lt 1) { $nucleos = 1 }
      $antes = @{}
      foreach ($p in Get-Process) { try { if ($p.CPU) { $antes[$p.Id] = $p.CPU } } catch {} }
      Start-Sleep -Seconds 2
      $uso = @{}
      foreach ($p in Get-Process) {
        if ($p.Id -eq 0 -or $p.Id -eq $PID) { continue }
        try { $t = $p.CPU } catch { $t = $null }
        if ($t -and $antes.ContainsKey($p.Id)) { $uso[$p.ProcessName] += 100 * ($t - $antes[$p.Id]) / 2 / $nucleos }
      }
      $top = @($uso.Keys | Where-Object { $uso[$_] -ge 1 } | Sort-Object { $uso[$_] } -Descending | Select-Object -First 3)
      if ($top.Count) { 'Lo que más procesador usa ahora:'; foreach ($n in $top) { '- {0}: {1:0} %' -f $n, $uso[$n] } }
      else { 'Ningún programa está usando mucho el procesador ahora.' }
      if ($freno -or $c -ge 80) { 'Úsalo sobre una mesa (no sobre la cama o las piernas) y cierra lo que no uses. Si se calienta seguido, pide a un técnico que lo limpie.' }
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
