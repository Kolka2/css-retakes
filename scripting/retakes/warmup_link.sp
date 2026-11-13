// Link to the optional warmup plugin (scripting/warmup.sp, include/warmup.inc).
// Included only from retakes.sp.
//
// Retakes has no warmup of its own. If the "warmup" library is loaded, retakes starts a
// warmup on map start (sm_retakes_warmuptime), stays out of the way while it runs - no
// teams, spawns, queue, money, bomb or weapon allocation - and begins the first retake
// when it ends. Without the library there is simply no warmup: Retakes_InWarmup() is
// always false and the map starts with a retake round.

bool g_WarmupLibrary;

public void OnAllPluginsLoaded() {
    g_WarmupLibrary = LibraryExists("warmup");
}

public void OnLibraryAdded(const char[] name) {
    if (StrEqual(name, "warmup")) {
        g_WarmupLibrary = true;
    }
}

public void OnLibraryRemoved(const char[] name) {
    if (StrEqual(name, "warmup")) {
        g_WarmupLibrary = false;
    }
}

/**
 * Returns if the warmup plugin is loaded and its natives can be called.
 */
bool WarmupAvailable() {
    return g_WarmupLibrary && GetFeatureStatus(FeatureType_Native, "Warmup_IsActive") == FeatureStatus_Available;
}

/**
 * Implementation of the Retakes_InWarmup() native. The rest of the plugin calls the
 * native, like the addons do.
 */
bool InWarmup() {
    return WarmupAvailable() && Warmup_IsActive();
}

/**
 * Returns if the plugin is in a "free play" state: the warmup or the spawn editor.
 * Retakes does not run rounds in either of them.
 */
bool InFreePlay() {
    return Retakes_InWarmup() || g_EditMode;
}

/**
 * Starts the map-start warmup, if the warmup plugin is there to run it.
 */
void StartMapWarmup() {
    int time = g_WarmupTimeCvar.IntValue;
    if (time > 0 && WarmupAvailable()) {
        Warmup_Start(time);
    }
}

/**
 * Leaves the warmup/editor and restarts the game; the first retake follows the restart.
 */
void GoLive() {
    DebugLog("going live (edit mode: %d), restarting the game", g_EditMode);
    g_EditMode = false;
    // The game restart zeroes the scoreboard, so the plugin's own progress (round points,
    // the T win streak, the round counter) starts over as well. This also drops any
    // prepared round: the round after the restart is prepared by Event_RoundStart, since
    // mp_restartgame does not fire round_end.
    ResetRetakesProgress();
    ServerCommand("mp_restartgame 1");
}

public void Warmup_OnStart(int seconds) {
    DebugLog("warmup: started, %d seconds", seconds);
}

/**
 * The warmup wants to end. While the spawn editor is open it has to wait: its end
 * restarts the game, which would throw the editors back to the map spawns.
 */
public Action Warmup_OnEnding() {
    if (g_Enabled && g_EditMode) {
        return Plugin_Handled;
    }
    return Plugin_Continue;
}

/**
 * The warmup is over: start the first retake. Nothing to do on a map change, and the
 * editor (if open) goes live on its own when it is closed.
 */
public void Warmup_OnEnd(WarmupEndReason reason) {
    DebugLog("warmup: ended, reason %d", reason);
    if (!g_Enabled || g_EditMode || reason == WarmupEnd_MapChange) {
        return;
    }
    GoLive();
}
