# Ver los datos del equipo: nombre, sistema, número de serie, memoria, disco e IP. Solo lectura: termina con 10.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $os = Get-CimInstance Win32_OperatingSystem
      $cs = Get-CimInstance Win32_ComputerSystem
      $serie = "$((Get-CimInstance Win32_BIOS).SerialNumber)".Trim()
      if (-not $serie -or $serie -match '^(0|To be filled.*|Default string|System Serial Number)$') { $serie = 'no disponible' }
      $ver = ''
      try { $ver = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name DisplayVersion).DisplayVersion } catch {}
      $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
      # la IP de la conexión que tiene salida (con puerta de enlace); si no hay, cualquiera que no sea automática (169.254)
      $red = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = True')
      $ips = @($red | Where-Object { $_.DefaultIPGateway } | ForEach-Object { $_.IPAddress } | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
      if (-not $ips.Count) { $ips = @($red | ForEach-Object { $_.IPAddress } | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' -and $_ -notlike '169.254.*' }) }
      $ip = 'sin conexión de red'; if ($ips.Count) { $ip = $ips[0] }
      "Nombre del equipo: $env:COMPUTERNAME"
      $s = "Sistema: $($os.Caption)"; if ($ver) { $s += " $ver" }; "$s (versión $($os.Version))"
      "Modelo: $("$($cs.Manufacturer) $($cs.Model)".Trim())"
      "Número de serie: $serie"
      if ($cs.PartOfDomain) { "Dominio: $($cs.Domain)" }
      'Memoria: {0:0.0} GB' -f ($cs.TotalPhysicalMemory / 1GB)
      'Disco del sistema: {0:0} GB en total, {1:0} GB libres' -f ($d.Size / 1GB), ($d.FreeSpace / 1GB)
      "Dirección IP: $ip"
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
