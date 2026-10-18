import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeService();
  runApp(const MyApp());
}

Future<void> initializeService() async {
  final service = FlutterBackgroundService();

  // Налаштування каналу сповіщень для Android (обов'язково для Foreground Service на Android 8+)
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'print_service_channel', 
    'Служба друку 1С', 
    description: 'Канал для фонового сервісу друку',
    importance: Importance.low, 
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  // Ініціалізуємо плагін сповіщень
  await flutterLocalNotificationsPlugin.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
  );

  final androidPlugin = flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();

  // Запит дозволу на сповіщення (критично для Android 13+)
  await androidPlugin?.requestNotificationsPermission();

  // Створюємо канал
  await androidPlugin?.createNotificationChannel(channel);

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'print_service_channel',
      initialNotificationTitle: 'Друк 1C (TSPL Gateway)',
      initialNotificationContent: 'HTTP-сервер активний на порту 8088',
      foregroundServiceTypes: [AndroidForegroundType.dataSync],
    ),
    iosConfiguration: IosConfiguration(
      autoStart: false,
      onForeground: onStart,
    ),
  );
}

@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();

  // Дозволяємо змінювати стан сервісу
  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });
    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });
  }

  // Запуск локального HTTP-сервера на localhost
  final server = await HttpServer.bind(
    InternetAddress.loopbackIPv4,
    8088,
    shared: true,
  );

  debugPrint('Шлюз друку запущено: http://${server.address.address}:${server.port}');

  // Єдина точка обробки зупинки сервісу через внутрішні події
  service.on('stopService').listen((event) async {
    await server.close(force: true);
    service.stopSelf();
  });

  // Асинхронна обробка запитів від 1С
  server.listen((HttpRequest request) async {
    request.response.headers.contentType = ContentType.json;

    // 1. Команда зупинки сервісу від 1С при завершенні зміни
    if (request.method == 'POST' && request.uri.path == '/stop') {
      try {
        request.response
          ..statusCode = HttpStatus.ok
          ..write('{"status":"stopping"}');
        await request.response.close();

        // Невелика пауза (200 мс), щоб HTTP-відповідь встигла дійти до 1С
        await Future.delayed(const Duration(milliseconds: 200));

        await server.close(force: true);
        service.stopSelf();
      } catch (e) {
        debugPrint('Помилка зупинки сервера: $e');
      }
      return;
    }

    // 2. Команда друку етикетки
    if (request.method == 'POST' && request.uri.path == '/print') {
      try {
        final printerIp = request.headers.value('printer-ip') ?? '192.168.1.150';
        final printerPort = int.tryParse(request.headers.value('printer-port') ?? '9100') ?? 9100;

        final tsplContent = await utf8.decoder.bind(request).join();

        final isSuccess = await sendToPrinter(printerIp, printerPort, tsplContent);

        if (isSuccess) {
          request.response
            ..statusCode = HttpStatus.ok
            ..write('{"status":"ok"}');
        } else {
          request.response
            ..statusCode = HttpStatus.gatewayTimeout
            ..write('{"status":"error","message":"Принтер недоступний або таймаут"}');
        }
      } catch (e) {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..write('{"status":"error","message":"$e"}');
      } finally {
        await request.response.close();
      }
      return;
    }

    // 3. Усі інші невідомі маршрути
    request.response
      ..statusCode = HttpStatus.notFound
      ..write('{"status":"error","message":"Not Found"}')
      ..close();
  });
}

// Функція прямого підключення до принтера через TCP-сокет
Future<bool> sendToPrinter(String ip, int port, String commands) async {
  Socket? socket;
  try {
    socket = await Socket.connect(ip, port, timeout: const Duration(seconds: 3));

    socket.add(utf8.encode(commands));
    await socket.flush();
    
    // Коректне закриття сокету після успішної відправки
    await socket.close();
    return true;
  } catch (e) {
    debugPrint('Помилка відправки в принтер ($ip:$port): $e');
    // Жорстке знищення сокету при помилці (Критично для TSC, щоб звільнити порт 9100)
    socket?.destroy();
    return false;
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('Служба друку 1С')),
        body: const Center(
          child: Text(
            'Сервіс працює у фоні.\nСлухає: 127.0.0.1:8088/print',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16),
          ),
        ),
      ),
    );
  }
}