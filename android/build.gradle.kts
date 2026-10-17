// 根构建脚本
//
// 注意：这里有一步「统一抬高 compileSdk」的处理。
// 原因：部分社区插件（file_picker、share_plus、permission_handler 等）
// 在自己的 android/build.gradle 里把 compileSdk 写死为 34，
// 而 Flutter 3.47 所需的依赖要求至少 36，会直接导致
// 「checkDebugAarMetadata」失败。这里在子工程评估完成后统一覆盖。
//
// 顺序很关键：注册 afterEvaluate 的块必须放在 evaluationDependsOn 之前，
// 否则子工程 already evaluated，注册会直接抛异常。

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

// 统一把插件工程的 compileSdk 抬到 36
subprojects {
    afterEvaluate {
        if (plugins.hasPlugin("com.android.library") ||
            plugins.hasPlugin("com.android.application")
        ) {
            val androidExt = extensions.findByName("android")
            if (androidExt != null) {
                runCatching {
                    val cls = androidExt.javaClass
                    val setter = cls.getMethod("setCompileSdk", Int::class.javaPrimitiveType)
                    setter.invoke(androidExt, 36)
                }.onFailure {
                    logger.lifecycle(
                        "[compileSdk-fix] ${name} 覆盖 compileSdk 失败：${it.message}"
                    )
                }
            }
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
