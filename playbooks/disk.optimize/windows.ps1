# Optimizar el disco del sistema con lo que Windows hace según el tipo de disco (Optimize-Volume sin opciones, igual
# que «Optimizar unidades»): TRIM en SSD, desfragmentación en discos mecánicos. Solo el disco del sistema.
# Si la empresa desactivó el servicio de optimización, no se fuerza.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$letra = $env:SystemDrive.TrimEnd(':')

function Tipo {  # 'SSD', 'HDD' o '' si Windows no lo sabe (máquinas virtuales)
  try {
    $n = (Get-Partition -DriveLetter $letra | Get-Disk).Number
    "$(@(Get-PhysicalDisk | Where-Object { "$($_.DeviceId)" -eq "$n" })[0].MediaType)" -replace '^(Unspecified|0)$', ''
  } catch { '' }
}
function NoPuedo {
  $s = Get-Service defragsvc -ErrorAction SilentlyContinue
  if (-not $s) { return 'Este equipo no tiene el servicio de optimización de discos de Windows.' }
  if ("$($s.StartType)" -eq 'Disabled') { return 'La optimización de discos está desactivada en este equipo (lo decidió soporte o la empresa): no la fuerzo.' }
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = NoPuedo; if ($m) { $m; exit 3 }
      switch (Tipo) {
        'SSD' { "Tu disco ${letra}: es SSD: si sigo, le paso TRIM (le aviso qué espacio está libre) para que no se ponga lento." }
        'HDD' { "Tu disco ${letra}: es mecánico: si sigo, lo desfragmento. Puede tardar bastante y el equipo irá más lento mientras tanto." }
        default { "Si sigo, optimizo el disco ${letra}: con lo que Windows recomienda para su tipo." }
      }
      exit 0
    }
    'comprobar' {
      $yo = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
      if (-not $yo.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'Helpert necesita privilegios de administrador para optimizar el disco.'; exit 3 }
      $m = NoPuedo; if ($m) { $m; exit 3 }
      exit 0
    }
    'aplicar' {
      try { Optimize-Volume -DriveLetter $letra } catch { "No pude optimizar el disco ${letra}: $($_.Exception.Message)"; exit 1 }
      "Optimicé el disco ${letra}:. El efecto se nota con el uso."
      exit 0
    }
    'verificar' {
      # la optimización no deja una marca fácil de leer: basta con que el disco siga sano y haya terminado bien
      $v = $null; try { $v = Get-Volume -DriveLetter $letra } catch {}
      if ($v -and "$($v.HealthStatus)" -notin 'Healthy', 'Unknown', '0', '5') { "Windows marca el disco ${letra}: con problemas: pide a soporte que lo revise."; exit 1 }
      'Listo: el disco quedó optimizado.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
