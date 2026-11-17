// Round flow: preparing the next round after round_end, placing the players at
// round_start, counting the result at round_end. Included only from retakes.sp.
// The steps of a round are listed next to g_PreparePending in retakes.sp.

/**
 * Returns if the plugin put the client on a team for the current round.
 */
bool IsAssigned(int client) {
    return g_Team[client] == CS_TEAM_T || g_Team[client] == CS_TEAM_CT;
}

/**
 * Returns if a round has ended and the next one has not started yet.
 */
bool InIntermission() {
    return g_PreparePending || g_RoundPrepared;
}

static void ResetRoundPoints() {
    for (int i = 1; i <= MaxClients; i++) {
        g_RoundPoints[i] = 0;
    }
}

/**
 * Called once a second while the plugin is enabled.
 */
void OnSecondTick() {
    UpdateBotQuota(false);

    if (InFreePlay() || InIntermission() || !g_TeamsValid || g_hAutoTeamsCvar.IntValue == 0) {
        return;
    }

    // Fewer than two participants play the round while somebody could fill it (a human
    // joined between rounds, the game has just added the bots): do not wait for the
    // round to end, start the next one.
    bool humansWaiting = !Queue_IsEmpty(g_hWaitingQueue);
    bool botsWaiting = GetUnassignedBotCount() > 0 && g_ActivePlayers < GetBotsFillTarget();
    if (g_ActivePlayers < 2 && (humansWaiting || botsWaiting)) {
        DebugLog("round: only %d active player(s) while others are waiting, restarting the round", g_ActivePlayers);
        CS_TerminateRound(1.0, CSRoundEnd_Draw);
    }

    // A round with two or more participants is left alone, even if some bots wait in
    // spectators: the game adds bots one at a time, so the first round after the editor
    // or on an empty server may be played 1v1. Known and accepted (see PORT/PROGRESS.md).
}

/**
 * Sets up everything for the next round: the ranking queue, the teams, the bombsite and
 * the bomb carrier. This is what round_prestart did in CS:GO; CS:S has no such event, so:
 *  - normally this runs one frame after round_end (see Event_RoundEnd), i.e. before the
 *    game restarts the round and respawns the players in their new teams;
 *  - if a round starts without it (first round, mp_restartgame), Event_RoundStart runs it.
 * It never runs twice for the same round, and it does not move or equip anybody:
 * that is PlacePlayers().
 */
void PrepareNextRound() {
    g_PreparePending = false;
    g_RoundPrepared = true;
    g_TeamsValid = false;
    g_BombOwner = -1;
    g_BombHandedOut = false;

    for (int i = 1; i <= MaxClients; i++) {
        g_SpawnIndices[i] = -1;
        g_Team[i] = CS_TEAM_SPECTATOR;
    }

    // The bot count goes first: if more humans have joined, the spare bots leave before
    // the teams are built.
    UpdateBotQuota(true);
    BuildRankingQueue();
    UpdateTeams();
    g_BombOwner = PickBombOwner();
    DebugLogPreparedRound();
}

/**
 * Writes the outcome of PrepareNextRound to the debug log.
 */
static void DebugLogPreparedRound() {
    if (!DebugEnabled()) {
        return;
    }

    if (!g_TeamsValid) {
        DebugLog("prepare: teams were NOT set (spawns on the map: %d, sm_retakes_maxplayers: %d)",
                 g_NumSpawns, g_hMaxPlayers.IntValue);
        return;
    }

    DebugLog("prepare: site %s, %d T vs %d CT (active players: %d), waiting queue: %d",
             SITESTRING(g_Bombsite), g_NumT, g_NumCT, g_ActivePlayers, Queue_Length(g_hWaitingQueue));
    for (int i = 1; i <= MaxClients; i++) {
        if (IsParticipant(i) && IsAssigned(i)) {
            DebugLog("prepare:   %s %L, points %d%s", TEAMSTRING(g_Team[i]), i, g_RoundPoints[i],
                     (i == g_BombOwner) ? ", BOMB CARRIER" : "");
        }
    }
}

