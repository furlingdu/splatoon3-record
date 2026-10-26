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
    afterEvaluate {
        val Android = extensions.findByName("android") ?: return@afterEvaluate
        val Candidates = listOf(
            "compileSdkVersion" to Int::class.javaPrimitiveType,
            "setCompileSdk" to Int::class.javaPrimitiveType,
            "setCompileSdk" to Int::class.javaObjectType,
            "setCompileSdkVersion" to String::class.java
        )
        for ((Name, Type) in Candidates) {
            val Setter = Android.javaClass.methods.firstOrNull { Method ->
                Method.name == Name && Method.parameterCount == 1 && Method.parameterTypes[0] == Type
            } ?: continue
            try {
                Setter.invoke(Android, if (Type == String::class.java) "36" else 36)
                break
            } catch (_: Exception) {
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
