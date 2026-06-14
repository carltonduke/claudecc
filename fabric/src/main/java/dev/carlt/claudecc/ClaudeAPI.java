package dev.carlt.claudecc;

import com.google.gson.JsonParser;
import dan200.computercraft.api.lua.IArguments;
import dan200.computercraft.api.lua.IComputerSystem;
import dan200.computercraft.api.lua.ILuaAPI;
import dan200.computercraft.api.lua.LuaException;
import dan200.computercraft.api.lua.LuaFunction;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.file.Files;

public class ClaudeAPI implements ILuaAPI {
    private static final HttpClient HTTP_CLIENT = HttpClient.newHttpClient();
    private static final String API_URL = "https://api.anthropic.com/v1/messages";
    private static final String MODEL = "claude-sonnet-4-6";
    private static final int MAX_TOKENS = 8192;

    private final IComputerSystem computer;

    public ClaudeAPI(IComputerSystem computer) {
        this.computer = computer;
    }

    @Override
    public String[] getNames() {
        return new String[]{ "claudecc" };
    }

    /**
     * Send a list of messages to Claude and receive a response via an event.
     * <p>
     * On a plain text response, a {@code claude_response} event is queued with the response text as the second
     * parameter.
     * <p>
     * When Claude requests a tool call, a {@code claude_tool_use} event is queued with four parameters:
     * <ol>
     *   <li>Any text Claude emitted before the tool call (may be empty)</li>
     *   <li>The tool_use id (needed when sending the result back)</li>
     *   <li>The tool name</li>
     *   <li>The tool input as a JSON string</li>
     * </ol>
     * <p>
     * On failure a {@code claude_error} event is queued with an error message as the second parameter.
     *
     * @param args Arg 0: JSON-encoded messages array. Arg 1 (optional): JSON-encoded tools array (may be
     *             nil). Arg 2 (optional): live environment context, appended after the active player's
     *             resolved system prompt (their custom one or the default).
     * @throws LuaException If required arguments are missing or have the wrong type.
     */
    @LuaFunction
    public final void ask(IArguments args) throws LuaException {
        var messagesJson = args.getString(0);
        var toolsJson = args.count() > 1 && args.get(1) instanceof String t ? t : null;
        var envContext = args.count() > 2 && args.get(2) instanceof String s ? s : null;

        var server = computer.getLevel().getServer();
        var activeUuid = ActiveUserTracker.getActive(computer.getID()).orElse(null);
        if (activeUuid == null) {
            computer.queueEvent("claude_error",
                "No active player on this computer. Right-click it to claim it before running Claude.");
            return;
        }
        var keyPath = ClaudeCommand.keyPath(server, activeUuid);

        String apiKey;
        try {
            if (!Files.exists(keyPath)) {
                computer.queueEvent("claude_error", "Your API key isn't set. Run /claudecc api <key> to set it.");
                return;
            }
            apiKey = Files.readString(keyPath).strip();
            if (apiKey.isEmpty()) {
                computer.queueEvent("claude_error", "Your API key is empty. Run /claudecc api <key> to set it.");
                return;
            }
        } catch (IOException e) {
            computer.queueEvent("claude_error", "Failed to read API key: " + e.getMessage());
            return;
        }

        // Resolve the system prompt: the active player's custom prompt (or the default), then the
        // live environment context the Lua side supplied as arg 2.
        var systemPrompt = ClaudeCommand.getSystemPrompt(server, activeUuid);
        if (envContext != null && !envContext.isEmpty()) {
            systemPrompt = systemPrompt + "\n\n" + envContext;
        }

        var bodyBuilder = new StringBuilder();
        bodyBuilder.append("{\"model\":\"").append(MODEL)
            .append("\",\"stream\":true")
            .append(",\"max_tokens\":").append(MAX_TOKENS)
            .append(",\"messages\":").append(messagesJson);
        if (toolsJson != null) {
            bodyBuilder.append(",\"tools\":").append(toolsJson);
        }
        if (!systemPrompt.isEmpty()) {
            bodyBuilder.append(",\"system\":").append(new com.google.gson.JsonPrimitive(systemPrompt));
        }
        bodyBuilder.append("}");

        var request = HttpRequest.newBuilder()
            .uri(URI.create(API_URL))
            .header("x-api-key", apiKey)
            .header("anthropic-version", "2023-06-01")
            .header("content-type", "application/json")
            .POST(HttpRequest.BodyPublishers.ofString(bodyBuilder.toString()))
            .build();

        HTTP_CLIENT.sendAsync(request, HttpResponse.BodyHandlers.ofLines())
            .thenAccept(response -> {
                var remaining = response.headers()
                    .firstValue("anthropic-ratelimit-input-tokens-remaining")
                    .map(Integer::parseInt).orElse(-1);

                if (response.statusCode() != 200) {
                    var body = response.body()
                        .collect(java.util.stream.Collectors.joining());
                    if (remaining >= 0) {
                        computer.queueEvent("claude_ratelimit", remaining);
                    }
                    var msg = "API returned status " + response.statusCode() + ": " + extractError(body);
                    if (response.statusCode() == 429) {
                        var retryAfter = response.headers().firstValue("retry-after").orElse(null);
                        if (retryAfter != null) {
                            msg += "  (retry-after " + retryAfter + "s, " + remaining + " input tokens left)";
                        }
                    }
                    computer.queueEvent("claude_error", msg);
                    return;
                }
                processStream(response.body(), remaining);
            })
            .exceptionally(err -> {
                computer.queueEvent("claude_error", err.getMessage());
                return null;
            });
    }

