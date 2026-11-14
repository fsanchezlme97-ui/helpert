# Revisar por qué el equipo está lento. Solo lectura: el diagnóstico informa y termina con 10.
# Todo sale de CIM y de Get-Process (no de contadores de rendimiento, cuyos nombres cambian con el idioma).
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $cpu = @(Get-CimInstance Win32_Processor)
      $nucleos = 0; $carga = 0; foreach ($c in $cpu) { $nucleos += $c.NumberOfLogicalProcessors; $carga += [int]$c.LoadPercentage }
      $carga = [int]($carga / [math]::Max(1, $cpu.Count)); if ($nucleos -lt 1) { $nucleos = 1 }
      $os = Get-CimInstance Win32_OperatingSystem
      $total = [double]$os.TotalVisibleMemorySize; $libre = [double]$os.FreePhysicalMemory  # en KB
      $usada = [int](100 * ($total - $libre) / $total)
      $pf = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
      $asignado = 0; $enUso = 0; foreach ($f in $pf) { $asignado += $f.AllocatedBaseSize; $enUso += $f.CurrentUsage }
      $swap = 0; if ($asignado) { $swap = [int](100 * $enUso / $asignado) }
      $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$env:SystemDrive'"
      $disco = [int](100 - 100 * $d.FreeSpace / $d.Size)
      $dias = [int][math]::Floor(((Get-Date) - $os.LastBootUpTime).TotalDays)
      "Procesador: $carga % de uso con $nucleos núcleos. Memoria: $usada % usada de $([math]::Round($total / 1MB)) GB. Disco del sistema: $disco % lleno. Sin reiniciar: $dias día(s)."

      # uso de procesador de cada programa en 2 segundos, sumado por programa (un navegador son muchos procesos)
      $antes = @{}
      foreach ($p in Get-Process) { try { if ($p.CPU) { $antes[$p.Id] = $p.CPU } } catch {} }
      Start-Sleep -Seconds 2
      $cpuDe = @{}; $memDe = @{}
      foreach ($p in Get-Process) {
        if ($p.Id -eq 0 -or $p.Id -eq $PID) { continue }  # sin contar el inactivo ni esta misma revisión
        $n = $p.ProcessName
        try { $c = $p.CPU } catch { $c = $null }
        if ($c -and $antes.ContainsKey($p.Id)) { $cpuDe[$n] += 100 * ($c - $antes[$p.Id]) / 2 / $nucleos }
        $memDe[$n] += 100 * $p.WorkingSet64 / 1KB / $total
      }
      $top = @($memDe.Keys | ForEach-Object { [pscustomobject]@{ Nombre = $_; Cpu = [double]$cpuDe[$_]; Mem = [double]$memDe[$_] } } |
        Where-Object { $_.Cpu -gt 5 -or $_.Mem -gt 5 } | Sort-Object Cpu, Mem -Descending | Select-Object -First 5)
      if ($top.Count) {
        'Lo que más consume ahora:'
        foreach ($t in $top) { '- {0}: {1:0} % de procesador, {2:0.0} % de memoria' -f $t.Nombre, $t.Cpu, $t.Mem }
      }

      $consejos = @()
      if ($carga -ge 90) { $consejos += 'El procesador está al límite: cierra los programas que más consumen.' }
      if ($usada -ge 85 -or $swap -ge 50) { $consejos += 'La memoria está casi llena: cierra pestañas del navegador y programas que no uses.' }
      if ($disco -ge 90) { $consejos += 'El disco está casi lleno: pídeme liberar espacio en disco.' }
      # con el inicio rápido de Windows, «Apagar» no reinicia de verdad: solo «Reiniciar» lo hace
      if ($dias -ge 7) { $consejos += "Lleva $dias días sin reiniciarse: guarda tu trabajo y elige Inicio > Encendido > Reiniciar (apagarlo no basta)." }
      if ($consejos.Count -eq 0) { 'No veo nada fuera de lo normal en este momento.' } else { $consejos }
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
