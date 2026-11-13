// The spawn editor's own small "endless round": while g_EditMode is set the round never
// ends and the dead respawn. Included only from retakes.sp.
// This does not depend on the warmup plugin; the editor works with or without it.

#define EDITOR_ROUND_TIME 3600      // seconds kept on the round clock
#define EDITOR_RESPAWN_DELAY 1.5    // seconds between a death and the respawn

float g_LastDeathTime[MAXPLAYERS+1];

/**
 * Keeps an hour on the round clock, so the round timer never runs out in the editor.
 */
void Editor_KeepRoundEndless() {
    int elapsed = 0;
    // CSS-VERIFY: CCSGameRulesProxy has m_fRoundStartTime (the end of the freeze time).
    if (FindSendPropInfo("CCSGameRulesProxy", "m_fRoundStartTime") != -1) {
        elapsed = RoundToFloor(GetGameTime() - GameRules_GetPropFloat("m_fRoundStartTime"));
        if (elapsed < 0) {
            elapsed = 0;
        }
    }
    SetRoundTime(elapsed + EDITOR_ROUND_TIME);
}

/**
 * Respawns the dead players. This covers both the players that were killed and the
 * ones that joined a team too late to be spawned by the game.
 */
static void RespawnDeadPlayers() {
    float now = GetGameTime();
    for (int i = 1; i <= MaxClients; i++) {
        if (!IsValidClient(i) || !IsOnTeam(i) || IsPlayerAlive(i)) {
            continue;
        }
        if (!HasPickedClass(i) || now - g_LastDeathTime[i] < EDITOR_RESPAWN_DELAY) {
            continue;
        }
        CS_RespawnPlayer(i);
    }
}

/**
 * Called once a second while the plugin is enabled.
 */
void Editor_OnSecondTick() {
    if (!g_EditMode) {
        return;
    }

    Editor_KeepRoundEndless();
    RespawnDeadPlayers();
}

/**
 * Blocks the end of the round in the editor, so the map is never reset under the editors.
 */
public Action CS_OnTerminateRound(float &delay, CSRoundEndReason &reason) {
    if (!g_Enabled || !g_EditMode) {
        return Plugin_Continue;
    }

    // "Game Commencing" is the game's own first restart (it resets the scores), let it through.
    if (reason == CSRoundEnd_GameStart) {
        return Plugin_Continue;
    }

    // CSS-VERIFY: Plugin_Handled here really cancels the end of the round in CS:S
    // (a team wiped out, the time ran out) and the game does not get stuck afterwards.
    return Plugin_Handled;
}
