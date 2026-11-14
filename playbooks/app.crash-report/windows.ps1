# Ver por qué un programa se cierra solo: busca en el registro de Aplicación de Windows sus cierres inesperados
# (evento 1000, «Application Error») y cuelgues (1002, «Application Hang») de los últimos 14 días. Solo lectura:
# termina con 10. HP_PROGRAMA ya viene validado; se compara como texto literal.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$prog = "$env:HP_PROGRAMA".ToLower() -replace '\.exe$', ''
# nombres que la gente dice -> nombre del proceso
switch -Regex ($prog) {
  '^(libreoffice|writer|calc|impress)$' { $prog = 'soffice' }
  '^(word|winword)$' { $prog = 'winword' }
  '^(powerpoint|powerpnt)$' { $prog = 'powerpnt' }
  '^(chrome|google-chrome)$' { $prog = 'chrome' }
  '^(edge|msedge|microsoft-edge)$' { $prog = 'msedge' }
  '^(teams|ms-teams)$' { $prog = 'teams' }
}
function Veces($n) { if ($n -eq 1) { '1 vez' } else { "$n veces" } }

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      if ($prog.Length -lt 3) { 'Necesito el nombre del programa (al menos 3 letras).'; exit 1 }
      $patron = '*' + [Management.Automation.WildcardPattern]::Escape($prog) + '*'
      # sin eventos que coincidan, Get-WinEvent da error en vez de una lista vacía
      $todos = @(try { Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000, 1002; StartTime = (Get-Date).AddDays(-14) } -MaxEvents 3000 -ErrorAction Stop } catch { })
      $ev = @($todos | Where-Object { $_.Properties.Count -gt 0 -and "$($_.Properties[0].Value)" -like $patron })
      if ($ev.Count -eq 0) {
        "No encontré cierres inesperados de «$env:HP_PROGRAMA» en el registro de Windows de los últimos 14 días."
        'Si se cierra sin dejar rastro, puede ser un problema de su configuración: restablecerlo o repararlo suele ayudar. Si sigue, avisa a soporte.'
        exit 10
      }
      $fallos = @($ev | Where-Object { $_.Id -eq 1000 }); $cuelgues = @($ev | Where-Object { $_.Id -eq 1002 })
      $u = ($ev | Sort-Object TimeCreated | Select-Object -Last 1).TimeCreated
      $partes = @()
      if ($fallos.Count) { $partes += "se cerró de golpe $(Veces $fallos.Count)" }
      if ($cuelgues.Count) { $partes += "se colgó $(Veces $cuelgues.Count)" }
      "En los últimos 14 días, «$env:HP_PROGRAMA» $($partes -join ' y '); la última, el $($u.ToString('dd/MM')) a las $($u.ToString('HH:mm'))."
      if ($fallos.Count) {
        # el módulo donde falló más veces (dato útil para soporte)
        $mod = @($fallos | Where-Object { $_.Properties.Count -gt 3 } | ForEach-Object { "$($_.Properties[3].Value)" } | Group-Object | Sort-Object Count -Descending)
        if ($mod.Count -and $mod[0].Name) { "Para soporte: casi siempre falló en «$($mod[0].Name)»." }
        'Actualizarlo o repararlo suele ayudar. Si sigue, avisa a soporte con este resumen.'
      } else {
        'Cuando se cuelga, suele ser por falta de memoria o por un archivo muy grande: cierra otros programas mientras lo usas. Si sigue, avisa a soporte.'
      }
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
