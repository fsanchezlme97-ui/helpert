# Recuperar el micrófono: quita el silencio del micrófono predeterminado, sube su volumen al 60 % si estaba por
# debajo del 20 % y arranca el servicio de sonido de Windows (Audiosrv y AudioEndpointBuilder) si estaba detenido.
# El volumen se lee y se cambia con la API de audio de Windows (IAudioEndpointVolume), que es del dispositivo, no de
# una sesión: funciona desde el servicio. El otro playbook de audio es el mismo script con FLUJO y QUE distintos.
$ErrorActionPreference = 'Stop'; $ProgressPreference = 'SilentlyContinue'
$FLUJO = 1; $QUE = 'El micrófono'; $FALTA = 'No encontré ningún micrófono activo: revisa que esté conectado (o que lo estén los audífonos que lo traen).'

function Audio {
  if ('HpAudio' -as [type]) { return }
  # cada método de las interfaces COM ocupa su lugar en orden, aunque no se use; los que se llaman devuelven su HRESULT
  Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices;
[ComImport, Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IAudioEndpointVolume {
  int RegisterControlChangeNotify(IntPtr n); int UnregisterControlChangeNotify(IntPtr n); int GetChannelCount(out uint n);
  int SetMasterVolumeLevel(float db, IntPtr ctx); [PreserveSig] int SetMasterVolumeLevelScalar(float v, IntPtr ctx);
  int GetMasterVolumeLevel(out float db); [PreserveSig] int GetMasterVolumeLevelScalar(out float v);
  int SetChannelVolumeLevel(uint c, float db, IntPtr ctx); int SetChannelVolumeLevelScalar(uint c, float v, IntPtr ctx);
  int GetChannelVolumeLevel(uint c, out float db); int GetChannelVolumeLevelScalar(uint c, out float v);
  [PreserveSig] int SetMute([MarshalAs(UnmanagedType.Bool)] bool m, IntPtr ctx); [PreserveSig] int GetMute([MarshalAs(UnmanagedType.Bool)] out bool m);
}
[ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDevice { [PreserveSig] int Activate(ref Guid id, int ctx, IntPtr p, out IAudioEndpointVolume v); }
[ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IMMDeviceEnumerator { int EnumAudioEndpoints(int f, int s, out IntPtr d); [PreserveSig] int GetDefaultAudioEndpoint(int f, int r, out IMMDevice d); }
[ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumerator { }
public static class HpAudio {
  // flujo 0 = salida, 1 = micrófono; rol 0 = el predeterminado. null si no hay dispositivo activo
  static IAudioEndpointVolume Vol(int flujo) {
    try {
      var e = (IMMDeviceEnumerator)new MMDeviceEnumerator(); IMMDevice d; IAudioEndpointVolume v;
      if (e.GetDefaultAudioEndpoint(flujo, 0, out d) < 0 || d == null) return null;
      Guid g = typeof(IAudioEndpointVolume).GUID;
      if (d.Activate(ref g, 23, IntPtr.Zero, out v) < 0) return null;
      return v;
    } catch (Exception) { return null; }  // el servicio de sonido no responde
  }
  // volumen en % (0-100) y silencio; -1 si no hay dispositivo
  public static int Leer(int flujo, out bool mudo) {
    mudo = false; var v = Vol(flujo); float n;
    if (v == null || v.GetMasterVolumeLevelScalar(out n) < 0 || v.GetMute(out mudo) < 0) return -1;
    return (int)Math.Round(n * 100);
  }
  public static bool Arreglar(int flujo) {
    var v = Vol(flujo); float n; if (v == null) return false;
    // S_FALSE (1) = ya estaba así: solo un HRESULT negativo es error
    if (v.SetMute(false, IntPtr.Zero) < 0 || v.GetMasterVolumeLevelScalar(out n) < 0) return false;
    return n >= 0.2f || v.SetMasterVolumeLevelScalar(0.6f, IntPtr.Zero) >= 0;
  }
}
'@
}
function Servicio($n) { Get-Service -Name $n -ErrorAction SilentlyContinue }
function Detenido { @('AudioEndpointBuilder', 'Audiosrv' | Where-Object { "$((Servicio $_).Status)" -ne 'Running' }).Count -gt 0 }
# por qué no se puede arrancar el servicio de sonido; nada si se puede
function Bloqueado {
  foreach ($n in 'AudioEndpointBuilder', 'Audiosrv') {
    $s = Servicio $n
    if (-not $s) { return 'Este equipo no tiene el servicio de sonido de Windows.' }
    if ("$($s.StartType)" -eq 'Disabled') { return 'El servicio de sonido de Windows está desactivado en este equipo (puede ser una política de la empresa): avisa a soporte.' }
  }
}
$mudo = $false
function Volumen { Audio; [HpAudio]::Leer($FLUJO, [ref]$script:mudo) }

try {
  switch ($env:HP_PASO) {
    'diagnosticar' {
      $m = Bloqueado; if ($m) { $m; exit 3 }
      if (Detenido) { 'El servicio de sonido de Windows está detenido.'; exit 0 }
      $v = Volumen
      if ($v -lt 0) { $FALTA; exit 1 }
      if (-not $mudo -and $v -ge 20) { "$QUE no está silenciado y su volumen es $v %."; exit 10 }
      if ($mudo) { "$QUE está silenciado." }
      if ($v -lt 20) { "$QUE está al $v %." }
      exit 0
    }
    'comprobar' {
      $yo = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
      if (-not $yo.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { 'Helpert necesita privilegios de administrador para arreglar el micrófono.'; exit 3 }
      $m = Bloqueado; if ($m) { $m; exit 3 }
      exit 0
    }
    'aplicar' {
      if (Detenido) {
        # Audiosrv depende de AudioEndpointBuilder: se arranca primero el de abajo
        try { Start-Service -Name AudioEndpointBuilder; Start-Service -Name Audiosrv } catch { 'No pude arrancar el servicio de sonido de Windows. Reinicia el equipo; si sigue igual, avisa a soporte.'; exit 1 }
        Start-Sleep -Seconds 3
      }
      Audio
      if (-not [HpAudio]::Arreglar($FLUJO)) { $FALTA; exit 1 }
      'Quité el silencio y dejé el volumen en un nivel audible.'
      exit 0
    }
    'verificar' {
      $v = if (Detenido) { -1 } else { Volumen }
      if ($v -lt 0 -or $mudo -or $v -lt 20) { "$QUE sigue silenciado o sin responder."; exit 1 }
      "$QUE funciona: volumen $v %, sin silencio. Si aún no te escuchan, revisa en la llamada que esté elegido este micrófono."
      exit 0
    }
    default { 'Paso no válido'; exit 2 }
  }
} catch {
  $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }
  "Algo salió mal y no pude terminar: $($e.Message)"; exit 1
}
