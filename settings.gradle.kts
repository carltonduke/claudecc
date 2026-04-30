pluginManagement {
    repositories {
        gradlePluginPortal()
        maven("https://maven.minecraftforge.net")
        maven("https://maven.fabricmc.net")
    }
}

rootProject.name = "claudecc-addon"
include("forge", "fabric")
