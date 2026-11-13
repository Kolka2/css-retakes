// Round points: what the players earn during a round. The points decide who plays on
// which side in the next round (see BuildRankingQueue in teams.sp).
// Included only from retakes.sp.

/**
 * Returns if the 2 players should be fighting each other.
 * Returns false on friendly fire/suicides.
 */
static bool HelpfulAttack(int attacker, int victim) {
    if (!IsValidClient(attacker) || !IsValidClient(victim)) {
        return false;
    }
    return GetClientTeam(attacker) != GetClientTeam(victim) && attacker != victim;
}

/**
 * Called when a player dies - gives points to the killer.
 */
public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast) {
    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (victim > 0) {
        // for the respawn in the editor, see editor_freeplay.sp
        g_LastDeathTime[victim] = GetGameTime();
    }

    if (!Retakes_Live()) {
        return Plugin_Continue;
    }

    int attacker = GetClientOfUserId(event.GetInt("attacker"));

    bool validAttacker = IsValidClient(attacker);
    bool validVictim = IsValidClient(victim);

    if (DebugEnabled() && validVictim) {
        if (validAttacker) {
            DebugLog("kill: %N (team %d) killed %N (team %d)%s", attacker, GetClientTeam(attacker),
                     victim, GetClientTeam(victim), InIntermission() ? ", between rounds" : "");
        } else {
            DebugLog("kill: %N (team %d) died%s", victim, GetClientTeam(victim),
                     InIntermission() ? ", between rounds" : "");
        }
    }

    if (validAttacker && validVictim) {
        if (HelpfulAttack(attacker, victim)) {
            g_RoundPoints[attacker] += POINTS_KILL;
        } else {
            g_RoundPoints[attacker] -= POINTS_KILL;
        }
    }

    return Plugin_Continue;
}

/**
 * Called when a player deals damage to another player - adds round points if needed.
 */
public Action Event_DamageDealt(Event event, const char[] name, bool dontBroadcast) {
    if (!Retakes_Live()) {
        return Plugin_Continue;
    }

    int attacker = GetClientOfUserId(event.GetInt("attacker"));
    int victim = GetClientOfUserId(event.GetInt("userid"));

    if (HelpfulAttack(attacker, victim)) {
        int damage = event.GetInt("dmg_health");
        g_RoundPoints[attacker] += (damage * POINTS_DMG);
    }
    return Plugin_Continue;
}

/**
 * Called when the bomb explodes or is defused, gives points to the one that planted/defused it.
 */
public Action Event_Bomb(Event event, const char[] name, bool dontBroadcast) {
    if (!Retakes_Live()) {
        return Plugin_Continue;
    }

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (IsValidClient(client)) {
        g_RoundPoints[client] += POINTS_BOMB;
    }

    return Plugin_Continue;
}
