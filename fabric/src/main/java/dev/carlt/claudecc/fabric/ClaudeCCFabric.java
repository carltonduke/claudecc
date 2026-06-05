package dev.carlt.claudecc.fabric;

import dan200.computercraft.api.ComputerCraftAPI;
import dev.carlt.claudecc.ActiveUserTracker;
import dev.carlt.claudecc.ClaudeAPI;
import dev.carlt.claudecc.ClaudeCommand;
import net.fabricmc.api.ModInitializer;
import net.fabricmc.fabric.api.command.v2.CommandRegistrationCallback;
import net.fabricmc.fabric.api.event.player.UseBlockCallback;
import net.fabricmc.fabric.api.networking.v1.ServerPlayConnectionEvents;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.world.InteractionResult;

public class ClaudeCCFabric implements ModInitializer {
    @Override
    public void onInitialize() {
        ComputerCraftAPI.registerAPIFactory(ClaudeAPI::new);
        CommandRegistrationCallback.EVENT.register((dispatcher, registryAccess, environment) ->
            ClaudeCommand.register(dispatcher));
        UseBlockCallback.EVENT.register((player, world, hand, hit) -> {
            if (!world.isClientSide && player instanceof ServerPlayer sp) {
                var be = world.getBlockEntity(hit.getBlockPos());
                var id = ActiveUserTracker.extractComputerId(be);
                if (id >= 0) {
                    ActiveUserTracker.setActive(id, sp.getUUID());
                }
            }
            return InteractionResult.PASS;
        });
        ServerPlayConnectionEvents.DISCONNECT.register((handler, server) ->
            ActiveUserTracker.clearForPlayer(handler.player.getUUID()));
    }
}
