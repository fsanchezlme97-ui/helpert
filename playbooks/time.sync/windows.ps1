# Corregir la hora: activa la hora automática (servicio W32Time) y la sincroniza. No cambia la zona horaria.
# La hora la corrige solo W32Time. Para saber si quedó bien se le pregunta la hora a un servidor (SNTP) y se compara
# con la del equipo, sin leer los textos de w32tm, que cambian con el idioma. Esa respuesta no viene autenticada:
# sirve solo para medir, nunca para fijar la hora (cualquiera en la red podría mover el reloj).
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$PARAM = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
$TOLERANCIA = 5  # segundos

function Valor($ruta, $nombre) { try { (Get-ItemProperty -LiteralPath $ruta -Name $nombre -ErrorAction Stop).$nombre } catch { $null } }
# con la salida redirigida, Windows PowerShell convierte cada línea de stderr de un programa en un error, y con
# 'Stop' eso cortaría el script: aquí se ignora (lo que importa se comprueba después midiendo la hora)
function W32tm { $ErrorActionPreference = 'Continue'; & w32tm.exe @args 2>$null }
function Ahora { (Get-Date).ToString('dd/MM/yyyy HH:mm', [Globalization.CultureInfo]::InvariantCulture) }
function Activa { (Get-Service w32time).Status -eq 'Running' -and (Valor $PARAM 'Type') -ne 'NoSync' }
# segundos que el reloj del equipo va adelantado (+) o atrasado (-); $null si ningún servidor responde
function Desfase {
  $servidores = @()
  # la fuente que usa W32Time (en un dominio, el controlador); si es un texto como «Reloj CMOS local», no sirve
  if (Activa) { $f = "$(W32tm /query /source)".Trim(); if ($f -and $f -notmatch '\s') { $servidores += $f -replace ',.*$', '' } }
  $servidores += @("$(Valor $PARAM 'NtpServer')" -split '\s+' | Where-Object { $_ } | ForEach-Object { $_ -replace ',.*$', '' })
  $servidores += 'time.windows.com'
  foreach ($s in ($servidores | Select-Object -Unique)) {
    $u = New-Object Net.Sockets.UdpClient
    try {
      $u.Client.ReceiveTimeout = 3000
      $u.Connect($s, 123)
      $q = New-Object byte[] 48; $q[0] = 0x1B  # SNTP versión 3, modo cliente
      $t1 = [DateTime]::UtcNow
      [void]$u.Send($q, 48)
      $ep = New-Object Net.IPEndPoint ([Net.IPAddress]::Any), 0
      $r = $u.Receive([ref]$ep)
      $t4 = [DateTime]::UtcNow
      # hora del servidor: segundos y fracción desde 1900 en los bytes 40 a 47 (big-endian)
      $seg = [BitConverter]::ToUInt32([byte[]]@($r[43], $r[42], $r[41], $r[40]), 0)
      $fra = [BitConverter]::ToUInt32([byte[]]@($r[47], $r[46], $r[45], $r[44]), 0)
      if ($seg -eq 0) { continue }
      $srv = (New-Object DateTime 1900, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)).AddSeconds($seg + $fra / 4294967296.0)
      return ($t1.AddTicks([long](($t4 - $t1).Ticks / 2)) - $srv).TotalSeconds
    } catch {} finally { $u.Close() }
  }
  $null
}
function Bien($d) { $d -ne $null -and [math]::Abs($d) -le $TOLERANCIA }

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $d = Desfase
      if ((Activa) -and (Bien $d)) { "La hora del equipo está sincronizada por internet: $(Ahora)."; exit 10 }
      if ((Get-Service w32time).Status -ne 'Running') { 'El servicio de hora de Windows está detenido.' }
      if ((Valor $PARAM 'Type') -eq 'NoSync') { 'La hora automática está desactivada.' }
      if ($d -eq $null) { "No pude comparar la hora con un servidor de hora; puede que la red lo bloquee (ahora marca $(Ahora))." }
      elseif (-not (Bien $d)) { 'La hora del equipo va {0:0} segundos {1} (ahora marca {2}).' -f [math]::Abs($d), $(if ($d -gt 0) { 'adelantada' } else { 'atrasada' }), (Ahora) }
      "Zona horaria: $((Get-TimeZone).DisplayName)."
      exit 0
    }
    'comprobar' {
      $yo = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
      if (-not $yo.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'Helpert necesita privilegios de administrador para ajustar la hora.'; exit 3 }
      exit 0
    }
    'aplicar' {
      Set-Service w32time -StartupType Automatic
      if ((Get-Service w32time).Status -ne 'Running') { Start-Service w32time; Start-Sleep -Seconds 2 }
      if ((Valor $PARAM 'Type') -eq 'NoSync') {
        # en un dominio la hora la da el controlador de dominio; fuera de él, el servidor ya configurado (time.windows.com)
        if ((Get-CimInstance Win32_ComputerSystem).PartOfDomain) { $de = '/syncfromflags:domhier' } else { $de = '/syncfromflags:manual' }
        W32tm /config $de /update | Out-Null
      }
      W32tm /resync /rediscover /nowait | Out-Null
      # si ningún servidor responde no tiene sentido esperar: verificar lo dirá
      for ($i = 0; $i -lt 10; $i++) { $d = Desfase; if ($d -eq $null -or (Bien $d)) { break }; Start-Sleep -Seconds 2 }
      'Activé la hora automática y pedí sincronizarla.'
      exit 0
    }
    'verificar' {
      $d = Desfase
      if (-not (Activa) -or -not (Bien $d)) { 'La hora todavía no se sincroniza; puede que la red bloquee el servicio de hora.'; exit 1 }
      "La hora está sincronizada: $(Ahora)."
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
