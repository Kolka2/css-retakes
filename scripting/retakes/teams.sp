// Teams: switching players, the join commands, the ranking queue and the team
// assignment for the next round. Included only from retakes.sp.

#define CSS_FIRST_T_CLASS 1
#define CSS_LAST_T_CLASS 4
#define CSS_FIRST_CT_CLASS 5
#define CSS_LAST_CT_CLASS 8

int GetOtherTeam(int team) {
    return (team == CS_TEAM_CT) ? CS_TEAM_T : CS_TEAM_CT;
}

/**
 * Counts the clients (humans and bots) on the T and CT teams.
 * ignoredClient is a client that is about to leave and must not be counted.
 */
void GetTeamCounts(int &tCount, int &ctCount, int ignoredClient = 0) {
    tCount = 0;
    ctCount = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (i == ignoredClient || !IsValidClient(i)) {
            continue;
        }
        if (GetClientTeam(i) == CS_TEAM_T) {
            tCount++;
        } else if (GetClientTeam(i) == CS_TEAM_CT) {
            ctCount++;
        }
    }
}

/**
 * Makes sure the client has a player class (model) that belongs to the team.
 * In CS:S a player without a valid class is not respawned on round restart, and a
 * player moved from spectators by the plugin never saw the class menu.
 */
static void EnsureClientClass(int client, int team) {
    // m_iClass: 1-4 are the T classes, 5-8 the CT classes. A player switched from
    // spectators by CS_SwitchTeam with the class set spawns at the round restart without
    // the model menu (seen on a live server).
    int class = GetEntProp(client, Prop_Send, "m_iClass");
    if (team == CS_TEAM_T) {
        if (class < CSS_FIRST_T_CLASS || class > CSS_LAST_T_CLASS) {
            SetEntProp(client, Prop_Send, "m_iClass", GetRandomInt(CSS_FIRST_T_CLASS, CSS_LAST_T_CLASS));
        }
    } else if (team == CS_TEAM_CT) {
        if (class < CSS_FIRST_CT_CLASS || class > CSS_LAST_CT_CLASS) {
            SetEntProp(client, Prop_Send, "m_iClass", GetRandomInt(CSS_FIRST_CT_CLASS, CSS_LAST_CT_CLASS));
        }
    }
}

/**
 * Returns if a player has picked a player class (model). In CS:S a player that joined
 * a team cannot spawn until the class menu is answered.
 */
bool HasPickedClass(int client) {
    // CSS-VERIFY: m_iClass is 0 until the player has picked a class (model).
    return GetEntProp(client, Prop_Send, "m_iClass") != 0;
}

/**
 * Switches a player to a new team.
 */
void SwitchPlayerTeam(int client, int team) {
    if (GetClientTeam(client) == team)
        return;

    g_PluginTeamSwitch[client] = true;
    if (team > CS_TEAM_SPECTATOR) {
        CS_SwitchTeam(client, team);
        EnsureClientClass(client, team);
        CS_UpdateClientModel(client);
    } else {
        ChangeClientTeam(client, team);
    }
    g_PluginTeamSwitch[client] = false;
}


/***********************
 *                     *
 *   Joining a team    *
 *                     *
 ***********************/

/**
 * Called when a player joins a team, silences team join events
 */
public Action Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)  {
    if (!g_Enabled) {
        return Plugin_Continue;
    }

    // The original plugin only set "silent" here. The CS:S client ignores that field and
    // prints "<player> is joining the ... force" for every switch (checked on a live server:
    // the chat filled up on every round), so the event is also kept from the clients.
    // Server-side listeners (other plugins) still receive it. The scoreboard and the team
    // counters are driven by networked properties and stay correct (checked as well).
    SetEventBool(event, "silent", true);
    event.BroadcastDisabled = true;
    return Plugin_Changed;
}

public Action Command_JoinTeam(int client, const char[] command, int argc) {
    if (!g_Enabled || g_hAutoTeamsCvar.IntValue == 0) {
        return Plugin_Continue;
    }

    if (!IsValidClient(client) || argc < 1)
        return Plugin_Handled;

    if (g_EditMode) {
        MovePlayerToEditMode(client);
        return Plugin_Handled;
    }

    // During the warmup the teams are not ours to manage: the game and the warmup plugin
    // handle joining and switching sides.
    if (Retakes_InWarmup()) {
        return Plugin_Continue;
    }

    char arg[4];
    GetCmdArg(1, arg, sizeof(arg));
    int team_to = StringToInt(arg);
    int team_from = GetClientTeam(client);

    if (g_PluginTeamSwitch[client] || IsFakeClient(client)) {
        return Plugin_Continue;
    }

    // note if a player hits autoselect their team_from=team_to=CS_TEAM_NONE
    if (team_from == team_to && team_from != CS_TEAM_NONE) {
        // Picking your own team again opens the model menu in CS:S, and changing the model
        // mid-round kills the player. Not allowed: T/CT can only be left for spectators.
        if (IsOnTeam(client)) {
            return Plugin_Handled;
        }
        return Plugin_Continue;
    }

    if (   (team_from == CS_TEAM_CT && team_to == CS_TEAM_T )
        || (team_from == CS_TEAM_T  && team_to == CS_TEAM_CT)) {
        // the plugin decides who plays on which side
        return Plugin_Handled;
    }

    if (team_to == CS_TEAM_SPECTATOR) {
        // voluntarily joining spectator will not put you in the queue
        SwitchPlayerTeam(client, CS_TEAM_SPECTATOR);
        Queue_Drop(g_hWaitingQueue, client);

        // check if a team is now empty
        CheckRoundDone();

        return Plugin_Handled;
    }

    EnqueueJoiningPlayer(client);
    return Plugin_Handled;
}

