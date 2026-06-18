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

    /** Default system prompt used when a player hasn't set a custom one via /claudecc system_prompt. */
    public static final String DEFAULT_SYSTEM_PROMPT =
        "You are Claude, an AI assistant embedded in a CC: Tweaked computer in Minecraft. "
        + "Help the player by chatting and by using the provided tools to read and write files, "
        + "inspect the available Lua APIs and peripherals, and run programs on this computer. "
        + "Be concise and practical, prefer inspecting the system with tools over guessing, and "
        + "when you write a program consider running it to confirm it works."
        + "Minimize table output and verbosity unless explicitly asked. Be succint and brief.";

    public static Path keyPath(MinecraftServer server, UUID uuid) {
        return server.getWorldPath(LevelResource.ROOT)
            .resolve("computercraft/claude_keys/" + uuid + ".txt");
    }

    public static Path systemPromptPath(MinecraftServer server, UUID uuid) {
        return server.getWorldPath(LevelResource.ROOT)
            .resolve("computercraft/claude_prompts/" + uuid + ".txt");
    }

    /** The player's custom system prompt, or {@link #DEFAULT_SYSTEM_PROMPT} if none is set or it can't be read. */
    public static String getSystemPrompt(MinecraftServer server, UUID uuid) {
        try {
            var path = systemPromptPath(server, uuid);
            if (Files.exists(path)) {
                var s = Files.readString(path).strip();
                if (!s.isEmpty()) return s;
            }
        } catch (IOException ignored) {
            // Fall through to the default on any read failure.
        }
        return DEFAULT_SYSTEM_PROMPT;
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
                    ))))
            .then(literal("system_prompt")
                .then(literal("clear")
                    .executes(ctx -> clearSystemPrompt(ctx.getSource())))
                .then(literal("show")
                    .executes(ctx -> showSystemPrompt(ctx.getSource())))
                .then(argument("prompt", StringArgumentType.greedyString())
                    .executes(ctx -> setSystemPrompt(
                        ctx.getSource(),
                        StringArgumentType.getString(ctx, "prompt")
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

    private static int setSystemPrompt(CommandSourceStack source, String prompt) {
        var player = source.getPlayer();
        if (player == null) {
            source.sendFailure(Component.literal("/claudecc system_prompt must be run by a player."));
            return 0;
        }
        // Allow the player to wrap the prompt in a matching pair of quotes.
        if (prompt.length() >= 2) {
            char first = prompt.charAt(0), last = prompt.charAt(prompt.length() - 1);
            if ((first == '\'' || first == '"') && first == last) {
                prompt = prompt.substring(1, prompt.length() - 1);
            }
        }
        try {
            var path = systemPromptPath(source.getServer(), player.getUUID());
            Files.createDirectories(path.getParent());
            Files.writeString(path, prompt);
            source.sendSuccess(() -> Component.literal(
                "Custom system prompt saved; it applies to your next message. "
                + "(Run /claudecc system_prompt clear to restore the default.)"), false);
            return 1;
        } catch (IOException e) {
            source.sendFailure(Component.literal("Failed to save system prompt: " + e.getMessage()));
            return 0;
        }
    }

    private static int clearSystemPrompt(CommandSourceStack source) {
        var player = source.getPlayer();
        if (player == null) {
            source.sendFailure(Component.literal("/claudecc system_prompt clear must be run by a player."));
            return 0;
        }
        try {
            var existed = Files.deleteIfExists(systemPromptPath(source.getServer(), player.getUUID()));
            source.sendSuccess(() -> Component.literal(
                existed ? "Custom system prompt removed; using the default."
                        : "No custom system prompt was set."), false);
            return 1;
        } catch (IOException e) {
            source.sendFailure(Component.literal("Failed to remove system prompt: " + e.getMessage()));
            return 0;
        }
    }

    private static int showSystemPrompt(CommandSourceStack source) {
        var player = source.getPlayer();
        if (player == null) {
            source.sendFailure(Component.literal("/claudecc system_prompt show must be run by a player."));
            return 0;
        }
        var custom = Files.exists(systemPromptPath(source.getServer(), player.getUUID()));
        var prompt = getSystemPrompt(source.getServer(), player.getUUID());
        source.sendSuccess(() -> Component.literal(
            (custom ? "Your custom system prompt:\n" : "Default system prompt (no custom set):\n")
            + prompt
            + "\n(The computer's live environment context is appended automatically.)"), false);
        return 1;
    }
}
