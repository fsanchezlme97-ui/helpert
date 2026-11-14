# Revisar el cable de red: si el puerto detecta el cable, a qué velocidad y si recibió dirección IP. Los datos salen
# de Get-NetAdapter (estado y velocidad numéricos, sin textos que cambien con el idioma). Solo revisa: termina con 10.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$TECNICO = 'Si sigue igual, el cable o el punto de red lo revisa un técnico.'

# puertos de red con cable: físicos, 802.3 (14); se descartan Wi-Fi (9) y Bluetooth (10), que a veces se anuncian como 802.3
function Puertos {
  @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object {
      $_.NdisPhysicalMedium -eq 14 -or ($_.MediaType -eq '802.3' -and @(9, 10) -notcontains $_.NdisPhysicalMedium) })
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $todos = @(Puertos)
      if ($todos.Count -eq 0) { 'Este equipo no tiene puerto de red con cable (o el adaptador de red USB o el dock no está conectado).'; exit 10 }
      $p = @($todos | Where-Object { $_.Status -eq 'Up' }) | Select-Object -First 1
      if (-not $p) {
        if (@($todos | Where-Object { $_.Status -ne 'Disabled' }).Count -eq 0) { 'El puerto de red con cable está desactivado en el equipo: lo activa soporte.'; exit 10 }
        'El puerto de red no detecta el cable.'
        'Revisa que el cable esté bien encajado en el equipo y en la pared o el router (debe hacer clic) y que se encienda la luz del puerto.'
        "Prueba con otro cable o en otro punto de red. $TECNICO"
        exit 10
      }
      $v = [int64]($p.Speed / 1000000)
      $vel = ''; if ($v -gt 0) { $vel = " a $v Mb/s" }
      $ip = @(Get-NetIPAddress -InterfaceIndex $p.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue) |
        Sort-Object { $_.IPAddress -like '169.254.*' } | Select-Object -First 1
      if (-not $ip) {
        "El puerto detecta el cable$vel, pero el equipo no recibió dirección IP del router."; 'Prueba «Renovar la dirección IP». Si sigue igual, lo revisa soporte.'
      } elseif ($ip.IPAddress -like '169.254.*') {
        "El puerto detecta el cable$vel, pero el router no le dio una dirección al equipo ($($ip.IPAddress))."; 'Prueba «Renovar la dirección IP». Si sigue igual, lo revisa soporte.'
      } else {
        "El cable está bien: el puerto lo detecta$vel y el equipo recibió la dirección $($ip.IPAddress)."
      }
      if ($v -eq 10) { "Ojo: 10 Mb/s es muy poco; suele ser un cable o un punto de red dañado. $TECNICO" }
      if ($v -eq 100) { 'Ojo: 100 Mb/s funciona, pero si en la oficina suele ir a 1000 Mb/s, el cable puede estar dañado.' }
      if ($p.FullDuplex -eq $false) { 'Además, la conexión va en modo «half duplex», señal típica de un cable o punto de red con problemas.' }
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
