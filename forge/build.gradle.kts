plugins {
    id("net.minecraftforge.gradle") version "[6.0,6.2)"
}

val mcVersion: String by extra
val forgeVersion: String by extra
val ccVersion: String by extra

repositories {
    maven("https://maven.squiddev.cc") {
        name = "SquidDev"
        content { includeGroup("cc.tweaked") }
    }
}

minecraft {
    mappings("official", mcVersion)

    runs {
        create("client") {
            workingDirectory(project.file("run"))
            mods { create("claudecc") { source(sourceSets["main"]) } }
        }
        create("server") {
            workingDirectory(project.file("run/server"))
            mods { create("claudecc") { source(sourceSets["main"]) } }
        }
    }
}

dependencies {
    minecraft("net.minecraftforge:forge:$mcVersion-$forgeVersion")
    // Only the API jar is needed at compile time; the full mod provides it at runtime.
    compileOnly(fg.deobf("cc.tweaked:cc-tweaked-$mcVersion-common-api:$ccVersion"))
}

tasks.jar {
    manifest {
        attributes(
            "Implementation-Title" to "claudecc",
            "Implementation-Version" to project.version,
        )
    }
}
