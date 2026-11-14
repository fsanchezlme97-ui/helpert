# Revisar los servicios esenciales (lista fija: impresión, sonido, red, DNS, Wi-Fi, búsqueda, hora) e iniciar los que
# tienen inicio automático y están detenidos. Los desactivados se informan y no se tocan (los desactiva soporte o una
# política). Nunca toca otros servicios ni reinicia los que ya funcionan.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$ESENCIALES = [ordered]@{
  Spooler = 'impresión'; Audiosrv = 'sonido'; AudioEndpointBuilder = 'sonido (dispositivos)'; Dhcp = 'red (dirección IP)'
  Dnscache = 'DNS (nombres de sitios web)'; NlaSvc = 'red (detección de la conexión)'; nsi = 'red'; LanmanWorkstation = 'carpetas compartidas'
  WlanSvc = 'Wi-Fi'; WSearch = 'búsqueda de archivos'; W32Time = 'hora automática'
}

function Servicios {  # los de la lista que existen en este equipo (Wi-Fi, búsqueda o sonido pueden no estar)
  $f = ($ESENCIALES.Keys | ForEach-Object { "Name='$_'" }) -join ' OR '
  @(Get-CimInstance Win32_Service -Filter $f -Property Name, StartMode, State)
}
function Detenidos { @(Servicios | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -eq 'Stopped' }) }
function Para($s) { "- $($ESENCIALES[$s.Name]) ($($s.Name))" }

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $todos = Servicios
      $d = @($todos | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -eq 'Stopped' })
      $off = @($todos | Where-Object { $_.StartMode -eq 'Disabled' } | ForEach-Object { $ESENCIALES[$_.Name] } | Select-Object -Unique)
      if ($d.Count -eq 0) { 'Los servicios esenciales (impresión, sonido, red, DNS, búsqueda, hora) que deben estar activos están funcionando.' }
      else {
        "Hay $($d.Count) servicio(s) esencial(es) detenido(s) que deberían estar activos:"
        $d | Select-Object -First 6 | ForEach-Object { Para $_ }
        'Los volvería a iniciar; no toco ningún otro servicio.'
      }
      if ($off.Count) { "Están desactivados en este equipo: $($off -join ', '). Eso lo decide soporte; si los necesitas, avísale." }
      if ($d.Count) { exit 0 } else { exit 10 }
    }
    'comprobar' {
      $yo = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
      if (-not $yo.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'Helpert necesita privilegios de administrador para iniciar servicios.'; exit 3 }
      if ((Detenidos).Count -eq 0) { 'Ya no hay servicios esenciales detenidos.'; exit 3 }
      exit 0
    }
    'aplicar' {
      $ok = 0; $mal = @()
      foreach ($s in (Detenidos)) {
        try { Start-Service -Name $s.Name -WarningAction SilentlyContinue -ErrorAction Stop; $ok++ } catch { $mal += $ESENCIALES[$s.Name] }
      }
      if ($mal.Count) { "Inicié $ok servicio(s), pero no arrancaron: $($mal -join ', '). Avisa a soporte para que lo revise."; exit 1 }
      "Volví a iniciar $ok servicio(s) esencial(es)."
      exit 0
    }
    'verificar' {
      Start-Sleep -Seconds 2
      $d = Detenidos
      if ($d.Count) { 'Todavía hay servicios esenciales detenidos:'; $d | Select-Object -First 6 | ForEach-Object { Para $_ }; exit 1 }
      'Los servicios esenciales están funcionando.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