public void Frame_PrepareNextRound(any serial) {
    // If the round has already started within this frame (or the map changed),
    // Event_RoundStart has prepared it.
    if (!g_PreparePending || serial != g_RoundSerial || !Retakes_Live()) {
        g_PreparePending = false;
        return;
    }

    // CS_SwitchTeam on a living player between round_end and the round restart does not
    // kill the player, and after the restart everybody spawns on the new team (seen in a
    // few hundred rounds on a live server).
    PrepareNextRound();
}

/**
 * Puts everybody that plays the round on a retake spawn and gives the weapons.
 * Called once per round, from round_start, when the game has respawned the players.
 */
static void PlacePlayers() {
    // Somebody who left the team after the round was prepared (went to spectators)
    // does not play it.
    for (int i = 1; i <= MaxClients; i++) {
        if (IsAssigned(i) && (!IsParticipant(i) || GetClientTeam(i) != g_Team[i])) {
            g_Team[i] = CS_TEAM_SPECTATOR;
        }
    }

    // The bomb carrier picks first: there are fewer spawns that suit it.
    if (IsParticipant(g_BombOwner) && IsAssigned(g_BombOwner)) {
        g_SpawnIndices[g_BombOwner] = SelectSpawn(CS_TEAM_T, true);
    }
    for (int i = 1; i <= MaxClients; i++) {
        if (i != g_BombOwner && IsAssigned(i)) {
            g_SpawnIndices[i] = SelectSpawn(g_Team[i], false);
        }
    }

    for (int i = 1; i <= MaxClients; i++) {
        if (!IsAssigned(i)) {
            continue;
        }

        // The game respawns everybody on a team at round restart, including the players
        // the plugin moved in from spectators (seen on a live server). This is a safety net.
        // A player who has not picked a model is not spawned by the game: the plugin
        // picks one and closes the model menu before respawning the player.
        if (!IsPlayerAlive(i)) {
            if (!HasPickedClass(i)) {
                DebugLog("round_start: %L has not picked a model, giving a random one and closing the model menu", i);
                CloseClassMenu(i);
            }
            DebugLog("round_start: %L was not spawned by the game, respawning", i);
            CS_RespawnPlayer(i);
        }
        if (IsPlayerAlive(i)) {
            SetupPlayer(i);
        }
    }
}

/**
 * Sets up a player for the round: teleports to the retake spawn and gives the weapons.
 */
static void SetupPlayer(int client) {
    int spawnIndex = g_SpawnIndices[client];
    if (spawnIndex < 0) {
        DebugLog("spawn: %L has no retake spawn this round, left at the map spawn", client);
        return;
    }

    TeleportEntity(client, g_SpawnPoints[spawnIndex], g_SpawnAngles[spawnIndex], NULL_VECTOR);
    GiveWeapons(client);
    DebugLog("spawn: %L -> %s spawn #%d, \"%s\" + \"%s\", nades \"%s\", armor %d, helmet %d, kit %d",
             client, TEAMSTRING(g_Team[client]), spawnIndex, g_PlayerPrimary[client], g_PlayerSecondary[client],
             g_PlayerNades[client], g_PlayerArmor[client], g_PlayerHelmet[client], g_PlayerKit[client]);
}

/**
 * Called when a player spawns. The players of a round are placed by PlacePlayers() at
 * round_start, not here: a spawn in the middle of a round never moves or re-equips anybody.
 */
public Action Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast) {
    if (!g_Enabled) {
        return Plugin_Continue;
    }

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (!IsValidClient(client) || !IsOnTeam(client))
        return Plugin_Continue;

    // In CS:S player_spawn also fires when a player joins the server and is still dead.
    if (!IsPlayerAlive(client))
        return Plugin_Continue;

    ShowGunsHint(client);

    // Nothing to do in the warmup (the warmup plugin owns it) or in the editor.
    if (InFreePlay()) {
        return Plugin_Continue;
    }

    // No slot in this round: a bot the game added in the middle of a round.
    if (g_TeamsValid && !IsAssigned(client) && g_hAutoTeamsCvar.IntValue != 0) {
        RequestFrame(Frame_MoveUnassignedToSpectator, GetClientUserId(client));
    }

    return Plugin_Continue;
}

