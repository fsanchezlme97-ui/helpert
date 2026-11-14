# Vaciar la papelera de la persona: C:\$Recycle.Bin\<SID> en cada disco fijo (un $I... con los datos y un $R... con el
# contenido por elemento). Definitivo. Se borra con el token de la persona (el de su sesión), nunca como SYSTEM: así
# una unión o un enlace en su papelera no puede llevar a borrar archivos ajenos. Clear-RecycleBin no sirve: como
# SYSTEM vaciaría la papelera de todas las cuentas.
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
function Preparar {
  $script:sid = SidDe $env:HP_USUARIO
  if (-not $sid) { return 'No sé qué persona lo pide.' }
  $script:tok = Token $sid
  if (-not $tok) { return 'Necesito que tengas la sesión abierta en este equipo para vaciar tu papelera.' }
  $script:papeleras = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { [IO.Path]::Combine($_.DeviceID + '\', '$Recycle.Bin', $sid) })
}
# cuenta los elementos y lo que ocupan; con el token de la persona
function Contar {
  $cuenta.N = 0; $cuenta.Bytes = 0
  foreach ($p in $papeleras) {
    if (-not [IO.Directory]::Exists($p)) { continue }
    try { $todos = [IO.Directory]::GetFileSystemEntries($p, '$R*') } catch { continue }
    foreach ($r in $todos) {
      $cuenta.N++
      try {
        if ([IO.File]::Exists($r)) { $cuenta.Bytes += (New-Object IO.FileInfo $r).Length }
        else { foreach ($f in (New-Object IO.DirectoryInfo $r).EnumerateFiles('*', [IO.SearchOption]::AllDirectories)) { $cuenta.Bytes += $f.Length } }
      } catch {}
    }
  }
}
# Directory.Delete no entra en uniones ni enlaces: los quita sin tocar lo que hay detrás
function Vaciar {
  foreach ($p in $papeleras) {
    if (-not [IO.Directory]::Exists($p)) { continue }
    try { $todos = [IO.Directory]::GetFileSystemEntries($p, '$R*'); $datos = [IO.Directory]::GetFiles($p, '$I*') } catch { continue }
    foreach ($r in $todos) {
      try { if ([IO.Directory]::Exists($r)) { [IO.Directory]::Delete($r, $true) } else { [IO.File]::Delete($r) } } catch {}
    }
    foreach ($i in $datos) {
      $r = [IO.Path]::Combine($p, '$R' + [IO.Path]::GetFileName($i).Substring(2))
      if (-not ([IO.File]::Exists($r) -or [IO.Directory]::Exists($r))) { try { [IO.File]::Delete($i) } catch {} }
    }
  }
}
$cuenta = @{ N = 0; Bytes = 0 }

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      $null = ComoPersona $tok { Contar }
      if ($cuenta.N -eq 0) { 'Tu papelera ya está vacía.'; exit 10 }
      "Tu papelera tiene $($cuenta.N) elemento(s) y ocupa $([math]::Round($cuenta.Bytes / 1MB)) MB."
      'Si sigo, la vacío definitivamente: lo que hay en ella ya no se podrá recuperar.'
      exit 0
    }
    'comprobar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      $null = ComoPersona $tok { Contar }
      if ($cuenta.N -eq 0) { 'La papelera ya está vacía.'; exit 3 }
      exit 0
    }
    'aplicar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      $null = ComoPersona $tok { Contar }
      $mb = [math]::Round($cuenta.Bytes / 1MB)
      $null = ComoPersona $tok { Vaciar; Contar }
      if ($cuenta.N -gt 0) { "No pude borrar $($cuenta.N) elemento(s) de la papelera: puede que algún programa los tenga abiertos."; exit 1 }
      "Vacié la papelera: liberé unos $mb MB."
      exit 0
    }
    'verificar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      $null = ComoPersona $tok { Contar }
      if ($cuenta.N -gt 0) { "En la papelera quedan $($cuenta.N) elemento(s)."; exit 1 }
      'La papelera está vacía.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
