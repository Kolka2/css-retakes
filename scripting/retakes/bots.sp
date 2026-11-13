// Bot management. Included only from retakes.sp.
//
// Bots are full participants of the rounds (see IsParticipant in generic.sp), but humans
// always come first: a bot only takes a slot no human wants. The plugin decides how many
// bots to keep on the server and sets it through bot_quota (bot_quota_mode normal).

ConVar g_hBotQuotaCvar;
bool g_BotQuotaMissingLogged;
bool g_BotLeaving[MAXPLAYERS+1]; // the bot has been kicked by the plugin, do not put it in a round

/**
 * Returns the number of humans that play or wait in the queue.
 * Humans that sit in spectators by their own choice are not counted.
 */
int GetJoinedHumanCount() {
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
bool IsUsableBot(int client) {
    return IsParticipant(client) && IsFakeClient(client) && !g_BotLeaving[client];
}

static int GetUsableBotCount() {
    int count = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsUsableBot(i)) {
            count++;
        }
    }
    return count;
}

/**
 * Returns the number of bots that are in game but have no slot in the current round
 * (they joined after the round was prepared).
 */
int GetUnassignedBotCount() {
    int count = 0;
    for (int i = 1; i <= MaxClients; i++) {
        if (IsUsableBot(i) && !IsAssigned(i)) {
            count++;
        }
    }
    return count;
}

/**
 * Returns the number of participants (humans + bots) the plugin tries to keep
 * when there are not enough humans: sm_retakes_bots_total capped by sm_retakes_maxplayers.
 */
int GetBotsFillTarget() {
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
static int GetDesiredBotCount() {
    // Bots only get in the way in the editor; without humans they have nobody to play with.
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
void UpdateBotQuota(bool roundPrep) {
    if (!g_Enabled) {
        return;
    }

    if (g_hBotQuotaCvar == null) {
        // With bot_quota_mode normal the game itself adds and removes bots up to bot_quota
        // (bots in spectators count as well); seen on a live server.
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
        // Bots are not removed in the middle of a live round: the preparation of the
        // next round does it.
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
