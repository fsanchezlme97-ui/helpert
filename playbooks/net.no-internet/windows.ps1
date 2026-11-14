# Sin internet o Wi-Fi: limpia la caché DNS y reinicia los adaptadores de red físicos que están activos.
# La conectividad sale de la detección de red de Windows (NCSI), no de textos de netsh o ipconfig, que cambian con el idioma.
# Ojo: aplicar corta la red unos segundos. Solo sirve si el equipo aún llega al servidor de Helpert (red local).
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

function Conectividad {
  $c = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object { "$($_.IPv4Connectivity)"; "$($_.IPv6Connectivity)" })
  if ($c -contains 'Internet') { 'internet' } elseif ($c -contains 'LocalNetwork' -or $c -contains 'Subnet') { 'solo red local' } else { 'sin conexión' }
}
function DnsOk { try { $null = Resolve-DnsName example.com -DnsOnly -QuickTimeout -ErrorAction Stop; $true } catch { $false } }
function Adaptadores { @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' -or $_.Status -eq 'Disconnected' }) }

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $c = Conectividad
      if ($c -eq 'internet' -and (DnsOk)) { 'La conexión a internet funciona y los nombres de dominio se resuelven.'; exit 10 }
      $ruta = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
      $puerta = 'ninguna'; if ($ruta) { $puerta = "$($ruta.NextHop) (por $($ruta.InterfaceAlias))" }
      "Conectividad: $c. Puerta de enlace: $puerta."
      if (@(Adaptadores | Where-Object { $_.Status -eq 'Up' }).Count -eq 0) { 'Ningún adaptador de red está conectado (ni cable ni Wi-Fi).' }
      if (-not (DnsOk)) { 'Los nombres de dominio no se resuelven.' }
      exit 0
    }
    'comprobar' {
      $yo = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
      if (-not $yo.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'Helpert necesita privilegios de administrador para reiniciar la red.'; exit 3 }
      if (@(Adaptadores).Count -eq 0) { 'No encontré adaptadores de red activos para reiniciar.'; exit 3 }
      exit 0
    }
    'aplicar' {
      Clear-DnsClientCache
      try { Adaptadores | Restart-NetAdapter -Confirm:$false } catch { 'No se pudo reiniciar la red.'; exit 1 }
      for ($i = 0; $i -lt 30; $i++) { if ((Conectividad) -eq 'internet') { break }; Start-Sleep -Seconds 1 }
      'Limpié la caché DNS y reinicié la red.'
      exit 0
    }
    'verificar' {
      for ($i = 0; $i -lt 10; $i++) { if ((Conectividad) -eq 'internet' -and (DnsOk)) { break }; Start-Sleep -Seconds 1 }
      if ((Conectividad) -ne 'internet' -or -not (DnsOk)) { 'Sigue sin haber conexión a internet.'; exit 1 }
      'La conexión a internet volvió.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
