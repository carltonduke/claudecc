plugins {
    id("net.neoforged.moddev.legacyforge") version "2.0.141"
}

val mcVersion: String by extra
val ccVersion: String by extra
// Captured outside legacyForge to avoid shadowing by the DSL's own forgeVersion property
val forgeVersionNumber = project.extra["forgeVersion"] as String

repositories {
    maven("https://maven.squiddev.cc") {
        name = "SquidDev"
        content { includeGroup("cc.tweaked") }
    }
}

legacyForge {
    enable {
        forgeVersion = "$mcVersion-$forgeVersionNumber"
    }

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
    modRuntimeOnly("cc.tweaked:cc-tweaked-$mcVersion-forge:$ccVersion")
}

tasks.jar {
    manifest {
        attributes(
            "Implementation-Title" to "claudecc",
            "Implementation-Version" to project.version,
        )
    }
}
