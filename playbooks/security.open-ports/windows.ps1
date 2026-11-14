# Ver qué programas aceptan conexiones desde la red: puertos TCP en escucha y UDP abiertos, sin contar los que solo
# atienden al propio equipo (127.0.0.1, ::1). Los UDP de 49152 en adelante se omiten: son los puertos de paso que
# Windows da a cada programa para sus propias consultas, no servicios que esperan conexiones. Solo lectura: termina con 10.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

function Puertos {
  $proc = @{}; foreach ($p in Get-Process) { $proc[[int]$p.Id] = $p.ProcessName }
  $svc = @{}; foreach ($s in @(Get-CimInstance Win32_Service -Filter 'ProcessId > 0')) { if (-not $svc[[int]$s.ProcessId]) { $svc[[int]$s.ProcessId] = $s.DisplayName } }
  $l = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Select-Object LocalPort, LocalAddress, OwningProcess, @{ n = 'P'; e = { 'tcp' } })
  $l += @(Get-NetUDPEndpoint -ErrorAction SilentlyContinue | Where-Object { $_.LocalPort -lt 49152 } | Select-Object LocalPort, LocalAddress, OwningProcess, @{ n = 'P'; e = { 'udp' } })
  $l | Where-Object { $_.LocalAddress -notlike '127.*' -and $_.LocalAddress -ne '::1' } | ForEach-Object {
    $id = [int]$_.OwningProcess
    if ($id -eq 4) { $q = 'Windows (sistema)' }
    elseif ($svc[$id]) { $q = "servicio «$($svc[$id])»" }
    elseif ($proc[$id]) { $q = $proc[$id] }
    else { $q = 'programa desconocido' }
    [pscustomobject]@{ Puerto = [int]$_.LocalPort; Texto = "$($_.LocalPort)/$($_.P): $q" }
  } | Sort-Object Puerto, Texto -Unique
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $l = @(Puertos)
      if ($l.Count -eq 0) { 'Ningún programa acepta conexiones desde la red en este equipo.'; exit 10 }
      "Hay $($l.Count) puerto(s) abiertos a la red. Puerto y programa:"
      $l | Select-Object -First 7 | ForEach-Object { "- $($_.Texto)" }
      if ($l.Count -gt 7) { "… y $($l.Count - 7) más." }
      'Que un puerto esté abierto no quiere decir que el cortafuegos deje entrar conexiones de afuera.'
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
