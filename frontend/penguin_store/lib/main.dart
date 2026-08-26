import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:penguin_store/core/theme/app_theme.dart';
import 'package:penguin_store/features/shop/providers/auth_provider.dart';
import 'package:penguin_store/features/shop/providers/cart_provider.dart';
import 'package:provider/provider.dart';
import 'core/routing/app_router.dart';
import 'core/theme/app_colors.dart';
import 'package:flutter_stripe/flutter_stripe.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';

Future<void> initPush() async {
  try {
    print("Requesting FCM permissions...");
    await FirebaseMessaging.instance.requestPermission();

    final token = await FirebaseMessaging.instance.getToken(
      vapidKey:
          'BKScsiuuCpC-1sKiMPTAIj9i4OBmGd5qwTgggu4WREUIY1vP6NzVjgmqP6NWR_n1odCauNuSwz5VBCNHzorKOw0',
    );

    print("✅ FCM Token: $token");
  } catch (e) {
    print("❌ FCM error: $e");
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  Stripe.publishableKey =
      'pk_test_51TRZQcC2PJj8GFRJu9id3IBbT4rqMSDpGmcCQLRKVO5q1BdkMOXwFuRm9CrsIxfAchZKc6xEKRF3B7P0ByyJbSWe007itj8oW7';
  await Stripe.instance.applySettings();

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
      routerConfig: appRouter,
      theme: darkTheme,
      // theme: ThemeData(
      //   scaffoldBackgroundColor: AppColors.secondaryWhite,
      //   primaryColor: AppColors.primaryBlack,
      //   textTheme: GoogleFonts.poppinsTextTheme(Theme.of(context).textTheme),
      //   useMaterial3: true,
      //   appBarTheme: const AppBarTheme(
      //     backgroundColor: AppColors.primaryBlack,
      //     foregroundColor: AppColors.pureWhite,
      //     elevation: 0,
      //   ),
      // ),
    );
  }
}