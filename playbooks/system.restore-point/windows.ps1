# Crear un punto de restauración de Windows (clase SystemRestore de WMI). No activa la protección del sistema si está
# apagada: eso lo decide soporte. Windows no crea otro punto si ya hay uno de menos de 24 horas (lo limita
# SystemRestorePointCreationFrequency): en ese caso ese punto ya sirve para volver atrás.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$HORAS = 24
$NS = 'root/default'

function Valor($ruta, $nombre) { try { (Get-ItemProperty -LiteralPath $ruta -Name $nombre -ErrorAction Stop).$nombre } catch { $null } }
function Admin { (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
# las versiones de servidor no traen restauración del sistema: no existe la clase
function Hay { try { $null = Get-CimClass -Namespace $NS -ClassName SystemRestore -ErrorAction Stop; $true } catch { $false } }
function Politica { (Valor 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\SystemRestore' 'DisableSR') -eq 1 }
# la protección del sistema está encendida en el disco de Windows: SPP la anota como «\\?\Volume{…}\:(C%3A)»
function Protegido {
  $v = "$(Valor 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SPP\Clients' '{09F7EDC5-294E-4180-AF6A-FB0E6A0E9513}')"
  $v.Contains('(' + ($env:SystemDrive -replace ':', '%3A') + ')') -or $v.Contains("($env:SystemDrive)")
}
function Ultimo {  # fecha del punto de restauración más reciente, o $null
  $p = @(Get-CimInstance -Namespace $NS -ClassName SystemRestore -ErrorAction SilentlyContinue)
  if ($p.Count -eq 0) { return $null }
  ($p | ForEach-Object { [Management.ManagementDateTimeConverter]::ToDateTime($_.CreationTime) } | Sort-Object -Descending)[0]
}
function Reciente { $u = Ultimo; $u -and ((Get-Date) - $u).TotalHours -lt $HORAS }
function NoSePuede {
  if (-not (Hay)) { return 'Este Windows no tiene restauración del sistema (las versiones para servidores no la traen).' }
  if (Politica) { return 'Una política de la empresa desactiva los puntos de restauración en este equipo. Si necesitas uno, habla con soporte.' }
  if (-not (Protegido)) { return "La protección del sistema está apagada en el disco $env:SystemDrive, así que Windows no puede guardar puntos de restauración. Pide a soporte que la active." }
}
function Fecha($d) { $d.ToString('dd/MM/yyyy HH:mm', [Globalization.CultureInfo]::InvariantCulture) }

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      if (-not (Admin)) { 'Helpert necesita privilegios de administrador para revisar los puntos de restauración.'; exit 3 }
      $m = NoSePuede; if ($m) { $m; exit 3 }
      $u = Ultimo
      if (Reciente) {
        "Ya hay un punto de restauración de hace $([int]((Get-Date) - $u).TotalHours) hora(s) ($(Fecha $u))."
        "Windows no guarda otro hasta que pasen $HORAS horas; ese ya sirve para volver atrás."
        exit 10
      }
      if ($u) { "El último punto de restauración es del $(Fecha $u)." } else { 'Este equipo no tiene ningún punto de restauración.' }
      'Guardaría uno nuevo ahora; tarda unos minutos y no cambia nada de tus archivos ni programas.'
      exit 0
    }
    'comprobar' {
      if (-not (Admin)) { 'Helpert necesita privilegios de administrador para crear un punto de restauración.'; exit 3 }
      $m = NoSePuede; if ($m) { $m; exit 3 }
      exit 0
    }
    'aplicar' {
      $r = Invoke-CimMethod -Namespace $NS -ClassName SystemRestore -MethodName CreateRestorePoint -Arguments @{
        Description = "Helpert $(Fecha (Get-Date))"; RestorePointType = [uint32]12; EventType = [uint32]100 }
      if ($r.ReturnValue -ne 0) { "Windows no pudo crear el punto de restauración (código $($r.ReturnValue)). Avisa a soporte."; exit 1 }
      'Guardé un punto de restauración. Si algo sale mal después de un cambio, soporte puede devolver el equipo a este momento.'
      exit 0
    }
    'verificar' {
      if (-not (Reciente)) { 'No encuentro un punto de restauración reciente.'; exit 1 }
      "Hay un punto de restauración del $(Fecha (Ultimo))."
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
