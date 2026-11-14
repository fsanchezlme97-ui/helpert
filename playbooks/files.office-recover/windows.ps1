# Recuperar documentos sin guardar: copia las copias de recuperación automática de Word, Excel, PowerPoint y
# LibreOffice (de los últimos 30 días) a «Recuperados» dentro de Documentos. No borra ni mueve nada: solo copia,
# nunca sobrescribe. Todo con el token de la persona (el de su sesión), nunca como SYSTEM.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
# carpeta dentro del perfil, extensiones (vacío = todas) y si se buscan también en subcarpetas
$FUENTES = @(
  @('AppData\Roaming\Microsoft\Word', '.asd .wbk', $true),
  @('AppData\Roaming\Microsoft\Excel', '.xar .xlsb', $true),
  @('AppData\Roaming\Microsoft\PowerPoint', '.pptx .ppt', $true),
  @('AppData\Local\Microsoft\Office\UnsavedFiles', '', $false),
  @('AppData\Roaming\LibreOffice\4\user\backup', '', $false)
)

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
  $script:perfil = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'").LocalPath
  if (-not $perfil) { return 'No encontré tu carpeta personal en este equipo.' }
  $script:tok = Token $sid
  if (-not $tok) { return 'Necesito que tengas la sesión abierta en este equipo para revisar tus documentos.' }
  # Documentos puede estar en otro sitio (OneDrive): se lee de su registro sin expandir, porque %USERPROFILE% aquí es el de SYSTEM
  $docs = $null
  try { $docs = (Get-Item -LiteralPath "Registry::HKEY_USERS\$sid\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders").GetValue('Personal', $null, 'DoNotExpandEnvironmentNames') } catch {}
  if ($docs -like '%USERPROFILE%*') { $docs = $perfil + $docs.Substring(13) }
  if (-not $docs -or $docs.Contains('%') -or -not [IO.Path]::IsPathRooted($docs)) { $docs = [IO.Path]::Combine($perfil, 'Documents') }
  $script:destino = [IO.Path]::Combine($docs, 'Recuperados')
}
# copias de recuperación de los últimos 30 días, sin las carpetas de inicio (XLSTART, STARTUP); con el token de la persona
function Buscar {
  $desde = [DateTime]::Now.AddDays(-30)
  foreach ($f in $FUENTES) {
    $d = New-Object IO.DirectoryInfo ([IO.Path]::Combine($perfil, $f[0]))
    if (-not $d.Exists) { continue }
    $ext = @($f[1].Split([char[]]' ', [StringSplitOptions]::RemoveEmptyEntries))
    $modo = [IO.SearchOption]::TopDirectoryOnly; if ($f[2]) { $modo = [IO.SearchOption]::AllDirectories }
    try {
      foreach ($a in $d.EnumerateFiles('*', $modo)) {
        if ($a.LastWriteTime -lt $desde -or $a.FullName -match '\\(XLSTART|STARTUP)\\') { continue }
        if ($ext.Count -and $ext -notcontains $a.Extension.ToLower()) { continue }
        $copias.Add($a)
      }
    } catch {}
  }
}
function Copiada($a) {  # ya está en Recuperados (con su nombre, o con fecha delante y el mismo tamaño)
  $c = New-Object IO.FileInfo ([IO.Path]::Combine($destino, $a.Name))
  if ($c.Exists -and $c.Length -eq $a.Length) { return $true }
  if (-not [IO.Directory]::Exists($destino)) { return $false }
  foreach ($o in [IO.Directory]::GetFiles($destino, '*-' + $a.Name)) { if ((New-Object IO.FileInfo $o).Length -eq $a.Length) { return $true } }
  $false
}
function Copiar {
  [void][IO.Directory]::CreateDirectory($destino)
  foreach ($a in $copias) {
    if (Copiada $a) { continue }
    $d = [IO.Path]::Combine($destino, $a.Name)
    if ([IO.File]::Exists($d)) { $d = [IO.Path]::Combine($destino, [DateTime]::Now.ToString('yyyyMMdd-HHmmss') + '-' + $a.Name) }
    try { [void]$a.CopyTo($d, $false); $cuenta.Bien++ } catch { $cuenta.Mal++ }
  }
}
function Faltan { foreach ($a in $copias) { if (-not (Copiada $a)) { $cuenta.Faltan++ } } }
$copias = New-Object Collections.Generic.List[object]
$cuenta = @{ Bien = 0; Mal = 0; Faltan = 0 }

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      $null = ComoPersona $tok { Buscar }
      if ($copias.Count -eq 0) {
        'No encontré copias de recuperación de Word, Excel, PowerPoint ni LibreOffice de los últimos 30 días.'
        'Abre el programa: si tenía algo que recuperar, te lo ofrece al empezar. En Word también puedes probar Archivo > Información > Administrar documento > Recuperar documentos no guardados.'
        exit 10
      }
      "Encontré $($copias.Count) copia(s) de recuperación:"
      $copias | Sort-Object LastWriteTime -Descending | Select-Object -First 5 | ForEach-Object { '- {0} ({1:yyyy-MM-dd HH:mm})' -f $_.Name, $_.LastWriteTime }
      "Si sigo, las copio a $destino (no se borra nada)."
      exit 0
    }
    'comprobar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      $null = ComoPersona $tok { Buscar }
      if ($copias.Count -eq 0) { 'Ya no hay copias de recuperación.'; exit 3 }
      exit 0
    }
    'aplicar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      try { $null = ComoPersona $tok { Buscar; Copiar } } catch { "No pude crear la carpeta $destino."; exit 1 }
      if ($cuenta.Mal) { "No pude copiar $($cuenta.Mal) archivo(s): puede que el programa los tenga abiertos. Ciérralo y vuelve a pedírmelo."; exit 1 }
      "Copié $($cuenta.Bien) documento(s) a $destino. Ábrelos desde ahí y guárdalos con el nombre que quieras."
      'Los archivos .asd se abren desde Word (Archivo > Abrir); los .xar, desde Excel.'
      exit 0
    }
    'verificar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      $null = ComoPersona $tok { Buscar; Faltan }
      if ($cuenta.Faltan) { "Faltan $($cuenta.Faltan) copia(s) en $destino."; exit 1 }
      "Las copias de recuperación están en $destino."
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
