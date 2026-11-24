# shared_preferences_android 2.5 calls its Kotlin API from Dart through JNI and
# ships no keep rules: without these, R8 removes SharedPreferencesApiRegistrar's
# methods in release builds and every SharedPreferences call fails at runtime
# (NoSuchMethodError ... SharedPreferencesApiRegistrar.getAll).
# JNI also looks up parameter types by name. Keeping just the registrar still
# lets R8 rename kotlin.coroutines.Continuation, changing getAll's descriptor.
-keep,includedescriptorclasses class io.flutter.plugins.sharedpreferences.** { *; }

# package:jni resolves Kotlin suspend-result helpers by literal class/member
# names too (jni/lib/src/kotlin.dart); its consumer rules only keep JNI classes.
-keep class kotlin.coroutines.Continuation { *; }
-keep class kotlin.coroutines.intrinsics.** { *; }
-keep class kotlin.Result { *; }
-keep class kotlin.Result$Failure { *; }
-keep class kotlin.Unit { *; }
