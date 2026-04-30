package dev.carlt.claudecc;

import com.mojang.brigadier.CommandDispatcher;
import com.mojang.brigadier.arguments.StringArgumentType;
import net.minecraft.commands.CommandSourceStack;
import net.minecraft.network.chat.Component;
import net.minecraft.server.MinecraftServer;
import net.minecraft.world.level.storage.LevelResource;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static net.minecraft.commands.Commands.argument;
import static net.minecraft.commands.Commands.literal;

public final class ClaudeCommand {
    private ClaudeCommand() {}

    public static Path keyPath(MinecraftServer server) {
        return server.getWorldPath(LevelResource.ROOT).resolve("computercraft/claude_api_key");
    }

    public static void register(CommandDispatcher<CommandSourceStack> dispatcher) {
        dispatcher.register(literal("claudecc")
            .requires(src -> src.hasPermission(2))
            .then(literal("api")
                .then(argument("key", StringArgumentType.greedyString())
                    .executes(ctx -> setApiKey(
                        ctx.getSource(),
                        StringArgumentType.getString(ctx, "key")
                    )))));
    }

    private static int setApiKey(CommandSourceStack source, String key) {
        try {
            var path = keyPath(source.getServer());
            Files.createDirectories(path.getParent());
            Files.writeString(path, key);
            source.sendSuccess(() -> Component.literal("Claude API key saved."), false);
            return 1;
        } catch (IOException e) {
            source.sendFailure(Component.literal("Failed to save API key: " + e.getMessage()));
            return 0;
        }
    }
}
