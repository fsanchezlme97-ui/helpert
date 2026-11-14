# Renovar la dirección IP: suelta y vuelve a pedir la dirección al router (DHCP) en el adaptador de cable o Wi-Fi
# conectado, con los métodos de Win32_NetworkAdapterConfiguration (no dependen del idioma, como los textos de ipconfig).
# Nunca toca un adaptador con IP fija. Ojo: aplicar corta la red unos segundos.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

function Admin { (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
# adaptador físico conectado; primero el de la ruta por defecto
function Adaptador {
  $up = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
  $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric | Select-Object -First 1
  $a = $up | Where-Object { $r -and $_.ifIndex -eq $r.ifIndex } | Select-Object -First 1
  if ($a) { $a } else { $up | Select-Object -First 1 }
}
function Dhcp($a) { "$((Get-NetIPInterface -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).Dhcp)" -eq 'Enabled' }
function Nombre($a) { if ($a.NdisPhysicalMedium -eq 9) { 'el Wi-Fi' } else { 'la conexión por cable' } }
# la dirección IPv4; una 169.254 solo si no tiene otra
function Direccion($a) {
  @(Get-NetIPAddress -InterfaceIndex $a.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue) |
    Sort-Object { $_.IPAddress -like '169.254.*' } | Select-Object -First 1
}
function Valida($ip) { $ip -and $ip.IPAddress -notlike '169.254.*' -and "$($ip.AddressState)" -ne 'Duplicate' }
function Puerta($a) { (Get-NetRoute -InterfaceIndex $a.ifIndex -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Select-Object -First 1).NextHop }
# aviso de Windows «conflicto de dirección IP» (evento 4199 de Tcpip) en las últimas 24 horas
function Conflicto {
  try { @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Tcpip'; Id = 4199; StartTime = (Get-Date).AddDays(-1) } -MaxEvents 1 -ErrorAction SilentlyContinue).Count -gt 0 } catch { $false }
}
# deja en $a el adaptador, o devuelve por qué no se puede
function NoPuedo {
  $script:a = Adaptador
  if (-not $script:a) { return 'No hay ninguna conexión de red activa: conecta primero el cable o el Wi-Fi.' }
  if (-not (Dhcp $script:a)) { return "Este equipo usa una IP fija en $(Nombre $script:a): renovarla no sirve. Si hay un problema con esa dirección, lo revisa soporte." }
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = NoPuedo; if ($m) { $m; exit 3 }
      $ip = Direccion $a; $corte = 'La red se corta unos segundos mientras tanto.'
      if (-not $ip) { "Tu equipo no tiene dirección IP en $(Nombre $a): puedo pedirle una nueva al router."; $corte; exit 0 }
      if ("$($ip.AddressState)" -eq 'Duplicate' -or (Conflicto)) {
        "Windows detectó que otro equipo de la red usa tu misma dirección IP ($($ip.IPAddress)): puedo pedirle una nueva al router."; $corte; exit 0
      }
      if ($ip.IPAddress -like '169.254.*') { "Tu dirección IP es $($ip.IPAddress): el router no le dio una dirección al equipo. Puedo pedirle una nueva."; $corte; exit 0 }
      $g = Puerta $a
      if ($g -and (Test-Connection -ComputerName $g -Count 2 -Quiet -ErrorAction SilentlyContinue)) {
        "Tu dirección IP es $($ip.IPAddress) y el router responde: renovarla no debería cambiar nada."; exit 10
      }
      "Tu dirección IP es $($ip.IPAddress), pero el router no responde: puedo pedirle una dirección nueva."; $corte
      exit 0
    }
    'comprobar' {
      if (-not (Admin)) { 'Helpert necesita privilegios de administrador para renovar la dirección IP.'; exit 3 }
      $m = NoPuedo; if ($m) { $m; exit 3 }
      exit 0
    }
    'aplicar' {
      $m = NoPuedo; if ($m) { $m; exit 1 }  # se vuelve a mirar: nunca se toca una IP fija
      $c = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "InterfaceIndex = $([int]$a.ifIndex)"
      if (-not $c) { 'No encontré la configuración de ese adaptador.'; exit 1 }
      # con tiempos que caben en los 60 s del manifiesto; si el router no contesta, la renovación da error
      $r = 1
      try { $null = Invoke-CimMethod -InputObject $c -MethodName ReleaseDHCPLease -OperationTimeoutSec 8 } catch { }
      try { $r = (Invoke-CimMethod -InputObject $c -MethodName RenewDHCPLease -OperationTimeoutSec 30).ReturnValue } catch { }
      for ($i = 0; $i -lt 3 -and -not (Valida (Direccion $a)); $i++) { Start-Sleep -Seconds 1 }
      $ip = Direccion $a
      if ($r -ne 0 -or -not (Valida $ip)) { 'Pedí una dirección nueva, pero el router no me la dio. Si sigue igual, lo revisa soporte.'; exit 1 }
      "Pedí una dirección IP nueva al router. Ahora es $($ip.IPAddress)."
      exit 0
    }
    'verificar' {
      $a = Adaptador; $ip = $null
      if ($a) { $ip = Direccion $a }
      if (-not (Valida $ip)) { 'El equipo sigue sin una dirección IP válida: el router no responde. Lo revisa soporte.'; exit 1 }
      "El equipo tiene la dirección IP $($ip.IPAddress)."
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
