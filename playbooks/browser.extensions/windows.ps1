# Ver las extensiones del navegador: lista las de Chrome, Edge, Brave, Chromium y Firefox de la persona (Chrome y
# parecidos: carpeta Extensions de cada perfil; Firefox: extensions.json). Solo lectura: termina con 10.
# Se leen con el token de la persona (el de su sesión), nunca como SYSTEM.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$CHROMES = [ordered]@{ Chrome = 'Google\Chrome\User Data'; Edge = 'Microsoft\Edge\User Data'; Brave = 'BraveSoftware\Brave-Browser\User Data'; Chromium = 'Chromium\User Data' }

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
# con el token de la persona; lo que escribe el bloque se pierde, así que deja sus resultados en variables $script:
function ComoPersona($tok, [scriptblock]$b) {
  if ($tok -is [string]) { $null = & $b } else { [Security.Principal.WindowsIdentity]::RunImpersonated($tok, [Action]$b) }
}
function Preparar {
  $script:sid = SidDe $env:HP_USUARIO
  if (-not $sid) { return 'No sé qué persona lo pide.' }
  $script:perfil = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'").LocalPath
  if (-not $perfil) { return 'No encontré tu carpeta personal en este equipo.' }
  $script:tok = Token $sid
  if (-not $tok) { return "Necesito que tengas la sesión abierta en este equipo para revisar tus navegadores." }
}
function Json($f) { [IO.File]::ReadAllText($f) | ConvertFrom-Json }
function Carpetas($d) { if ([IO.Directory]::Exists($d)) { @([IO.Directory]::GetDirectories($d) | Sort-Object) } else { @() } }
# nombre de una extensión de Chrome y parecidos ($d: Extensions\<id>); puede venir traducido (__MSG_clave__)
function NombreChrome($d) {
  $v = @(Carpetas $d); if (-not $v.Count) { return $null }
  $d = $v[-1]
  $m = Json ([IO.Path]::Combine($d, 'manifest.json'))
  if ($m.theme) { return $null }
  $n = "$($m.name)"
  if ($n -match '^__MSG_(.+)__$') {
    $clave = $Matches[1]
    foreach ($loc in @('es', 'es_419', $m.default_locale, 'en', 'en_US')) {
      if (-not $loc) { continue }
      $f = [IO.Path]::Combine($d, '_locales', $loc, 'messages.json')
      if (-not [IO.File]::Exists($f)) { continue }
      # las claves no distinguen mayúsculas: se buscan con una expresión regular en vez de convertir el JSON
      $t = [IO.File]::ReadAllText($f)
      $r = [regex]::Match($t, '"' + [regex]::Escape($clave) + '"\s*:\s*\{[^}]*?"message"\s*:\s*"((?:[^"\\]|\\.)*)"', 'IgnoreCase')
      if ($r.Success) { return [regex]::Unescape($r.Groups[1].Value) }
    }
  }
  $n
}
function Anotar($nav, $nombres) {
  $script:total += $nombres.Count
  if (-not $nombres.Count) { return }
  $extra = ''; if ($nombres.Count -gt 8) { $extra = " y $($nombres.Count - 8) más" }
  $salida.Add("${nav}: $(@($nombres | Select-Object -First 8) -join ', ')$extra.")
}
# corre con el token de la persona
function Revisar {
  $local = [IO.Path]::Combine($perfil, 'AppData\Local')
  foreach ($nav in $CHROMES.Keys) {
    $base = [IO.Path]::Combine($local, $CHROMES[$nav])
    $perfiles = @(Carpetas $base | Where-Object { (Split-Path -Leaf $_) -match '^(Default|Profile \d+)$' })
    foreach ($p in $perfiles) {
      $nombres = @(@(foreach ($e in (Carpetas ([IO.Path]::Combine($p, 'Extensions')))) {
            try { NombreChrome $e } catch { Split-Path -Leaf $e }
          }) | Where-Object { $_ })
      $et = $nav; if ($perfiles.Count -gt 1) { $et = "$nav (perfil $(Split-Path -Leaf $p))" }
      Anotar $et $nombres
    }
  }
  $ff = @(Carpetas ([IO.Path]::Combine($perfil, 'AppData\Roaming\Mozilla\Firefox\Profiles')) | Where-Object { [IO.File]::Exists([IO.Path]::Combine($_, 'extensions.json')) })
  foreach ($p in $ff) {
    try { $addons = @((Json ([IO.Path]::Combine($p, 'extensions.json'))).addons) } catch { continue }
    $nombres = @(foreach ($a in $addons) {
        if ($a.type -ne 'extension' -or @('app-builtin', 'app-system-defaults') -contains $a.location) { continue }
        $n = "$($a.defaultLocale.name)"; if (-not $n) { $n = "$($a.id)" }
        if (-not $a.active) { $n += ' (desactivada)' }
        $n
      })
    $et = 'Firefox'; if ($ff.Count -gt 1) { $et = "Firefox (perfil $((Split-Path -Leaf $p) -replace '^[^.]*\.', ''))" }
    Anotar $et $nombres
  }
}
$salida = New-Object Collections.Generic.List[string]; $total = 0

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      ComoPersona $tok { Revisar }
      if ($total -eq 0) { 'No encontré extensiones en tus navegadores.'; exit 10 }
      "Encontré $total extensión(es) en tus navegadores:"
      foreach ($l in @($salida | Select-Object -First 7)) { "- $l" }
      if ($salida.Count -gt 7) { "- y $($salida.Count - 7) perfil(es) más." }
      'Si alguna no la reconoces o no la instalaste tú, quítala desde el menú de extensiones del navegador o pide ayuda a soporte.'
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
