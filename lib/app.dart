import 'package:flutter/material.dart';
import 'package:livekit_components/livekit_components.dart' as components;
import 'package:provider/provider.dart';

import 'controllers/app_ctrl.dart';
import 'master/master_ctrl.dart';
import 'screens/master_screen.dart';
import 'screens/agent_screen.dart';
import 'screens/welcome_screen.dart';
import 'ui/color_pallette.dart' show LKColorPaletteLight, LKColorPaletteDark;
import 'widgets/app_layout_switcher.dart';
import 'widgets/session_error_banner.dart';

final appCtrl = AppCtrl();

class VoiceAssistantApp extends StatelessWidget {
  const VoiceAssistantApp({super.key});

  ThemeData buildTheme({required bool isLight}) {
    final colorPallete = isLight ? LKColorPaletteLight() : LKColorPaletteDark();

    return ThemeData(
      useMaterial3: true,
      cardColor: colorPallete.bg2,
      scaffoldBackgroundColor: colorPallete.bg1,
      canvasColor: colorPallete.bg1,
      inputDecorationTheme: InputDecorationTheme(
        fillColor: colorPallete.bg2,
        hintStyle: TextStyle(
          color: colorPallete.fg4,
          fontSize: 14,
        ),
      ),
      buttonTheme: ButtonThemeData(
        disabledColor: Colors.red,
        colorScheme: ColorScheme.dark(
          primary: Colors.white,
          secondary: Colors.white,
          surface: colorPallete.fgAccent,
        ),
      ),
      colorScheme: isLight
          ? const ColorScheme.light(
              primary: Colors.black,
              secondary: Colors.black,
              surface: Colors.white,
            )
          : const ColorScheme.dark(
              primary: Colors.white,
              secondary: Colors.white,
              surface: Colors.black,
            ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w400,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext ctx) => MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: appCtrl),
          ChangeNotifierProvider.value(value: appCtrl.master),
          ChangeNotifierProvider.value(value: appCtrl.session),
          ChangeNotifierProvider.value(value: appCtrl.roomContext),
        ],
        child: components.SessionContext(
          session: appCtrl.session,
          child: MaterialApp(
            title: 'J.A.R.V.I.S',
            theme: buildTheme(isLight: true),
            darkTheme: buildTheme(isLight: false),
            // themeMode: ThemeMode.dark,
            home: Selector<AppCtrl, bool>(
              selector: (ctx, appCtx) => appCtx.isInPip,
              builder: (ctx, isInPip, _) => isInPip
                  // Floating window: only the agent visualizer fits.
                  ? const Material(child: AgentTrackView(compact: true))
                  : Center(
                      child: Container(
                        // The master phone lies on its side and uses the whole width.
                        constraints: BoxConstraints(
                          maxWidth: ctx.select<MasterCtrl, bool>((m) => m.enabled) ? double.infinity : 620,
                        ),
                        child: Stack(
                          children: [
                            // The master phone keeps its own screen during calls too:
                            // the voice effect and the call buttons are part of it.
                            Selector2<AppCtrl, MasterCtrl, (AppScreenState, bool)>(
                              selector: (ctx, appCtx, master) => (appCtx.appScreenState, master.enabled),
                              builder: (ctx, state, _) => state.$2
                                  ? const MasterScreen()
                                  : AppLayoutSwitcher(
                                      frontBuilder: (ctx) => const WelcomeScreen(),
                                      backBuilder: (ctx) => const AgentScreen(),
                                      isFront: state.$1 == AppScreenState.welcome,
                                    ),
                            ),
                            const SessionErrorBanner(),
                          ],
                        ),
                      ),
                    ),
            ),
          ),
        ),
      );
}
