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
     * @param args Arg 0: JSON-encoded messages array. Arg 1 (optional): JSON-encoded tools array.
     * @throws LuaException If required arguments are missing or have the wrong type.
     */
    @LuaFunction
    public final void ask(IArguments args) throws LuaException {
        var messagesJson = args.getString(0);
        var toolsJson = args.count() > 1 ? args.getString(1) : null;

        var server = computer.getLevel().getServer();
        var keyPath = ClaudeCommand.keyPath(server);

        String apiKey;
        try {
            if (!Files.exists(keyPath)) {
                computer.queueEvent("claude_error", "No API key configured. An operator must run /claudecc api <key>.");
                return;
            }
            apiKey = Files.readString(keyPath).strip();
            if (apiKey.isEmpty()) {
                computer.queueEvent("claude_error", "API key is empty. An operator must run /claudecc api <key>.");
                return;
            }
        } catch (IOException e) {
            computer.queueEvent("claude_error", "Failed to read API key: " + e.getMessage());
            return;
        }

        var bodyBuilder = new StringBuilder();
        bodyBuilder.append("{\"model\":\"").append(MODEL)
            .append("\",\"stream\":true")
            .append(",\"max_tokens\":").append(MAX_TOKENS)
            .append(",\"messages\":").append(messagesJson);
        if (toolsJson != null) {
            bodyBuilder.append(",\"tools\":").append(toolsJson);
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
                if (response.statusCode() != 200) {
                    var body = response.body()
                        .collect(java.util.stream.Collectors.joining());
                    computer.queueEvent("claude_error",
                        "API returned status " + response.statusCode() + ": " + extractError(body));
                    return;
                }
                processStream(response.body());
            })
            .exceptionally(err -> {
                computer.queueEvent("claude_error", err.getMessage());
                return null;
            });
    }

    private void processStream(java.util.stream.Stream<String> lines) {
        var fullText   = new StringBuilder();
        var toolId     = new String[]{null};
        var toolName   = new String[]{null};
        var toolInput  = new StringBuilder();
        var stopReason = new String[]{"end_turn"};

        lines.forEach(line -> {
            if (!line.startsWith("data: ")) return;
            var data = line.substring(6).trim();
            if (data.isEmpty()) return;
            try {
                var json = JsonParser.parseString(data).getAsJsonObject();
                switch (json.get("type").getAsString()) {
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
                    }
                }
            } catch (Exception ignored) {}
        });

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
