# Reparar la búsqueda de Thunderbird: cierra Thunderbird de la persona (sus procesos, por SID) y borra el índice de
# búsqueda global (global-messages-db.sqlite de cada perfil); Thunderbird lo rehace solo. Los correos no se tocan.
# Desde el servicio (sesión 0) no se le puede pedir a una ventana de otra sesión que se cierre: se cierra a la fuerza.
# Lo que toca la carpeta de la persona se hace con su propio token (el de su sesión), nunca como SYSTEM.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$NOMBRE = 'Thunderbird'
$PROCS = @('thunderbird')

function SidDe($cuenta) {  # solo cuentas de personas (locales, de dominio o de Entra ID), nunca SYSTEM ni de servicio
  if (-not $cuenta) { return $null }
  try { $s = (New-Object Security.Principal.NTAccount($cuenta)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { return $null }
  if ($s -match '^S-1-(5-21|12-1)-') { $s }
}
function Token($sid) {
  if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq $sid) { return 'yo' }
  $s = @(Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" | Where-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid -eq $sid })
  if ($s.Count -eq 0) { return $null }
  Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class HpWts { [DllImport("wtsapi32.dll", SetLastError = true)] public static extern bool WTSQueryUserToken(uint sesion, out IntPtr token); }'
  $h = [IntPtr]::Zero
  if (-not [HpWts]::WTSQueryUserToken([uint32]$s[0].SessionId, [ref]$h)) { return $null }
  New-Object Microsoft.Win32.SafeHandles.SafeAccessTokenHandle $h
}
# con el token de la persona; lo que escribe el bloque se pierde, así que deja sus resultados en variables $script:
function ComoPersona($tok, [scriptblock]$b) {
  if ($tok -is [string]) { $null = & $b } else { [Security.Principal.WindowsIdentity]::RunImpersonated($tok, [Action]$b) }
}
function Preparar {
  $script:sid = SidDe $env:HP_USUARIO
  if (-not $sid) { return 'No sé qué persona lo pide.' }
  $script:perfil = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'").LocalPath
  if (-not $perfil) { return 'No encontré tu carpeta personal en este equipo.' }
  $script:tok = Token $sid
  if (-not $tok) { return "Necesito que tengas la sesión abierta en este equipo para reparar la búsqueda de Thunderbird." }
}
function Procesos {
  @(Get-CimInstance Win32_Process | Where-Object { $PROCS -contains ("$($_.Name)" -replace '\.exe$', '') } |
      Where-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid -eq $sid })
}
function Cerrar {
  foreach ($p in @(Procesos)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
  for ($i = 0; $i -lt 10; $i++) { if (@(Procesos).Count -eq 0) { return $true }; Start-Sleep -Seconds 1 }
  $false
}
# archivos del índice (con sus -journal / -wal) de cada perfil y su tamaño en MB; corre con el token de la persona
function Revisar {
  $base = [IO.Path]::Combine($perfil, 'AppData\Roaming\Thunderbird\Profiles')
  $script:indices = @()
  if ([IO.Directory]::Exists($base)) {
    $script:indices = @(foreach ($p in [IO.Directory]::GetDirectories($base)) { [IO.Directory]::GetFiles($p, 'global-messages-db.sqlite*') })
  }
  $b = 0; foreach ($f in $indices) { try { $b += (New-Object IO.FileInfo $f).Length } catch {} }
  $script:mb = [math]::Round($b / 1MB)
}
$indices = @(); $mb = 0

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      ComoPersona $tok { Revisar }
      if ($indices.Count -eq 0) { 'No encontré el índice de búsqueda de Thunderbird: o no lo usas en este equipo o tiene la búsqueda global desactivada.'; exit 10 }
      "El índice de búsqueda de Thunderbird ocupa $mb MB. Lo borraría; Thunderbird lo rehace solo y tus correos no se tocan."
      if (@(Procesos).Count) { 'Thunderbird está abierto: lo voy a cerrar antes. Si estás escribiendo un correo, guárdalo como borrador.' }
      exit 0
    }
    'comprobar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      ComoPersona $tok { Revisar }
      if ($indices.Count -eq 0) { 'No hay índice de búsqueda que borrar.'; exit 3 }
      exit 0
    }
    'aplicar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      if (-not (Cerrar)) { 'No pude cerrar Thunderbird, así que no borré nada.'; exit 1 }
      ComoPersona $tok { Revisar; foreach ($f in $indices) { try { [IO.File]::Delete($f) } catch {} } }
      'Cerré Thunderbird y borré su índice de búsqueda. Ábrelo y déjalo abierto un rato: rehace el índice solo (con mucho correo puede tardar horas).'
      exit 0
    }
    'verificar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      if (@(Procesos).Count) { 'Thunderbird está abierto y rehaciendo su índice.'; exit 0 }
      ComoPersona $tok { Revisar }
      if ($indices.Count) { 'No pude borrar el índice de búsqueda de Thunderbird.'; exit 1 }
      'Listo: el índice viejo ya no está. Abre Thunderbird para que lo rehaga.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
