plugins {
    id("fabric-loom") version "1.16.1"
}

val mcVersion: String by extra
val fabricLoaderVersion: String by extra
val fabricApiVersion: String by extra
val ccVersion: String by extra

repositories {
    maven("https://maven.squiddev.cc") {
        name = "SquidDev"
        content { includeGroup("cc.tweaked") }
    }
    maven("https://maven.fabricmc.net")
}

dependencies {
    minecraft("com.mojang:minecraft:$mcVersion")
    mappings(loom.officialMojangMappings())
    modImplementation("net.fabricmc:fabric-loader:$fabricLoaderVersion")
    modImplementation("net.fabricmc.fabric-api:fabric-api:$fabricApiVersion")
    // Only the API jar is needed at compile time; the full mod provides it at runtime.
    modCompileOnly("cc.tweaked:cc-tweaked-$mcVersion-fabric-api:$ccVersion")
    // The full CC:Tweaked mod so it loads in dev runs (mandatory dependency).
    modRuntimeOnly("cc.tweaked:cc-tweaked-$mcVersion-fabric:$ccVersion")
}
