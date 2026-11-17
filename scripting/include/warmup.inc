#if defined _warmup_included
  #endinput
#endif
#define _warmup_included

#define WARMUP_LIBRARY     "warmup"
#define WARMUP_API_VERSION 1

/**
 * Why a warmup ended, see Warmup_OnEnd.
 */
enum WarmupEndReason {
    WarmupEnd_Finished = 0,   // the time ran out and/or enough players joined
    WarmupEnd_Forced,         // Warmup_End() or the sm_warmup_end command
    WarmupEnd_MapChange,      // the map is changing
    WarmupEnd_PluginUnload,   // the warmup plugin is being unloaded
};

/**
 * Called when a warmup starts (or is restarted while already running).
 *
 * @param seconds   length of the warmup in seconds, 0 if it has no time limit
 * @noreturn
 */
forward void Warmup_OnStart(int seconds);

/**
 * Called when the warmup is about to finish on its own: the time ran out and/or
 * the minimum number of players has been reached.
 *
 * Return Plugin_Handled (or higher) to keep the warmup running. The forward is
 * then called again every second until nobody objects.
 * It is not called when the warmup is ended by Warmup_End(), a map change or a plugin unload.
 *
 * @return          Plugin_Continue to let the warmup end, Plugin_Handled to extend it
 */
forward Action Warmup_OnEnding();

/**
 * Called after a warmup has ended and the cvars it changed have been restored.
 * With WarmupEnd_Finished and WarmupEnd_Forced the game may be about to restart,
 * see the sm_warmup_restart_delay cvar.
 *
 * @param reason    why the warmup ended
 * @noreturn
 */
forward void Warmup_OnEnd(WarmupEndReason reason);

/**
 * Returns if a warmup is running.
 */
native bool Warmup_IsActive();

/**
 * Starts a warmup. If one is already running it is restarted with the new length.
 *
 * @param seconds   length in seconds; 0 for no time limit; -1 to use sm_warmup_time
 * @return          true if the warmup is running now, false if the plugin is disabled
 */
native bool Warmup_Start(int seconds = -1);

/**
 * Ends the running warmup right away, without asking Warmup_OnEnding.
 * Warmup_OnEnd is called with WarmupEnd_Forced.
 *
 * @param restartGame   whether to restart the game afterwards (sm_warmup_restart_delay)
 * @return              true if a warmup was running
 */
native bool Warmup_End(bool restartGame = true);

/**
 * Returns the API version of the loaded plugin (compare with WARMUP_API_VERSION).
 * Plugins built against the first published include (without this native) only know
 * the natives and forwards above; all of them are part of version 1.
 */
native int Warmup_GetApiVersion();

public SharedPlugin __pl_warmup = {
    name = WARMUP_LIBRARY,
    file = "warmup.smx",
#if defined REQUIRE_PLUGIN
    required = 1,
#else
    required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_warmup_SetNTVOptional() {
    MarkNativeAsOptional("Warmup_IsActive");
    MarkNativeAsOptional("Warmup_Start");
    MarkNativeAsOptional("Warmup_End");
    MarkNativeAsOptional("Warmup_GetApiVersion");
}
#endif
