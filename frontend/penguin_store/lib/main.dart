import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:penguin_store/features/shop/providers/auth_provider.dart';

import 'package:penguin_store/features/shop/providers/cart_provider.dart';
import 'package:provider/provider.dart';
import 'core/routing/app_router.dart';
import 'core/theme/app_colors.dart';

void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => CartProvider()),
        ChangeNotifierProvider(create: (_) => AuthProvider()),
      ],
      child: const PenguinStoreApp(),
    ),
  );
}

class PenguinStoreApp extends StatelessWidget {
  const PenguinStoreApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'Penguin Store',
      debugShowCheckedModeBanner: false,
      routerConfig: appRouter, // This connects to our go_router setup
      theme: ThemeData(
        scaffoldBackgroundColor: AppColors.secondaryWhite,
        primaryColor: AppColors.primaryBlack,
        // Using Google Fonts for a modern, sleek e-commerce look
        textTheme: GoogleFonts.poppinsTextTheme(Theme.of(context).textTheme),
        useMaterial3: true,
        // Global styling for the top navigation bar
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.primaryBlack,
          foregroundColor: AppColors.pureWhite,
          elevation: 0,
        ),
      ),
    );
  }
}