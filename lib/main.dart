import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'providers/app_provider.dart';
import 'theme/app_theme.dart';
import 'screens/main_navigation.dart';
import 'screens/auth_entry_screen.dart';

void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (FlutterErrorDetails details) {
      FlutterError.presentError(details);
      debugPrint('[FlutterError] ${details.exception}');
    };
    ErrorWidget.builder = (FlutterErrorDetails details) {
      return Container(
        color: const Color(0xFFFFF9F0),
        alignment: Alignment.center,
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Text(
            'Notice: ${details.exceptionAsString()}',
            style: const TextStyle(color: Color(0xFF1E293B), fontSize: 12),
          ),
        ),
      );
    };
    runApp(
      ChangeNotifierProvider(
        create: (_) => AppProvider(),
        child: const ProductivityApp(),
      ),
    );
  }, (error, stack) {
    debugPrint('[Uncaught Exception] $error\n$stack');
  });
}

class ProductivityApp extends StatelessWidget {
  const ProductivityApp({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<AppProvider>(context);

    if (!provider.isInitialized) {
      return MaterialApp(
        title: 'Wrindha OS',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.lightTheme,
        themeMode: ThemeMode.light,
        home: const Scaffold(
          backgroundColor: Color(0xFFFFF9F0),
          body: Center(
            child: CircularProgressIndicator(color: Color(0xFF2A85FF)),
          ),
        ),
      );
    }

    return MaterialApp(
      title: 'Wrindha OS',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      themeMode: ThemeMode.light,
      home: provider.isLoggedIn
          ? const MainNavigationScreen()
          : const AuthEntryScreen(),
    );
  }
}
