// The bomb: who carries it, handing it out at the round start and putting it into the
// carrier's hands. Included only from retakes.sp.

#define SELECT_BOMB_WINDOW 3.0   // seconds after the handout to keep trying to select the C4

int g_SelectBombClient = -1;     // the human bomb carrier that still has to pull out the C4
float g_SelectBombUntil;
bool g_BombHandedOut;            // FixBomb() has run for the current round

/**
 * Called when the bomb is planted.
 */
public Action Event_BombPlant(Event event, const char[] name, bool dontBroadcast) {
    if (!g_Enabled) {
        return Plugin_Continue;
    }

    g_bombPlanted = true;

    return Plugin_Continue;
}

/**
 * Picks the bomb carrier among the terrorists of the round.
 * With sm_retakes_bots_carry_bomb 0 a human is picked whenever there is one on the team.
 */
int PickBombOwner() {
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
        // With only bots on the T team a bot carries the bomb even with
        // sm_retakes_bots_carry_bomb 0: a round without the bomb would make no sense.
        owner = RandomElement(everybody);
    }

    delete humans;
    delete everybody;
    return owner;
}

/**
 * Returns the weapon_c4 entity carried by a client, or -1.
 */
int GetClientC4(int client) {
    char classname[32];
    int size = GetEntPropArraySize(client, Prop_Send, "m_hMyWeapons");
    for (int i = 0; i < size; i++) {
        int weapon = GetEntPropEnt(client, Prop_Send, "m_hMyWeapons", i);
        if (weapon > MaxClients && IsValidEntity(weapon)
            && GetEntityClassname(weapon, classname, sizeof(classname))
            && StrEqual(classname, "weapon_c4")) {
            return weapon;
        }
    }
    return -1;
}

/**
 * Keeps the C4 away from everybody but the bomb carrier until FixBomb() has run.
 *
 * On every round restart CS:S gives a C4 to a random terrorist. FixBomb() takes it away
 * 0.1 s later, but by then that player has already been told "You have the bomb" (seen on
 * a live server: the hint showed up for players that never carried the bomb). Refusing the
 * pickup leaves the game's C4 on the ground, where FixBomb() removes it.
 * After FixBomb() anybody may pick the bomb up, e.g. when the carrier dies.
 */
public Action Hook_WeaponCanUse(int client, int weapon) {
    if (!g_Enabled || g_BombHandedOut || client == g_BombOwner || InFreePlay()) {
        return Plugin_Continue;
    }

    char classname[32];
    if (!IsValidEntity(weapon) || !GetEntityClassname(weapon, classname, sizeof(classname))
        || !StrEqual(classname, "weapon_c4")) {
        return Plugin_Continue;
    }

    // CSS-VERIFY: the refused C4 does not confuse the bots or the radar.
    DebugLog("bomb: refused the C4 the game tried to give to %L", client);
    return Plugin_Handled;
}

/**
 * Hooks the user messages the "You have the bomb" hint may travel in.
 */
void HookBombHintMessages() {
    static char names[][] = { "HintText", "TextMsg" };
    for (int i = 0; i < sizeof(names); i++) {
        UserMsg id = GetUserMessageId(names[i]);
        if (id != INVALID_MESSAGE_ID) {
            HookUserMessage(id, Hook_BombHintMessage, true);
        }
    }
}

/**
 * Drops the "You have the bomb" hint for a player that is not carrying the bomb.
 *
 * Refusing the game's C4 in Hook_WeaponCanUse did not stop the hint (checked on a live
 * server), so the message itself is filtered here. The text is looked for in every string
 * of the message, whatever its layout is.
 */
public Action Hook_BombHintMessage(UserMsg msg_id, BfRead msg, const int[] players, int playersNum, bool reliable, bool init) {
    if (!g_Enabled || playersNum != 1 || InFreePlay()) {
        return Plugin_Continue;
    }

    bool bombHint = false;
    char buffer[192];
    while (!bombHint && msg.BytesLeft > 0) {
        msg.ReadString(buffer, sizeof(buffer));
        bombHint = StrContains(buffer, "you_have_the_bomb", false) != -1;
    }
    if (!bombHint) {
        return Plugin_Continue;
    }

    // Before FixBomb() only the chosen carrier is told; after it, whoever holds the C4.
    int client = players[0];
    bool carrier = g_BombHandedOut ? (IsValidClient(client) && GetClientC4(client) != -1)
                                   : (client == g_BombOwner);
    if (carrier) {
        return Plugin_Continue;
    }

    // CSS-VERIFY: the hint travels in HintText or TextMsg with "you_have_the_bomb" in it,
    // and blocking the message hides it.
    DebugLog("bomb: blocked the \"you have the bomb\" hint for %L", client);
    return Plugin_Handled;
}

