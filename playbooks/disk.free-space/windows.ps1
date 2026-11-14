# Liberar espacio en disco: temporales de más de 7 días (del sistema y de la persona) y registros de Windows
# (CBS) de más de 30 días. La papelera queda fuera a propósito: vaciarla necesita una confirmación aparte.
# Los temporales de la persona se borran con su propio token, nunca como SYSTEM: una unión que ella cree en su
# carpeta no puede llevar a SYSTEM a borrar archivos ajenos. Por lo mismo, en Windows\Temp (donde cualquiera puede
# crear carpetas) y en Logs\CBS solo se borran archivos sueltos, sin entrar en subcarpetas.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$disco = $env:SystemDrive

function Uso { $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$disco'"; [int](100 - 100 * $d.FreeSpace / $d.Size) }
function LibreMB { [int]((Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$disco'").FreeSpace / 1MB) }
function MB($lista) { $s = 0; foreach ($f in $lista) { $s += $f.Length }; [int]($s / 1MB) }
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
function ComoPersona($tok, [scriptblock]$b) {
  if ($tok -is [string]) { & $b } else { [Security.Principal.WindowsIdentity]::RunImpersonated($tok, [Action]$b) }
}
# archivos de $dir sin cambios hace más de $dias días; con $hondo también en subcarpetas (sin seguir uniones ni enlaces)
function Viejos($dir, $dias, $hondo) {
  $limite = (Get-Date).AddDays(-$dias)
  $pila = New-Object Collections.Stack; $pila.Push($dir)
  while ($pila.Count) {
    $d = New-Object IO.DirectoryInfo $pila.Pop()
    try {
      foreach ($f in $d.GetFiles()) { if ($f.LastWriteTime -lt $limite) { $f } }
      if ($hondo) { foreach ($s in $d.GetDirectories()) { if (-not ($s.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $pila.Push($s.FullName) } } }
    } catch {}
  }
}
function Borrar($lista) { foreach ($f in $lista) { try { $f.Delete() } catch {} } }

# temporales de la persona; $conPersona dice si se pudo actuar con su cuenta (la lista puede estar vacía)
$conPersona = $false
function Persona {
  $sid = SidDe $env:HP_USUARIO
  if (-not $sid) { return $null }
  $perfil = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'").LocalPath
  if (-not $perfil) { return $null }
  $script:tok = Token $sid
  if (-not $tok) { return $null }
  $script:conPersona = $true
  $script:tempPersona = [IO.Path]::Combine($perfil, 'AppData\Local\Temp')
  $l = New-Object Collections.Generic.List[object]
  $null = ComoPersona $tok { foreach ($f in (Viejos $tempPersona 7 $true)) { $l.Add($f) } }
  , $l
}
function Sistema { @(Viejos "$env:SystemRoot\Temp" 7 $false) }
function Registros { @(Viejos "$env:SystemRoot\Logs\CBS" 30 $false) }

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $t = MB (Sistema); $l = MB (Registros)
      $p = Persona
      $u = MB $p
      $total = $t + $u + $l
      "El disco del sistema está al $(Uso)% de uso."
      "Se pueden liberar unos $total MB: $t MB de temporales del sistema, $u MB de tus temporales y $l MB de registros antiguos de Windows."
      if (-not $conPersona) { 'No pude revisar tus temporales: necesito que tengas la sesión abierta en este equipo.' }
      if ($total -ge 100 -or (Uso) -ge 90) { exit 0 }
      'Hay espacio suficiente y poco que limpiar.'
      exit 10
    }
    'comprobar' {
      $yo = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
      if (-not $yo.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'Helpert necesita privilegios de administrador para limpiar el disco.'; exit 3 }
      exit 0
    }
    'aplicar' {
      $antes = LibreMB
      Borrar (Sistema)
      Borrar (Registros)
      $p = Persona
      if ($conPersona) { $null = ComoPersona $tok { Borrar $p } }
      $libre = (LibreMB) - $antes; if ($libre -lt 0) { $libre = 0 }
      "Liberé $libre MB. El disco quedó al $(Uso)% de uso."
      if (-not $conPersona) { 'No toqué tus temporales porque no encontré tu sesión abierta en este equipo.' }
      exit 0
    }
    'verificar' {
      $u = Uso
      if ($u -ge 95) { "El disco sigue casi lleno ($u%)."; exit 1 }
      "El disco está al $u%, con espacio suficiente."
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
