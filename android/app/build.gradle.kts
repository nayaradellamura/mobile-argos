import java.util.Properties

// Assinatura de release. As credenciais ficam em android/key.properties, que
// NAO e versionado (ver .gitignore). No CI o arquivo e escrito a partir de
// secrets do repositorio.
//
// Sem esse arquivo, o build cai na chave de debug — assim quem clona consegue
// compilar, so nao produz um APK com a assinatura oficial.
//
// Por que isso importa: o Google Sign-In valida o SHA-1 da chave que assinou o
// APK contra os registrados no Firebase. Com chave de debug gerada na hora (o
// que o runner do CI faz), o SHA muda a cada build e o login Google falha com
// PlatformException(sign_in_failed, ...: 10) — DEVELOPER_ERROR.
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasReleaseKeystore = keystoreProperties.getProperty("storeFile")?.let {
    rootProject.file(it).exists()
} ?: false

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.argos_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.example.argos_app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKeystore) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (hasReleaseKeystore) {
                signingConfigs.getByName("release")
            } else {
                logger.warn(
                    "AVISO: key.properties ausente — assinando o release com a chave de " +
                    "DEBUG. O Google Sign-In vai falhar (DEVELOPER_ERROR), porque o SHA-1 " +
                    "dessa chave nao esta registrado no Firebase."
                )
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
