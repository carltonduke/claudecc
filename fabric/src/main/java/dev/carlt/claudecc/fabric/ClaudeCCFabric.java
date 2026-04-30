package dev.carlt.claudecc.fabric;

import dan200.computercraft.api.ComputerCraftAPI;
import dev.carlt.claudecc.ClaudeAPI;
import dev.carlt.claudecc.ClaudeCommand;
import net.fabricmc.api.ModInitializer;
import net.fabricmc.fabric.api.command.v2.CommandRegistrationCallback;

public class ClaudeCCFabric implements ModInitializer {
    @Override
    public void onInitialize() {
        ComputerCraftAPI.registerAPIFactory(ClaudeAPI::new);
        CommandRegistrationCallback.EVENT.register((dispatcher, registryAccess, environment) ->
            ClaudeCommand.register(dispatcher));
    }
}
