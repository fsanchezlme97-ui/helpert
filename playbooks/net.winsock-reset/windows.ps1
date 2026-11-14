# Restablecer la red de Windows: netsh winsock reset y netsh int ip reset (IPv4 e IPv6). El cambio se aplica al
# reiniciar, y aquí no se reinicia: se le dice a la persona. Borra la configuración de red manual (IP o DNS fijos).
# La conectividad sale de la detección de red de Windows (NCSI), no de textos de netsh, que cambian con el idioma.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$CATALOGO = 'HKLM:\SYSTEM\CurrentControlSet\Services\WinSock2\Parameters\Protocol_Catalog9\Catalog_Entries'

function Admin { (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Conectividad {
  $c = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object { "$($_.IPv4Connectivity)"; "$($_.IPv6Connectivity)" })
  if ($c -contains 'Internet') { 'internet' } elseif ($c -contains 'LocalNetwork' -or $c -contains 'Subnet') { 'solo red local' } else { 'sin conexión' }
}
function DnsOk { try { $null = Resolve-DnsName example.com -DnsOnly -QuickTimeout -ErrorAction Stop; $true } catch { $false } }
function Conectados { @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' }) }
# adaptadores con IP fija o DNS puestos a mano: eso es lo que se pierde
function Manuales {
  @(foreach ($a in @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue)) {
      $i = Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
      $dns = (Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$($a.InterfaceGuid)" -Name NameServer -ErrorAction SilentlyContinue).NameServer
      if (($i -and "$($i.Dhcp)" -eq 'Disabled') -or $dns) { "«$($a.Name)»" }
    }) -join ', '
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      if ((Conectados).Count -eq 0) { 'Ningún adaptador de red está conectado (ni cable ni Wi-Fi): restablecer la red no ayudaría. Conecta primero el cable o el Wi-Fi.'; exit 3 }
      if ((Conectividad) -eq 'internet' -and (DnsOk)) { 'La red funciona: hay conexión a internet, así que no hace falta restablecerla.'; exit 10 }
      'El Wi-Fi o el cable conectan, pero no hay internet: puedo restablecer Winsock y TCP/IP de Windows.'
      'Después hay que reiniciar el equipo (guarda tu trabajo antes).'
      $m = Manuales
      if ($m) { "Ojo: hay configuración de red manual (IP o DNS fijos) en $m. Se borra y la tiene que volver a poner soporte." }
      exit 0
    }
    'comprobar' {
      if (-not (Admin)) { 'Helpert necesita privilegios de administrador para restablecer la red.'; exit 3 }
      if (-not (Get-Command netsh.exe -ErrorAction SilentlyContinue)) { 'No encontré la herramienta netsh de Windows.'; exit 3 }
      exit 0
    }
    'aplicar' {
      $null = & netsh.exe winsock reset
      if ($LASTEXITCODE -ne 0) { 'No pude restablecer Winsock; no cambié nada más.'; exit 1 }
      $null = & netsh.exe int ip reset; $v4 = $LASTEXITCODE
      $null = & netsh.exe int ipv6 reset; $v6 = $LASTEXITCODE
      'Restablecí Winsock y TCP/IP. Reinicia el equipo para que el cambio se aplique (guarda tu trabajo antes).'
      # netsh int ip reset suele fallar en alguna clave que Windows protege, aunque restablezca el resto
      if ($v4 -ne 0 -or $v6 -ne 0) { 'Una parte de TCP/IP no se pudo restablecer (Windows protege algunas claves); casi siempre no importa.' }
      exit 0
    }
    'verificar' {
      if (@(Get-ChildItem -LiteralPath $CATALOGO -ErrorAction SilentlyContinue).Count -eq 0) { 'El catálogo de red de Windows (Winsock) quedó vacío: avisa a soporte antes de reiniciar.'; exit 1 }
      'Winsock y TCP/IP quedaron restablecidos. Falta reiniciar el equipo para que la red vuelva a funcionar.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
