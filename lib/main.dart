import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ======================== CONFIGURACIÓN DE FIREBASE ========================
// Clave web de tu proyecto "basesita-bonita" (Firebase Authentication).
const String firebaseApiKey = 'AIzaSyC_dsW7kglbQRF4Ar1MkFtvah7Rn6_EDJ4';

// ID de cliente WEB de Google (Firebase -> Authentication -> Método de acceso
// -> Google -> "Configuración del SDK web" -> ID de cliente web).
// Termina en ".apps.googleusercontent.com".
const String googleWebClientId =
    '90586077269-hto53s4mco6qaijbfqen317h30mpdojd.apps.googleusercontent.com';
// ===========================================================================

// Duración del movimiento. DEBEN coincidir con DURACION_SALIR_MS y
// DURACION_ENTRAR_MS del sketch del ESP32 (solo se usan para la barra animada).
const double segundosSalir = 0.8;
const double segundosEntrar = 0.8;

// Mismos UUID que el sketch del ESP32-C3
const String serviceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
const String charUuid = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';

// Colores tomados del logo de Novanyok
const Color amarillo = Color(0xFFFFBB1B);
const Color naranja = Color(0xFFEE8029);
const Color crema = Color(0xFFFCEFAB);
const Color azul = Color(0xFF2E6EB8);
const Color rojo = Color(0xFFD62F2F);
const Color verdeClaro = Color(0xFFCFF2D2);
const Color verdeOscuro = Color(0xFF1E7A34);

// ================================ SONIDOS ================================
// Sonidos suaves y cortos (assets/sonidos/*.wav). Se pueden silenciar con el
// botón del altavoz de la pantalla de control; la elección se recuerda.
class Sonidos {
  static bool activo = true;
  static final Map<String, ap.AudioPlayer> _jugadores = {};

  static Future<void> iniciar() async {
    try {
      final p = await SharedPreferences.getInstance();
      activo = p.getBool('sonido') ?? true;
    } catch (_) {}
    try {
      // "mixWithOthers": no corta la música ni los audios de otras apps
      await ap.AudioPlayer.global.setAudioContext(
        ap.AudioContextConfig(
          focus: ap.AudioContextConfigFocus.mixWithOthers,
          stayAwake: false,
        ).build(),
      );
    } catch (_) {}
  }

  static Future<void> alternar() async {
    activo = !activo;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool('sonido', activo);
    } catch (_) {}
  }

  static Future<void> tocar(String nombre, {double volumen = 0.85}) async {
    if (!activo) return;
    try {
      final j = _jugadores.putIfAbsent(
        nombre,
        () => ap.AudioPlayer()..setReleaseMode(ap.ReleaseMode.stop),
      );
      await j.stop();
      await j.play(ap.AssetSource('sonidos/$nombre.wav'), volume: volumen);
    } catch (_) {}
  }
}

// ============================ SESIÓN / CUENTAS ============================
class ErrorAuth implements Exception {
  final String codigo;
  ErrorAuth(this.codigo);
}

class SesionUsuario {
  final String uid;
  final String email;
  final String nombre;
  final String refreshToken;
  final bool invitado; // invitado = sin cuenta, funciona sin internet
  const SesionUsuario({
    required this.uid,
    required this.email,
    required this.nombre,
    required this.refreshToken,
    this.invitado = false,
  });
}

// Registro e inicio de sesión con Firebase Authentication (API REST)
class AuthServicio {
  static final ValueNotifier<SesionUsuario?> sesion =
      ValueNotifier<SesionUsuario?>(null);
  static const String _cuentas = 'https://identitytoolkit.googleapis.com/v1/accounts';

  static Future<Map<String, dynamic>> _post(
    String url, {
    Map<String, dynamic>? json,
    Map<String, String>? form,
  }) async {
    final respuesta = await (json != null
            ? http.post(Uri.parse(url),
                headers: {'Content-Type': 'application/json'},
                body: jsonEncode(json))
            : http.post(Uri.parse(url), body: form))
        .timeout(const Duration(seconds: 15));
    final datos = jsonDecode(respuesta.body) as Map<String, dynamic>;
    if (respuesta.statusCode != 200) {
      final error = datos['error'];
      final mensaje = (error is Map ? error['message'] : null) ?? 'ERROR';
      throw ErrorAuth(mensaje.toString());
    }
    return datos;
  }

