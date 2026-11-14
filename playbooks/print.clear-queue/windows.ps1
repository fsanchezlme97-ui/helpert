# Liberar cola de impresión (cola de Windows, servicio Spooler). Códigos: 0 bien (en diagnosticar: hay algo que
# hacer), 10 nada que hacer, otro fallo. Solo ve las impresoras instaladas en el equipo: las compartidas desde un
# servidor (\\servidor\impresora) guardan su cola en ese servidor, y eso lo libera soporte.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$imp = "$env:HP_IMPRESORA"

# la pedida (por nombre exacto o, si no, que lo contenga, porque en Windows suelen tener espacios) o todas
function Impresoras {
  $t = @(Get-Printer -ErrorAction SilentlyContinue)
  if (-not $imp) { return $t }
  $e = @($t | Where-Object { $_.Name -eq $imp })
  if ($e.Count -eq 0) { $e = @($t | Where-Object { $_.Name -like "*$imp*" }) }
  $e
}
function Trabajos($ps) { @($ps | ForEach-Object { Get-PrintJob -PrinterObject $_ -ErrorAction SilentlyContinue }) }
function Pausadas($ps) { @($ps | Where-Object { $_.PrinterStatus -eq 1 }) }  # 1 = en pausa
function Activo { (Get-Service Spooler).Status -eq 'Running' }

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      if (-not (Activo)) { 'El servicio de impresión está detenido.'; exit 0 }
      $ps = @(Impresoras)
      if ($imp -and $ps.Count -eq 0) { "No encontré la impresora «$imp» en este equipo. Si es una impresora compartida de un servidor, su cola está en ese servidor: soporte tiene que liberarla."; exit 1 }
      $j = Trabajos $ps; $p = Pausadas $ps
      if ($j.Count -eq 0 -and $p.Count -eq 0) { 'La cola de impresión está vacía, ninguna impresora está en pausa y el servicio funciona.'; exit 10 }
      if ($j.Count) {
        $de = ''; if ($imp) { $de = " de $($ps[0].Name)" }
        "Hay $($j.Count) trabajo(s) atascado(s) en la cola${de}:"
        $j | Select-Object -First 10 | ForEach-Object { "- $($_.PrinterName) (trabajo $($_.Id))" }
      }
      if ($p.Count) { "Impresora(s) en pausa: $(@($p | ForEach-Object { $_.Name }) -join ', ')." }
      exit 0
    }
    'comprobar' {
      $yo = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
      if (-not $yo.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'Helpert necesita privilegios de administrador para reiniciar la impresión.'; exit 3 }
      if ($imp -and (Activo) -and @(Impresoras).Count -eq 0) { "No existe la impresora $imp en este equipo."; exit 3 }
      exit 0
    }
    'aplicar' {
      if (-not (Activo)) { Start-Service Spooler; Start-Sleep -Seconds 2 }
      $ps = @(Impresoras)
      $j = Trabajos $ps
      $j | Remove-PrintJob -ErrorAction SilentlyContinue
      foreach ($p in (Pausadas $ps)) {
        Get-CimInstance Win32_Printer | Where-Object { $_.Name -eq $p.Name } | Invoke-CimMethod -MethodName Resume | Out-Null
      }
      try {
        Stop-Service Spooler -Force
        # sin una impresora pedida se vacía también la carpeta de la cola (lo que no se pudo borrar por las buenas);
        # solo archivos sueltos, sin entrar en subcarpetas
        if (-not $imp) {
          foreach ($f in [IO.Directory]::GetFiles("$env:SystemRoot\System32\spool\PRINTERS")) { try { [IO.File]::Delete($f) } catch {} }
        }
        Start-Service Spooler
      } catch { 'No se pudo reiniciar el servicio de impresión.'; exit 1 }
      "Borré $($j.Count) trabajo(s) atascado(s), reactivé las impresoras en pausa y reinicié el servicio de impresión."
      exit 0
    }
    'verificar' {
      for ($i = 0; $i -lt 5 -and -not (Activo); $i++) { Start-Sleep -Seconds 1 }
      if (-not (Activo)) { 'El servicio de impresión no volvió a arrancar.'; exit 1 }
      Start-Sleep -Seconds 2  # las impresoras tardan un poco en volver a aparecer tras reiniciar el servicio
      $ps = @(Impresoras)
      if ((Trabajos $ps).Count -or (Pausadas $ps).Count) { 'Todavía quedan trabajos o impresoras en pausa.'; exit 1 }
      'La cola está vacía y la impresión funciona.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
