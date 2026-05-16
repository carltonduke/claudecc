package dev.carlt.claudecc.forge;

import dan200.computercraft.api.ComputerCraftAPI;
import dev.carlt.claudecc.ClaudeAPI;
import dev.carlt.claudecc.ClaudeCommand;
import net.neoforged.bus.api.IEventBus;
import net.neoforged.fml.common.Mod;
import net.neoforged.neoforge.common.NeoForge;
import net.neoforged.neoforge.event.RegisterCommandsEvent;

@Mod("claudecc")
public class ClaudeCCForge {
    public ClaudeCCForge(IEventBus modBus) {
        ComputerCraftAPI.registerAPIFactory(ClaudeAPI::new);
        NeoForge.EVENT_BUS.addListener(ClaudeCCForge::onRegisterCommands);
    }

    private static void onRegisterCommands(RegisterCommandsEvent event) {
        ClaudeCommand.register(event.getDispatcher());
    }
}