    private void processStream(java.util.stream.Stream<String> lines, int ratelimitRemaining) {
        var fullText     = new StringBuilder();
        var toolId       = new String[]{null};
        var toolName     = new String[]{null};
        var toolInput    = new StringBuilder();
        var stopReason   = new String[]{"end_turn"};
        var inputTokens  = new int[]{0};
        var outputTokens = new int[]{0};

        lines.forEach(line -> {
            if (!line.startsWith("data: ")) return;
            var data = line.substring(6).trim();
            if (data.isEmpty()) return;
            try {
                var json = JsonParser.parseString(data).getAsJsonObject();
                switch (json.get("type").getAsString()) {
                    case "message_start" -> {
                        var msg = json.getAsJsonObject("message");
                        if (msg.has("usage")) {
                            var u = msg.getAsJsonObject("usage");
                            if (u.has("input_tokens")) inputTokens[0] = u.get("input_tokens").getAsInt();
                        }
                    }
                    case "content_block_start" -> {
                        var block = json.getAsJsonObject("content_block");
                        if ("tool_use".equals(block.get("type").getAsString())) {
                            toolId[0]   = block.get("id").getAsString();
                            toolName[0] = block.get("name").getAsString();
                            toolInput.setLength(0);  // reset for each new tool block
                        }
                    }
                    case "content_block_delta" -> {
                        var delta     = json.getAsJsonObject("delta");
                        var deltaType = delta.get("type").getAsString();
                        if ("text_delta".equals(deltaType)) {
                            var text = delta.get("text").getAsString();
                            fullText.append(text);
                            if (!text.isEmpty()) computer.queueEvent("claude_chunk", text);
                        } else if ("input_json_delta".equals(deltaType)) {
                            toolInput.append(delta.get("partial_json").getAsString());
                        }
                    }
                    case "message_delta" -> {
                        var d = json.getAsJsonObject("delta");
                        if (d.has("stop_reason") && !d.get("stop_reason").isJsonNull())
                            stopReason[0] = d.get("stop_reason").getAsString();
                        if (json.has("usage")) {
                            var u = json.getAsJsonObject("usage");
                            if (u.has("output_tokens")) outputTokens[0] = u.get("output_tokens").getAsInt();
                        }
                    }
                }
            } catch (Exception ignored) {}
        });

        computer.queueEvent("claude_usage", inputTokens[0], outputTokens[0], ratelimitRemaining);

        if ("tool_use".equals(stopReason[0]) && toolId[0] != null) {
            computer.queueEvent("claude_tool_use",
                fullText.toString(), toolId[0], toolName[0], toolInput.toString());
        } else {
            computer.queueEvent("claude_response", fullText.toString());
        }
    }

    /**
     * Copy text to the system clipboard. Only works in single-player (requires a local desktop); silently
     * does nothing on dedicated servers.
     *
     * @param text The text to copy.
     */
    @LuaFunction
    public final void copyToClipboard(String text) {
        try {
            var sel = new java.awt.datatransfer.StringSelection(text);
            java.awt.Toolkit.getDefaultToolkit().getSystemClipboard().setContents(sel, null);
        } catch (Exception e) {
            // Headless server or AWT unavailable — silently ignore.
        }
    }

    private static String extractError(String body) {
        try {
            var json = JsonParser.parseString(body).getAsJsonObject();
            if (json.has("error")) {
                return json.getAsJsonObject("error").get("message").getAsString();
            }
            return body;
        } catch (Exception e) {
            return body;
        }
    }
}
