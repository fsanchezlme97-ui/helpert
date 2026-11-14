# Ver lo que arranca al inicio: programas de inicio (claves Run y carpetas de Inicio, los de la persona y los de todos),
# tareas programadas al iniciar y servicios automáticos de otros fabricantes. Solo lectura: termina con 10.
# Los que la persona o soporte apagaron en el Administrador de tareas (StartupApproved) no se cuentan.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$APROBADOS = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'

function SidDe($cuenta) {  # solo cuentas de personas (locales, de dominio o de Entra ID), nunca SYSTEM ni de servicio
  if (-not $cuenta) { return $null }
  try { $s = (New-Object Security.Principal.NTAccount($cuenta)).Translate([Security.Principal.SecurityIdentifier]).Value } catch { return $null }
  if ($s -match '^S-1-(5-21|12-1)-') { $s }
}
# nombres apagados: el primer byte impar quiere decir desactivado
function Apagados($raices) {
  $n = @{}
  foreach ($r in $raices) {
    foreach ($sub in 'Run', 'Run32', 'StartupFolder') {
      try { $k = Get-Item -LiteralPath "$r\$APROBADOS\$sub" -ErrorAction Stop } catch { continue }
      foreach ($v in $k.GetValueNames()) { $b = $k.GetValue($v); if ($b -is [byte[]] -and $b.Count -and ($b[0] -band 1)) { $n[$v.ToLower()] = 1 } }
    }
  }
  $n
}
function Nombres($lista, $max) {
  $l = @($lista | Sort-Object -Unique)
  $t = ($l | Select-Object -First $max) -join ', '
  if ($l.Count -gt $max) { $t += " y $($l.Count - $max) más" }
  $t
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $sid = SidDe $env:HP_USUARIO
      $raices = @('HKLM:'); if ($sid) { $raices += "Registry::HKEY_USERS\$sid" }
      $off = Apagados $raices
      $mios = @(); $todos = @()
      foreach ($c in @(Get-CimInstance Win32_StartupCommand)) {
        $hoja = ("$($c.Command)".Trim('"') -split '\\')[-1]
        if ($off.ContainsKey("$($c.Name)".ToLower()) -or $off.ContainsKey("$($c.Name).lnk".ToLower()) -or $off.ContainsKey($hoja.ToLower())) { continue }
        if ($c.Location -like 'HKLM*' -or $c.Location -eq 'Common Startup') { $todos += $c.Name }
        elseif ($sid -and ($c.Location -like "*$sid*" -or $c.User -eq $env:HP_USUARIO)) { $mios += $c.Name }
      }
      if (-not $sid) { 'No pude revisar tus programas de inicio: no sé qué persona lo pide.' }
      elseif ($mios.Count) { "Al iniciar tu sesión se abren estos programas tuyos: $(Nombres $mios 8)." }
      else { 'No tienes programas propios que se abran al iniciar tu sesión.' }
      if ($todos.Count) { "Para todas las personas del equipo se abren: $(Nombres $todos 8)." }

      $tareas = @()
      try {
        $tareas = @(Get-ScheduledTask -ErrorAction Stop | Where-Object {
            $_.State -ne 'Disabled' -and $_.TaskPath -notlike '\Microsoft\*' -and
            @($_.Triggers | Where-Object { $_.CimClass.CimClassName -match 'MSFT_Task(Logon|Boot)Trigger' }).Count
          } | ForEach-Object { $_.TaskName })
      } catch {}
      if ($tareas.Count) { "Tareas programadas que arrancan al iniciar: $(Nombres $tareas 5)." }

      # shortcut: «de otros fabricantes» = su programa no está en Windows ni en carpetas de Microsoft; firmar por editor sería más exacto
      $serv = @(Get-CimInstance Win32_Service -Filter "StartMode='Auto'" | Where-Object { $_.PathName -and $_.PathName -notmatch '\\Windows\\|\\Microsoft\\|Windows Defender' } | ForEach-Object { $_.DisplayName })
      if ($serv.Count) { "Servicios de otros fabricantes que arrancan con el equipo ($($serv.Count)): $(Nombres $serv 6)." }
      'Para quitar un programa de tu inicio: Configuración > Aplicaciones > Inicio. Las tareas y los servicios los cambia soporte.'
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