/**
 * Blocks changing the player model (class) while the game is live: in CS:S it kills the
 * player. The plugin sets the class itself when it puts a player on a team, so nobody
 * needs the class menu outside of the warmup and the editor.
 */
public Action Command_JoinClass(int client, const char[] command, int argc) {
    if (!g_Enabled || g_hAutoTeamsCvar.IntValue == 0 || InFreePlay()) {
        return Plugin_Continue;
    }

    if (!IsValidClient(client) || IsFakeClient(client)) {
        return Plugin_Continue;
    }

    // A player without a model (should not happen) must still be able to pick one.
    if (IsOnTeam(client) && HasPickedClass(client)) {
        return Plugin_Handled;
    }

    return Plugin_Continue;
}

/**
 * Puts a joining player into the waiting queue; the next round preparation takes it
 * from there. With fewer than two players on the teams the current round is ended
 * right away, so the player does not have to wait.
 */
static void EnqueueJoiningPlayer(int client) {
    int tCount, ctCount;
    GetTeamCounts(tCount, ctCount);
    int onTeams = tCount + ctCount;

    ChangeClientTeam(client, CS_TEAM_SPECTATOR);
    Queue_Enqueue(g_hWaitingQueue, client);

    if (onTeams < 2) {
        DebugLog("join: %L placed in the waiting queue, fewer than 2 players on teams - restarting the round", client);
        UpdateBotQuota(false);
        // Between rounds the next round is already prepared without this player:
        // the check in OnSecondTick picks the player up.
        if (!InIntermission()) {
            CS_TerminateRound(0.0, CSRoundEnd_CTWin);
        }
        return;
    }

    DebugLog("join: %L placed in the waiting queue (%d on teams)", client, onTeams);
    Retakes_Message(client, "%t", "JoinedQueueMessage");
    ShowGunsHint(client);
}

/**
 * Moves a player that spawned without a slot in the round (a bot added by the game
 * in the middle of a round) to spectators. It will be picked up by the next round.
 */
public void Frame_MoveUnassignedToSpectator(int userid) {
    int client = GetClientOfUserId(userid);
    if (!IsParticipant(client) || !IsOnTeam(client) || IsAssigned(client)) {
        return;
    }
    if (!g_Enabled || InFreePlay() || !g_TeamsValid || g_hAutoTeamsCvar.IntValue == 0) {
        return;
    }

    // CSS-VERIFY: a bot moved to spectators with ChangeClientTeam stays there (does not
    // rejoin a team by itself) until the next round preparation.
    DebugLog("round: %L spawned without a slot in this round, moving to spectators", client);
    SwitchPlayerTeam(client, CS_TEAM_SPECTATOR);
    if (!IsFakeClient(client)) {
        // a human (e.g. moved by an admin) goes to the queue to play the next round
        Queue_Enqueue(g_hWaitingQueue, client);
        Retakes_Message(client, "%t", "JoinedQueueMessage");
    }
}


/***********************
 *                     *
 * Teams of the round  *
 *                     *
 ***********************/

/**
 * Called at the end of the round - puts all the players into a priority queue by
 * their score for placing them next round.
 */
