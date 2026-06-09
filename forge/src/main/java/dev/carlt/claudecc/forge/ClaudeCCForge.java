package dev.carlt.claudecc.forge;

import dan200.computercraft.api.ComputerCraftAPI;
import dev.carlt.claudecc.ActiveUserTracker;
import dev.carlt.claudecc.ClaudeAPI;
import dev.carlt.claudecc.ClaudeCommand;
import net.minecraft.resources.ResourceLocation;
import net.neoforged.bus.api.IEventBus;
import net.neoforged.fml.common.Mod;
import net.neoforged.neoforge.common.NeoForge;
import net.neoforged.neoforge.event.RegisterCommandsEvent;
import net.neoforged.neoforge.event.entity.player.PlayerEvent;
import net.neoforged.neoforge.event.entity.player.PlayerInteractEvent;
import net.neoforged.neoforge.server.permission.events.PermissionGatherEvent;
import net.neoforged.neoforge.server.permission.nodes.PermissionNode;
import net.neoforged.neoforge.server.permission.nodes.PermissionTypes;

@Mod("claudecc")
public class ClaudeCCForge {
    public static final PermissionNode<Boolean> PERM_USE = new PermissionNode<>(
        ResourceLocation.fromNamespaceAndPath("claudecc", "use"),
        PermissionTypes.BOOLEAN,
        (player, uuid, context) -> player != null && player.hasPermissions(2)
    );

    public ClaudeCCForge(IEventBus modBus) {
        ComputerCraftAPI.registerAPIFactory(ClaudeAPI::new);
        NeoForge.EVENT_BUS.addListener(ClaudeCCForge::onRegisterCommands);
        NeoForge.EVENT_BUS.addListener(ClaudeCCForge::onPermissionGather);
        NeoForge.EVENT_BUS.addListener(ClaudeCCForge::onRightClick);
        NeoForge.EVENT_BUS.addListener(ClaudeCCForge::onPlayerLeave);
    }

    private static void onRegisterCommands(RegisterCommandsEvent event) {
        ClaudeCommand.register(event.getDispatcher());
    }

    private static void onPermissionGather(PermissionGatherEvent.Nodes event) {
        event.addNodes(PERM_USE);
    }

    private static void onRightClick(PlayerInteractEvent.RightClickBlock event) {
        if (event.getLevel().isClientSide) return;
        var be = event.getLevel().getBlockEntity(event.getPos());
        var id = ActiveUserTracker.extractComputerId(be);
        if (id >= 0) {
            ActiveUserTracker.setActive(id, event.getEntity().getUUID());
        }
    }

    private static void onPlayerLeave(PlayerEvent.PlayerLoggedOutEvent event) {
        ActiveUserTracker.clearForPlayer(event.getEntity().getUUID());
    }
}
