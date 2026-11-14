# Recuperar de la papelera de Windows (C:\$Recycle.Bin\<SID>: un $I... con la ruta original y un $R... con el
# contenido). Todo con el token de la persona (el de su sesión), nunca como SYSTEM: la ruta original la escribe
# cualquiera que pueda escribir en su papelera, así que SYSTEM no debe mover nada hacia ella.
# HP_NOMBRE ya viene validado: letras, números, punto, guion y guion bajo (sin comodines).
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
function Preparar {
  $script:sid = SidDe $env:HP_USUARIO
  if (-not $sid) { return 'No sé qué persona lo pide.' }
  if ($nombre.Length -eq 0) { return 'Necesito una palabra del nombre del archivo.' }
  $script:tok = Token $sid
  if (-not $tok) { return 'Necesito que tengas la sesión abierta en este equipo para revisar tu papelera.' }
}
# los 5 borrados más recientes con el nombre pedido; corre con el token de la persona
function Buscar {
  $dir = [IO.Path]::Combine($env:SystemDrive + '\', '$Recycle.Bin', $sid)
  if (-not [IO.Directory]::Exists($dir)) { return }
  $todos = foreach ($i in [IO.Directory]::GetFiles($dir, '$I*')) {
    try {
      $b = [IO.File]::ReadAllBytes($i)
      $r = [IO.Path]::Combine($dir, '$R' + [IO.Path]::GetFileName($i).Substring(2))
      if ($b.Length -lt 28 -or -not ([IO.File]::Exists($r) -or [IO.Directory]::Exists($r))) { continue }
      # versión 2 (Windows 10 y 11): la ruta empieza en el byte 28; versión 1: en el 24, con largo fijo
      if ([BitConverter]::ToInt64($b, 0) -eq 2) { $desde = 28 } else { $desde = 24 }
      $ruta = [Text.Encoding]::Unicode.GetString($b, $desde, $b.Length - $desde).Split([char]0)[0]
      if ([IO.Path]::IsPathRooted($ruta) -and [IO.Path]::GetFileName($ruta) -like "*$nombre*") {
        [pscustomobject]@{ I = $i; R = $r; Ruta = $ruta; Fecha = [DateTime]::FromFileTime([BitConverter]::ToInt64($b, 16)) }
      }
    } catch {}
  }
  foreach ($x in @($todos | Sort-Object Fecha -Descending | Select-Object -First 5)) { $hallados.Add($x) }
}
# si ya hay otro con ese nombre, se deja al lado: nunca se sobrescribe
function Destino($ruta) {
  if (-not ([IO.File]::Exists($ruta) -or [IO.Directory]::Exists($ruta))) { return $ruta }
  $dir = [IO.Path]::GetDirectoryName($ruta); $base = [IO.Path]::GetFileNameWithoutExtension($ruta); $ext = [IO.Path]::GetExtension($ruta)
  $otro = [IO.Path]::Combine($dir, "$base (recuperado)$ext")
  if ([IO.File]::Exists($otro) -or [IO.Directory]::Exists($otro)) { $otro = [IO.Path]::Combine($dir, (Get-Date).ToString('HHmmss') + ' ' + [IO.Path]::GetFileName($ruta)) }
  $otro
}
$hallados = New-Object Collections.Generic.List[object]
$hechos = New-Object Collections.Generic.List[string]

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      $null = ComoPersona $tok { Buscar }
      if ($hallados.Count -eq 0) { "No encontré nada con «$nombre» en el nombre en tu papelera. Si la vaciaste, soporte puede revisar las copias de seguridad."; exit 10 }
      'Encontré en la papelera:'
      foreach ($h in $hallados) { "- $([IO.Path]::GetFileName($h.Ruta)) (estaba en $([IO.Path]::GetDirectoryName($h.Ruta)))" }
      if ($hallados.Count -gt 1) { 'Si sigo, devuelvo todos a su carpeta.' }
      exit 0
    }
    'comprobar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      $null = ComoPersona $tok { Buscar }
      if ($hallados.Count -eq 0) { 'Ya no está en la papelera.'; exit 3 }
      exit 0
    }
    'aplicar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      $null = ComoPersona $tok {
        Buscar
        foreach ($h in $hallados) {
          try {
            $d = Destino $h.Ruta
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($d))
            if ([IO.Directory]::Exists($h.R)) { [IO.Directory]::Move($h.R, $d) } else { [IO.File]::Move($h.R, $d) }
            [IO.File]::Delete($h.I)
            $hechos.Add($d)
          } catch {}
        }
      }
      if ($hechos.Count -eq 0) { 'No pude recuperar el archivo.'; exit 1 }
      foreach ($d in $hechos) { "- Recuperado en $d" }
      exit 0
    }
    'verificar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      $null = ComoPersona $tok { Buscar }
      # aplicar devuelve los 5 más recientes: si quedan, o no se pudieron mover o había más de 5 con ese nombre
      if ($hallados.Count) { "Todavía quedan en la papelera: $(@($hallados | ForEach-Object { [IO.Path]::GetFileName($_.Ruta) }) -join ', ')."; exit 1 }
      'Listo: el archivo volvió a su carpeta.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
