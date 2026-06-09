package dev.carlt.claudecc;

import com.mojang.brigadier.CommandDispatcher;
import com.mojang.brigadier.arguments.StringArgumentType;
import dev.carlt.claudecc.forge.ClaudeCCForge;
import net.minecraft.commands.CommandSourceStack;
import net.minecraft.network.chat.Component;
import net.minecraft.server.MinecraftServer;
import net.minecraft.world.level.storage.LevelResource;
import net.neoforged.neoforge.server.permission.PermissionAPI;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.UUID;

import static net.minecraft.commands.Commands.argument;
import static net.minecraft.commands.Commands.literal;

public final class ClaudeCommand {
    private ClaudeCommand() {}

    public static Path keyPath(MinecraftServer server, UUID uuid) {
        return server.getWorldPath(LevelResource.ROOT)
            .resolve("computercraft/claude_keys/" + uuid + ".txt");
    }

    public static void register(CommandDispatcher<CommandSourceStack> dispatcher) {
        dispatcher.register(literal("claudecc")
            .requires(ClaudeCommand::canUse)
            .then(literal("api")
                .then(literal("clear")
                    .executes(ctx -> clearApiKey(ctx.getSource())))
                .then(argument("key", StringArgumentType.greedyString())
                    .executes(ctx -> setApiKey(
                        ctx.getSource(),
                        StringArgumentType.getString(ctx, "key")
                    )))));
    }

    private static boolean canUse(CommandSourceStack source) {
        var player = source.getPlayer();
        if (player == null) return source.hasPermission(2);
        return PermissionAPI.getPermission(player, ClaudeCCForge.PERM_USE);
    }

    private static int setApiKey(CommandSourceStack source, String key) {
        var player = source.getPlayer();
        if (player == null) {
            source.sendFailure(Component.literal(
                "/claudecc api must be run by a player so the key can be associated with your account."));
            return 0;
        }
        try {
            var path = keyPath(source.getServer(), player.getUUID());
            Files.createDirectories(path.getParent());
            Files.writeString(path, key);
            var name = player.getName().getString();
            source.sendSuccess(() -> Component.literal("Claude API key saved for " + name + "."), false);
            source.sendSuccess(() -> Component.literal(
                "⚠ This key is stored on the server and may appear in server logs. "
                + "Only use on servers you trust, and consider setting a low spend limit on your Anthropic key. "
                + "(Run /claudecc api clear to remove it.)"), false);
            return 1;
        } catch (IOException e) {
            source.sendFailure(Component.literal("Failed to save API key: " + e.getMessage()));
            return 0;
        }
    }

    private static int clearApiKey(CommandSourceStack source) {
        var player = source.getPlayer();
        if (player == null) {
            source.sendFailure(Component.literal(
                "/claudecc api clear must be run by a player."));
            return 0;
        }
        try {
            var existed = Files.deleteIfExists(keyPath(source.getServer(), player.getUUID()));
            source.sendSuccess(() -> Component.literal(
                existed ? "Claude API key removed." : "No API key was set."), false);
            return 1;
        } catch (IOException e) {
            source.sendFailure(Component.literal("Failed to remove API key: " + e.getMessage()));
            return 0;
        }
    }
}
