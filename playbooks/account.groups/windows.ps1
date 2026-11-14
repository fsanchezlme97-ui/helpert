# Ver a qué grupos pertenece la cuenta de la persona, en el equipo y en el dominio (o Entra ID): los grupos de su
# sesión abierta, que es lo que Windows usa para darle acceso (incluye los grupos dentro de grupos). Sin sesión
# abierta no se puede. Solo lectura: termina con 10. Dar accesos lo hace soporte.
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
# grupos reales (locales, BUILTIN, del dominio, de Entra ID); no los automáticos como «Todos» o «Interactivo»
function Grupos($tok) {
  if ($tok -is [string]) { $id = [Security.Principal.WindowsIdentity]::GetCurrent() }
  else { $id = New-Object Security.Principal.WindowsIdentity ($tok.DangerousGetHandle()) }
  foreach ($g in $id.Groups) {
    $v = $g.Value
    if ($v -notmatch '^S-1-(5-32|5-21|12-1)-') { continue }
    try { $g.Translate([Security.Principal.NTAccount]).Value }
    catch { if ($v -like 'S-1-12-1-*') { "grupo de Entra ID $v" } else { "grupo sin nombre visible $v" } }
  }
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $sid = SidDe $env:HP_USUARIO
      if (-not $sid) { 'No sé qué persona lo pide.'; exit 3 }
      $tok = Token $sid
      if (-not $tok) { 'Necesito que tengas la sesión abierta en este equipo para ver tus grupos.'; exit 3 }
      $l = @(Grupos $tok | Sort-Object -Unique)
      if ($l.Count -eq 0) { "No encontré grupos para la cuenta «$env:HP_USUARIO»."; exit 10 }
      "La cuenta «$env:HP_USUARIO» pertenece a $($l.Count) grupo(s):"
      $l -join ', '
      'Son los grupos con los que entraste: si te acaban de agregar a uno, cierra sesión y vuelve a entrar para que cuente. Dar accesos lo hace soporte.'
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