  static Future<void> _guardar(SesionUsuario s) async {
    sesion.value = s;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString('uid', s.uid);
      await p.setString('email', s.email);
      await p.setString('nombre', s.nombre);
      await p.setString('refreshToken', s.refreshToken);
      await p.setBool('invitado', s.invitado);
    } catch (_) {}
  }

  // Funciona sin internet: solo lee lo guardado en el celular
  static Future<void> cargarGuardada() async {
    try {
      final p = await SharedPreferences.getInstance();
      final uid = p.getString('uid');
      final token = p.getString('refreshToken') ?? '';
      final invitado = p.getBool('invitado') ?? false;
      if (uid == null || (!invitado && token.isEmpty)) return;
      sesion.value = SesionUsuario(
        uid: uid,
        email: p.getString('email') ?? '',
        nombre: p.getString('nombre') ?? '',
        refreshToken: token,
        invitado: invitado,
      );
    } catch (_) {
      return;
    }
    unawaited(_validar());
  }

  // Comprueba en segundo plano que la cuenta siga existiendo (si hay internet)
  static Future<void> _validar() async {
    final s = sesion.value;
    if (s == null || s.invitado) return;
    try {
      await _post(
        'https://securetoken.googleapis.com/v1/token?key=$firebaseApiKey',
        form: {'grant_type': 'refresh_token', 'refresh_token': s.refreshToken},
      );
    } on ErrorAuth catch (e) {
      const invalidos = [
        'USER_DISABLED',
        'USER_NOT_FOUND',
        'TOKEN_EXPIRED',
        'INVALID_REFRESH_TOKEN',
      ];
      if (invalidos.contains(e.codigo)) await cerrar();
    } catch (_) {
      // Sin internet: se mantiene la sesión
    }
  }

  static Future<void> registrar(String nombre, String correo, String clave) async {
    final r = await _post(
      '$_cuentas:signUp?key=$firebaseApiKey',
      json: {'email': correo, 'password': clave, 'returnSecureToken': true},
    );
    try {
      await _post(
        '$_cuentas:update?key=$firebaseApiKey',
        json: {
          'idToken': r['idToken'],
          'displayName': nombre,
          'returnSecureToken': false,
        },
      );
    } catch (_) {}
    await _guardar(SesionUsuario(
      uid: r['localId'] as String,
      email: (r['email'] ?? correo) as String,
      nombre: nombre,
      refreshToken: r['refreshToken'] as String,
    ));
  }

  static Future<void> iniciar(String correo, String clave) async {
    final r = await _post(
      '$_cuentas:signInWithPassword?key=$firebaseApiKey',
      json: {'email': correo, 'password': clave, 'returnSecureToken': true},
    );
    await _guardar(SesionUsuario(
      uid: r['localId'] as String,
      email: (r['email'] ?? correo) as String,
      nombre: (r['displayName'] ?? '') as String,
      refreshToken: r['refreshToken'] as String,
    ));
  }

  // Iniciar sesión o registrarse con Google (es lo mismo: si no existe, se crea)
  static Future<void> google() async {
    final gs = GoogleSignIn(scopes: ['email'], serverClientId: googleWebClientId);
    try {
      await gs.signOut(); // para que siempre muestre la lista de cuentas
    } catch (_) {}
    final cuenta = await gs.signIn();
    if (cuenta == null) throw ErrorAuth('CANCELADO');
    final autenticacion = await cuenta.authentication;
    final idToken = autenticacion.idToken;
    if (idToken == null) throw ErrorAuth('SIN_ID_TOKEN');

    final r = await _post(
      '$_cuentas:signInWithIdp?key=$firebaseApiKey',
      json: {
        'postBody': 'id_token=$idToken&providerId=google.com',
        'requestUri': 'http://localhost',
        'returnIdpCredential': true,
        'returnSecureToken': true,
      },
    );
    await _guardar(SesionUsuario(
      uid: r['localId'] as String,
      email: (r['email'] ?? cuenta.email) as String,
      nombre: (r['displayName'] ?? r['fullName'] ?? cuenta.displayName ?? '')
          as String,
      refreshToken: r['refreshToken'] as String,
    ));
  }

  // Modo invitado: NO usa internet, todo queda en el celular
  static Future<void> invitado() async {
    await _guardar(const SesionUsuario(
      uid: 'invitado-local',
      email: '',
      nombre: 'Invitado',
      refreshToken: '',
      invitado: true,
    ));
  }

  static Future<void> recuperar(String correo) async {
    await _post(
      '$_cuentas:sendOobCode?key=$firebaseApiKey',
      json: {'requestType': 'PASSWORD_RESET', 'email': correo},
    );
  }

  static Future<void> cerrar() async {
    sesion.value = null;
    try {
      await GoogleSignIn().signOut();
    } catch (_) {}
    try {
      final p = await SharedPreferences.getInstance();
      for (final k in ['uid', 'email', 'nombre', 'refreshToken', 'invitado']) {
        await p.remove(k);
      }
    } catch (_) {}
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AuthServicio.cargarGuardada();
  await Sonidos.iniciar();
  runApp(const NovanyokApp());
}

class NovanyokApp extends StatelessWidget {
  const NovanyokApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Novanyok',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: azul, primary: azul),
        scaffoldBackgroundColor: amarillo,
      ),
      home: const PuertaAcceso(),
    );
  }
}