/**
 * Round start. In CS:S the players have already been respawned when this event fires.
 */
public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast) {
    g_RoundSerial++;
    g_bombPlanted = false;

    if (!g_Enabled) {
        return Plugin_Continue;
    }

    if (InFreePlay()) {
        if (g_EditMode) {
            Editor_KeepRoundEndless();
        }
        return Plugin_Continue;
    }

    // A round_end handled in this very frame has not been prepared yet, and never will be.
    bool roundEnded = g_PreparePending;
    g_PreparePending = false;

    if (g_RoundPrepared) {
        DebugLog("round_start: using the teams prepared after round_end");
    } else {
        if (!roundEnded) {
            // A round that starts without a round_end is a game restart (mp_restartgame,
            // by hand or after the warmup/editor). The game has zeroed the scoreboard, so
            // the plugin's own progress (win streak, points, round counter) starts over too.
            DebugLog("round_start: the game was restarted, resetting the retakes progress");
            ResetRetakesProgress();
        }
        DebugLog("round_start: the round was not prepared after round_end, preparing now");
        PrepareNextRound();
    }
    g_RoundPrepared = false;

    ResetRoundPoints();

    if (!g_TeamsValid) {
        // No retake this round (the map has no spawns): FixBomb() will not run, so the
        // game's own bomb must stay usable.
        g_BombHandedOut = true;
        return Plugin_Continue;
    }

    // Checked on a live CS:S server: teleporting and re-equipping the players inside the round_start handler
    // works like it did in player_spawn: everybody starts on the retake spawn with the
    // right weapons, and a player whose team was switched right here (unprepared round)
    // needs no respawn.
    PlacePlayers();

    // Checked on a live CS:S server: when m_iRoundTime runs out with no bomb planted the CTs win (Target Saved),
    // and once the bomb is planted this timer no longer ends the round.
    SetRoundTime(g_hRoundTime.IntValue);
    Retakes_MessageToAll("%t", "RetakeSiteMessage", SITESTRING(g_Bombsite), g_NumT, g_NumCT);

    CreateTimer(0.1, Timer_FixBomb, g_RoundSerial, TIMER_FLAG_NO_MAPCHANGE);
    return Plugin_Continue;
}

/**
 * Hands out the bomb shortly after the round start, when the game has given its own C4.
 */
public Action Timer_FixBomb(Handle timer, any serial) {
    if (serial == g_RoundSerial && Retakes_Live() && g_TeamsValid) {
        FixBomb();
    }
    return Plugin_Handled;
}

/**
 * Round freezetime end, resets the round points.
 */
public Action Event_RoundFreezeEnd(Event event, const char[] name, bool dontBroadcast) {
    ResetRoundPoints();
    return Plugin_Continue;
}

/**
 * Round end event, calls the appropriate winner (T/CT) function and sets the scores.
 */
public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast) {
    if (!Retakes_Live()) {
        return Plugin_Continue;
    }

    // A second round_end before the next round starts (e.g. CS_TerminateRound because a
    // player left): the round is already counted and the next one is already prepared.
    if (InIntermission()) {
        DebugLog("round_end: ignored, the next round is already being prepared");
        return Plugin_Continue;
    }

    int winner = event.GetInt("winner");
    DebugLog("round_end: winner team %d, reason %d, bomb planted: %d, active players: %d",
             winner, event.GetInt("reason"), g_bombPlanted, g_ActivePlayers);

    // A winner other than T/CT is a draw or "Game Commencing": the points are left alone.
    if (g_ActivePlayers >= 2 && g_TeamsValid && (winner == CS_TEAM_T || winner == CS_TEAM_CT)) {
        g_RoundCount++;

        ArrayList ts = new ArrayList();
        ArrayList cts = new ArrayList();

        for (int i = 1; i <= MaxClients; i++) {
            if (IsParticipant(i)) {
                if (GetClientTeam(i) == CS_TEAM_CT)
                    cts.Push(i);
                else if (GetClientTeam(i) == CS_TEAM_T)
                    ts.Push(i);
            }
        }

        Call_StartForward(g_OnRoundWon);
        Call_PushCell(winner);
        Call_PushCell(ts);
        Call_PushCell(cts);
        Call_Finish();

        delete ts;
        delete cts;

        for (int i = 1; i <= MaxClients; i++) {
            if (IsParticipant(i) && IsOnTeam(i) && GetClientTeam(i) != winner) {
                g_RoundPoints[i] -= POINTS_LOSS;
            }
        }

        if (winner == CS_TEAM_T) {
            TerroristsWon();
        } else if (winner == CS_TEAM_CT) {
            CounterTerroristsWon();
        }
    }

    // "Game Commencing" is the game's own restart and zeroes the scoreboard as well.
    if (event.GetInt("reason") == view_as<int>(CSRoundEnd_GameStart)) {
        DebugLog("round_end: game commencing, resetting the retakes progress");
        ResetRetakesProgress();
    }

    // The teams of the next round are set on the next frame, before the round restarts.
    // Not a timer: with CS_TerminateRound and a delay of 0.0-0.1 a timer could be late.
    // (Switching "0.3 s before the restart" was tried: it gave a visible hitch before the
    // round start - the team switch and the respawn came back to back - and was dropped.)
    g_PreparePending = true;
    RequestFrame(Frame_PrepareNextRound, g_RoundSerial);

    return Plugin_Continue;
}