void BuildRankingQueue() {
    PQ_Clear(g_hRankingQueue);

    Call_StartForward(g_hOnPreRoundEnqueue);
    Call_PushCell(g_hRankingQueue);
    Call_PushCell(g_hWaitingQueue);
    Call_Finish();

    int maxPlayers = g_hMaxPlayers.IntValue;

    // Humans always come first: the ones that already play, ...
    for (int client = 1; client <= MaxClients; client++) {
        if (IsPlayer(client) && IsOnTeam(client)) {
            PQ_Enqueue(g_hRankingQueue, client, g_RoundPoints[client]);
        }
    }

    // ... then the humans from the waiting queue, ...
    while (!Queue_IsEmpty(g_hWaitingQueue) && PQ_GetSize(g_hRankingQueue) < maxPlayers) {
        int client = Queue_Dequeue(g_hWaitingQueue);
        if (IsPlayer(client)) {
            PQ_Enqueue(g_hRankingQueue, client, -POINTS_LOSS);
        }
    }

    // ... and only the slots left up to sm_retakes_bots_total go to bots. A bot never
    // takes the place of a human, but its points are ordinary: humans and bots swap
    // sides by the same rules.
    int fillTarget = GetBotsFillTarget();
    for (int client = 1; client <= MaxClients; client++) {
        if (PQ_GetSize(g_hRankingQueue) >= fillTarget) {
            break;
        }
        if (IsUsableBot(client)) {
            int points = IsOnTeam(client) ? g_RoundPoints[client] : -POINTS_LOSS;
            PQ_Enqueue(g_hRankingQueue, client, points);
        }
    }

    if (g_hAutoTeamsCvar.IntValue == 0) {
        PQ_Clear(g_hRankingQueue);
    }

    Call_StartForward(g_hOnPostRoundEnqueue);
    Call_PushCell(g_hRankingQueue);
    Call_PushCell(g_hWaitingQueue);
    Call_Finish();
}

/**
 * Splits the players of the ranking queue into team sizes (before any plugin
 * changes them through Retakes_OnTeamSizesSet).
 */
static void GetTeamSizes(int &players, int &numT, int &numCT) {
    players = PQ_GetSize(g_hRankingQueue);
    if (players > g_hMaxPlayers.IntValue)
        players = g_hMaxPlayers.IntValue;

    numT = RoundToNearest(g_hRatioConstant.FloatValue * float(players));
    if (numT < 1)
        numT = 1;

    numCT = players - numT;
}

/**
 * Places players onto the correct team.
 * This assumes the priority queue has already been built (see BuildRankingQueue).
 */
void UpdateTeams() {
    for (int i = 0; i < MAX_SPAWNS; i++) {
        g_SpawnTaken[i] = false;
    }

    if (!MapHasEnoughSpawns()) {
        return;
    }

    PickBombsite();

    GetTeamSizes(g_ActivePlayers, g_NumT, g_NumCT);
    Call_StartForward(g_hOnTeamSizesSet);
    Call_PushCellRef(g_NumT);
    Call_PushCellRef(g_NumCT);
    Call_Finish();

    AssignTeams();
    g_TeamsValid = true;
}

/**
 * Returns if the map has retake spawns at all; tells the players and the log if not.
 */
static bool MapHasEnoughSpawns() {
    if (g_NumSpawns >= g_hMaxPlayers.IntValue) {
        return true;
    }

    if (!g_NoSpawnsLogged) {
        g_NoSpawnsLogged = true;
        LogError("This map does not have enough spawns! (%d spawns, sm_retakes_maxplayers is %d)",
                 g_NumSpawns, g_hMaxPlayers.IntValue);
    }
    if (TranslationPhraseExists("NotEnoughSpawns")) {
        Retakes_MessageToAll("%t", "NotEnoughSpawns");
    } else {
        // an old translation file on the server must not break the round preparation
        Retakes_MessageToAll("{LIGHT_RED}This map does not have enough retake spawns. {NORMAL}An admin can create them with {GREEN}!edit");
    }
    return false;
}

/**
 * Picks the bombsite of the round. Only a site with enough spawns for the expected
 * teams is used: a map may be set up partially (e.g. spawns for A only).
 */
static void PickBombsite() {
    int players, numT, numCT;
    GetTeamSizes(players, numT, numCT);
    if (numCT < 0)
        numCT = 0;

    bool siteAOk = SiteHasSpawns(BombsiteA, numT, numCT);
    bool siteBOk = SiteHasSpawns(BombsiteB, numT, numCT);
    if (siteAOk && !siteBOk) {
        g_Bombsite = BombsiteA;
    } else if (siteBOk && !siteAOk) {
        g_Bombsite = BombsiteB;
    } else {
        g_Bombsite = GetRandomBool() ? BombsiteA : BombsiteB;
    }

    if (siteAOk != siteBOk) {
        DebugLog("prepare: only site %s has enough spawns for %d T + %d CT, using it",
                 SITESTRING(g_Bombsite), numT, numCT);
    } else if (!siteAOk && !g_SiteSpawnsLogged) {
        g_SiteSpawnsLogged = true;
        LogError("Neither bombsite has enough spawns for %d T + %d CT (run sm_retakes_validatespawns), some players will stay at the map spawns",
                 numT, numCT);
    }

    Call_StartForward(g_OnSitePicked);
    Call_PushCellRef(g_Bombsite);
    Call_Finish();
}

/**
 * Calls a forward that takes the two team lists and the bombsite.
 */