// Muestra el acceso o el control según haya sesión, con una transición suave
class PuertaAcceso extends StatelessWidget {
  const PuertaAcceso({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SesionUsuario?>(
      valueListenable: AuthServicio.sesion,
      builder: (context, sesion, _) => AnimatedSwitcher(
        duration: const Duration(milliseconds: 500),
        switchInCurve: Curves.easeOutCubic,
        transitionBuilder: (hijo, animacion) => FadeTransition(
          opacity: animacion,
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.06),
              end: Offset.zero,
            ).animate(animacion),
            child: hijo,
          ),
        ),
        child: sesion == null
            ? const PantallaAcceso(key: ValueKey('acceso'))
            : PantallaControl(key: ValueKey('control-${sesion.uid}')),
      ),
    );
  }
}

// ============================== ANIMACIONES ==============================

// Fondo con huellitas, corazones y pelotas que flotan suavemente
class FondoPatron extends StatefulWidget {
  const FondoPatron({super.key});

  @override
  State<FondoPatron> createState() => _FondoPatronState();
}

class _FondoPatronState extends State<FondoPatron>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 7))
        ..repeat();

  static const _iconos = [
    Icons.pets,
    Icons.favorite_border,
    Icons.sports_baseball_outlined,
    Icons.pets,
    Icons.favorite_border,
  ];

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: LayoutBuilder(builder: (context, c) {
        const paso = 92.0;
        final cols = (c.maxWidth / paso).ceil() + 1;
        final filas = (c.maxHeight / paso).ceil() + 1;

        return AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final t = _c.value * 2 * math.pi;
            final hijos = <Widget>[];
            for (var f = 0; f < filas; f++) {
              for (var col = 0; col < cols; col++) {
                final i = f * cols + col;
                final fase = i * 0.9;
                hijos.add(Positioned(
                  left: col * paso + (f.isOdd ? paso / 2 : 0) - 20,
                  top: f * paso - 10 + 7 * math.sin(t + fase),
                  child: Transform.rotate(
                    angle: ((i % 5) - 2) * 0.25 + 0.14 * math.sin(t + fase * 1.3),
                    child: Icon(
                      _iconos[i % _iconos.length],
                      size: 34,
                      color: const Color(0x33F28C1A),
                    ),
                  ),
                ));
              }
            }
            return Stack(children: hijos);
          },
        );
      }),
    );
  }
}

// Aparece con desvanecimiento y deslizamiento hacia arriba
class Aparece extends StatefulWidget {
  final Widget child;
  final int retardoMs;
  const Aparece({super.key, required this.child, this.retardoMs = 0});

  @override
  State<Aparece> createState() => _ApareceState();
}

class _ApareceState extends State<Aparece> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 650));
  late final Animation<double> _opacidad =
      CurvedAnimation(parent: _c, curve: Curves.easeOut);
  late final Animation<Offset> _posicion = Tween<Offset>(
    begin: const Offset(0, 0.22),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _c, curve: Curves.easeOutCubic));
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer(Duration(milliseconds: widget.retardoMs), () {
      if (mounted) _c.forward();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacidad,
      child: SlideTransition(position: _posicion, child: widget.child),
    );
  }
}

// Se encoge un poquito al tocarlo
class Pulsable extends StatefulWidget {
  final Widget child;
  final bool activo;
  const Pulsable({super.key, required this.child, this.activo = true});

  @override
  State<Pulsable> createState() => _PulsableState();
}

class _PulsableState extends State<Pulsable> {
  bool _abajo = false;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => setState(() => _abajo = widget.activo),
      onPointerUp: (_) => setState(() => _abajo = false),
      onPointerCancel: (_) => setState(() => _abajo = false),
      child: AnimatedScale(
        scale: _abajo ? 0.95 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

// Late (crece y se encoge) mientras esté activo
class Pulsante extends StatefulWidget {
  final bool activo;
  final Widget child;
  const Pulsante({super.key, required this.activo, required this.child});

  @override
  State<Pulsante> createState() => _PulsanteState();
}

class _PulsanteState extends State<Pulsante> with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 700));
  late final Animation<double> _escala = Tween<double>(begin: 1.0, end: 1.2)
      .animate(CurvedAnimation(parent: _c, curve: Curves.easeInOut));

  @override
  void initState() {
    super.initState();
    if (widget.activo) _c.repeat(reverse: true);
  }

  @override
  void didUpdateWidget(covariant Pulsante anterior) {
    super.didUpdateWidget(anterior);
    if (widget.activo && !_c.isAnimating) {
      _c.repeat(reverse: true);
    } else if (!widget.activo && _c.isAnimating) {
      _c.animateTo(0, duration: const Duration(milliseconds: 200));
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(scale: _escala, child: widget.child);
  }
}

