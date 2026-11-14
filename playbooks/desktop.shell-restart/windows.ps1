# Reiniciar la barra de tareas, el menú Inicio y el escritorio de la persona: cierra su explorer.exe y los procesos del
# menú Inicio (solo los suyos, por su SID); Windows los vuelve a abrir solo. Si explorer no vuelve, se abre en su sesión
# con una tarea programada como ella (y se borra). Nunca se abre otro si ya hay uno: abriría una ventana de carpetas.
# Sus programas no se cierran; las ventanas del Explorador de archivos sí.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$PARTES = @('explorer.exe', 'StartMenuExperienceHost.exe', 'ShellExperienceHost.exe')

function SidDe($cuenta) {  # solo cuentas de personas (locales, de dominio o de Entra ID), nunca SYSTEM ni de servicio
  if (-not $cuenta) { return $null }
  try { $s = (New-Object Security.Principal.NTAccount($cuenta)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { return $null }
  if ($s -match '^S-1-(5-21|12-1)-') { $s }
}
$sid = SidDe $env:HP_USUARIO
function Suyos($nombres) {  # procesos con esos nombres que son de la persona
  $f = ($nombres | ForEach-Object { "Name='$_'" }) -join ' OR '
  @(Get-CimInstance Win32_Process -Filter $f | Where-Object { $o = (Invoke-CimMethod -InputObject $_ -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid; $o -and $o -eq $sid })
}
function Escritorio { (Suyos @('explorer.exe')).Count -gt 0 }
function NoPuedo {
  if (-not $sid) { return 'No sé qué persona lo pide.' }
  $yo = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
  if (-not $yo.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { return 'Helpert necesita privilegios de administrador para reiniciar tu escritorio.' }
  if (-not (Escritorio)) { return 'No encontré tu escritorio abierto en este equipo. Si la pantalla está en negro, cierra sesión y vuelve a entrar.' }
}
function Esperar($seg) { for ($i = 0; $i -lt $seg; $i++) { if (Escritorio) { return $true }; Start-Sleep -Seconds 1 }; Escritorio }
function AbrirComoPersona {  # explorer.exe en la sesión de la persona, con su cuenta
  $n = 'Helpert-escritorio-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
  $a = New-ScheduledTaskAction -Execute "$env:SystemRoot\explorer.exe"
  $p = New-ScheduledTaskPrincipal -UserId $env:HP_USUARIO -LogonType Interactive
  try {
    $c = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries  # si no, con batería no arranca
    $null = Register-ScheduledTask -TaskName $n -Action $a -Principal $p -Settings $c -Force
    Start-ScheduledTask -TaskName $n
    $null = Esperar 10
  } finally { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue }
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = NoPuedo; if ($m) { $m; exit 3 }
      'Puedo reiniciar la barra de tareas, el menú Inicio y el escritorio; tus programas abiertos no se cierran.'
      'Las ventanas del Explorador de archivos que tengas abiertas sí se cerrarán.'
      exit 0
    }
    'comprobar' {
      $m = NoPuedo; if ($m) { $m; exit 3 }
      exit 0
    }
    'aplicar' {
      $m = NoPuedo; if ($m) { $m; exit 3 }
      foreach ($x in (Suyos $PARTES)) { Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue }
      Start-Sleep -Seconds 2
      if (-not (Esperar 10)) { try { AbrirComoPersona } catch { } }
      if (-not (Escritorio)) { 'Cerré el escritorio, pero no volvió a abrirse. Cierra sesión y vuelve a entrar.'; exit 1 }
      'Reinicié la barra de tareas, el menú Inicio y el escritorio. Tus programas siguen abiertos.'
      exit 0
    }
    'verificar' {
      if (-not (Esperar 5)) { 'El escritorio no volvió a abrirse. Cierra sesión y vuelve a entrar; si sigue igual, avisa a soporte.'; exit 1 }
      'La barra de tareas y el escritorio volvieron a funcionar.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
