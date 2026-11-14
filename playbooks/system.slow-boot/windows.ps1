# Ver por qué el equipo arranca o se apaga lento: Windows mide cada arranque y apagado en el registro
# Diagnostics-Performance (evento 100 arranque, 101-110 lo que lo retrasó; 200 apagado, 201-203 lo que lo retrasó).
# Se leen los datos del XML de cada evento, no el mensaje, que cambia con el idioma. Solo lectura: termina con 10.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$LOG = 'Microsoft-Windows-Diagnostics-Performance/Operational'
$es = [Globalization.CultureInfo]::InvariantCulture

function Eventos($id, $max, $desde, $hasta) {
  $f = @{ LogName = $LOG; Id = $id }
  if ($desde) { $f.StartTime = $desde; $f.EndTime = $hasta }
  @(try { Get-WinEvent -FilterHashtable $f -MaxEvents $max -ErrorAction Stop } catch { })  # sin eventos, Get-WinEvent da error
}
function Datos($ev) { $h = @{}; foreach ($d in ([xml]$ev.ToXml()).Event.EventData.Data) { if ($d.Name) { $h[$d.Name] = $d.'#text' } }; $h }
function Seg($ms) { [int]([double]$ms / 1000) }
function Tiempo($s) { if ($s -ge 60) { '{0} min {1} s' -f [math]::Floor($s / 60), ($s % 60) } else { "$s s" } }
# lo que más retrasó un arranque o apagado: eventos $ids cerca del momento $t, sumados por nombre, los $n peores
function Culpables($ids, $t, $n = 3) {
  $suma = @{}
  foreach ($ev in (Eventos $ids 50 $t.AddMinutes(-10) $t.AddMinutes(10))) {
    $d = Datos $ev
    $k = "$($d['FriendlyName'])".Trim(); if (-not $k) { $k = "$($d['Name'])".Trim() }
    if ($k) { $suma[$k] = [double]$suma[$k] + [double]$d['DegradationTime'] }
  }
  $suma.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First $n | Where-Object { $_.Value -ge 1000 } |
    ForEach-Object { "- $($_.Key): $(Tiempo (Seg $_.Value)) de más" }
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $yo = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
      if (-not $yo.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'Helpert necesita privilegios de administrador para leer las mediciones del arranque.'; exit 3 }
      $dias = [int]((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalDays
      $a = Eventos 100 1
      if ($a.Count -eq 0) {
        "Windows no guardó mediciones del arranque en este equipo. Está encendido sin reiniciar desde hace $dias día(s)."
        exit 10
      }
      $d = Datos $a[0]
      $escritorio = Seg $d['MainPathBootTime']; $total = Seg $d['BootTime']
      $cuando = $a[0].TimeCreated.ToString('dd/MM/yyyy', $es)
      if ($escritorio -ge 60) { "El arranque del $cuando tardó $(Tiempo $escritorio) hasta mostrar el escritorio: es más lento de lo normal." }
      else { "El arranque del $cuando tardó $(Tiempo $escritorio) hasta mostrar el escritorio, que es normal." }
      if ($total -gt $escritorio + 30) { "Después tardó $(Tiempo ($total - $escritorio)) más en quedar listo para usar." }
      $c = @(Culpables (101..110) $a[0].TimeCreated)
      if ($c.Count) { 'Lo que más lo retrasó:'; $c }
      $p = Eventos 200 1
      if ($p.Count) {
        $dp = Datos $p[0]; $s = Seg $dp['ShutdownTime']
        if ($s -ge 60) {
          $c = @(Culpables (201..203) $p[0].TimeCreated 2)
          if ($c.Count) { "El último apagado tardó $(Tiempo $s); lo que más lo retrasó:"; $c } else { "El último apagado tardó $(Tiempo $s)." }
        }
      }
      if ($escritorio -ge 60) { 'Desactivar los programas que arrancan solos suele ayudar: pídemelo. Si quieres que lo vea un técnico, pásale este resumen.' }
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
