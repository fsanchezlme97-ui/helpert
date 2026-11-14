# Encontrar lo que más ocupa en la carpeta personal. Solo lectura: el diagnóstico informa y termina con 10.
# Recorre la carpeta con el token de la persona (el de su sesión), no como SYSTEM: solo ve lo que ella puede ver.
# No entra en uniones ni enlaces, y no cuenta los archivos de OneDrive que están solo en la nube (no ocupan disco).
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
function Tam($b) { if ($b -ge 1GB) { '{0:N1} GB' -f ($b / 1GB) } else { '{0:N0} MB' -f ($b / 1MB) } }
# suma por carpeta de primer nivel y guarda los archivos de 100 MB o más; con tope de tiempo
function Recorrer($raiz) {
  $fin = [DateTime]::Now.AddSeconds(200)
  $pila = New-Object Collections.Stack
  try {
    foreach ($s in (New-Object IO.DirectoryInfo $raiz).EnumerateDirectories()) {
      if (-not ($s.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $pila.Push(@($s.FullName, $s.Name)) }
    }
    foreach ($f in (New-Object IO.DirectoryInfo $raiz).EnumerateFiles()) { $carpetas['(archivos sueltos)'] += $f.Length }
  } catch {}
  while ($pila.Count) {
    if ([DateTime]::Now -gt $fin) { $estado.Cortada = $true; break }
    $d, $arriba = $pila.Pop()
    try {
      $di = New-Object IO.DirectoryInfo $d
      foreach ($f in $di.EnumerateFiles()) {
        if (([int]$f.Attributes) -band 0x401000) { continue }  # solo en la nube (Offline / RecallOnDataAccess)
        $carpetas[$arriba] += $f.Length
        if ($f.Length -ge 100MB) { $grandes.Add($f) }
      }
      foreach ($s in $di.EnumerateDirectories()) { if (-not ($s.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $pila.Push(@($s.FullName, $arriba)) } }
    } catch {}
  }
}
$carpetas = @{}
$grandes = New-Object Collections.Generic.List[object]
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
      $total = 0; foreach ($v in $carpetas.Values) { $total += $v }
      if ($total -eq 0) { 'Tu carpeta personal está vacía o no pude leerla.'; exit 10 }
      $disco = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($perfil.Substring(0, 2))'"
      $libre = ''; if ($disco) { $libre = "; en el disco quedan $(Tam $disco.FreeSpace) libres" }
      "Tu carpeta personal ocupa $(Tam $total)$libre."
      $top = @($carpetas.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 5 | ForEach-Object { "$($_.Key) ($(Tam $_.Value))" })
      "Lo que más ocupa: $($top -join ', ')."
      if ($grandes.Count) {
        'Los archivos más grandes:'
        $grandes | Sort-Object Length -Descending | Select-Object -First 5 | ForEach-Object { "- $($_.FullName.Substring($perfil.Length + 1)) ($(Tam $_.Length))" }
      }
      'AppData guarda datos de programas; para limpiar temporales usa «Liberar espacio en disco».'
      if ($estado.Cortada) { 'Tu carpeta es muy grande y no alcancé a revisarla entera: las cifras son de lo que alcancé a ver.' }
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
