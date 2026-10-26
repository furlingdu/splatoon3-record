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

subprojects {
    afterEvaluate {
        val Android = extensions.findByName("android") ?: return@afterEvaluate
        val Setter = Android.javaClass.methods.firstOrNull { Method ->
            Method.name == "compileSdkVersion" && Method.parameterCount == 1 && Method.parameterTypes[0] == Int::class.javaPrimitiveType
        }
        try {
            Setter?.invoke(Android, 36)
        } catch (_: Exception) {
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
