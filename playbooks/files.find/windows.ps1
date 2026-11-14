# Buscar un archivo por nombre en la carpeta personal de la persona y en su papelera. Solo lectura: el diagnóstico
# busca y termina con 10, así el servidor nunca ofrece «aplicar». La búsqueda corre con el token de la persona (el de
# su sesión), no como SYSTEM: solo ve lo que ella puede ver.
# HP_NOMBRE ya viene validado por el agente: solo letras, números, punto, guion y guion bajo (sin comodines).
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$nombre = "$env:HP_NOMBRE"

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
# en la carpeta personal, sin carpetas ocultas ni del sistema (AppData y las uniones antiguas lo son);
# con tope de profundidad y de tiempo para no pasarse del límite del procedimiento
function Buscar($raiz) {
  $fin = (Get-Date).AddSeconds(35)
  $pila = New-Object Collections.Stack; $pila.Push(@($raiz, 0))
  $oculta = [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System
  while ($pila.Count) {
    if ((Get-Date) -gt $fin) { $script:cortada = $true; break }
    $d, $nivel = $pila.Pop()
    try {
      $di = New-Object IO.DirectoryInfo $d
      foreach ($f in $di.GetFileSystemInfos("*$nombre*")) {
        if ($f.Name -like "*$nombre*") { $hallados.Add([pscustomobject]@{ Fecha = $f.LastWriteTime; Ruta = $f.FullName }) }
      }
      if ($nivel -lt 12) { foreach ($s in $di.GetDirectories()) { if (-not ($s.Attributes -band $oculta)) { $pila.Push(@($s.FullName, ($nivel + 1))) } } }
    } catch {}
  }
}
# papelera de Windows: por cada elemento hay un $I... con la ruta original y un $R... con el contenido
function Papelera($sid) {
  $dir = [IO.Path]::Combine($env:SystemDrive + '\', '$Recycle.Bin', $sid)
  if (-not [IO.Directory]::Exists($dir)) { return }
  foreach ($i in [IO.Directory]::GetFiles($dir, '$I*')) {
    try {
      $b = [IO.File]::ReadAllBytes($i)
      if ($b.Length -lt 28) { continue }
      # versión 2 (Windows 10 y 11): largo de la ruta en el byte 24 y la ruta desde el 28; versión 1: ruta fija desde el 24
      if ([BitConverter]::ToInt64($b, 0) -eq 2) { $desde = 28 } else { $desde = 24 }
      $ruta = [Text.Encoding]::Unicode.GetString($b, $desde, $b.Length - $desde).Split([char]0)[0]
      if ([IO.Path]::GetFileName($ruta) -like "*$nombre*") {
        $papelera.Add([pscustomobject]@{ Fecha = [DateTime]::FromFileTime([BitConverter]::ToInt64($b, 16)); Ruta = $ruta })
      }
    } catch {}
  }
}
function Lista($l) { $l | Sort-Object Fecha -Descending | Select-Object -First 15 | ForEach-Object { '{0:yyyy-MM-dd HH:mm}  {1}' -f $_.Fecha, $_.Ruta } }
$hallados = New-Object Collections.Generic.List[object]
$papelera = New-Object Collections.Generic.List[object]
$cortada = $false

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $sid = SidDe $env:HP_USUARIO
      if (-not $sid) { 'No sé qué persona pide la búsqueda.'; exit 3 }
      if ($nombre.Length -eq 0) { 'Necesito una palabra del nombre del archivo.'; exit 3 }
      $perfil = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'").LocalPath
      if (-not $perfil -or -not (Test-Path -LiteralPath $perfil)) { "No encontré la carpeta personal de $env:HP_USUARIO."; exit 3 }
      $tok = Token $sid
      if (-not $tok) { 'Necesito que tengas la sesión abierta en este equipo para buscar en tu carpeta.'; exit 3 }
      $null = ComoPersona $tok { Buscar $perfil; Papelera $sid }
      if ($hallados.Count -eq 0 -and $papelera.Count -eq 0) {
        "No encontré archivos con «$nombre» en el nombre dentro de tu carpeta personal ni en la papelera."
        'Prueba con otra palabra del nombre, o puede estar en una memoria USB o una carpeta compartida.'
        if ($cortada) { 'La carpeta es muy grande y no alcancé a revisarla entera.' }
        exit 10
      }
      if ($hallados.Count) { "Encontré estos archivos con «$nombre» en el nombre (los más recientes primero):"; Lista $hallados }
      if ($papelera.Count) { 'En la papelera (puedes restaurarlos desde ahí; fecha en que se borraron):'; Lista $papelera }
      if ($cortada) { 'La carpeta es muy grande y no alcancé a revisarla entera: puede haber más.' }
      exit 10
    }
    default { 'Este procedimiento solo busca; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
