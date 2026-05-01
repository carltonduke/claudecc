pluginManagement {
    repositories {
        gradlePluginPortal()
        maven("https://maven.minecraftforge.net")
        maven("https://maven.fabricmc.net")
    }
}

rootProject.name = "claudecc"
include("forge", "fabric")
