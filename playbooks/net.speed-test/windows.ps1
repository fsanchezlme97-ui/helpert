# Medir la velocidad de internet: latencia al router (red local o Wi-Fi) y a internet (1.1.1.1), una descarga acotada
# de Cloudflare (hasta 25 MB o 15 s, a la memoria, sin archivo) y lo ocupado que está el procesador. Solo mide: termina con 10.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$URL = 'https://speed.cloudflare.com/__down?bytes=25000000'

# promedio en ms y pérdida en % de 4 pings; $null si no responde ninguno (hay routers y redes que no contestan pings)
function Latencia($h) {
  $r = @(try { Test-Connection -ComputerName $h -Count 4 -ErrorAction SilentlyContinue | Where-Object { $_.StatusCode -eq 0 } } catch { })
  if ($r.Count -eq 0) { return $null }
  @{ Ms = [int]($r | Measure-Object ResponseTime -Average).Average; Perdida = [int]((4 - $r.Count) * 25) }
}
# Mbps de descarga; $null si no se pudo
function Descarga {
  try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $q = [Net.HttpWebRequest]::Create($URL); $q.Timeout = 8000; $q.ReadWriteTimeout = 8000
    $reloj = [Diagnostics.Stopwatch]::StartNew()
    $r = $q.GetResponse(); $s = $r.GetResponseStream()
    $b = New-Object byte[] 262144; $total = 0
    while ($reloj.Elapsed.TotalSeconds -lt 15) { $n = $s.Read($b, 0, $b.Length); if ($n -le 0) { break }; $total += $n }
    $q.Abort()  # sin leer el resto: cerrar la respuesta a medias intentaría descargarla entera
    if ($total -eq 0) { return $null }
    [math]::Round($total * 8 / $reloj.Elapsed.TotalSeconds / 1000000, 1)
  } catch { $null }
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $ruta = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
      if (-not $ruta) { 'El equipo no está conectado a ninguna red: no hay nada que medir. Prueba «Sin internet o Wi-Fi».'; exit 10 }
      $ad = Get-NetAdapter -InterfaceIndex $ruta.ifIndex -ErrorAction SilentlyContinue
      $wifi = $ad -and $ad.NdisPhysicalMedium -eq 9
      $g = $null; if ($ruta.NextHop -and $ruta.NextHop -ne '0.0.0.0') { $g = Latencia $ruta.NextHop }
      $i = Latencia '1.1.1.1'
      $mbps = Descarga
      $cpu = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average

      # el veredicto primero: equipo, red local (Wi-Fi o cable) o la conexión a internet
      if ($cpu -gt 90) {
        'Parece del equipo: el procesador está casi al máximo y eso hace que todo, también internet, vaya lento. Cierra los programas que no uses o reinícialo.'
      } elseif ($g -and ($g.Ms -gt 30 -or $g.Perdida -gt 0)) {
        if ($wifi) { 'Parece del Wi-Fi: la conexión con el router es lenta o pierde datos. Acércate al router o, si puedes, usa un cable.' }
        else { 'Parece de la red local: la conexión con el router es lenta o pierde datos. Puede ser el cable, el punto de red o el router: lo revisa soporte.' }
      } elseif ($null -eq $mbps) {
        'No pude medir la velocidad de descarga: el equipo no llega al servidor de prueba (puede ser un bloqueo o un proxy de la empresa).'
      } elseif ($mbps -lt 5 -or ($i -and ($i.Ms -gt 150 -or $i.Perdida -gt 0))) {
        'Parece de la conexión a internet: tu equipo y la red local responden bien, pero la salida a internet es lenta. Si sigue así, avisa a soporte para que lo revise con el proveedor.'
      } else {
        'La conexión va bien: no veo nada lento en el equipo, la red local ni internet.'
      }
      if ($null -ne $mbps) { "Velocidad de descarga: $mbps Mbps." }
      if ($g) { "Tiempo de respuesta del router: $($g.Ms) ms (pérdida $($g.Perdida) %)." } else { 'El router no contesta a la prueba de respuesta (algunos no lo hacen).' }
      if ($i) { "Tiempo de respuesta de internet: $($i.Ms) ms (pérdida $($i.Perdida) %)." }
      if ($wifi) { 'Estás conectado por Wi-Fi.' }
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
