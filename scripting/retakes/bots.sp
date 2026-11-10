// Управление ботами. Подключается только из retakes.sp.
//
// Боты - полноценные участники раундов (см. IsParticipant в generic.sp), но люди всегда
// в приоритете: бот занимает только место, на которое нет человека. Сколько ботов держать
// на сервере, решает плагин и выставляет это через bot_quota (bot_quota_mode normal).

ConVar g_hBotQuotaCvar;
bool g_BotQuotaMissingLogged;
bool g_BotLeaving[MAXPLAYERS+1]; // бот уже кикнут плагином, в раунд его не берём

/**
 * Returns the number of humans that play or wait in the queue.
 * Humans that sit in spectators by their own choice are not counted.
 */
stock int GetJoinedHumanCount() {
    int count = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsPlayer(i) && (IsOnTeam(i) || Queue_Find(g_hWaitingQueue, i) != -1)) {
            count++;
        }
    }
    return count;
}

/**
 * Returns if a client is a bot that can be given a slot in a round.
 */
stock bool IsUsableBot(int client) {
    return IsParticipant(client) && IsFakeClient(client) && !g_BotLeaving[client];
}

stock int GetUsableBotCount() {
    int count = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsUsableBot(i)) {
            count++;
        }
    }
    return count;
}

/**
 * Returns the number of participants (humans + bots) the plugin tries to keep
 * when there are not enough humans: sm_retakes_bots_total capped by sm_retakes_maxplayers.
 */
stock int GetBotsFillTarget() {
    if (g_hBots.IntValue == 0) {
        return 0;
    }

    int total = g_hBotsTotal.IntValue;
    int maxPlayers = g_hMaxPlayers.IntValue;
    if (total > maxPlayers) {
        total = maxPlayers;
    }
    return total;
}

/**
 * Returns how many bots should be on the server right now.
 */
stock int GetDesiredBotCount() {
    // В редакторе боты только мешают; без людей ботам играть не с кем.
    if (g_hBots.IntValue == 0 || g_EditMode) {
        return 0;
    }

    int humans = GetJoinedHumanCount();
    if (humans == 0) {
        return 0;
    }

    int desired = GetBotsFillTarget() - humans;
    int freeSlots = g_hMaxPlayers.IntValue - humans;
    if (desired > freeSlots) {
        desired = freeSlots;
    }
    if (desired < 0) {
        desired = 0;
    }
    return desired;
}

/**
 * Kicks the bots that are over the limit: the ones that are not on a team first,
 * then the ones with the fewest round points.
 */
static void KickExcessBots(int desired) {
    int excess = GetUsableBotCount() - desired;
    while (excess > 0) {
        int worst = -1;
        for (int i = 1; i <= MaxClients; i++) {
            if (!IsUsableBot(i)) {
                continue;
            }
            if (worst == -1) {
                worst = i;
                continue;
            }

            bool onTeam = IsOnTeam(i);
            bool worstOnTeam = IsOnTeam(worst);
            if ((!onTeam && worstOnTeam) || (onTeam == worstOnTeam && g_RoundPoints[i] < g_RoundPoints[worst])) {
                worst = i;
            }
        }

        if (worst == -1) {
            break;
        }

        DebugLog("bots: kicking %L to free a slot (bots wanted: %d)", worst, desired);
        g_BotLeaving[worst] = true;
        KickClient(worst, "Retakes: the slot is needed for a player");
        excess--;
    }
}

/**
 * Recalculates bot_quota.
 *
 * roundPrep is true when called from PrepareNextRound: only then the number of bots may
 * go down while the game is live (and the plugin itself picks which bots leave), so that
 * a bot is never removed in the middle of a round. In warmup/edit mode, or when there are
 * no humans at all, the quota is lowered right away and the game kicks the bots itself.
 */
public void UpdateBotQuota(bool roundPrep) {
    if (!g_Enabled) {
        return;
    }

    if (g_hBotQuotaCvar == null) {
        // CSS-VERIFY: в CS:S есть квар bot_quota, и при bot_quota_mode normal игра сама добавляет
        // и убирает ботов до этого числа (боты в наблюдателях тоже считаются).
        g_hBotQuotaCvar = FindConVar("bot_quota");
        if (g_hBotQuotaCvar == null) {
            if (!g_BotQuotaMissingLogged) {
                g_BotQuotaMissingLogged = true;
                LogError("The bot_quota cvar was not found, bots are not managed by retakes");
            }
            return;
        }
    }

    int desired = GetDesiredBotCount();
    int current = g_hBotQuotaCvar.IntValue;

    if (!roundPrep && desired < current && !InFreePlay() && GetJoinedHumanCount() > 0) {
        // Посреди живого раунда ботов не убираем - это сделает подготовка следующего раунда.
        return;
    }

    if (roundPrep) {
        KickExcessBots(desired);
    }

    if (current != desired) {
        DebugLog("bots: bot_quota %d -> %d (humans joined: %d, sm_retakes_bots_total: %d, sm_retakes_maxplayers: %d)",
                 current, desired, GetJoinedHumanCount(), g_hBotsTotal.IntValue, g_hMaxPlayers.IntValue);
        g_hBotQuotaCvar.SetInt(desired);
    }
}

/**
 * Returns the number of bots that are in game but have no slot in the current round
 * (they joined after the round was prepared).
 */
stock int GetUnassignedBotCount() {
    int count = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsUsableBot(i) && !IsAssigned(i)) {
            count++;
        }
    }
    return count;
}

/**
 * Picks the bomb carrier among the terrorists of the round.
 * With sm_retakes_bots_carry_bomb 0 a human is picked whenever there is one on the team.
 */
public int PickBombOwner() {
    ArrayList humans = new ArrayList();
    ArrayList everybody = new ArrayList();
    for (int i = 1; i <= MaxClients; i++) {
        if (IsParticipant(i) && g_Team[i] == CS_TEAM_T) {
            everybody.Push(i);
            if (!IsFakeClient(i)) {
                humans.Push(i);
            }
        }
    }

    int owner = -1;
    if (g_hBotsCarryBomb.IntValue == 0 && humans.Length >= 1) {
        owner = RandomElement(humans);
    } else if (everybody.Length >= 1) {
        // Если среди T одни боты, бомбу несёт бот даже при sm_retakes_bots_carry_bomb 0:
        // иначе раунд без бомбы не имел бы смысла.
        owner = RandomElement(everybody);
    }

    delete humans;
    delete everybody;
    return owner;
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

    // CSS-VERIFY: бот, переведённый в наблюдатели через ChangeClientTeam, остаётся там
    // (не возвращается в команду сам) до следующей подготовки раунда.
    DebugLog("round: %L spawned without a slot in this round, moving to spectators", client);
    SwitchPlayerTeam(client, CS_TEAM_SPECTATOR);
}
