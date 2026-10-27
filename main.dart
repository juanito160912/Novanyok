import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

// Mismos UUID que el sketch del ESP32-C3
const String serviceUuid = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
const String charUuid = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';

void main() => runApp(const NovanyokApp());

class NovanyokApp extends StatelessWidget {
  const NovanyokApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Novanyok',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.blue,
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const PantallaControl(),
    );
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

  @override
  Widget build(BuildContext context) {
    final colores = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(title: const Text('Novanyok')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(_estado, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed:
                  _buscando ? null : (_conectado ? _desconectar : _conectar),
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52)),
              child: Text(_buscando
                  ? 'Buscando...'
                  : (_conectado ? 'Desconectar' : 'Conectar por Bluetooth')),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _conectado ? () => _enviar('SALIR') : null,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(80),
                backgroundColor: Colors.green.shade700,
              ),
              child: const Text('SALIR', style: TextStyle(fontSize: 24)),
            ),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: _conectado ? () => _enviar('ENTRAR') : null,
              style:
                  FilledButton.styleFrom(minimumSize: const Size.fromHeight(80)),
              child: const Text('ENTRAR', style: TextStyle(fontSize: 24)),
            ),
            const SizedBox(height: 14),
            FilledButton(
              onPressed:
                  _conectado ? () => _enviar('PARAR', confiable: true) : null,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(96),
                backgroundColor: colores.error,
                foregroundColor: colores.onError,
              ),
              child: const Text('PARAR', style: TextStyle(fontSize: 28)),
            ),
          ],
        ),
      ),
    );
  }
}