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
            .append("\",\"max_tokens\":").append(MAX_TOKENS)
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

        HTTP_CLIENT.sendAsync(request, HttpResponse.BodyHandlers.ofString()).whenComplete((response, err) -> {
            if (err != null) {
                computer.queueEvent("claude_error", err.getMessage());
                return;
            }
            if (response.statusCode() != 200) {
                computer.queueEvent("claude_error", "API returned status " + response.statusCode() + ": " + extractError(response.body()));
                return;
            }
            try {
                var json = JsonParser.parseString(response.body()).getAsJsonObject();
                var stopReason = json.get("stop_reason").getAsString();
                var contentArray = json.getAsJsonArray("content");

                var textBuilder = new StringBuilder();
                String toolUseId = null, toolUseName = null, toolUseInput = null;

                for (var element : contentArray) {
                    var item = element.getAsJsonObject();
                    var type = item.get("type").getAsString();
                    if ("text".equals(type)) {
                        textBuilder.append(item.get("text").getAsString());
                    } else if ("tool_use".equals(type) && toolUseId == null) {
                        toolUseId = item.get("id").getAsString();
                        toolUseName = item.get("name").getAsString();
                        toolUseInput = item.get("input").toString();
                    }
                }

                if ("tool_use".equals(stopReason) && toolUseId != null) {
                    computer.queueEvent("claude_tool_use",
                        textBuilder.toString(), toolUseId, toolUseName, toolUseInput);
                } else {
                    computer.queueEvent("claude_response", textBuilder.toString());
                }
            } catch (Exception e) {
                computer.queueEvent("claude_error", "Failed to parse response: " + e.getMessage());
            }
        });
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
