package dev.carlt.claudecc;

import net.minecraft.world.level.block.entity.BlockEntity;

import java.lang.reflect.Method;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

public final class ActiveUserTracker {
    private static final Map<Integer, UUID> ACTIVE = new ConcurrentHashMap<>();

    private static volatile Method getComputerIdMethod;
    private static volatile boolean reflectionFailed;

    private ActiveUserTracker() {}

    public static void setActive(int computerId, UUID uuid) {
        ACTIVE.put(computerId, uuid);
    }

    public static Optional<UUID> getActive(int computerId) {
        return Optional.ofNullable(ACTIVE.get(computerId));
    }

    public static void clearForPlayer(UUID uuid) {
        ACTIVE.entrySet().removeIf(e -> e.getValue().equals(uuid));
    }

    /**
     * Returns the CC computer ID for the given block entity, or -1 if the block entity is not a
     * CC: Tweaked computer (or if reflection fails). CC's public API does not expose the computer
     * ID from a BlockEntity, so we resolve {@code getComputerID()} reflectively the first time we
     * see a computer block entity and cache the {@link Method}.
     */
    public static int extractComputerId(BlockEntity be) {
        if (be == null || reflectionFailed) return -1;
        var className = be.getClass().getName();
        if (!className.startsWith("dan200.computercraft.shared.computer.blocks.ComputerBlockEntity")) {
            return -1;
        }
        try {
            var m = getComputerIdMethod;
            if (m == null) {
                m = be.getClass().getMethod("getComputerID");
                m.setAccessible(true);
                getComputerIdMethod = m;
            }
            var result = m.invoke(be);
            if (result instanceof Integer i) return i;
            return -1;
        } catch (ReflectiveOperationException e) {
            reflectionFailed = true;
            return -1;
        }
    }
}
