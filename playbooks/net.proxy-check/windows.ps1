# Revisar el proxy del equipo: el de la persona (Internet Settings de su registro, por su SID) o el de todo el equipo
# si una política lo fija así. Prueba si el proxy responde y si sin proxy hay internet. Solo revisa: termina con 10.
# El proxy de WinHTTP (el de los servicios de Windows) no se revisa: las páginas usan el de la persona.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$PRUEBA = 'http://www.msftconnecttest.com/connecttest.txt'
$IS = 'Software\Microsoft\Windows\CurrentVersion\Internet Settings'

function SidDe($cuenta) {  # solo cuentas de personas (locales, de dominio o de Entra ID), nunca SYSTEM ni de servicio
  if (-not $cuenta) { return $null }
  try { $s = (New-Object Security.Principal.NTAccount($cuenta)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { return $null }
  if ($s -match '^S-1-(5-21|12-1)-') { $s }
}
function Valor($ruta, $nombre) {
  try { (Get-ItemProperty -LiteralPath $ruta -Name $nombre -ErrorAction Stop).$nombre } catch { $null }
}
# código HTTP de la prueba; por el proxy dado o directo; 0 si no hubo respuesta
function Http($proxy, $url) {
  if (-not $url) { $url = $PRUEBA }
  try {
    $q = [Net.HttpWebRequest]::Create($url); $q.Timeout = 8000
    if ($proxy) { $q.Proxy = New-Object Net.WebProxy("http://$proxy") } else { $q.Proxy = New-Object Net.WebProxy }
    $r = $q.GetResponse(); $c = [int]$r.StatusCode; $r.Close(); $c
  } catch {
    $w = @($_.Exception, $_.Exception.InnerException) | Where-Object { $_ -is [Net.WebException] } | Select-Object -First 1
    if ($w -and $w.Response) { [int]$w.Response.StatusCode } else { 0 }
  }
}
# «host:puerto» del proxy de https (o http, o el único) de ProxyServer, sin esquema
function Servidor($s) {
  $partes = @("$s" -split ';' | Where-Object { $_ })
  $x = @($partes | Where-Object { $_ -like 'https=*' }) + @($partes | Where-Object { $_ -like 'http=*' }) + @($partes | Where-Object { $_ -notlike '*=*' })
  if ($x.Count -eq 0) { return $null }
  $v = ($x[0] -replace '^[a-z]+=', '') -replace '^[a-z]+://', ''
  ($v -split '@')[-1].TrimEnd('/')
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $ruta = "HKLM:\$IS"; $de = 'la configuración de todo el equipo (política de la empresa)'
      if ((Valor "HKLM:\SOFTWARE\Policies\Microsoft\Windows\CurrentVersion\Internet Settings" 'ProxySettingsPerUser') -ne 0) {
        $sid = SidDe $env:HP_USUARIO
        if (-not $sid) { 'No sé qué persona lo pide, así que no puedo leer su proxy.'; exit 3 }
        $ruta = "Registry::HKEY_USERS\$sid\$IS"; $de = 'tu configuración de Windows'
        if (-not (Test-Path -LiteralPath $ruta)) { 'No puedo leer tu configuración de internet: no tienes una sesión abierta en este equipo.'; exit 3 }
      }
      $proxy = $null; $pac = Valor $ruta 'AutoConfigURL'
      if ((Valor $ruta 'ProxyEnable') -eq 1) { $proxy = Servidor (Valor $ruta 'ProxyServer') }
      $cs = Valor "$ruta\Connections" 'DefaultConnectionSettings'
      $auto = $cs -and $cs.Length -gt 8 -and ($cs[8] -band 8)
      $directo = Http $null
      if ($proxy) {
        $c = Http $proxy
        if ($c -eq 407) { "El proxy configurado ($proxy) responde: pide identificarse, lo normal en una empresa." }
        elseif ($c) { "El proxy configurado ($proxy) responde y deja salir a internet." }
        else {
          "El proxy configurado ($proxy) no responde: por eso no cargan las páginas."
          if ($directo) { 'Sin proxy sí hay internet: si ya no deberías usarlo, soporte lo quita.' }
        }
      } elseif ($pac) {
        $h = ("$pac" -replace '^[a-z]+://', '' -split '/')[0]
        if (Http $null $pac) { 'El equipo toma el proxy de un archivo de configuración automática, y ese archivo responde.' }
        else { "El equipo toma el proxy de un archivo de configuración automática ($h), pero ese archivo no responde: por eso pueden fallar las páginas." }
      } elseif ($auto) {
        'El equipo busca el proxy solo en la red (detección automática); no lo puedo probar directamente.'
        if ($directo) { 'Sin proxy sí hay internet.' } else { 'Sin proxy tampoco hay internet.' }
      } else {
        if ($directo) { 'Este equipo no usa proxy y llega bien a internet: el problema no es el proxy.' }
        else { 'Este equipo no usa proxy y no llega a internet: el problema no es el proxy (prueba «Sin internet o Wi-Fi»).' }
        exit 10
      }
      "Lo tomé de $de. Está en Configuración > Red e Internet > Proxy; cambiarlo lo hace soporte."
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
