import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:open_note/core/theme/app_colors.dart';
import 'package:open_note/features/notebook/presentation/note_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    await BrowserContextMenu.disableContextMenu();
  }
  runApp(const OpenNoteApp());
}

class OpenNoteApp extends StatelessWidget {
  const OpenNoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'OpenNote',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: AppColors.primary,
          primary: AppColors.primary,
        ),
        appBarTheme: const AppBarTheme(
          elevation: 2,
          centerTitle: false,
        ),
      ),
      home: const NoteScreen(),
    );
  }
}
