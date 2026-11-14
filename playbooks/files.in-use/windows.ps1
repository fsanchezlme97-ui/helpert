# Ver qué programa de la persona tiene abierto un archivo y cerrarlo. Los archivos se buscan en su carpeta personal
# con su token (sin carpetas ocultas ni del sistema, como AppData). Quién los tiene abiertos lo dice el Restart
# Manager de Windows (no abre ni lee los archivos). Solo se cierran procesos de la persona (por su SID), nunca del
# sistema, del escritorio ni de Helpert; desde la sesión 0 no se le puede pedir a una ventana que se cierre: es a la fuerza.
# HP_ARCHIVO ya viene validado (letras, números, . _ -); se compara como texto literal.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$archivo = "$env:HP_ARCHIVO"
$PROTEGIDOS = '^(system|idle|registry|smss|csrss|wininit|winlogon|services|lsass|lsaiso|svchost|dwm|explorer|sihost|userinit|logonui|fontdrvhost|ctfmon|conhost|dllhost|taskhostw|runtimebroker|audiodg|spoolsv|wudfhost|searchhost|searchapp|searchui|searchindexer|searchprotocolhost|searchfilterhost|startmenuexperiencehost|shellexperiencehost|textinputhost|applicationframehost|lockapp|securityhealthsystray|securityhealthservice|smartscreen|msmpeng|powershell|pwsh|cmd|windowsterminal|openconsole|helpert.*)$'
$RM = @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class HpRm {
  [StructLayout(LayoutKind.Sequential)] public struct UP { public int Pid; public uint T1, T2; }
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] public struct PI {
    public UP P; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string App;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string Svc; public int Tipo, Estado, Sesion, Reiniciable; }
  [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern int RmStartSession(out uint h, int f, StringBuilder k);
  [DllImport("rstrtmgr.dll")] static extern int RmEndSession(uint h);
  [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern int RmRegisterResources(uint h, uint nf, string[] f, uint na, UP[] a, uint ns, string[] s);
  [DllImport("rstrtmgr.dll")] static extern int RmGetList(uint h, out uint need, ref uint n, [In, Out] PI[] l, ref uint r);
  public static int[] Pids(string[] f) {
    var res = new List<int>(); uint h;
    if (RmStartSession(out h, 0, new StringBuilder(64)) != 0) return res.ToArray();
    try {
      if (RmRegisterResources(h, (uint)f.Length, f, 0, null, 0, null) != 0) return res.ToArray();
      uint need = 0, n = 0, r = 0;
      if (RmGetList(h, out need, ref n, null, ref r) == 234 && need > 0) {
        var l = new PI[need]; n = need;
        if (RmGetList(h, out need, ref n, l, ref r) == 0) for (int i = 0; i < n; i++) res.Add(l[i].P.Pid);
      }
    } finally { RmEndSession(h); }
    return res.ToArray();
  }
}
'@

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
  if (-not ('HpRm' -as [type])) { Add-Type -TypeDefinition $RM }
  $script:sid = SidDe $env:HP_USUARIO
  if (-not $sid) { return 'No sé qué persona lo pide.' }
  if ($archivo.Length -lt 3) { return 'Necesito al menos 3 letras del nombre del archivo.' }
  $script:perfil = (Get-CimInstance Win32_UserProfile -Filter "SID='$sid'").LocalPath
  if (-not $perfil) { return 'No encontré tu carpeta personal en este equipo.' }
  $script:tok = Token $sid
  if (-not $tok) { return 'Necesito que tengas la sesión abierta en este equipo para revisar tus archivos.' }
}
# hasta 50 archivos con la palabra en el nombre; con el token de la persona y tope de tiempo
function Buscar {
  $fin = [DateTime]::Now.AddSeconds(20)
  $patron = '*' + [WildcardPattern]::Escape($archivo) + '*'
  $saltar = [IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System -bor [IO.FileAttributes]::ReparsePoint
  $pila = New-Object Collections.Stack; $pila.Push($perfil)
  while ($pila.Count -and $rutas.Count -lt 50 -and [DateTime]::Now -lt $fin) {
    $di = New-Object IO.DirectoryInfo $pila.Pop()
    try {
      foreach ($f in $di.EnumerateFiles()) { if ($f.Name -like $patron) { $rutas.Add($f.FullName) } }
      foreach ($s in $di.EnumerateDirectories()) { if (-not ($s.Attributes -band $saltar)) { $pila.Push($s.FullName) } }
    } catch {}
  }
}
# procesos de la persona (por SID) que tienen abierto alguno de esos archivos; el Explorador aparte (no se cierra)
function Abiertos {
  $script:explorador = $false
  if ($rutas.Count -eq 0) { return @() }
  @(foreach ($id in @([HpRm]::Pids($rutas.ToArray()) | Sort-Object -Unique)) {
      $p = Get-CimInstance Win32_Process -Filter "ProcessId=$id"
      if (-not $p) { continue }
      $o = (Invoke-CimMethod -InputObject $p -MethodName GetOwnerSid -ErrorAction SilentlyContinue).Sid
      if ($o -ne $sid) { continue }
      $n = "$($p.Name)".ToLower() -replace '\.exe$', ''
      if ($n -eq 'explorer') { $script:explorador = $true } elseif ($n -notmatch $PROTEGIDOS) { $p }
    })
}
function Todo { $null = ComoPersona $tok { Buscar }; @(Abiertos) }
$rutas = New-Object Collections.Generic.List[string]
$explorador = $false
$NADA = 'Ningún programa tuyo tiene abierto un archivo con «{0}» en el nombre.'
$EXPLORADOR = 'El Explorador de archivos lo tiene abierto (por ejemplo, en la vista previa): cierra esa ventana o el panel de vista previa y prueba de nuevo.'

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      $p = Todo
      if ($rutas.Count -eq 0) { "No encontré archivos con «$archivo» en el nombre en tu carpeta personal."; exit 10 }
      if ($p.Count -eq 0) {
        if ($explorador) { $EXPLORADOR } else { $NADA -f $archivo; 'Si el aviso sigue, cierra sesión y vuelve a entrar. Si el archivo está en una carpeta de red, puede tenerlo abierto otro equipo.' }
        exit 10
      }
      "Estos programas tienen abierto el archivo: $(@($p | ForEach-Object { $_.Name -replace '\.exe$', '' } | Sort-Object -Unique) -join ', ')."
      if ($explorador) { $EXPLORADOR }
      'Si sigo, los cierro; lo que no hayas guardado en ellos se pierde.'
      exit 0
    }
    'comprobar' {
      $m = Preparar; if ($m) { $m; exit 3 }
      if ((Todo).Count -eq 0) { 'Ya ningún programa tiene abierto el archivo.'; exit 3 }
      exit 0
    }
    'aplicar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      $p = Todo
      if ($p.Count -eq 0) { 'Ya ningún programa tenía abierto el archivo.'; exit 0 }
      foreach ($x in $p) { Stop-Process -Id $x.ProcessId -Force -ErrorAction SilentlyContinue }
      "Cerré a la fuerza $($p.Count) programa(s) que tenían abierto el archivo; lo que no estaba guardado en ellos se perdió."
      exit 0
    }
    'verificar' {
      $m = Preparar; if ($m) { $m; exit 1 }
      Start-Sleep -Seconds 1
      if ((Todo).Count -gt 0) { 'Algún programa sigue con el archivo abierto.'; exit 1 }
      'Ningún programa tiene abierto el archivo. Ya puedes moverlo, borrarlo o abrirlo.'
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
