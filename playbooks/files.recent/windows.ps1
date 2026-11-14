# Ver los últimos archivos que la persona modificó en su carpeta personal (30 días). Solo lectura: el diagnóstico
# informa y termina con 10. Recorre la carpeta con el token de la persona (el de su sesión), no como SYSTEM, sin
# carpetas ocultas ni del sistema (AppData y las uniones antiguas lo son), sin archivos ocultos y con tope de tiempo.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

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
function Recorrer($raiz) {
  $fin = [DateTime]::Now.AddSeconds(80)
  $desde = [DateTime]::Now.AddDays(-30)
  $oculta = [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System
  $pila = New-Object Collections.Stack; $pila.Push($raiz)
  while ($pila.Count) {
    if ([DateTime]::Now -gt $fin) { $estado.Cortada = $true; break }
    $di = New-Object IO.DirectoryInfo $pila.Pop()
    try {
      foreach ($f in $di.EnumerateFiles()) { if ($f.LastWriteTime -gt $desde -and -not ($f.Attributes -band $oculta)) { $hallados.Add($f) } }
      foreach ($s in $di.EnumerateDirectories()) { if (-not ($s.Attributes -band ($oculta -bor [IO.FileAttributes]::ReparsePoint))) { $pila.Push($s.FullName) } }
    } catch {}
  }
}
$hallados = New-Object Collections.Generic.List[object]
$estado = @{ Cortada = $false }

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $sid = SidDe $env:HP_USUARIO
      if (-not $sid) { 'No sé qué persona lo pide.'; exit 3 }
      $perfil = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'").LocalPath
      if (-not $perfil -or -not (Test-Path -LiteralPath $perfil)) { "No encontré la carpeta personal de $env:HP_USUARIO."; exit 3 }
      $tok = Token $sid
      if (-not $tok) { 'Necesito que tengas la sesión abierta en este equipo para revisar tu carpeta.'; exit 3 }
      $null = ComoPersona $tok { Recorrer $perfil }
      if ($hallados.Count -eq 0) {
        'No encontré archivos tuyos modificados en los últimos 30 días dentro de tu carpeta personal.'
        'Puede estar en una memoria USB, una carpeta de red o en la nube; si recuerdas parte del nombre, usa «Buscar un archivo».'
      } else {
        'Estos son los últimos archivos que modificaste (los más recientes primero):'
        $hallados | Sort-Object LastWriteTime -Descending | Select-Object -First 10 | ForEach-Object { '{0:yyyy-MM-dd HH:mm}  {1}' -f $_.LastWriteTime, $_.FullName.Substring($perfil.Length + 1) }
        'Si recuerdas parte del nombre, «Buscar un archivo» también busca en la papelera.'
      }
      if ($estado.Cortada) { 'Tu carpeta es muy grande y no alcancé a revisarla entera: puede haber otros más recientes.' }
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
