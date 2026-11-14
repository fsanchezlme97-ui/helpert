# Activar el cortafuegos de Windows en las redes (perfiles) donde está apagado, con su configuración por defecto:
# no borra reglas ni abre puertos. Si lo apaga una directiva de la empresa (GPO) o si otro programa hace de
# cortafuegos, no lo toca: lo decide soporte.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$POL = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall'
$CLAVE = @{ Domain = 'DomainProfile'; Private = 'StandardProfile'; Public = 'PublicProfile' }
$NOMBRE = @{ Domain = 'de dominio'; Private = 'privada'; Public = 'pública' }

function Valor($ruta, $nombre) { try { (Get-ItemProperty -LiteralPath $ruta -Name $nombre -ErrorAction Stop).$nombre } catch { $null } }
# perfiles apagados según la configuración que rige ahora (local + directivas)
function Apagados { @(Get-NetFirewallProfile -PolicyStore ActiveStore | Where-Object { "$($_.Enabled)" -ne 'True' } | ForEach-Object { "$($_.Name)" }) }
function PorDirectiva($perfiles) { @($perfiles | Where-Object { $_ -and (Valor "$POL\$($CLAVE[$_])" 'EnableFirewall') -eq 0 }) }
function Nombres($perfiles) { ($perfiles | ForEach-Object { $NOMBRE[$_] }) -join ', ' }
# otro cortafuegos registrado y activo en el Centro de seguridad (solo existe en Windows de escritorio)
function Otro {
  try { $p = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName FirewallProduct -ErrorAction Stop) } catch { return $null }
  ($p | Where-Object { $_.productState -band 0x1000 } | Select-Object -First 1).displayName
}
function Admin { (New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $a = Apagados
      if ($a.Count -eq 0) { 'El cortafuegos de Windows está activo en todas las redes. No hay nada que hacer.'; exit 10 }
      $o = Otro
      if ($o) { "El cortafuegos de Windows está apagado porque lo reemplaza «$o», que está activo. Si dudas, pregunta a soporte."; exit 10 }
      if ((PorDirectiva $a).Count) { "El cortafuegos está apagado por una directiva de la empresa (redes: $(Nombres $a)). Lo decide soporte."; exit 3 }
      "El cortafuegos de Windows está apagado en las redes: $(Nombres $a)."
      'Lo puedo activar con su configuración por defecto, sin borrar reglas ni abrir puertos.'
      exit 0
    }
    'comprobar' {
      if (-not (Admin)) { 'Helpert necesita privilegios de administrador para activar el cortafuegos.'; exit 3 }
      $a = @(Apagados)
      if ((PorDirectiva $a).Count) { 'El cortafuegos está apagado por una directiva de la empresa: lo decide soporte.'; exit 3 }
      exit 0
    }
    'aplicar' {
      $a = Apagados
      if ($a.Count -eq 0) { 'El cortafuegos ya estaba activo.'; exit 0 }
      Set-NetFirewallProfile -Profile $a -Enabled True
      "Activé el cortafuegos de Windows en las redes: $(Nombres $a)."
      exit 0
    }
    'verificar' {
      $a = Apagados
      if ($a.Count) { "El cortafuegos sigue apagado en las redes: $(Nombres $a). Puede que una configuración de la empresa lo impida: avisa a soporte."; exit 1 }
      'El cortafuegos de Windows está activo en todas las redes.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
