package dev.carlt.claudecc.forge;

import dan200.computercraft.api.ComputerCraftAPI;
import dev.carlt.claudecc.ClaudeAPI;
import dev.carlt.claudecc.ClaudeCommand;
import net.minecraftforge.event.RegisterCommandsEvent;
import net.minecraftforge.eventbus.api.SubscribeEvent;
import net.minecraftforge.fml.common.Mod;

@Mod("claudecc")
@Mod.EventBusSubscriber
public class ClaudeCCForge {
    public ClaudeCCForge() {
        ComputerCraftAPI.registerAPIFactory(ClaudeAPI::new);
    }

    @SubscribeEvent
    public static void onRegisterCommands(RegisterCommandsEvent event) {
        ClaudeCommand.register(event.getDispatcher());
    }
}
