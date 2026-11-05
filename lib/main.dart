import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// ======================== CONFIGURACIÓN DE FIREBASE ========================
// Clave web de tu proyecto "basesita-bonita" (Firebase Authentication).
const String firebaseApiKey = 'AIzaSyC_dsW7kglbQRF4Ar1MkFtvah7Rn6_EDJ4';
// ===========================================================================

// Mismos UUID que el sketch del ESP32-C3
const String serviceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
const String charUuid = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';

// Colores tomados del logo de Novanyok
const Color amarillo = Color(0xFFFFBB1B);
const Color naranja = Color(0xFFEE8029);
const Color crema = Color(0xFFFCEFAB);
const Color azul = Color(0xFF2E6EB8);
const Color rojo = Color(0xFFD62F2F);

class ErrorAuth implements Exception {
  final String codigo;
  ErrorAuth(this.codigo);
}

class SesionUsuario {
  final String uid;
  final String email;
  final String nombre;
  final String refreshToken;
  const SesionUsuario({
    required this.uid,
    required this.email,
    required this.nombre,
    required this.refreshToken,
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
    } catch (_) {}
  }

  static Future<void> cargarGuardada() async {
    try {
      final p = await SharedPreferences.getInstance();
      final token = p.getString('refreshToken');
      final uid = p.getString('uid');
      if (token == null || uid == null) return;
      sesion.value = SesionUsuario(
        uid: uid,
        email: p.getString('email') ?? '',
        nombre: p.getString('nombre') ?? '',
        refreshToken: token,
      );
    } catch (_) {
      return;
    }
    unawaited(_validar());
  }

