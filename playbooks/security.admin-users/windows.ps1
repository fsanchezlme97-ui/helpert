# Ver qué cuentas y grupos son miembros del grupo local Administradores (se busca por su SID, S-1-5-32-544, porque
# el nombre cambia con el idioma). Se lee con ADSI: Get-LocalGroupMember falla con miembros de Entra ID o de un
# dominio que no responde. Solo lectura: termina con 10. Dar o quitar permisos lo hace soporte.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'

function Prop($o, $n) { $o.GetType().InvokeMember($n, 'GetProperty', $null, $o, $null) }
function Miembros {
  $grupo = (New-Object Security.Principal.SecurityIdentifier 'S-1-5-32-544').Translate([Security.Principal.NTAccount]).Value.Split('\')[-1]
  $apagadas = @(Get-CimInstance Win32_UserAccount -Filter 'LocalAccount=True' | Where-Object { $_.Disabled } | ForEach-Object { $_.Name })
  foreach ($m in @(([ADSI]"WinNT://./$grupo,group").psbase.Invoke('Members'))) {
    # WinNT://GRUPODETRABAJO/EQUIPO/cuenta (local), WinNT://DOMINIO/cuenta (dominio), WinNT://S-1-12-1-... (Entra ID)
    $p = "$(Prop $m 'ADsPath')".Substring(8).Split('/')
    $esGrupo = (Prop $m 'Class') -eq 'Group'
    if ($p.Count -ge 3) {
      $x = "- $($p[-1]) (cuenta local$(if ($apagadas -contains $p[-1]) { ', desactivada' }))"
    } elseif ($p.Count -eq 2) {
      $x = "- $($p[0])\$($p[1]) ($(if ($esGrupo) { 'grupo' } else { 'cuenta' }) del dominio)"
    } elseif ($p[0] -like 'S-1-12-1-*') {
      $x = '- Un grupo o rol de Microsoft Entra ID (la empresa lo administra desde la nube)'
    } else {
      $x = "- Una cuenta que ya no existe o no se puede resolver ($($p[0]))"
    }
    $x
  }
}

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $l = @(Miembros | Sort-Object -Unique)
      if ($l.Count -eq 0) { 'El grupo de administradores de este equipo está vacío.'; exit 10 }
      "Estas $($l.Count) cuenta(s) o grupo(s) tienen permisos de administrador en este equipo:"
      $l | Select-Object -First 8
      if ($l.Count -gt 8) { "… y $($l.Count - 8) más." }
      'Dar o quitar permisos lo hace soporte.'
      exit 10
    }
    default { 'Este procedimiento solo revisa; no cambia nada.'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
