# Cerrar un programa congelado: solo procesos de la persona que pide (por su SID), nunca del sistema ni del escritorio.
# HP_PROGRAMA ya viene validado (letras, números, . _ -). Desde el servicio (sesión 0) no se le puede pedir a una
# ventana de otra sesión que se cierre: se cierra a la fuerza, igual que en Linux cuando no responde.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$prog = "$env:HP_PROGRAMA".ToLower() -replace '\.exe$', ''
# nombres que la gente dice -> nombre del proceso
switch -Regex ($prog) {
  '^(libreoffice|writer|calc|impress)$' { $prog = 'soffice' }
  '^(word|winword)$' { $prog = 'winword' }
  '^(powerpoint|powerpnt)$' { $prog = 'powerpnt' }
  '^(chrome|google-chrome)$' { $prog = 'chrome' }
  '^(edge|msedge|microsoft-edge)$' { $prog = 'msedge' }
  '^(teams|ms-teams|teams-for-linux)$' { $prog = 'teams' }
}
# el escritorio, la sesión, las consolas y el propio Helpert no se cierran nunca
$PROTEGIDOS = '^(system|idle|registry|smss|csrss|wininit|winlogon|services|lsass|lsaiso|svchost|dwm|explorer|sihost|userinit|logonui|fontdrvhost|ctfmon|conhost|dllhost|taskhostw|runtimebroker|audiodg|spoolsv|wudfhost|searchhost|searchapp|searchui|searchindexer|startmenuexperiencehost|shellexperiencehost|textinputhost|applicationframehost|lockapp|securityhealthsystray|securityhealthservice|smartscreen|msmpeng|powershell|pwsh|cmd|windowsterminal|openconsole|helpert.*)$'

function SidDe($cuenta) {  # solo cuentas de personas (locales, de dominio o de Entra ID), nunca SYSTEM ni de servicio
  if (-not $cuenta) { return $null }
  try { $s = (New-Object Security.Principal.NTAccount($cuenta)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { return $null }
  if ($s -match '^S-1-(5-21|12-1)-') { $s }
}
$sid = SidDe $env:HP_USUARIO

function NoPuedo {
  if (-not $sid) { return 'No sé qué persona lo pide.' }
  $yo = [Security.Principal.WindowsIdentity]::GetCurrent()
  $admin = (New-Object Security.Principal.WindowsPrincipal $yo).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if ($yo.User.Value -ne $sid -and -not $admin) { return 'No puedo cerrar programas de otra persona.' }
  if ($prog.Length -lt 3) { return 'Necesito el nombre del programa (al menos 3 letras).' }
}
# procesos de la persona cuyo nombre contiene el programa (sin distinguir mayúsculas)
function Procesos {
  @(Get-CimInstance Win32_Process | Where-Object {
      $n = "$($_.Name)".ToLower() -replace '\.exe$', ''
      $n.Contains($prog) -and $n -notmatch $PROTEGIDOS
    } | Where-Object { (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid -eq $sid })
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = NoPuedo; if ($m) { $m; exit 3 }
      if ($prog -match $PROTEGIDOS) { "«$prog» es parte del sistema o del escritorio: no lo cierro."; exit 1 }
      $p = @(Procesos)
      if ($p.Count -eq 0) { "No encontré «$env:HP_PROGRAMA» abierto. Si ya no está, ábrelo de nuevo."; exit 10 }
      $nombres = @($p | ForEach-Object { $_.Name } | Sort-Object -Unique) -join ', '
      "Encontré «$nombres» abierto ($($p.Count) proceso(s))."
      'Si lo cierro, se pierde lo que no hayas guardado en ese programa.'
      exit 0
    }
    'comprobar' {
      $m = NoPuedo; if ($m) { $m; exit 3 }
      if (@(Procesos).Count -eq 0) { 'El programa ya no está abierto.'; exit 3 }
      exit 0
    }
    'aplicar' {
      $p = @(Procesos)
      if ($p.Count -eq 0) { 'El programa ya estaba cerrado.'; exit 0 }
      foreach ($x in $p) { Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue }
      "Cerré el programa a la fuerza ($($p.Count) proceso(s)); lo que no estaba guardado en él se perdió."
      exit 0
    }
    'verificar' {
      Start-Sleep -Seconds 1
      if (@(Procesos).Count -gt 0) { 'El programa sigue abierto.'; exit 1 }
      'El programa está cerrado. Ya puedes abrirlo de nuevo.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
