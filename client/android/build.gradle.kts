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
// 统一强制所有 Android 子模块 compileSdk = 36（AGP 9 时代新插件要求）
// 必须在 evaluationDependsOn(":app") 之前注册 afterEvaluate，否则项目已评估会报错。
subprojects {
    afterEvaluate {
        extensions.findByName("android")?.let { ext ->
            (ext as com.android.build.gradle.BaseExtension).compileSdkVersion(36)
        }
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