  // Comprueba en segundo plano que la cuenta siga existiendo
  static Future<void> _validar() async {
    final s = sesion.value;
    if (s == null) return;
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

  static Future<void> invitado() async {
    final r = await _post(
      '$_cuentas:signUp?key=$firebaseApiKey',
      json: {'returnSecureToken': true},
    );
    await _guardar(SesionUsuario(
      uid: r['localId'] as String,
      email: '',
      nombre: 'Invitado',
      refreshToken: r['refreshToken'] as String,
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
      final p = await SharedPreferences.getInstance();
      for (final k in ['uid', 'email', 'nombre', 'refreshToken']) {
        await p.remove(k);
      }
    } catch (_) {}
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AuthServicio.cargarGuardada();
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

// Muestra el acceso o el control según haya sesión iniciada
class PuertaAcceso extends StatelessWidget {
  const PuertaAcceso({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SesionUsuario?>(
      valueListenable: AuthServicio.sesion,
      builder: (context, sesion, _) =>
          sesion == null ? const PantallaAcceso() : const PantallaControl(),
    );
  }
}

// Fondo con huellitas, corazones y pelotas, como en el logo
class FondoPatron extends StatelessWidget {
  const FondoPatron({super.key});

  static const _iconos = [
    Icons.pets,
    Icons.favorite_border,
    Icons.sports_baseball_outlined,
    Icons.pets,
    Icons.favorite_border,
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      const paso = 84.0;
      final cols = (c.maxWidth / paso).ceil() + 1;
      final filas = (c.maxHeight / paso).ceil() + 1;
      final hijos = <Widget>[];
      for (var f = 0; f < filas; f++) {
        for (var col = 0; col < cols; col++) {
          final i = f * cols + col;
          hijos.add(Positioned(
            left: col * paso + (f.isOdd ? paso / 2 : 0) - 20,
            top: f * paso - 10,
            child: Transform.rotate(
              angle: ((i % 5) - 2) * 0.25,
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
    });
  }
}

Widget logoCircular(double tamano) {
  return Container(
    width: tamano,
    height: tamano,
    decoration: const BoxDecoration(
      shape: BoxShape.circle,
      boxShadow: [
        BoxShadow(color: Color(0x40000000), blurRadius: 18, offset: Offset(0, 8)),
      ],
    ),
    child: ClipOval(child: Image.asset('assets/logo.png', fit: BoxFit.cover)),
  );
}

// ============================ REGISTRO / LOGIN ============================
class PantallaAcceso extends StatefulWidget {
  const PantallaAcceso({super.key});

  @override
  State<PantallaAcceso> createState() => _PantallaAccesoState();
}

class _PantallaAccesoState extends State<PantallaAcceso> {
  final _nombre = TextEditingController();
  final _correo = TextEditingController();
  final _clave = TextEditingController();
  final _clave2 = TextEditingController();

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
    super.dispose();
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
      return 'El registro con correo no está activado en Firebase';
    }
    return 'Error: $c';
  }

  Future<void> _recuperar() async {
    final correo = _correo.text.trim();
    if (!correo.contains('@') || !correo.contains('.')) {
      setState(() {
        _error = 'Escribe tu correo arriba para enviarte el enlace';
        _info = null;
      });
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
      if (mounted) {
        setState(() => _error = e.codigo.contains('EMAIL_NOT_FOUND')
            ? 'Ese correo no está registrado'
            : _traducir(e.codigo));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No se pudo conectar. Revisa tu internet.');
      }
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _entrarInvitado() async {
    setState(() {
      _cargando = true;
      _error = null;
      _info = null;
    });
    try {
      await AuthServicio.invitado();
    } on ErrorAuth catch (e) {
      if (mounted) {
        setState(() => _error = e.codigo.contains('OPERATION_NOT_ALLOWED')
            ? 'El acceso anónimo no está activado en Firebase'
            : _traducir(e.codigo));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No se pudo conectar. Revisa tu internet.');
      }
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _enviar() async {
    final problema = _validar();
    if (problema != null) {
      setState(() {
        _error = problema;
        _info = null;
      });
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
      if (mounted) setState(() => _error = _traducir(e.codigo));
    } catch (_) {
      if (mounted) setState(() => _error = 'No se pudo conectar. Revisa tu internet.');
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: FondoPatron()),
          SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 28),
              children: [
                Center(child: logoCircular(170)),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: crema,
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _registro ? 'Crea tu cuenta' : 'Inicia sesión',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: azul,
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (_registro)
                        _campo(_nombre, 'Nombre', Icons.person),
                      _campo(_correo, 'Correo electrónico', Icons.email,
                          tipo: TextInputType.emailAddress),
                      _campo(_clave, 'Contraseña', Icons.lock, clave: true),
                      if (_registro)
                        _campo(_clave2, 'Repite la contraseña', Icons.lock_outline,
                            clave: true),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: rojo, fontWeight: FontWeight.w700),
                          ),
                        ),
                      if (_info != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Text(
                            _info!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: azul, fontWeight: FontWeight.w700),
                          ),
                        ),
                      FilledButton(
                        onPressed: _cargando ? null : _enviar,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(56),
                          backgroundColor: azul,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(28)),
                        ),
                        child: _cargando
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                    strokeWidth: 3, color: Colors.white),
                              )
                            : Text(
                                _registro ? 'REGISTRARME' : 'ENTRAR',
                                style: const TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 1.2),
                              ),
                      ),
                      if (!_registro)
                        TextButton(
                          onPressed: _cargando ? null : _recuperar,
                          child: const Text(
                            '¿Olvidaste tu contraseña?',
                            style: TextStyle(
                                color: azul, fontWeight: FontWeight.w700),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
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
                      shadows: [Shadow(color: Color(0x55000000), blurRadius: 4)],
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _cargando ? null : _entrarInvitado,
                  child: const Text(
                    'Continuar como invitado',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      decoration: TextDecoration.underline,
                      decorationColor: Colors.white,
                      shadows: [Shadow(color: Color(0x55000000), blurRadius: 4)],
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

// ============================== CONTROL BLE ==============================
class PantallaControl extends StatefulWidget {
  const PantallaControl({super.key});

  @override
  State<PantallaControl> createState() => _PantallaControlState();
}

class _PantallaControlState extends State<PantallaControl> {
  BluetoothDevice? _dispositivo;
  BluetoothCharacteristic? _car;
  StreamSimport 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

// ======================== CONFIGURACIÓN DE FIREBASE ========================
// Clave web de tu proyecto "basesita-bonita" (Firebase Authentication).
const String firebaseApiKey = 'AIzaSyC_dsW7kglbQRF4Ar1MkFtvah7Rn6_EDJ4';
// ===========================================================================

// Mismos UUID que el sketch del ESP32-C3
const String serviceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
const String charUuid = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';

// Colores tomados del logo de Novanyok
const Color amarillo = Color(0xFFFFBB1B);
const Color naranja = Color(0xFFEE8029);
const Color crema = Color(0xFFFCEFAB);
const Color azul = Color(0xFF2E6EB8);
const Color rojo = Color(0xFFD62F2F);

class ErrorAuth implements Exception {
  final String codigo;
  ErrorAuth(this.codigo);
}

class SesionUsuario {
  final String uid;
  final String email;
  final String nombre;
  final String refreshToken;
  const SesionUsuario({
    required this.uid,
    required this.email,
    required this.nombre,
    required this.refreshToken,
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
    } catch (_) {}
  }

  static Future<void> cargarGuardada() async {
    try {
      final p = await SharedPreferences.getInstance();
      final token = p.getString('refreshToken');
      final uid = p.getString('uid');
      if (token == null || uid == null) return;
      sesion.value = SesionUsuario(
        uid: uid,
        email: p.getString('email') ?? '',
        nombre: p.getString('nombre') ?? '',
        refreshToken: token,
      );
    } catch (_) {
      return;
    }
    unawaited(_validar());
  }

  // Comprueba en segundo plano que la cuenta siga existiendo
  static Future<void> _validar() async {
    final s = sesion.value;
    if (s == null) return;
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

  static Future<void> invitado() async {
    final r = await _post(
      '$_cuentas:signUp?key=$firebaseApiKey',
      json: {'returnSecureToken': true},
    );
    await _guardar(SesionUsuario(
      uid: r['localId'] as String,
      email: '',
      nombre: 'Invitado',
      refreshToken: r['refreshToken'] as String,
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
      final p = await SharedPreferences.getInstance();
      for (final k in ['uid', 'email', 'nombre', 'refreshToken']) {
        await p.remove(k);
      }
    } catch (_) {}
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AuthServicio.cargarGuardada();
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

// Muestra el acceso o el control según haya sesión iniciada
class PuertaAcceso extends StatelessWidget {
  const PuertaAcceso({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<SesionUsuario?>(
      valueListenable: AuthServicio.sesion,
      builder: (context, sesion, _) =>
          sesion == null ? const PantallaAcceso() : const PantallaControl(),
    );
  }
}

// Fondo con huellitas, corazones y pelotas, como en el logo
class FondoPatron extends StatelessWidget {
  const FondoPatron({super.key});

  static const _iconos = [
    Icons.pets,
    Icons.favorite_border,
    Icons.sports_baseball_outlined,
    Icons.pets,
    Icons.favorite_border,
  ];

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, c) {
      const paso = 84.0;
      final cols = (c.maxWidth / paso).ceil() + 1;
      final filas = (c.maxHeight / paso).ceil() + 1;
      final hijos = <Widget>[];
      for (var f = 0; f < filas; f++) {
        for (var col = 0; col < cols; col++) {
          final i = f * cols + col;
          hijos.add(Positioned(
            left: col * paso + (f.isOdd ? paso / 2 : 0) - 20,
            top: f * paso - 10,
            child: Transform.rotate(
              angle: ((i % 5) - 2) * 0.25,
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
    });
  }
}

Widget logoCircular(double tamano) {
  return Container(
    width: tamano,
    height: tamano,
    decoration: const BoxDecoration(
      shape: BoxShape.circle,
      boxShadow: [
        BoxShadow(color: Color(0x40000000), blurRadius: 18, offset: Offset(0, 8)),
      ],
    ),
    child: ClipOval(child: Image.asset('assets/logo.png', fit: BoxFit.cover)),
  );
}

// ============================ REGISTRO / LOGIN ============================
class PantallaAcceso extends StatefulWidget {
  const PantallaAcceso({super.key});

  @override
  State<PantallaAcceso> createState() => _PantallaAccesoState();
}

class _PantallaAccesoState extends State<PantallaAcceso> {
  final _nombre = TextEditingController();
  final _correo = TextEditingController();
  final _clave = TextEditingController();
  final _clave2 = TextEditingController();

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
    super.dispose();
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
      return 'El registro con correo no está activado en Firebase';
    }
    return 'Error: $c';
  }

  Future<void> _recuperar() async {
    final correo = _correo.text.trim();
    if (!correo.contains('@') || !correo.contains('.')) {
      setState(() {
        _error = 'Escribe tu correo arriba para enviarte el enlace';
        _info = null;
      });
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
      if (mounted) {
        setState(() => _error = e.codigo.contains('EMAIL_NOT_FOUND')
            ? 'Ese correo no está registrado'
            : _traducir(e.codigo));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No se pudo conectar. Revisa tu internet.');
      }
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _entrarInvitado() async {
    setState(() {
      _cargando = true;
      _error = null;
      _info = null;
    });
    try {
      await AuthServicio.invitado();
    } on ErrorAuth catch (e) {
      if (mounted) {
        setState(() => _error = e.codigo.contains('OPERATION_NOT_ALLOWED')
            ? 'El acceso anónimo no está activado en Firebase'
            : _traducir(e.codigo));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'No se pudo conectar. Revisa tu internet.');
      }
    } finally {
      if (mounted) setState(() => _cargando = false);
    }
  }

  Future<void> _enviar() async {
    final problema = _validar();
    if (problema != null) {
      setState(() {
        _error = problema;
        _info = null;
      });
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
      if (mounted) setState(() => _error = _traducir(e.codigo));
    } catch (_) {
      if (mounted) setState(() => _error = 'No se pudo conectar. Revisa tu internet.');
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: FondoPatron()),
          SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(22, 20, 22, 28),
              children: [
                Center(child: logoCircular(170)),
                const SizedBox(height: 18),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: crema,
                    borderRadius: BorderRadius.circular(26),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        _registro ? 'Crea tu cuenta' : 'Inicia sesión',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: azul,
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 16),
                      if (_registro)
                        _campo(_nombre, 'Nombre', Icons.person),
                      _campo(_correo, 'Correo electrónico', Icons.email,
                          tipo: TextInputType.emailAddress),
                      _campo(_clave, 'Contraseña', Icons.lock, clave: true),
                      if (_registro)
                        _campo(_clave2, 'Repite la contraseña', Icons.lock_outline,
                            clave: true),
                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Text(
                            _error!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: rojo, fontWeight: FontWeight.w700),
                          ),
                        ),
                      if (_info != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Text(
                            _info!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: azul, fontWeight: FontWeight.w700),
                          ),
                        ),
                      FilledButton(
                        onPressed: _cargando ? null : _enviar,
                        style: FilledButton.styleFrom(
                          minimumSize: const Size.fromHeight(56),
                          backgroundColor: azul,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(28)),
                        ),
                        child: _cargando
                            ? const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(
                                    strokeWidth: 3, color: Colors.white),
                              )
                            : Text(
                                _registro ? 'REGISTRARME' : 'ENTRAR',
                                style: const TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 1.2),
                              ),
                      ),
                      if (!_registro)
                        TextButton(
                          onPressed: _cargando ? null : _recuperar,
                          child: const Text(
                            '¿Olvidaste tu contraseña?',
                            style: TextStyle(
                                color: azul, fontWeight: FontWeight.w700),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 14),
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
                      shadows: [Shadow(color: Color(0x55000000), blurRadius: 4)],
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _cargando ? null : _entrarInvitado,
                  child: const Text(
                    'Continuar como invitado',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      decoration: TextDecoration.underline,
                      decorationColor: Colors.white,
                      shadows: [Shadow(color: Color(0x55000000), blurRadius: 4)],
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

// ============================== CONTROL BLE ==============================
class PantallaControl extends StatefulWidget {
  const PantallaControl({super.key});

  @override
  State<PantallaControl> createState() => _PantallaControlState();
}

class _PantallaControlState extends State<PantallaControl> {
  BluetoothDevice? _dispositivo;
  BluetoothCharacteristic? _car;
  StreamS