// Logo que entra con rebote y luego flota suavemente
class LogoAnimado extends StatefulWidget {
  final double tamano;
  const LogoAnimado({super.key, required this.tamano});

  @override
  State<LogoAnimado> createState() => _LogoAnimadoState();
}

class _LogoAnimadoState extends State<LogoAnimado> with TickerProviderStateMixin {
  late final AnimationController _entrada =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
        ..forward();
  late final AnimationController _flota =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 2600))
        ..repeat(reverse: true);
  late final Animation<double> _escala =
      CurvedAnimation(parent: _entrada, curve: Curves.elasticOut);

  @override
  void dispose() {
    _entrada.dispose();
    _flota.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _escala,
      child: AnimatedBuilder(
        animation: _flota,
        builder: (context, hijo) {
          final v = Curves.easeInOut.transform(_flota.value) - 0.5;
          return Transform.translate(
            offset: Offset(0, v * 12),
            child: Transform.rotate(angle: v * 0.05, child: hijo),
          );
        },
        child: Container(
          width: widget.tamano,
          height: widget.tamano,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                  color: Color(0x40000000), blurRadius: 18, offset: Offset(0, 8)),
            ],
          ),
          child: ClipOval(child: Image.asset('assets/logo.png', fit: BoxFit.cover)),
        ),
      ),
    );
  }
}

// ============================ REGISTRO / LOGIN ============================
class PantallaAcceso extends StatefulWidget {
  const PantallaAcceso({super.key});

  @override
  State<PantallaAcceso> createState() => _PantallaAccesoState();
}

