# Revisar la batería: carga, salud (capacidad actual frente a la de fábrica), ciclos y cargador. Win32_Battery da la
# carga; root\wmi (si el fabricante lo expone) da capacidades, ciclos y si hay corriente. Solo lectura: termina con 10.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

function Wmi($clase) { try { @(Get-CimInstance -Namespace root\wmi -ClassName $clase -ErrorAction Stop) } catch { @() } }

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $b = @(Get-CimInstance Win32_Battery)
      if (-not $b.Count) { 'Este equipo no tiene batería (o Windows no la detecta).'; exit 10 }
      $carga = $b[0].EstimatedChargeRemaining
      $estado = @(Wmi 'BatteryStatus') | Select-Object -First 1
      if ($estado) { $cargador = [bool]$estado.PowerOnline; $cargando = [bool]$estado.Charging }
      else { $st = [int]$b[0].BatteryStatus; $cargador = @(2, 3, 6, 7, 8, 9, 11) -contains $st; $cargando = @(6, 7, 8, 9) -contains $st }  # 1, 4, 5: con batería
      $fabrica = 0; foreach ($x in Wmi 'BatteryStaticData') { $fabrica += [double]$x.DesignedCapacity }
      $lleno = 0; foreach ($x in Wmi 'BatteryFullChargedCapacity') { $lleno += [double]$x.FullChargedCapacity }
      $ciclos = 0; foreach ($x in Wmi 'BatteryCycleCount') { $ciclos += [int]$x.CycleCount }
      $salud = $null; if ($fabrica -gt 0 -and $lleno -gt 0) { $salud = [int][math]::Min(100, 100 * $lleno / $fabrica) }
      $t = "Batería al $carga %"
      if ($cargando) { $t += ', cargando' }
      if ($cargador) { $t += '. Cargador: conectado.' } else { $t += '. Cargador: desconectado.' }
      $t
      if ($null -ne $salud) { "Salud: $salud % de la capacidad que tenía nueva." }
      if ($ciclos -gt 0) { "Ciclos de carga: $ciclos." }
      if ($null -ne $salud -and $salud -lt 60) { 'La batería está muy gastada: pide a soporte que la cambien.' }
      elseif ($null -ne $salud -and $salud -lt 80) { 'La batería ya está gastada y dura menos que nueva; si no te alcanza, pide a soporte que la cambien.' }
      if ($cargador -and -not $cargando -and $carga -lt 95) { 'No está cargando aunque el cargador está conectado. Algunos equipos frenan la carga para cuidar la batería; si no es así, prueba otro enchufe o cargador, o avisa a soporte.' }
      if (-not $cargador -and $carga -le 15) { 'Queda poca carga: conecta el cargador.' }
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
