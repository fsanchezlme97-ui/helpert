# Ver qué programa usa internet: los 5 programas con más conexiones TCP establecidas, sin contar las del propio equipo
# (127.0.0.1, ::1). Cuenta conexiones, no lo que gasta cada una. Solo revisa: no cierra nada.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

# nombre que reconoce la persona: la descripción del programa («Google Chrome») o su nombre de proceso
function Programa($id) {
  $p = Get-Process -Id $id -ErrorAction SilentlyContinue
  if (-not $p) { return '(un programa que ya se cerró)' }
  if ($id -eq 4 -or $p.ProcessName -eq 'svchost') { return 'Servicios de Windows' }
  $d = $null; try { $d = $p.Description } catch { }
  if ($d) { $d } else { $p.ProcessName }
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $c = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
          Where-Object { $_.RemoteAddress -notmatch '^(127\.|::1$|::ffff:127\.)' })
      if ($c.Count -eq 0) { 'Ahora mismo ningún programa está conectado a internet.'; exit 10 }
      $cuenta = @{}
      foreach ($g in ($c | Group-Object OwningProcess)) { $n = Programa ([int]$g.Name); $cuenta[$n] = [int]$cuenta[$n] + $g.Count }
      $top = @($cuenta.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5)
      "El programa con más conexiones abiertas es $($top[0].Name) ($($top[0].Value) de $($c.Count))."
      foreach ($x in $top) { "- $($x.Name): $($x.Value) conexión(es)" }
      'Muchas conexiones no siempre es mucho consumo, pero las descargas, las actualizaciones y la sincronización con la nube suelen ser las que más gastan.'
      'Si no estás usando alguno, puedes cerrarlo tú; yo no cierro nada.'
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
