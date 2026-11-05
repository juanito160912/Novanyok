import 'dart:async';
import 'dart:convert';
 
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
 
// Mismos UUID que el sketch del ESP32-C3
const String serviceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
const String charUuid = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
 
// Colores tomados del logo de Novanyok
const Color amarillo = Color(0xFFFFBB1B);
const Color naranja = Color(0xFFEE8029);
const Color crema = Color(0xFFFCEFAB);
const Color azul = Color(0xFF2E6EB8);
const Color rojo = Color(0xFFD62F2F);
 
void main() => runApp(const NovanyokApp());
 
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
      home: const PantallaControl(),
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
 
class PantallaControl extends StatefulWidget {
  const PantallaControl({super.key});
 
  @override
  State<PantallaControl> createState() => _PantallaControlState();
}
 
class _PantallaControlState extends State<PantallaControl> {
  BluetoothDevice? _dispositivo;
  BluetoothCharacteristic? _car;
  StreamSubscription<BluetoothConnectionState>? _connSub;
 
  String _estado = 'Desconectado';
  bool _buscando = false;
 
  bool get _conectado => _car != null;
 
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
    } catch (e) {
      setState(() => _estado = 'Error: $e');
    } finally {
      if (mounted) setState(() => _buscando = false);
    }
  }
 
  Future<void> _desconectar() async {
    await _enviar('PARAR', confiable: true);
    await _dispositivo?.disconnect();
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
 
  @override
  void dispose() {
    _connSub?.cancel();
    _dispositivo?.disconnect();
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
    return FilledButton(
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
    );
  }
 
  @override
  Widget build(BuildContext context) {
    final IconData iconoBt = _conectado
        ? Icons.bluetooth_connected
        : (_buscando ? Icons.bluetooth_searching : Icons.bluetooth);
 
    return Scaffold(
      body: Stack(
        children: [
          const Positioned.fill(child: FondoPatron()),
          SafeArea(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(22, 16, 22, 28),
              children: [
                Center(
                  child: Container(
                    width: 210,
                    height: 210,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Color(0x40000000),
                          blurRadius: 18,
                          offset: Offset(0, 8),
                        ),
                      ],
                    ),
                    child: ClipOval(
                      child: Image.asset('assets/logo.png', fit: BoxFit.cover),
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'COLLAR ISABELINO RETRÁCTIL',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.6,
                    shadows: [Shadow(color: Color(0x55000000), blurRadius: 4)],
                  ),
                ),
                const SizedBox(height: 18),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                  decoration: BoxDecoration(
                    color: crema,
                    borderRadius: BorderRadius.circular(22),
                  ),
                  child: Row(
                    children: [
                      Icon(iconoBt, color: azul, size: 26),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _estado,
                          style: const TextStyle(
                            color: azul,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton(
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
                  child: Text(
                    _buscando
                        ? 'Buscando...'
                        : (_conectado ? 'Desconectar' : 'Conectar por Bluetooth'),
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                ),
                const SizedBox(height: 26),
                _boton(
                  texto: 'SALIR',
                  icono: Icons.expand,
                  color: azul,
                  alto: 84,
                  tamano: 24,
                  onPressed: _conectado ? () => _enviar('SALIR') : null,
                ),
                const SizedBox(height: 14),
                _boton(
                  texto: 'ENTRAR',
                  icono: Icons.compress,
                  color: naranja,
                  alto: 84,
                  tamano: 24,
                  onPressed: _conectado ? () => _enviar('ENTRAR') : null,
                ),
                const SizedBox(height: 14),
                _boton(
                  texto: 'PARAR',
                  icono: Icons.stop_rounded,
                  color: rojo,
                  alto: 104,
                  tamano: 30,
                  onPressed:
                      _conectado ? () => _enviar('PARAR', confiable: true) : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
 
