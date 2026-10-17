// Android 应用配置（适配 Flutter 3.47 / AGP 9 的 Kotlin DSL）
//
// 若需让 Flutter 重新生成这一层壳，可运行 scripts\02-apply-android-config.ps1：
// 它会先备份下面这些自定义文件，再调用 flutter create，最后还原回来。

plugins {
    id("com.android.application")
    // Flutter Gradle 插件必须放在 Android / Kotlin 插件之后
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.timetable_app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.timetable_app"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // 自用场景：先用调试签名，方便直接安装
            signingConfig = signingConfigs.getByName("debug")
            // 说明：此处刻意关闭代码压缩与资源压缩。
            // 原因：google_mlkit_text_recognition 的公共接口引用了多个语种识别器
            // （中文/日文/韩文/梵文），未引入的语种会让 R8 报「Missing classes」而中断构建。
            // 自用装机场景下体积不是问题，换来的是构建稳定、无混淆坑。
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // ML Kit 中文识别模型
    //
    // 为什么必须显式声明：google_mlkit_text_recognition 插件把各语种模型
    // 声明为 compileOnly（由使用方自行提供）。若不声明，APK 里只会打包
    // 拉丁语系模型（Latn_ctc），中文课程名一个字都认不出来。
    // 这里选 bundled 版，模型随 APK 分发，完全离线可用。
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
}
