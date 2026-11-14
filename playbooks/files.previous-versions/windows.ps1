# Recuperar una versión anterior de un archivo desde las instantáneas del sistema (Volume Shadow Copy, las de
# «Versiones anteriores»). Elige el archivo más reciente de la carpeta personal con la palabra en el nombre, busca en
# las instantáneas (de la más nueva a la más vieja) la primera versión distinta de la actual y la copia al lado como
# «nombre (versión del AAAA-MM-DD HHMM).ext». Nunca sobrescribe: el archivo actual no se toca.
# La lista de instantáneas la lee SYSTEM; buscar, leer y copiar archivos, el token de la persona. Las rutas
# \\?\GLOBALROOT de las instantáneas van por la API de Windows (kernel32), porque .NET en PowerShell 5.1 no las acepta.
# HP_ARCHIVO ya viene validado (letras, números, . _ -); se compara como texto literal.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$archivo = "$env:HP_ARCHIVO"
$VSS = @'
using System; using System.Runtime.InteropServices;
public static class HpVss {
  [StructLayout(LayoutKind.Sequential)] struct D { public uint A, C1, C2, L1, L2, W1, W2, H, Lo; }
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool GetFileAttributesExW(string p, int nivel, out D d);
  [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] public static extern bool CopyFileW(string de, string a, bool siExisteFalla);
  // fecha de modificación (FILETIME UTC) o -1 si no existe o es una carpeta
  public static long Fecha(string p) { D d; if (!GetFileAttributesExW(p, 0, out d) || (d.A & 16) != 0) return -1; return ((long)d.W2 << 32) | d.W1; }
}
'@

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
  if (-not ('HpVss' -as [type])) { Add-Type -TypeDefinition $VSS }
  $yo = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $yo.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return 'Helpert necesita privilegios de administrador para ver las instantáneas del sistema.' }
  $script:sid = SidDe $env:HP_USUARIO
  if (-not $sid) { return 'No sé qué persona lo pide.' }
  if ($archivo.Length -lt 3) { return 'Necesito al menos 3 letras del nombre del archivo.' }
  $script:perfil = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'").LocalPath
  if (-not $perfil) { return 'No encontré tu carpeta personal en este equipo.' }
  $script:tok = Token $sid
  if (-not $tok) { return 'Necesito que tengas la sesión abierta en este equipo para buscar tu archivo.' }
}
# el archivo más reciente con la palabra en el nombre (sin carpetas ocultas ni del sistema); con el token de la persona
function Buscar {
  $fin = [DateTime]::Now.AddSeconds(60)
  $patron = '*' + [WildcardPattern]::Escape($archivo) + '*'
  $saltar = [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System -bor [IO.FileAttributes]::ReparsePoint
  $pila = New-Object Collections.Stack; $pila.Push($perfil)
  while ($pila.Count -and [DateTime]::Now -lt $fin) {
    $di = New-Object IO.DirectoryInfo $pila.Pop()
    try {
      foreach ($f in $di.EnumerateFiles()) {
        if ($f.Name -notlike $patron -or $f.Name.StartsWith('~$')) { continue }
        $res.N++
        if (-not $res.Archivo -or $f.LastWriteTimeUtc -gt $res.Archivo.LastWriteTimeUtc) { $res.Archivo = $f }
      }
      foreach ($s in $di.EnumerateDirectories()) { if (-not ($s.Attributes -band $saltar)) { $pila.Push($s.FullName) } }
    } catch {}
  }
}
# instantáneas del disco del archivo, de la más nueva a la más vieja (como SYSTEM: solo la lista, sin abrir archivos)
function Sombras {
  $letra = $res.Archivo.FullName.Substring(0, 2)
  try {
    $vol = (Get-CimInstance Win32_Volume -Filter "DriveLetter='$letra'").DeviceID
    @(Get-CimInstance Win32_ShadowCopy | Where-Object { $_.VolumeName -eq $vol } | Sort-Object InstallDate -Descending)
  } catch { @() }  # sin el servicio de instantáneas: como si no hubiera
}
# la primera versión distinta de la actual; con el token de la persona
function Version {
  $rel = $res.Archivo.FullName.Substring(3)
  $hoy = $res.Archivo.LastWriteTimeUtc.ToFileTimeUtc()
  foreach ($s in $sombras) {
    $p = $s.DeviceObject + '\' + $rel
    $t = [HpVss]::Fecha($p)
    if ($t -ge 0 -and $t -ne $hoy) {
      $res.Origen = $p; $res.Fecha = $s.InstallDate
      $f = $res.Archivo
      $nombre = '{0} (versión del {1:yyyy-MM-dd HHmm}){2}' -f [IO.Path]::GetFileNameWithoutExtension($f.Name), $s.InstallDate, $f.Extension
      $res.Destino = [IO.Path]::Combine($f.DirectoryName, $nombre)
      return
    }
  }
}
function Todo {
  $null = ComoPersona $tok { Buscar }
  if (-not $res.Archivo) { return "No encontré archivos con «$archivo» en el nombre en tu carpeta personal." }
  $script:sombras = Sombras
  if ($sombras.Count -eq 0) {
    return "Este equipo no tiene instantáneas del sistema de ese disco, así que no hay versiones anteriores de «$($res.Archivo.Name)».`nSi el archivo está en OneDrive, puedes recuperar una versión anterior desde su historial de versiones (clic derecho > Historial de versiones). Si no, soporte puede revisar las copias de seguridad."
  }
  $null = ComoPersona $tok { Version }
  if (-not $res.Origen) { return "Las instantáneas del sistema no tienen una versión distinta de «$($res.Archivo.Name)». Si está en OneDrive, prueba con su historial de versiones." }
}
$res = @{ N = 0; Archivo = $null; Origen = $null; Fecha = $null; Destino = $null }
$sombras = @()

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      $m = Todo; if ($m) { $m; exit 10 }
      "Encontré «$($res.Archivo.Name)» en $($res.Archivo.DirectoryName) (modificado el $('{0:yyyy-MM-dd HH:mm}' -f $res.Archivo.LastWriteTime))."
      if ($res.N -gt 1) { "Hay $($res.N) archivos con «$archivo» en el nombre: elegí el que modificaste por último. Si no es ese, dime una palabra más precisa." }
      "Hay una versión anterior del $('{0:yyyy-MM-dd HH:mm}' -f $res.Fecha) en las instantáneas del sistema."
      "Si sigo, la copio al lado como «$([IO.Path]::GetFileName($res.Destino))»; tu archivo actual no se toca."
      exit 0
    }
    'comprobar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      $m = Todo; if ($m) { $m; exit 3 }
      exit 0
    }
    'aplicar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      $m = Todo; if ($m) { $m; exit 1 }
      $null = ComoPersona $tok { if (-not [IO.File]::Exists($res.Destino)) { $res.Copiada = [HpVss]::CopyFileW($res.Origen, $res.Destino, $true) } else { $res.Copiada = $true } }
      if (-not $res.Copiada) { 'No pude copiar la versión anterior: puede que no tengas permiso para leerla o escribir en esa carpeta.'; exit 1 }
      "Copié la versión del $('{0:yyyy-MM-dd HH:mm}' -f $res.Fecha) como «$($res.Destino)». Ábrela y, si es la buena, guárdala con el nombre que quieras."
      exit 0
    }
    'verificar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      $m = Todo; if ($m) { $m; exit 1 }
      $null = ComoPersona $tok { $res.Existe = [IO.File]::Exists($res.Destino) }
      if (-not $res.Existe) { 'No encuentro la copia de la versión anterior.'; exit 1 }
      "La versión anterior está en «$($res.Destino)»."
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
