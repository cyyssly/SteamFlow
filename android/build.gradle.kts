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
subprojects {
    project.evaluationDependsOn(":app")
}

// 统一把各模块（含插件模块）的 compileSdk 提升到 36：
// 有些插件自带的 compileSdk 低于其依赖（flutter_plugin_android_lifecycle）要求的 36，
// AGP 会在 checkReleaseAarMetadata 阶段直接报错并中断构建。
// AGP 9 的 android 扩展类型无法在根脚本中静态引用，故通过反射调用其 setter。
val targetCompileSdkVersion = "android-36"
subprojects {
    val applyCompileSdk = {
        val androidExt = project.extensions.findByName("android")
        if (androidExt != null) {
            val setters = listOf<Pair<String, Array<Any>>>(
                "setCompileSdkVersion" to arrayOf<Any>(targetCompileSdkVersion),
                "setCompileSdk" to arrayOf<Any>(36),
            )
            var applied = false
            for ((methodName, args) in setters) {
                if (applied) break
                applied = runCatching {
                    androidExt.javaClass
                        .getMethod(methodName, *args.map { it.javaClass }.toTypedArray())
                        .invoke(androidExt, *args)
                }.isSuccess
            }
            if (applied) {
                logger.lifecycle("SteamFlow: ${project.name} -> compileSdk $targetCompileSdkVersion")
            } else {
                logger.lifecycle("SteamFlow: ${project.name} 的 compileSdk 未能调整，沿用其自身设置")
            }
        }
    }
    // :app 已被上面的 evaluationDependsOn 提前求值，不能再注册 afterEvaluate。
    if (state.executed) applyCompileSdk() else afterEvaluate { applyCompileSdk() }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