/**
 * Makes sure there is exactly one C4 in the game and the bomb carrier has it.
 * CS:S has no mp_give_player_c4: on every round restart the game itself gives a C4 to a
 * random terrorist (after the players have spawned), so this runs shortly after round_start.
 */
void FixBomb() {
    g_SelectBombClient = -1;

    // The carrier may have left between the round preparation and its start: take
    // another living terrorist.
    if (!IsValidClient(g_BombOwner) || !IsPlayerAlive(g_BombOwner) || GetClientTeam(g_BombOwner) != CS_TEAM_T) {
        g_BombOwner = PickBombOwner();
        if (g_BombOwner != -1 && (!IsPlayerAlive(g_BombOwner) || GetClientTeam(g_BombOwner) != CS_TEAM_T)) {
            g_BombOwner = -1;
        }
        DebugLog("bomb: the bomb carrier is gone, new carrier: %d", g_BombOwner);
    }

    int keep = -1;
    if (g_BombOwner != -1) {
        keep = GetClientC4(g_BombOwner);
    }

    // CSS-VERIFY: removing the spare weapon_c4 entities (RemovePlayerItem + Kill) breaks
    // nothing (the radar, the bots, the win conditions).
    for (int i = 1; i <= MaxClients; i++) {
        if (i == g_BombOwner || !IsValidClient(i) || !IsPlayerAlive(i)) {
            continue;
        }
        int c4 = GetClientC4(i);
        if (c4 != -1) {
            DebugLog("bomb: removing the C4 the game gave to %L", i);
            RemovePlayerItem(i, c4);
            AcceptEntityInput(c4, "Kill");
        }
    }

    // Bombs lying on the ground (refused by Hook_WeaponCanUse, dropped in the last round
    // or on a team switch).
    int entity = -1;
    while ((entity = FindEntityByClassname(entity, "weapon_c4")) != -1) {
        if (entity != keep) {
            AcceptEntityInput(entity, "Kill");
        }
    }

    // From here on the bomb can change hands freely (see Hook_WeaponCanUse).
    g_BombHandedOut = true;

    if (g_BombOwner == -1) {
        DebugLog("bomb: there is nobody to carry the bomb this round");
        return;
    }

    if (keep == -1) {
        keep = GivePlayerItem(g_BombOwner, "weapon_c4");
        if (keep == -1) {
            LogError("Failed to give weapon_c4 to %L", g_BombOwner);
            return;
        }
        DebugLog("bomb: C4 given to %L", g_BombOwner);
    } else {
        DebugLog("bomb: %L already has the C4", g_BombOwner);
    }

    // A human carrier gets the C4 into the hands right away. Bots do not need it: they
    // plant the bomb on their own.
    if (!IsFakeClient(g_BombOwner)) {
        g_SelectBombClient = g_BombOwner;
        g_SelectBombUntil = GetGameTime() + SELECT_BOMB_WINDOW;
    }
}

/**
 * Puts the C4 into the hands of the human bomb carrier.
 *
 * Weapon selection in Source is driven by the client: the "use"/"slotN" commands are
 * client-side, so FakeClientCommand(client, "use weapon_c4") does nothing on the server
 * (checked on a live CS:S server). The supported server-side way is to fill the
 * weapon-select field of the player's user command, which is what this hook does for
 * a short time after the bomb was handed out (checked on a live server as well).
 */
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3],
                             int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2]) {
    if (client != g_SelectBombClient) {
        return Plugin_Continue;
    }

    if (GetGameTime() > g_SelectBombUntil || g_bombPlanted || client != g_BombOwner || !IsPlayerAlive(client)) {
        g_SelectBombClient = -1;
        return Plugin_Continue;
    }

    int c4 = GetClientC4(client);
    if (c4 == -1) {
        g_SelectBombClient = -1;
        return Plugin_Continue;
    }

    if (GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon") == c4) {
        DebugLog("bomb: %L now holds the C4", client);
        g_SelectBombClient = -1;
        return Plugin_Continue;
    }

    // If the player picks a weapon in this very tick, stay out of the way.
    if (weapon != 0) {
        return Plugin_Continue;
    }

    weapon = c4;
    return Plugin_Changed;
}
