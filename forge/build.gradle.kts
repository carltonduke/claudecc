plugins {
    id("net.neoforged.moddev") version "2.0.141"
}

val mcVersion: String by extra
val ccVersion: String by extra
val neoforgeVersion: String by extra

base {
    archivesName = "claudecc-forge"
}

repositories {
    maven("https://maven.squiddev.cc") {
        name = "SquidDev"
        content { includeGroup("cc.tweaked") }
    }
}

neoForge {
    version = neoforgeVersion

    val claudecc by mods.registering {
        sourceSet(sourceSets["main"])
    }

    runs {
        configureEach {
            loadedMods.add(claudecc)
        }
        create("client") {
            client()
            gameDirectory = project.file("run")
        }
        create("server") {
            server()
            gameDirectory = project.file("run/server")
        }
    }
}

dependencies {
    compileOnly("cc.tweaked:cc-tweaked-$mcVersion-common-api:$ccVersion")
    // The full CC:Tweaked mod (NeoForge build). It carries neoforge.mods.toml, so
    // ModDevGradle detects it as a mod and FML loads it in dev runs — satisfying the
    // mandatory computercraft dependency. (compileOnly above keeps the jar API-only.)
    runtimeOnly("cc.tweaked:cc-tweaked-$mcVersion-forge:$ccVersion")
}

tasks.jar {
    manifest {
        attributes(
            "Implementation-Title" to "claudecc",
            "Implementation-Version" to project.version,
        )
    }
}