static void CallTeamsForward(Handle fwd, ArrayList ts, ArrayList cts) {
    Call_StartForward(fwd);
    Call_PushCell(ts);
    Call_PushCell(cts);
    Call_PushCell(g_Bombsite);
    Call_Finish();
}

/**
 * Puts a client on a team for the round, with the default loadout of that team
 * (a weapon allocator plugin replaces it in Retakes_OnWeaponsAllocated).
 */
static void AssignToTeam(int client, int team) {
    bool ct = (team == CS_TEAM_CT);
    SwitchPlayerTeam(client, team);
    g_Team[client] = team;
    strcopy(g_PlayerPrimary[client], WEAPON_STRING_LENGTH, ct ? "weapon_m4a1" : "weapon_ak47");
    strcopy(g_PlayerSecondary[client], WEAPON_STRING_LENGTH, ct ? "weapon_usp" : "weapon_glock");
    g_PlayerNades[client] = "";
    g_PlayerKit[client] = ct;
    g_PlayerHealth[client] = 100;
    g_PlayerArmor[client] = 100;
    g_PlayerHelmet[client] = true;
}

/**
 * Takes g_NumT + g_NumCT players from the ranking queue and puts them on the teams.
 */
static void AssignTeams() {
    bool autoTeams = g_hAutoTeamsCvar.IntValue != 0;

    if (g_ScrambleSignal || g_hUseRandomTeams.IntValue != 0) {
        int n = g_hRankingQueue.Length;
        for (int i = 0; i < n; i++) {
            int value = GetRandomInt(1, 1000);
            g_hRankingQueue.Set(i, value, 1);
            DebugLog("prepare: scramble, %L drew %d", g_hRankingQueue.Get(i, 0), value);
        }
        DebugLog("prepare: the teams are scrambled (%s): the highest draws play T",
                 g_ScrambleSignal ? "win streak or sm_scramble" : "sm_retakes_random_teams");
        g_ScrambleSignal = false;
    }

    ArrayList ts = new ArrayList();
    ArrayList cts = new ArrayList();

    if (autoTeams) {
        // Ordinary team switching by retakes
        for (int i = 0; i < g_NumT; i++) {
            int client = PQ_Dequeue(g_hRankingQueue);
            if (IsValidClient(client)) {
                ts.Push(client);
            }
        }

        for (int i = 0; i < g_NumCT; i++) {
            int client = PQ_Dequeue(g_hRankingQueue);
            if (IsValidClient(client)) {
                cts.Push(client);
            }
        }
    } else {
        // Use the already set teams (CS:S has no halftime side swap to undo)
        for (int i = 1; i <= MaxClients; i++) {
            if (IsValidClient(i)) {
                if (GetClientTeam(i) == CS_TEAM_CT)
                    cts.Push(i);
                else if (GetClientTeam(i) == CS_TEAM_T)
                    ts.Push(i);
            }
        }
        g_NumCT = cts.Length;
        g_NumT = ts.Length;
        g_ActivePlayers = g_NumCT + g_NumT;
    }

    CallTeamsForward(g_hOnTeamsSet, ts, cts);

    for (int i = 0; i < ts.Length; i++) {
        int client = ts.Get(i);
        if (IsValidClient(client)) {
            AssignToTeam(client, CS_TEAM_T);
        }
    }

    for (int i = 0; i < cts.Length; i++) {
        int client = cts.Get(i);
        if (IsValidClient(client)) {
            AssignToTeam(client, CS_TEAM_CT);
        }
    }

    // if somebody didn't get put in, put them back into the waiting queue
    while (!PQ_IsEmpty(g_hRankingQueue)) {
        int client = PQ_Dequeue(g_hRankingQueue);
        if (IsPlayer(client)) {
            Queue_EnqueueFront(g_hWaitingQueue, client);
        }
    }

    // Everybody who is on T/CT but did not get into the round (no room, a spare bot) goes
    // to spectators: otherwise the game would spawn them at a map spawn with the default
    // weapons.
    if (autoTeams) {
        for (int i = 1; i <= MaxClients; i++) {
            if (IsParticipant(i) && IsOnTeam(i) && !IsAssigned(i)) {
                SwitchPlayerTeam(i, CS_TEAM_SPECTATOR);
                if (!IsFakeClient(i)) {
                    Queue_Enqueue(g_hWaitingQueue, i);
                }
            }
        }
    }

    CallTeamsForward(g_OnWeaponsAllocated, ts, cts);

    int length = Queue_Length(g_hWaitingQueue);
    for (int i = 0; i < length; i++) {
        int client = g_hWaitingQueue.Get(i);
        if (IsValidClient(client)) {
            Retakes_Message(client, "%t", "WaitingQueueMessage", g_hMaxPlayers.IntValue);
        }
    }

    delete ts;
    delete cts;
}