static bool ScramblesEnabled() {
    return g_hRoundsToScramble.IntValue >= 1;
}

static void TerroristsWon() {
    int toScramble = g_hRoundsToScramble.IntValue;
    g_WinStreak++;

    if (g_WinStreak >= toScramble) {
        if (ScramblesEnabled()) {
            g_ScrambleSignal = true;
            Retakes_MessageToAll("%t", "ScrambleMessage", g_WinStreak);
        }
        g_WinStreak = 0;
    } else if (g_WinStreak >= toScramble - 3 && ScramblesEnabled()) {
        Retakes_MessageToAll("%t", "WinStreakAlmostToScramble", g_WinStreak, toScramble - g_WinStreak);
    } else if (g_WinStreak >= 3) {
        Retakes_MessageToAll("%t", "WinStreak", g_WinStreak);
    }
}

static void CounterTerroristsWon() {
    // The original plugin stayed silent here during the first two rounds
    // (g_RoundCount >= 3); the threshold was dropped by the owner's decision.
    if (!g_bombPlanted && IsValidClient(g_BombOwner)) {
        Retakes_MessageToAll("%t", "FailedToPlant", g_BombOwner);
        Call_StartForward(g_OnFailToPlant);
        Call_PushCell(g_BombOwner);
        Call_Finish();
    }

    if (g_WinStreak >= 3) {
        Retakes_MessageToAll("%t", "WinStreakOver", g_WinStreak);
    }

    g_WinStreak = 0;
}

/**
 * Ends the round if one of the teams has no players left.
 * ignoredClient is a client that is about to leave and must not be counted.
 */
void CheckRoundDone(int ignoredClient = 0) {
    if (!g_Enabled || InFreePlay()) {
        return;
    }

    // Nothing to end between round_end and the start of the next round.
    if (InIntermission()) {
        return;
    }

    int tCount = 0, ctCount = 0;
    GetTeamCounts(tCount, ctCount, ignoredClient);
    if (tCount == 0 || ctCount == 0) {
        CS_TerminateRound(0.1, CSRoundEnd_TerroristWin);
    }
}

/**
 * Forgets everything the plugin has accumulated on this map: round points, the T win
 * streak, a pending scramble, the round counter and the prepared round. The waiting
 * queue, the spawns and the cvars are left alone.
 */
void ResetRetakesProgress() {
    ResetRoundPoints();
    for (int i = 1; i <= MaxClients; i++) {
        g_SpawnIndices[i] = -1;
        g_Team[i] = CS_TEAM_SPECTATOR;
    }

    g_WinStreak = 0;
    g_RoundCount = 0;
    g_ScrambleSignal = false;

    g_PreparePending = false;
    g_RoundPrepared = false;
    g_TeamsValid = false;

    g_BombOwner = -1;
    g_BombHandedOut = false;
    g_SelectBombClient = -1;
    g_bombPlanted = false;
}
