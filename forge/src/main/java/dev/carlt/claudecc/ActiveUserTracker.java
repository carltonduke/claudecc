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
    private static volatile Method createServerComputerMethod;
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
     * CC: Tweaked computer or turtle (or if reflection fails). CC's public API does not expose the
     * computer ID from a BlockEntity, so we resolve {@code getComputerID()} reflectively the first
     * time we see a computer-family block entity and cache the {@link Method}.
     * <p>
     * A freshly placed computer hasn't been server-ticked yet, so its ID is still unassigned (-1)
     * at right-click time. In that case we force CC to create the server computer (which assigns and
     * persists the ID) and read it again, so the very first right-click can claim the computer.
     * Must only be called server-side (callers guard on the logical side).
     */
    public static int extractComputerId(BlockEntity be) {
        if (be == null || reflectionFailed) return -1;
        if (!isComputerFamily(be.getClass())) {
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
            int id = result instanceof Integer i ? i : -1;

            if (id < 0) {
                // Computer not created/ticked yet: createServerComputer() assigns the ID. It's
                // idempotent (returns the existing computer if already created). Fail soft so a
                // one-off hiccup here doesn't permanently disable claiming via reflectionFailed.
                try {
                    var create = createServerComputerMethod;
                    if (create == null) {
                        create = be.getClass().getMethod("createServerComputer");
                        create.setAccessible(true);
                        createServerComputerMethod = create;
                    }
                    create.invoke(be);
                    var retry = m.invoke(be);
                    id = retry instanceof Integer i ? i : -1;
                } catch (ReflectiveOperationException ignored) {
                    // Leave id as -1; the next right-click (after the computer ticks) will claim it.
                }
            }
            return id;
        } catch (ReflectiveOperationException e) {
            reflectionFailed = true;
            return -1;
        }
    }

    /**
     * Both CC computers and turtles extend {@code AbstractComputerBlockEntity}, which declares
     * {@code getComputerID()}. Walk the superclass chain to detect either, so that turtles (in the
     * {@code ...shared.turtle.blocks} package) are recognised as well as plain computers.
     */
    private static boolean isComputerFamily(Class<?> cls) {
        for (Class<?> c = cls; c != null; c = c.getSuperclass()) {
            if (c.getName().equals(
                    "dan200.computercraft.shared.computer.blocks.AbstractComputerBlockEntity")) {
                return true;
            }
        }
        return false;
    }
}
