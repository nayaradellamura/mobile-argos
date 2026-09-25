allprojects {
    repositories {
        google()
        mavenCentral()
    }

    // Sem isso, o Gradle resolve com "versao mais alta vence" entre tudo que
    // pede com.google.android.gms:play-services-auth (google_sign_in_android
    // pede exatamente 21.0.0, mas outro plugin pode puxar uma mais nova e
    // ganhar a resolucao). A Google publica versoes novas dessa lib com
    // frequencia, entao sem travar aqui o binario nativo muda silenciosamente
    // entre builds — foi exatamente isso que fez o Shorebird recusar um patch
    // por "mudanca de codigo nativo" mesmo sem nenhuma mudanca de codigo real.
    configurations.all {
        resolutionStrategy {
            force("com.google.android.gms:play-services-auth:21.0.0")
        }
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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
