# Revisar las actualizaciones pendientes de Windows Update (o del servidor de la empresa, si lo hay) y si falta
# reiniciar. Solo lectura: busca, pero no descarga ni instala nada. Termina con 10.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

function Reinicio {
  try { if ((New-Object -ComObject Microsoft.Update.SystemInfo).RebootRequired) { return $true } } catch {}
  (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
  (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $falta = Reinicio
      try {
        $buscador = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
        $r = $buscador.Search('IsInstalled=0 and IsHidden=0')
      } catch {
        $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
        $c = '0x{0:X8}' -f $e.HResult
        if ($c -eq '0x80070422') { 'El servicio Windows Update está desactivado en este equipo: lo tiene que revisar soporte.' }
        else { "No pude consultar Windows Update (código $c). Revisa que tengas Internet; si sigue igual, avisa a soporte." }
        if ($falta) { 'Además, hay un reinicio pendiente para terminar de aplicar actualizaciones ya instaladas.' }
        exit 1
      }
      $lista = @(); foreach ($u in $r.Updates) { $lista += $u }
      if ($lista.Count -eq 0) { 'Windows está al día: no hay actualizaciones pendientes.' }
      else {
        $seg = @($lista | Where-Object { $_.MsrcSeverity }).Count
        $t = "Hay $($lista.Count) actualización(es) pendiente(s)"; if ($seg) { $t += ", $seg de seguridad" }; "${t}:"
        foreach ($u in ($lista | Select-Object -First 6)) {
          $n = "$($u.Title)"; if ($n.Length -gt 90) { $n = $n.Substring(0, 87) + '...' }
          "- $n"
        }
        if ($lista.Count -gt 6) { "- y $($lista.Count - 6) más." }
        'Instalarlas lo programa soporte.'
      }
      if ($falta) { 'Además, hay un reinicio pendiente para terminar de aplicar actualizaciones ya instaladas.' }
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