class _PantallaAccesoState extends State<PantallaAcceso>
    with SingleTickerProviderStateMixin {
  final _nombre = TextEditingController();
  final _correo = TextEditingController();
  final _clave = TextEditingController();
  final _clave2 = TextEditingController();

  late final AnimationController _sacudir =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 450));

  bool _registro = false;
  bool _ocultar = true;
  bool _cargando = false;
  String? _error;
  String? _info;

  @override
  void dispose() {
    _nombre.dispose();
    _correo.dispose();
    _clave.dispose();
    _clave2.dispose();
    _sacudir.dispose();
    super.dispose();
  }

  void _fallo(String mensaje) {
    if (!mounted) return;
    setState(() {
      _error = mensaje;
      _info = null;
    });
    _sacudir.forward(from: 0);
    Sonidos.tocar('error', volumen: 0.7);
  }

  String? _validar() {
    final correo = _correo.text.trim();
    if (_registro && _nombre.text.trim().isEmpty) return 'Escribe tu nombre';
    if (!correo.contains('@') || !correo.contains('.')) {
      return 'Escribe un correo válido';
    }
    if (_clave.text.length < 6) {
      return 'La contraseña debe tener al menos 6 caracteres';
    }
    if (_registro && _clave.text != _clave2.text) {
      return 'Las contraseñas no coinciden';
    }
    return null;
  }

  String _traducir(String c) {
    if (c.contains('INVALID_LOGIN_CREDENTIALS') ||
        c.contains('INVALID_PASSWORD') ||
        c.contains('EMAIL_NOT_FOUND')) {
      return 'Correo o contraseña incorrectos';
    }
    if (c.contains('EMAIL_EXISTS')) return 'Ese correo ya está registrado';
    if (c.contains('WEAK_PASSWORD')) {
      return 'La contraseña es muy débil (mínimo 6 caracteres)';
    }
    if (c.contains('INVALID_EMAIL')) return 'El correo no es válido';
    if (c.contains('TOO_MANY_ATTEMPTS')) {
      return 'Demasiados intentos. Espera un momento e inténtalo de nuevo';
    }
    if (c.contains('USER_DISABLED')) return 'Esta cuenta está deshabilitada';
    if (c.contains('OPERATION_NOT_ALLOWED')) {
      return 'Ese método no está activado en Firebase';
    }
    if (c.contains('INVALID_IDP_RESPONSE') || c.contains('SIN_ID_TOKEN')) {
      return 'Google no devolvió la identificación. Revisa el ID de cliente web';
    }
    return 'Error: $c';
  }

  String _traducirGoogle(PlatformException e) {
    final detalle = '${e.code} ${e.message ?? ''}'.trim();
    final m = detalle.toLowerCase();
    if (m.contains('network') || m.contains('apiexception: 7')) {
      return 'Sin internet. Puedes usar el modo invitado.';
    }
    if (m.contains('apiexception: 10') || m.contains('developer_error')) {
      return 'Google no reconoce esta app (revisa la huella SHA-1 y el paquete en Firebase). [$detalle]';
    }
    if (m.contains('apiexception: 12500')) {
      return 'Google rechazó el inicio (revisa el correo de asistencia y la pantalla de consentimiento). [$detalle]';
    }
    if (m.contains('apiexception: 16')) {
      return 'Google canceló el inicio (suele ser la huella SHA-1 o el cliente Android). [$detalle]';
    }
    return 'Error de Google: $detalle';
  }

  Future<void> _recuperar() async {
    final correo = _correo.text.trim();
    if (!correo.contains('@') || !correo.contains('.')) {
      _fallo('Escribe tu correo arriba para enviarte el enlace');
      return;
    }
    setState(() {
      _cargando = true;
      _error = null;
      _info = null;
    });
    try {
      await AuthServicio.recuperar(correo);
      if (mounted) {
        setState(() => _info =
            'Te enviamos un enlace a $correo para crear una contraseña nueva.');
      }
    } on ErrorAuth catch (e) {
      _fallo(e.codigo.contains('EMAIL_NOT_FOUND')
          ? 'Ese correo no está registrado'
          : _traducir(e.codigo));
    } catch (_) {
      _fallo('No se pudo conectar. Revisa tu internet.');
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _google() async {
    if (googleWebClientId.contains('TU_ID')) {
      _fallo('Falta pegar el ID de cliente web de Google en main.dart');
      return;
    }
    setState(() {
      _cargando = true;
      _error = null;
      _info = null;
    });
    try {
      await AuthServicio.google();
    } on ErrorAuth catch (e) {
      if (e.codigo != 'CANCELADO') _fallo(_traducir(e.codigo));
    } on PlatformException catch (e) {
      _fallo(_traducirGoogle(e));
    } catch (_) {
      _fallo('No se pudo conectar. Revisa tu internet.');
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  // Modo invitado: no necesita internet
  Future<void> _entrarInvitado() async {
    await AuthServicio.invitado();
  }

  Future<void> _enviar() async {
    final problema = _validar();
    if (problema != null) {
      _fallo(problema);
      return;
    }

    setState(() {
      _cargando = true;
      _error = null;
      _info = null;
    });

    try {
      final correo = _correo.text.trim();
      if (_registro) {
        await AuthServicio.registrar(_nombre.text.trim(), correo, _clave.text);
      } else {
        await AuthServicio.iniciar(correo, _clave.text);
      }
    } on ErrorAuth catch (e) {
      _fallo(_traducir(e.codigo));
    } catch (_) {
      _fallo('No se pudo conectar. Revisa tu internet o usa el modo invitado.');
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Widget _campo(
    TextEditingController c,
    String etiqueta,
    IconData icono, {
    bool clave = false,
    TextInputType tipo = TextInputType.text,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: c,
        obscureText: clave && _ocultar,
        keyboardType: tipo,
        autocorrect: false,
        enabled: !_cargando,
        decoration: InputDecoration(
          labelText: etiqueta,
          prefixIcon: Icon(icono, color: azul),
          suffixIcon: clave
              ? IconButton(
                  icon: Icon(_ocultar ? Icons.visibility : Icons.visibility_off),
                  onPressed: () => setState(() => _ocultar = !_ocultar),
                )
              : null,
          filled: true,
          fillColor: Colors.white,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(18),
            borderSide: BorderSide.none,
          ),
        ),
      ),
    );
  }

  // Muestra u oculta un bloque con animación de tamaño y desvanecimiento
  Widget _seccion(bool visible, Widget hijo) {
    return AnimatedCrossFade(
      firstChild: const SizedBox(width: double.infinity),
      secondChild: hijo,
      crossFadeState:
          visible ? CrossFadeState.showSecond : CrossFadeState.showFirst,
      duration: const Duration(milliseconds: 320),
      sizeCurve: Curves.easeOutCubic,
    );
  }

  Widget _mensaje() {
    final texto = _error ?? _info;
    return AnimatedSize(
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: texto == null
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                texto,
                key: ValueKey(texto),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: _error != null ? rojo : azul,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
    );
  }

  Widget _tarjeta() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: crema,
        borderRadius: BorderRadius.circular(26),
        boxShadow: const [
          BoxShadow(color: Color(0x26000000), blurRadius: 14, offset: Offset(0, 6)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: Text(
              _registro ? 'Crea tu cuenta' : 'Inicia sesión',
              key: ValueKey(_registro),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: azul,
                fontSize: 24,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(height: 16),
          _seccion(_registro, _campo(_nombre, 'Nombre', Icons.person)),
          _campo(_correo, 'Correo electrónico', Icons.email,
              tipo: TextInputType.emailAddress),
          _campo(_clave, 'Contraseña', Icons.lock, clave: true),
          _seccion(_registro,
              _campo(_clave2, 'Repite la contraseña', Icons.lock_outline, clave: true)),
          _mensaje(),
          Pulsable(
            activo: !_cargando,
            child: FilledButton(
              onPressed: _cargando ? null : _enviar,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
                backgroundColor: azul,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(28)),
              ),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: _cargando
                    ? const SizedBox(
                        key: ValueKey('cargando'),
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                            strokeWidth: 3, color: Colors.white),
                      )
                    : Text(
                        _registro ? 'REGISTRARME' : 'ENTRAR',
                        key: ValueKey(_registro),
                        style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 1.2),
                      ),
              ),
            ),
          ),
          _seccion(
            !_registro,
            TextButton(
              onPressed: _cargando ? null : _recuperar,
              child: const Text(
                '¿Olvidaste tu contraseña?',
                style: TextStyle(color: azul, fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _botonGoogle() {
    return Pulsable(
      activo: !_cargando,
      child: FilledButton(
        onPressed: _cargando ? null : _google,
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(56),
          backgroundColor: Colors.white,
          foregroundColor: const Color(0xFF3C4043),
          disabledBackgroundColor: const Color(0x66FFFFFF),
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              'G',
              style: TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w900,
                color: Color(0xFF4285F4),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              _registro ? 'Registrarme con Google' : 'Continuar con Google',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const sombra = [Shadow(color: Color(0x55000000), blurRadius: 4)];

    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: FondoPatron()),
          SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 28),
              children: [
                Center(child: LogoAnimado(tamano: 170)),
                const SizedBox(height: 18),
                Aparece(
                  retardoMs: 250,
                  child: AnimatedBuilder(
                    animation: _sacudir,
                    builder: (context, hijo) => Transform.translate(
                      offset: Offset(
                        math.sin(_sacudir.value * math.pi * 6) *
                            (1 - _sacudir.value) *
                            10,
                        0,
                      ),
                      child: hijo,
                    ),
                    child: _tarjeta(),
                  ),
                ),
                const SizedBox(height: 14),
                Aparece(retardoMs: 400, child: _botonGoogle()),
                const SizedBox(height: 8),
                Aparece(
                  retardoMs: 520,
                  child: Column(
                    children: [
                      TextButton(
                        onPressed: _cargando
                            ? null
                            : () => setState(() {
                                  _registro = !_registro;
                                  _error = null;
                                  _info = null;
                                }),
                        child: Text(
                          _registro
                              ? '¿Ya tienes cuenta? Inicia sesión'
                              : '¿No tienes cuenta? Regístrate',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            shadows: sombra,
                          ),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _cargando ? null : _entrarInvitado,
                        icon: const Icon(Icons.cloud_off, color: Colors.white),
                        label: const Text(
                          'Continuar como invitado (sin internet)',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            decoration: TextDecoration.underline,
                            decorationColor: Colors.white,
                            shadows: sombra,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ============================== CONTROL BLE ==============================
class PantallaControl extends StatefulWidget {
  const PantallaControl({super.key});

  @override
  State<PantallaControl> createState() => _PantallaControlState();
}

class _PantallaControlState extends State<PantallaControl>
    with TickerProviderStateMixin {
  BluetoothDevice? _dispositivo;
  BluetoothCharacteristic? _car;
  StreamSubscription<BluetoothConnectionState>? _connSub;

  String _estado = 'Desconectado';
  bool _buscando = false;

  // Barra animada que acompaña el movimiento del collar
  late final AnimationController _accionCtrl = AnimationController(vsync: this);
  String? _accion; // 'SALIR' o 'ENTRAR' mientras se mueve

  // Brillo que respira alrededor del botón PARAR
  late final AnimationController _pulso =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
        ..repeat(reverse: true);

  bool get _conectado => _car != null;

  SesionUsuario? get _usuario => AuthServicio.sesion.value;

  String get _nombreUsuario {
    final u = _usuario;
    if (u == null) return '';
    return u.nombre.isNotEmpty ? u.nombre : u.email;
  }

  @override
  void initState() {
    super.initState();
    _accionCtrl.addStatusListener((s) {
      if (s == AnimationStatus.completed && mounted) {
        setState(() => _accion = null);
      }
    });
    Sonidos.tocar('entrada');   // sonido de ingreso
  }

  void _iniciarAccion(String comando) {
    final seg = comando == 'SALIR' ? segundosSalir : segundosEntrar;
    setState(() => _accion = comando);
    _accionCtrl.duration = Duration(milliseconds: (seg * 1000).round());
    _accionCtrl.forward(from: 0);
  }

  void _pararAccion() {
    _accionCtrl.stop();
    if (mounted) setState(() => _accion = null);
  }

  Future<void> _conectar() async {
    setState(() {
      _buscando = true;
      _estado = 'Buscando Novanyok...';
    });

    try {
      await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();

      final adaptador = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.unknown)
          .first;
      if (adaptador != BluetoothAdapterState.on) {
        setState(() => _estado = 'Activa el Bluetooth del celular');
        return;
      }

      BluetoothDevice? encontrado;
      final sub = FlutterBluePlus.scanResults.listen((resultados) {
        for (final r in resultados) {
          final porNombre = r.device.platformName.startsWith('Novanyok');
          final porServicio =
              r.advertisementData.serviceUuids.contains(Guid(serviceUuid));
          if (porNombre || porServicio) {
            encontrado = r.device;
            FlutterBluePlus.stopScan();
            break;
          }
        }
      });

      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 8));
      await FlutterBluePlus.isScanning.where((s) => s == false).first;
      await sub.cancel();

      if (encontrado == null) {
        setState(() =>
            _estado = 'No se encontró Novanyok. Revisa que esté encendido.');
        return;
      }

      final dev = encontrado!;
      setState(() => _estado = 'Conectando...');
      await dev.connect(timeout: const Duration(seconds: 10));

      _connSub?.cancel();
      _connSub = dev.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected && mounted) {
          _pararAccion();
          Sonidos.tocar('desconectado');
          setState(() {
            _car = null;
            _estado = 'Desconectado';
          });
        }
      });

      final servicios = await dev.discoverServices();
      BluetoothCharacteristic? car;
      for (final s in servicios) {
        if (s.uuid == Guid(serviceUuid)) {
          for (final c in s.characteristics) {
            if (c.uuid == Guid(charUuid)) car = c;
          }
        }
      }

      if (car == null) {
        await dev.disconnect();
        setState(() =>
            _estado = 'Conectado, pero no se halló el servicio de Novanyok');
        return;
      }

      setState(() {
        _dispositivo = dev;
        _car = car;
        _estado = 'Conectado a ${dev.platformName}';
      });
      Sonidos.tocar('conectado');
    } catch (e) {
      setState(() => _estado = 'Error: $e');
    } finally {
      if (mounted) setState(() => _buscando = false);
    }
  }

  Future<void> _desconectar() async {
    _pararAccion();
    await _enviar('PARAR', confiable: true);
    await _dispositivo?.disconnect();
  }

  Future<void> _cerrarSesion() async {
    if (_conectado) await _desconectar();
    await AuthServicio.cerrar();
  }

  // confiable = true usa escritura con confirmación (para PARAR)
  Future<void> _enviar(String comando, {bool confiable = false}) async {
    final c = _car;
    if (c == null) return;
    try {
      await c.write(utf8.encode(comando), withoutResponse: !confiable);
    } catch (e) {
      if (mounted) setState(() => _estado = 'Error al enviar: $e');
    }
  }

  Future<void> _mover(String comando) async {
    Sonidos.tocar(comando == 'SALIR' ? 'salir' : 'entrar');
    HapticFeedback.lightImpact();
    _iniciarAccion(comando);
    await _enviar(comando);
  }

  Future<void> _parar() async {
    Sonidos.tocar('parar', volumen: 1.0);
    HapticFeedback.mediumImpact();
    _pararAccion();
    await _enviar('PARAR', confiable: true);
  }

  @override
  void dispose() {
    _connSub?.cancel();
    _dispositivo?.disconnect();
    _accionCtrl.dispose();
    _pulso.dispose();
    super.dispose();
  }

  Widget _boton({
    required String texto,
    required IconData icono,
    required Color color,
    required double alto,
    required double tamano,
    required VoidCallback? onPressed,
  }) {
    return Pulsable(
      activo: onPressed != null,
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          minimumSize: Size.fromHeight(alto),
          backgroundColor: color,
          foregroundColor: Colors.white,
          disabledBackgroundColor: const Color(0x66FFFFFF),
          disabledForegroundColor: Colors.white70,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
          elevation: 3,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icono, size: tamano + 6),
            const SizedBox(width: 12),
            Text(
              texto,
              style: TextStyle(
                fontSize: tamano,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Barra que se llena (SALIR) o se vacía (ENTRAR) mientras el collar se mueve
  Widget _barraAccion() {
    final accion = _accion;
    return AnimatedSize(
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      alignment: Alignment.topCenter,
      child: accion == null
          ? const SizedBox(width: double.infinity)
          : Padding(
              padding: const EdgeInsets.only(top: 14),
              child: Container(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
                decoration: BoxDecoration(
                  color: crema,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(accion == 'SALIR' ? Icons.expand : Icons.compress,
                            color: accion == 'SALIR' ? azul : naranja),
                        const SizedBox(width: 10),
                        Text(
                          accion == 'SALIR' ? 'Saliendo…' : 'Entrando…',
                          style: const TextStyle(
                            color: azul,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    AnimatedBuilder(
                      animation: _accionCtrl,
                      builder: (context, _) => ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: LinearProgressIndicator(
                          value: accion == 'SALIR'
                              ? _accionCtrl.value
                              : 1 - _accionCtrl.value,
                          minHeight: 12,
                          backgroundColor: Colors.white,
                          color: accion == 'SALIR' ? azul : naranja,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final IconData iconoBt = _conectado
        ? Icons.bluetooth_connected
        : (_buscando ? Icons.bluetooth_searching : Icons.bluetooth);
    final invitado = _usuario?.invitado ?? false;
    const sombra = [Shadow(color: Color(0x55000000), blurRadius: 4)];

    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: FondoPatron()),
          SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(22, 8, 22, 28),
              children: [
                Aparece(
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Hola, $_nombreUsuario',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                                shadows: sombra,
                              ),
                            ),
                            if (invitado)
                              const Row(
                                children: [
                                  Icon(Icons.cloud_off,
                                      color: Colors.white, size: 14),
                                  SizedBox(width: 4),
                                  Text(
                                    'Modo invitado · sin internet',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      shadows: sombra,
                                    ),
                                  ),
                                ],
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: Sonidos.activo ? 'Silenciar' : 'Activar sonido',
                        onPressed: () async {
                          await Sonidos.alternar();
                          if (mounted) setState(() {});
                          if (Sonidos.activo) Sonidos.tocar('conectado', volumen: 0.55);
                        },
                        icon: Icon(
                          Sonidos.activo ? Icons.volume_up : Icons.volume_off,
                          color: Colors.white,
                        ),
                      ),
                      IconButton(
                        tooltip: 'Cerrar sesión',
                        onPressed: _cerrarSesion,
                        icon: const Icon(Icons.logout, color: Colors.white),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Center(child: LogoAnimado(tamano: 190)),
                const SizedBox(height: 14),
                const Aparece(
                  retardoMs: 200,
                  child: Text(
                    'COLLAR ISABELINO RETRÁCTIL',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.6,
                      shadows: sombra,
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Aparece(
                  retardoMs: 300,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 400),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                    decoration: BoxDecoration(
                      color: _conectado ? verdeClaro : crema,
                      borderRadius: BorderRadius.circular(22),
                    ),
                    child: Row(
                      children: [
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 300),
                          transitionBuilder: (hijo, anim) => ScaleTransition(
                            scale: anim,
                            child: FadeTransition(opacity: anim, child: hijo),
                          ),
                          child: Pulsante(
                            key: ValueKey(iconoBt),
                            activo: _buscando,
                            child: Icon(
                              iconoBt,
                              color: _conectado ? verdeOscuro : azul,
                              size: 26,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 300),
                            layoutBuilder: (actual, anteriores) => Stack(
                              alignment: Alignment.centerLeft,
                              children: [
                                ...anteriores,
                                if (actual != null) actual,
                              ],
                            ),
                            child: Text(
                              _estado,
                              key: ValueKey(_estado),
                              style: TextStyle(
                                color: _conectado ? verdeOscuro : azul,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Aparece(
                  retardoMs: 380,
                  child: Pulsable(
                    activo: !_buscando,
                    child: FilledButton(
                      onPressed:
                          _buscando ? null : (_conectado ? _desconectar : _conectar),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(54),
                        backgroundColor: Colors.white,
                        foregroundColor: azul,
                        disabledBackgroundColor: const Color(0x66FFFFFF),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(28)),
                      ),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: Text(
                          _buscando
                              ? 'Buscando...'
                              : (_conectado
                                  ? 'Desconectar'
                                  : 'Conectar por Bluetooth'),
                          key: ValueKey('$_buscando-$_conectado'),
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w800),
                        ),
                      ),
                    ),
                  ),
                ),
                _barraAccion(),
                const SizedBox(height: 24),
                Aparece(
                  retardoMs: 460,
                  child: _boton(
                    texto: 'SALIR',
                    icono: Icons.expand,
                    color: azul,
                    alto: 84,
                    tamano: 24,
                    onPressed: _conectado ? () => _mover('SALIR') : null,
                  ),
                ),
                const SizedBox(height: 14),
                Aparece(
                  retardoMs: 540,
                  child: _boton(
                    texto: 'ENTRAR',
                    icono: Icons.compress,
                    color: naranja,
                    alto: 84,
                    tamano: 24,
                    onPressed: _conectado ? () => _mover('ENTRAR') : null,
                  ),
                ),
                const SizedBox(height: 14),
                Aparece(
                  retardoMs: 620,
                  child: AnimatedBuilder(
                    animation: _pulso,
                    builder: (context, hijo) => Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(28),
                        boxShadow: _conectado
                            ? [
                                BoxShadow(
                                  color: rojo.withAlpha(
                                      (255 * (0.15 + 0.35 * _pulso.value)).round()),
                                  blurRadius: 10 + 18 * _pulso.value,
                                  spreadRadius: 1 + 4 * _pulso.value,
                                ),
                              ]
                            : const [],
                      ),
                      child: hijo,
                    ),
                    child: _boton(
                      texto: 'PARAR',
                      icono: Icons.stop_rounded,
                      color: rojo,
                      alto: 104,
                      tamano: 30,
                      onPressed: _conectado ? _parar : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
