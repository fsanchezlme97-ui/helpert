# Buscar archivos repetidos (idénticos) de 1 MB o más en la carpeta personal. Solo lectura: el diagnóstico informa y
# termina con 10; no borra nada. Primero agrupa por tamaño y solo compara el contenido (huella SHA1) de los que miden lo
# mismo. Con el token de la persona (el de su sesión), no como SYSTEM; sin carpetas ocultas ni del sistema (AppData),
# sin uniones, sin archivos de OneDrive que están solo en la nube (leerlos los descargaría) y con tope de tiempo.
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
function Recorrer($raiz) {
  $fin = [DateTime]::Now.AddSeconds(150)
  $saltar = [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System -bor [IO.FileAttributes]::ReparsePoint
  $pila = New-Object Collections.Stack; $pila.Push($raiz)
  while ($pila.Count) {
    if ([DateTime]::Now -gt $fin) { $estado.Cortada = $true; break }
    $di = New-Object IO.DirectoryInfo $pila.Pop()
    try {
      foreach ($f in $di.EnumerateFiles()) {
        if ($f.Length -lt 1MB -or (([int]$f.Attributes) -band 0x401000)) { continue }  # solo en la nube (Offline / RecallOnDataAccess)
        if (-not $porTam.ContainsKey($f.Length)) { $porTam[$f.Length] = New-Object Collections.Generic.List[object] }
        $porTam[$f.Length].Add($f)
      }
      foreach ($s in $di.EnumerateDirectories()) { if (-not ($s.Attributes -band $saltar)) { $pila.Push($s.FullName) } }
    } catch {}
  }
}
# huella de los que comparten tamaño; agrupa por tamaño + huella
function Comparar {
  $fin = [DateTime]::Now.AddSeconds(300)
  $sha = [Security.Cryptography.SHA1]::Create()  # SHA1 y no MD5: MD5 falla con la política FIPS
  foreach ($l in $porTam.Values) {
    if ($l.Count -lt 2) { continue }
    foreach ($f in $l) {
      if ([DateTime]::Now -gt $fin) { $estado.Cortada = $true; return }
      try {
        $st = $f.OpenRead()
        try { $k = "$($f.Length):" + [BitConverter]::ToString($sha.ComputeHash($st)) } finally { $st.Dispose() }
        if (-not $grupos.ContainsKey($k)) { $grupos[$k] = New-Object Collections.Generic.List[object] }
        $grupos[$k].Add($f)
      } catch {}
    }
  }
}
$porTam = @{}
$grupos = @{}
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
      $null = ComoPersona $tok { Recorrer $perfil; Comparar }
      $rep = @($grupos.Values | Where-Object { $_.Count -gt 1 } | ForEach-Object { [pscustomobject]@{ Sobra = $_[0].Length * ($_.Count - 1); Lista = $_ } } | Sort-Object Sobra -Descending)
      if ($rep.Count -eq 0) { 'No encontré archivos repetidos de 1 MB o más en tu carpeta personal.' }
      else {
        $total = 0; foreach ($r in $rep) { $total += $r.Sobra }
        "Encontré $($rep.Count) grupo(s) de archivos repetidos; ocupan $(Tam $total) de más."
        'Los que más espacio repiten:'
        foreach ($r in ($rep | Select-Object -First 5)) {
          $a = $r.Lista[0].FullName.Substring($perfil.Length + 1); $b = $r.Lista[1].FullName.Substring($perfil.Length + 1)
          "- $($r.Lista.Count) copias de $(Tam $r.Lista[0].Length): $a y $b"
        }
        'No borré nada. Revisa cuáles quieres conservar antes de borrar las copias.'
      }
      if ($estado.Cortada) { 'Tu carpeta es muy grande y no alcancé a revisarla entera: puede haber más repetidos.' }
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
