import java.util.Properties
import java.util.Base64

plugins {
    id("com.android.application")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.chaquo.python")
}

chaquopy {
    defaultConfig {
        version = "3.11"
        // CI 上由 workflow 注入 CHAQUOPY_BUILD_PYTHON；本地不设时沿用 Chaquopy 自动探测
        System.getenv("CHAQUOPY_BUILD_PYTHON")?.takeIf { it.isNotBlank() }?.let { buildPython(it) }
        pip {
            install("requests")
            install("pycryptodome")
            install("beautifulsoup4")
            install("lxml")
            install("pyquery")
            install("cloudscraper")
            install("websocket-client")
            install("httpx")
        }
    }
}

val dartDefines = providers.gradleProperty("dart-defines").orNull.orEmpty()
    .split(",").filter { it.isNotEmpty() }
    .associate {
        val decoded = String(Base64.getDecoder().decode(it), Charsets.UTF_8)
        decoded.substringBefore("=") to decoded.substringAfter("=", "")
    }
val allSources = dartDefines["ALL_SOURCES"] == "true"

val releaseKey = file("/home/hatch/workspace/moyi/signing/key.properties")
    .takeIf { it.exists() } ?: rootProject.file("key.properties")
val releaseProperties = Properties()
if (releaseKey.exists()) {
    releaseKey.inputStream().use { releaseProperties.load(it) }
}

android {
    namespace = "moyi"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "28.2.13676358"

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.moyi.box"
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk {
            abiFilters.clear()
            abiFilters.addAll(listOf("arm64-v8a"))
        }
        manifestPlaceholders["appLabel"] = "魔蚁box"
        manifestPlaceholders["appBanner"] = if (allSources) "@drawable/tv_banner_all_sources" else "@drawable/tv_banner"
    }

    signingConfigs {
        if (releaseKey.exists()) {
            create("release") {
                storeFile = file(requireNotNull(releaseProperties.getProperty("storeFile")))
                storePassword = requireNotNull(releaseProperties.getProperty("storePassword"))
                keyAlias = requireNotNull(releaseProperties.getProperty("keyAlias"))
                keyPassword = requireNotNull(releaseProperties.getProperty("keyPassword"))
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
            ndk {
                abiFilters.clear()
                abiFilters.addAll(listOf("arm64-v8a"))
            }
        }
        release {
            signingConfig = signingConfigs.getByName(if (releaseKey.exists()) "release" else "debug")
            isMinifyEnabled = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            ndk {
                abiFilters.clear()
                abiFilters.addAll(listOf("arm64-v8a"))
            }
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    packaging {
        jniLibs {
            useLegacyPackaging = true
            pickFirsts += "lib/arm64-v8a/libc++_shared.so"
            pickFirsts += "lib/armeabi-v7a/libc++_shared.so"
            pickFirsts += "lib/x86/libc++_shared.so"
            pickFirsts += "lib/x86_64/libc++_shared.so"
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.google.code.gson:gson:2.11.0")
    implementation("org.jsoup:jsoup:1.18.1")
    implementation("androidx.core:core:1.13.1")
    implementation("androidx.media3:media3-exoplayer:1.4.1")
    implementation("androidx.media3:media3-exoplayer-hls:1.4.1")
    implementation("androidx.media3:media3-ui:1.4.1")
    implementation("tv.danmaku.ijk.media:ijkplayer-java:0.8.8")
    implementation("tv.danmaku.ijk.media:ijkplayer-armv7a:0.8.8")
    implementation("tv.danmaku.ijk.media:ijkplayer-arm64:0.8.8")
    implementation(name = "thunder-release", ext = "aar")
    testImplementation("junit:junit:4.13.2")
}

repositories {
    flatDir { dirs("libs") }
    maven { url = uri("https://maven.aliyun.com/repository/jcenter") }
}

flutter { source = "../.." }

tasks.withType<JavaCompile>().configureEach {
    if (name.contains("Release")) {
        doFirst {
            val registrant = file("src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java")
            if (registrant.exists()) {
                val generated = registrant.readText()
                val integrationPlugin = Regex(
                    """(?s)    try \{\s*flutterEngine\.getPlugins\(\)\.add\(new dev\.flutter\.plugins\.integration_test\.IntegrationTestPlugin\(\)\);\s*\} catch \(Exception e\) \{[^}]*\}\s*"""
                )
                val release = generated.replace(integrationPlugin, "")
                if (release != generated) registrant.writeText(release)
            }
        }
    }
}
